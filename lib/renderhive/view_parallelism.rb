module Renderhive
  # Pre-loads controller helper methods and pre-renders partial collections
  # in parallel before the view is rendered, then transparently swaps the
  # results into the regular view rendering path.
  #
  # DSL (declared inside the controller):
  #
  #   class CarsController < ApplicationController
  #     include Renderhive::ViewParallelism
  #
  #     helper_method :total_cars_card, :brands_count_card
  #
  #     def total_cars_card; ... ; end
  #     def brands_count_card; ... ; end
  #
  #     parallelize_view_methods :total_cars_card, :brands_count_card, only: :index
  #     parallelize_partial_collection :cars, only: :index, min_size: 6
  #
  #     def index
  #       @cars = Car.all.to_a.freeze
  #     end
  #   end
  #
  # Notifications:
  # - "view_methods.renderhive"     (controller, action, methods)
  # - "view_collection.renderhive"  (controller, action, collection, size,
  #                                  min_size, skipped, render_mode,
  #                                  batch_count, reason)
  module ViewParallelism
    EMPTY_LOCALS = {}.freeze
    EMPTY_HTML = ActiveSupport::SafeBuffer.new.freeze
    VALID_DELIVERIES = %i[ fragments collection both ].freeze

    # Helper module injected into the controller's view helpers so that
    # `render(record)` returns the pre-rendered fragment when available.
    module RenderInterceptor
      def render(options = {}, locals = nil, &block)
        ctrl = controller
        if ctrl
          cache = ctrl.instance_variable_get(:@_renderhive_fragments_by_partial)
          if cache && (locals.nil? || locals.empty?) && block.nil? &&
             options.respond_to?(:to_partial_path)
            partial_path = options.to_partial_path
            fragments = cache[partial_path]
            if fragments
              key = options.respond_to?(:id) && (id = options.id) ? id : options.object_id
              fragment = fragments[key]
              return fragment if fragment
            end
          end
        end

        locals.nil? ? super(options, &block) : super(options, locals, &block)
      end
    end

    # Helper module for views that want the lowest-overhead path: render the
    # fully pre-baked HTML for a configured collection in one shot instead of
    # calling `render(record)` for every item.
    module CollectionRenderer
      def renderhive_collection(collection_name, &block)
        ctrl = controller

        if ctrl
          ctrl.send(:renderhive_prepare_parallel_view_workload)
          html = ctrl.instance_variable_get(:@_renderhive_collection_html)&.[](collection_name.to_sym)
          return html if html
        end

        return capture(&block) if block_given?

        EMPTY_HTML
      end
    end

    extend ActiveSupport::Concern

    included do
      helper CollectionRenderer if respond_to?(:helper)
      class_attribute :renderhive_parallel_method_configs, default: {}
      class_attribute :renderhive_parallel_collection_configs, default: []
    end

    class_methods do
      def parallelize_view_methods(*method_names, only: nil, except: nil, max_threads: nil, workload: :auto)
        normalized_workload = normalize_parallel_workload(workload)

        method_names.flatten.each do |raw_name|
          method_name = raw_name.to_sym
          validate_parallelizable_method!(method_name)

          self.renderhive_parallel_method_configs = renderhive_parallel_method_configs.merge(
            method_name => {
              method_name: method_name,
              original_method: instance_method(method_name),
              only: normalize_parallel_actions(only),
              except: normalize_parallel_actions(except),
              max_threads: max_threads,
              workload: normalized_workload
            }
          )

          renderhive_parallel_wrapper_module.module_eval do
            define_method(method_name) do |*args, **kwargs, &block|
              results = @_renderhive_parallel_method_results
              if results && args.empty? && kwargs.empty? && block.nil? && results.key?(method_name)
                results[method_name]
              else
                super(*args, **kwargs, &block)
              end
            end
          end
        end
      end

      def parallelize_partial_collection(collection_name, partial: nil, as: nil, locals: nil, only: nil, except: nil, max_threads: nil, min_size: 0, batch_size: nil, workload: :auto, delivery: :fragments)
        helper RenderInterceptor if respond_to?(:helper)
        normalized_workload = normalize_parallel_workload(workload)
        normalized_delivery = normalize_parallel_delivery(delivery)

        self.renderhive_parallel_collection_configs = renderhive_parallel_collection_configs + [
          {
            collection_name: collection_name.to_sym,
            partial: partial,
            as: as&.to_sym,
            locals: locals,
            only: normalize_parallel_actions(only),
            except: normalize_parallel_actions(except),
            max_threads: max_threads,
            min_size: min_size.to_i,
            batch_size: batch_size&.to_i,
            workload: normalized_workload,
            delivery: normalized_delivery
          }
        ]
      end

      def validate_parallelizable_method!(method_name)
        return if method_defined?(method_name) || private_method_defined?(method_name) || protected_method_defined?(method_name)

        raise ArgumentError, "Defina ##{method_name} antes de chamar parallelize_view_methods"
      end

      def normalize_parallel_actions(actions)
        Array(actions).flatten.compact.map(&:to_s)
      end

      def normalize_parallel_workload(workload)
        Renderhive::Executor.send(:normalize_workload, workload)
      end

      def normalize_parallel_delivery(delivery)
        normalized = delivery.to_sym
        return normalized if VALID_DELIVERIES.include?(normalized)

        raise ArgumentError, "delivery deve ser um de: #{VALID_DELIVERIES.join(', ')}"
      end

      def renderhive_parallel_wrapper_module
        @renderhive_parallel_wrapper_module ||= Module.new.tap { |mod| prepend mod }
      end
    end

    def render(*args, **kwargs, &block)
      renderhive_prepare_parallel_view_workload
      super
    end

    def default_render(*args, **kwargs, &block)
      renderhive_prepare_parallel_view_workload
      super
    end

    private

    def renderhive_prepare_parallel_view_workload
      return if @_renderhive_parallel_workload_prepared

      @_renderhive_parallel_workload_prepared = true

      return unless renderhive_html_render?

      method_configs = renderhive_active_method_configs
      collection_jobs = renderhive_collect_active_collection_jobs

      return if method_configs.empty? && collection_jobs.empty?

      renderhive_preload_view_methods(method_configs) unless method_configs.empty?
      renderhive_preload_partial_collections(collection_jobs) unless collection_jobs.empty?
    end

    def renderhive_html_render?
      action_name.present? && request&.format&.html?
    end

    def renderhive_preload_view_methods(configs)
      thread_limit = configs.map { |config| config[:max_threads] }.compact.min
      workload = renderhive_group_workload(configs)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      pairs = Renderhive::Executor.map(configs, max_threads: thread_limit, workload: workload) do |config|
        [ config[:method_name], config[:original_method].bind_call(self) ]
      end

      results = {}
      pairs.each { |name, value| results[name] = value }
      @_renderhive_parallel_method_results = results

      ActiveSupport::Notifications.instrument(
        "view_methods.renderhive",
        controller: self.class.name,
        action: action_name,
        methods: configs.map { |config| config[:method_name] },
        workload: workload,
        workers: Renderhive::Executor.worker_count_for(configs.size, max_threads: thread_limit, workload: workload),
        elapsed_ms: renderhive_elapsed_ms(started_at)
      )
    end

    def renderhive_collect_active_collection_jobs
      jobs = []

      renderhive_active_collection_configs.each do |config|
        collection = renderhive_collection_records(config)

        next if collection.empty?

        if collection.size < config[:min_size]
          ActiveSupport::Notifications.instrument(
            "view_collection.renderhive",
            controller: self.class.name,
            action: action_name,
            collection: config[:collection_name],
            size: collection.size,
            min_size: config[:min_size],
            skipped: true,
            workload: config[:workload] || :auto,
            delivery: config[:delivery] || :fragments,
            reason: :below_min_size
          )
          next
        end

        jobs << [ config, collection ]
      end

      jobs
    end

    def renderhive_preload_partial_collections(jobs)
      # The view_context is built once on the main thread; each worker
      # `dup`s this object to avoid rebuilding lookup_context, helpers,
      # _routes and other expensive ivars per fragment.
      base_view = view_context

      jobs.each do |config, collection|
        partial_path = config[:partial] || collection.first.to_partial_path
        local_name = config[:as] || renderhive_local_name_for(partial_path)
        template = base_view.lookup_context.find_template(partial_path, [], true, [ local_name ], {})
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        fragments, collection_html, metrics = renderhive_pre_render_collection(
          collection,
          partial_path,
          template,
          local_name,
          config,
          base_view
        )

        @_renderhive_fragments_by_partial ||= {}
        @_renderhive_fragments_by_partial[partial_path] = fragments if fragments
        @_renderhive_collection_html ||= {}
        @_renderhive_collection_html[config[:collection_name]] = collection_html if collection_html

        ActiveSupport::Notifications.instrument(
          "view_collection.renderhive",
          controller: self.class.name,
          action: action_name,
          collection: config[:collection_name],
          partial: partial_path,
          size: collection.size,
          min_size: config[:min_size],
          skipped: false,
          render_mode: :batched_collection,
          batch_count: metrics[:batch_count],
          chunk_size: metrics[:chunk_size],
          workers: metrics[:workers],
          workload: metrics[:workload],
          delivery: metrics[:delivery],
          elapsed_ms: renderhive_elapsed_ms(started_at)
        )
      end
    end

    def renderhive_pre_render_collection(collection, partial_path, template, local_name, config, base_view)
      size = collection.size
      workload = config[:workload] || :auto
      workers = Renderhive::Executor.worker_count_for(size, max_threads: config[:max_threads], workload: workload)
      workers = 1 if workers <= 0

      chunk_size =
        if config[:batch_size].to_i.positive?
          config[:batch_size]
        else
          [ (size.to_f / workers).ceil, 1 ].max
        end

      chunks = collection.each_slice(chunk_size).to_a
      dynamic_locals = config[:locals].is_a?(Proc) ? config[:locals] : nil
      static_locals = config[:locals].is_a?(Hash) ? config[:locals] : EMPTY_LOCALS
      delivery = config[:delivery] || :fragments
      store_fragments = %i[fragments both].include?(delivery)
      store_collection_html = %i[collection both].include?(delivery)

      fragments = store_fragments ? {} : nil
      collection_parts = store_collection_html ? [] : nil

      if dynamic_locals.nil?
        # Fast path: each worker issues ONE call to the partial collection
        # renderer for the whole chunk. The resulting HTML is stored under
        # the first record's key; the remaining ones receive an empty
        # SafeBuffer. Since the view iterates in the original order, the
        # RenderInterceptor returns the full batch HTML on the first hit
        # and an empty string on the following ones — equivalent output
        # with 1 render per worker instead of 1 per record.
        rendered = Renderhive::Executor.map(chunks, max_threads: config[:max_threads], needs_db: false, workload: workload) do |records|
          view = base_view.dup
          render_opts = {
            partial: partial_path,
            collection: records,
            as: local_name,
            formats: [ :html ]
          }
          render_opts[:locals] = static_locals.dup unless static_locals.empty?
          html = view.render(render_opts)
          [ records, html ]
        end

        rendered.each do |records, html|
          collection_parts << html if collection_parts

          next unless fragments

          records.each_with_index do |record, idx|
            fragments[renderhive_fragment_key(record)] = idx.zero? ? html : EMPTY_HTML
          end
        end
      else
        # Dynamic locals per record require individual calls; we still
        # reuse the pre-resolved template to skip template lookup.
        rendered_chunks = Renderhive::Executor.map(chunks, max_threads: config[:max_threads], needs_db: false, workload: workload) do |records|
          view = base_view.dup
          records.map do |record|
            locals = renderhive_locals_for_fragment(local_name, record, dynamic_locals, static_locals)
            [ renderhive_fragment_key(record), template.render(view, locals) ]
          end
        end

        rendered_chunks.each do |pairs|
          pairs.each do |key, html|
            collection_parts << html if collection_parts
            fragments[key] = html if fragments
          end
        end
      end

      # Assemble the final collection buffer in one pass (native single-alloc
      # join when available, pure-Ruby fallback otherwise).
      collection_html = collection_parts && Renderhive::Buffer.join(collection_parts)

      [ fragments, collection_html, { batch_count: chunks.size, chunk_size: chunk_size, workers: workers, workload: workload, delivery: delivery } ]
    end

    def renderhive_active_method_configs
      self.class.renderhive_parallel_method_configs.values.select { |config| renderhive_action_enabled?(config) }
    end

    def renderhive_active_collection_configs
      self.class.renderhive_parallel_collection_configs.select { |config| renderhive_action_enabled?(config) }
    end

    def renderhive_action_enabled?(config)
      allowed_actions = config[:only]
      blocked_actions = config[:except]

      return false if allowed_actions.any? && !allowed_actions.include?(action_name)
      return false if blocked_actions.include?(action_name)

      true
    end

    def renderhive_collection_records(config)
      Array(instance_variable_get("@#{config[:collection_name]}"))
    end

    def renderhive_locals_for_fragment(local_name, record, dynamic_locals, static_locals)
      if dynamic_locals
        extra = dynamic_locals.arity == 2 ? dynamic_locals.call(record, self) : dynamic_locals.call(record)
        extra.merge(local_name => record)
      elsif static_locals.empty?
        { local_name => record }
      else
        static_locals.merge(local_name => record)
      end
    end

    def renderhive_local_name_for(partial_path)
      File.basename(partial_path.to_s).sub(/\A_/, "").to_sym
    end

    def renderhive_group_workload(configs)
      workloads = configs.map { |config| (config[:workload] || :auto).to_sym }.uniq
      workloads.one? ? workloads.first : :auto
    end

    def renderhive_elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(2)
    end

    def renderhive_fragment_key(renderable)
      if renderable.respond_to?(:id) && (id = renderable.id)
        id
      else
        renderable.object_id
      end
    end
  end
end
