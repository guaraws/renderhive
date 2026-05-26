require "test_helper"

class Renderhive::ViewParallelismConfigTest < Minitest::Test
  def test_parallelize_view_methods_stores_workload
    controller = Class.new do
      include Renderhive::ViewParallelism

      class << self
        def helper(*)
        end
      end

      def total_card
        1
      end

      parallelize_view_methods :total_card, workload: :cpu
    end

    assert_equal :cpu, controller.renderhive_parallel_method_configs[:total_card][:workload]
  end

  def test_parallelize_partial_collection_stores_workload
    controller = Class.new do
      include Renderhive::ViewParallelism

      class << self
        def helper(*)
        end
      end

      parallelize_partial_collection :cars, workload: :io
    end

    assert_equal :io, controller.renderhive_parallel_collection_configs.first[:workload]
  end

  def test_parallelize_view_methods_rejects_invalid_workload
    err = assert_raises(ArgumentError) do
      Class.new do
        include Renderhive::ViewParallelism

        class << self
          def helper(*)
          end
        end

        def total_card
          1
        end

        parallelize_view_methods :total_card, workload: :wat
      end
    end

    assert_match(/workload deve ser um de/, err.message)
  end

  def test_parallelize_partial_collection_rejects_invalid_workload
    err = assert_raises(ArgumentError) do
      Class.new do
        include Renderhive::ViewParallelism

        class << self
          def helper(*)
          end
        end

        parallelize_partial_collection :cars, workload: :wat
      end
    end

    assert_match(/workload deve ser um de/, err.message)
  end
end