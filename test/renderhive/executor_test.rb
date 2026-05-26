require "test_helper"

class Renderhive::ExecutorTest < Minitest::Test
  def teardown
    Renderhive::Executor.shutdown!
  end

  def test_worker_count_for_zero_or_negative_size
    assert_equal 0, Renderhive::Executor.worker_count_for(0)
    assert_equal 0, Renderhive::Executor.worker_count_for(-1)
  end

  def test_worker_count_capped_by_collection_size
    assert_equal 1, Renderhive::Executor.worker_count_for(1, max_threads: 8)
    assert_equal 3, Renderhive::Executor.worker_count_for(3, max_threads: 8)
  end

  def test_map_returns_results_in_order
    items = (1..50).to_a
    out = Renderhive::Executor.map(items, max_threads: 4, needs_db: false) { |n| n * 2 }
    assert_equal items.map { |n| n * 2 }, out
  end

  def test_map_short_circuits_for_single_worker
    out = Renderhive::Executor.map([ 1, 2, 3 ], max_threads: 1, needs_db: false) { |n| n + 1 }
    assert_equal [ 2, 3, 4 ], out
  end

  def test_map_propagates_errors
    err = assert_raises(RuntimeError) do
      Renderhive::Executor.map((1..20).to_a, max_threads: 4, needs_db: false) do |n|
        raise "boom-#{n}" if n == 10

        n
      end
    end
    assert_match(/\Aboom-/, err.message)
  end

  def test_map_returns_empty_for_empty_input
    assert_equal [], Renderhive::Executor.map([], needs_db: false) { |x| x }
  end
end
