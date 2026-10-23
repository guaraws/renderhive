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

  def test_worker_count_for_cpu_workload_is_conservative_on_mri
    expected = defined?(RUBY_ENGINE) && RUBY_ENGINE == "ruby" ? 1 : 8
    assert_equal expected, Renderhive::Executor.worker_count_for(10, max_threads: 8, workload: :cpu)
  end

  def test_worker_count_for_io_workload_preserves_requested_threads
    assert_equal 8, Renderhive::Executor.worker_count_for(10, max_threads: 8, workload: :io)
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

  def test_map_rejects_invalid_workload
    err = assert_raises(ArgumentError) do
      Renderhive::Executor.map([ 1, 2, 3 ], needs_db: false, workload: :wat) { |x| x }
    end

    assert_match(/workload deve ser um de/, err.message)
  end

  def test_map_runs_part_of_the_work_on_the_calling_thread
    caller = Thread.current
    threads = Renderhive::Executor.map((1..8).to_a, max_threads: 4, needs_db: false) do
      sleep 0.005
      Thread.current
    end

    assert_includes threads, caller
  end

  def test_map_error_does_not_wait_for_unclaimed_items
    calls = Queue.new
    assert_raises(RuntimeError) do
      Renderhive::Executor.map((1..200).to_a, max_threads: 2, needs_db: false) do |n|
        calls << n
        raise "boom" if n == 1

        sleep 0.001
      end
    end

    assert_operator calls.size, :<, 200
  end

  def test_nested_map_does_not_deadlock_on_a_saturated_pool
    out = Renderhive::Executor.map((1..4).to_a, max_threads: 4, needs_db: false) do |n|
      Renderhive::Executor.map((1..4).to_a, max_threads: 4, needs_db: false) { |m| n * m }.sum
    end

    assert_equal [ 10, 20, 30, 40 ], out
  end

  def test_auto_workload_collapses_to_one_worker_for_gvl_bound_profile
    profile = Renderhive::WorkloadProfile.new
    profile.record(1_000, 0)

    assert_equal 1, Renderhive::Executor.worker_count_for(100, max_threads: 8, workload: :auto, profile: profile)
    assert_equal 8, Renderhive::Executor.worker_count_for(100, max_threads: 8, workload: :io, profile: profile)
  end

  def test_auto_workload_keeps_workers_for_io_bound_profile
    profile = Renderhive::WorkloadProfile.new
    profile.record(100, 900)

    assert_equal 8, Renderhive::Executor.worker_count_for(100, max_threads: 8, workload: :auto, profile: profile)
  end

  def test_map_records_into_the_profile
    skip "GVL accounting unavailable" unless Renderhive::WorkloadProfile.supported?

    profile = Renderhive::WorkloadProfile.new
    Renderhive::Executor.map((1..4).to_a, max_threads: 4, needs_db: false, profile: profile) { sleep 0.01 }

    assert_operator profile.io_share, :>, 0.9
  end
end

