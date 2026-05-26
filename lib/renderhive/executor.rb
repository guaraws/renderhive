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
      def worker_count_for(size, max_threads: nil, workload: :auto)
        return 0 if size.to_i <= 0

        resolve_workers_count(size, max_threads, normalize_workload(workload))
      end

      def map(items, max_threads: nil, needs_db: true, workload: :auto, &block)
        collection = items.is_a?(Array) ? items : items.to_a
        size = collection.size
        return [] if size.zero?

        workers = worker_count_for(size, max_threads: max_threads, workload: workload)
        return collection.map(&block) if workers <= 1

        results = Array.new(size)
        chunk_size = (size.to_f / workers).ceil
        first_error = nil
        error_mutex = Mutex.new

        chunks = []
        (0...size).each_slice(chunk_size) { |range| chunks << range }

        latch = Concurrent::CountDownLatch.new(chunks.size)
        pool = pool_for

        chunks.each do |indices|
          pool.post do
            begin
              run_in_worker_context(needs_db: needs_db) do
                indices.each do |i|
                  results[i] = block.call(collection[i])
                end
              end
            rescue Exception => error # rubocop:disable Lint/RescueException
              error_mutex.synchronize { first_error ||= error }
            ensure
              latch.count_down
            end
          end
        end

        latch.wait
        raise first_error if first_error

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
          if defined?(Rails) && Rails.application
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
