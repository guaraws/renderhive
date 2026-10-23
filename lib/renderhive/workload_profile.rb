module Renderhive
  # Learns, per parallelized collection, whether parallel rendering pays off
  # on this process, and steers `workload: :auto` accordingly.
  #
  # On MRI only time spent *off* the GVL (blocking I/O, DB round-trips,
  # sleeps) can overlap across threads; time spent holding the GVL is
  # serialized no matter how many workers run. The native extension's GVL
  # hook (Ruby >= 3.3) splits every measured render into
  #
  #   held  — running Ruby/C code with the GVL
  #   wait  — runnable, but blocked behind another thread's GVL
  #   io    — wall - held - wait: off-GVL time, the only parallelizable part
  #
  # With `io_share = io / (held + io)` the best case for N workers is
  # `1 / max(1 - io_share, 1 / N)`. Below MIN_SPEEDUP the collection renders
  # inline on the request thread, skipping thread hand-offs and GVL
  # contention; above it, it fans out. Both modes keep measuring, so a page
  # that starts hitting the database again switches back on its own.
  #
  # Without GVL accounting (no extension, Ruby < 3.3, JRuby/TruffleRuby)
  # profiles never record anything and `:auto` keeps its static behaviour.
  class WorkloadProfile
    MIN_SPEEDUP = 1.25
    SMOOTHING = 0.3

    attr_reader :io_share

    class << self
      def supported?
        return @supported if defined?(@supported)

        @supported = Renderhive.native? && !Renderhive::Native.gvl_stats.nil?
      rescue StandardError
        @supported = false
      end

      # [held_ns, wait_ns, now_ns] for the current thread, nil if unsupported.
      def snapshot
        Renderhive::Native.gvl_stats if supported?
      end
    end

    def initialize
      @io_share = nil
    end

    def parallel?(workers)
      return true if @io_share.nil? || workers <= 1

      expected_speedup(workers) >= MIN_SPEEDUP
    end

    def expected_speedup(workers)
      1.0 / [ 1.0 - @io_share, 1.0 / workers ].max
    end

    # Accumulates one measured unit of work between two snapshots taken on
    # the same thread.
    def self.sample(before, after, totals)
      return unless before && after

      held = after[0] - before[0]
      wait = after[1] - before[1]
      wall = after[2] - before[2]
      totals[0] += held
      totals[1] += [ wall - held - wait, 0 ].max
    end

    def record(held_ns, io_ns)
      total = held_ns + io_ns
      return if total <= 0

      share = io_ns.fdiv(total)
      @io_share = @io_share ? @io_share + SMOOTHING * (share - @io_share) : share
    end
  end
end
