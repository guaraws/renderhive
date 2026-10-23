require "test_helper"

class Renderhive::WorkloadProfileTest < Minitest::Test
  def test_unmeasured_profile_allows_parallelism
    assert Renderhive::WorkloadProfile.new.parallel?(8)
  end

  def test_gvl_bound_profile_stays_inline
    profile = Renderhive::WorkloadProfile.new
    profile.record(950, 50)

    refute profile.parallel?(8)
    assert_in_delta 1.05, profile.expected_speedup(8), 0.01
  end

  def test_expected_speedup_is_capped_by_worker_count
    profile = Renderhive::WorkloadProfile.new
    profile.record(0, 1_000)

    assert_in_delta 4.0, profile.expected_speedup(4), 0.001
    assert profile.parallel?(4)
  end

  def test_recording_smooths_towards_new_measurements
    profile = Renderhive::WorkloadProfile.new
    profile.record(1_000, 0)
    5.times { profile.record(0, 1_000) }

    assert profile.parallel?(8), "should switch back once I/O dominates"
  end

  def test_sample_splits_wall_time_into_held_and_off_gvl
    totals = [ 0, 0 ]
    Renderhive::WorkloadProfile.sample([ 0, 0, 0 ], [ 30, 20, 100 ], totals)

    assert_equal [ 30, 50 ], totals
  end

  def test_sample_never_reports_negative_io
    totals = [ 0, 0 ]
    Renderhive::WorkloadProfile.sample([ 0, 0, 0 ], [ 100, 50, 100 ], totals)

    assert_equal [ 100, 0 ], totals
  end

  def test_native_snapshot_separates_sleep_from_cpu
    skip "GVL accounting unavailable" unless Renderhive::WorkloadProfile.supported?

    totals = [ 0, 0 ]
    before = Renderhive::WorkloadProfile.snapshot
    sleep 0.02
    Renderhive::WorkloadProfile.sample(before, Renderhive::WorkloadProfile.snapshot, totals)
    assert_operator totals[1], :>, 15_000_000
    assert_operator totals[0], :<, 5_000_000

    totals = [ 0, 0 ]
    before = Renderhive::WorkloadProfile.snapshot
    x = 0
    200_000.times { x += 1 }
    Renderhive::WorkloadProfile.sample(before, Renderhive::WorkloadProfile.snapshot, totals)
    assert_operator totals[0], :>, totals[1]
  end
end
