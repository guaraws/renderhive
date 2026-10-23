require "etc"
require "concurrent"

module Renderhive
  # Persistent thread-pool executor used by Renderhive::ViewParallelism.
  #
  # Highlights:
  # - Reuses a single `Concurrent::ThreadPoolExecutor` across requests.
  # - Falls back to `:caller_runs` when the pool is saturated, so the request
  #   thread degrades gracefully instead of blocking the queue.
  # - Splits work into one task per worker (chunked) to amortize scheduling.
  # - Optional `needs_db:` toggles the ActiveRecord `with_connection` wrap so
  #   pure-CPU tasks (e.g. partial rendering with no queries) don't reserve a
  #   connection.
  # - Caches the `Rails.application.executor` lookup.
  class Executor
    DEFAULT_IDLE_TIMEOUT = 60
    VALID_WORKLOADS = %i[ auto io cpu ].freeze

    class << self
      # `profile:` (a Renderhive::WorkloadProfile) lets `workload: :auto`
      # collapse to a single inline worker when measurements show the work is
      # GVL bound, i.e. parallelism cannot pay for its own overhead.
      def worker_count_for(size, max_threads: nil, workload: :auto, profile: nil)
        return 0 if size.to_i <= 0

        normalized = normalize_workload(workload)
        workers = resolve_workers_count(size, max_threads, normalized)
        return 1 if normalized == :auto && profile && !profile.parallel?(workers)

        workers
      end

      def map(items, max_threads: nil, needs_db: true, workload: :auto, profile: nil, &block)
        collection = items.is_a?(Array) ? items : items.to_a
        size = collection.size
        return [] if size.zero?

        workers = worker_count_for(size, max_threads: max_threads, workload: workload, profile: profile)
        totals = profile && WorkloadProfile.supported? ? [ 0, 0 ] : nil

        results =
          if workers <= 1
            before = totals && WorkloadProfile.snapshot
            mapped = collection.map(&block)
            WorkloadProfile.sample(before, WorkloadProfile.snapshot, totals) if totals
            mapped
          else
            run_shared_queue(collection, workers, needs_db, totals, block)
          end

        profile.record(*totals) if totals
        results
      end

      def shutdown!
        pool_mutex.synchronize do
          @pool&.shutdown
          @pool&.wait_for_termination(5)
          @pool = nil
        end
      end

      private

      # Work-sharing loop: items sit in a shared queue that both the pool
      # workers and the calling thread drain. The caller never idles on a
      # latch while there is work left, so:
      # - one fewer thread hand-off per call (the caller does its share);
      # - a saturated pool degrades to inline execution instead of queueing
      #   the request behind other requests' tasks;
      # - nested calls cannot deadlock waiting on their own pool.
      # Helpers that start after the queue is empty exit immediately.
      def run_shared_queue(collection, workers, needs_db, totals, block)
        size = collection.size
        results = Array.new(size)
        state = { claimed: 0, done: 0, error: nil }
        mutex = Mutex.new
        finished = ConditionVariable.new
        claimable = -> { state[:error].nil? && state[:claimed] < size }

        drain = lambda do
          loop do
            index = mutex.synchronize do
              next unless claimable.call

              state[:claimed] += 1
              state[:claimed] - 1
            end
            break if index.nil?

            before = totals && WorkloadProfile.snapshot
            begin
              results[index] = block.call(collection[index])
            rescue Exception => error # rubocop:disable Lint/RescueException
              mutex.synchronize { state[:error] ||= error }
            ensure
              after = totals && WorkloadProfile.snapshot
              mutex.synchronize do
                WorkloadProfile.sample(before, after, totals) if totals
                state[:done] += 1
                finished.broadcast if state[:done] == state[:claimed]
              end
            end
          end
        end

        pool = pool_for
        (workers - 1).times do
          pool.post do
            begin
              run_in_worker_context(needs_db: needs_db, &drain) if mutex.synchronize(&claimable)
            rescue Exception => error # rubocop:disable Lint/RescueException
              mutex.synchronize { state[:error] ||= error }
            end
          end
        end

        drain.call

        # Nothing is claimable any more; wait only for items still in flight.
        mutex.synchronize do
          finished.wait(mutex) while state[:done] < state[:claimed]
        end
        raise state[:error] if state[:error]

        results
      end

      def pool_for
        pool_mutex.synchronize do
          if @pool.nil? || @pool.shutdown?
            @pool = Concurrent::ThreadPoolExecutor.new(
              min_threads: 0,
              max_threads: max_pool_threads,
              max_queue: 0,
              idletime: DEFAULT_IDLE_TIMEOUT,
              fallback_policy: :caller_runs,
              name: "renderhive"
            )
          end
        end
        @pool
      end

      def pool_mutex
        @pool_mutex ||= Mutex.new
      end

      def max_pool_threads
        @max_pool_threads ||= [ default_workers * 2, 32 ].min
      end

      def resolve_workers_count(size, max_threads, workload)
        configured = max_threads || default_workers
        workers = [ [ configured.to_i, 1 ].max, size ].min

        case workload
        when :cpu
          mri? ? [ workers, 1 ].min : workers
        else
          workers
        end
      end

      def normalize_workload(workload)
        normalized = workload.to_sym
        return normalized if VALID_WORKLOADS.include?(normalized)

        raise ArgumentError, "workload deve ser um de: #{VALID_WORKLOADS.join(', ')}"
      end

      def default_workers
        @default_workers ||= begin
          workers = [ Etc.nprocessors, 2 ].max
          pool_size = database_pool_size
          pool_size ? [ workers, pool_size ].min : workers
        rescue StandardError
          4
        end
      end

      def rails_executor
        return @rails_executor if defined?(@rails_executor)

        @rails_executor =
          if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
            Rails.application.executor
          end
      end

      def run_in_worker_context(needs_db:, &block)
        executor = rails_executor

        if executor
          executor.wrap do
            needs_db ? with_active_record_connection(&block) : block.call
          end
        elsif needs_db
          with_active_record_connection(&block)
        else
          block.call
        end
      end

      def with_active_record_connection
        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.connection_pool.with_connection { yield }
        else
          yield
        end
      end

      def database_pool_size
        return unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.connection_pool.size
      rescue StandardError
        nil
      end

      def mri?
        defined?(RUBY_ENGINE) ? RUBY_ENGINE == "ruby" : true
      end
    end
  end
end
