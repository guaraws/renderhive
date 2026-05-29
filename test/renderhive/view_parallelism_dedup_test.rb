require "test_helper"

class Renderhive::ViewParallelismDedupTest < Minitest::Test
  def build_instance
    klass = Class.new do
      include Renderhive::ViewParallelism

      class << self
        def helper(*)
        end
      end
    end

    klass.allocate
  end

  def test_dedup_index_collapses_repeated_keys_preserving_first_representative
    instance = build_instance
    collection = [
      { id: 1, status: "active" },
      { id: 2, status: "inactive" },
      { id: 3, status: "active" },
      { id: 4, status: "active" }
    ]

    keys, distinct = instance.send(:renderhive_dedup_index, collection, ->(record) { record[:status] })

    assert_equal %w[active inactive active active], keys
    assert_equal [ "active", "inactive" ], distinct.map(&:first)
    assert_equal [ 1, 2 ], distinct.map { |_key, record| record[:id] }
  end

  def test_dedup_index_supports_two_arity_callable
    instance = build_instance
    collection = [ { id: 1 }, { id: 2 } ]

    keys, distinct = instance.send(:renderhive_dedup_index, collection, ->(record, ctx) { ctx.equal?(instance) ? record[:id] : nil })

    assert_equal [ 1, 2 ], keys
    assert_equal 2, distinct.size
  end

  def test_dedup_index_handles_empty_collection
    instance = build_instance

    keys, distinct = instance.send(:renderhive_dedup_index, [], ->(record) { record })

    assert_empty keys
    assert_empty distinct
  end
end
