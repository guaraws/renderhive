# Performance report

## Round 2 — end-to-end rendering — 2026-10-23

### Decision

Round 1 (below) optimized buffer assembly in isolation. Joining a few hundred
fragments takes tens of microseconds, against milliseconds for the request,
so it could not move end-to-end latency. Round 2 starts from an end-to-end
benchmark (`benchmark/rails_render_bench.rb`: real ActionController +
Action View, in-memory templates, byte-identical output checks) and fixes
what it exposed, in order of impact.

### Findings

1. **Double rendering (the dominant cost).** `RenderInterceptor` only caught
   `render(record)`. The most common idiom, `<%= render @cards %>`, and
   `render partial: ..., collection: ...`, re-rendered the entire collection
   after the parallel pre-render. With the default `delivery: :fragments`
   every Renderhive page was *slower* than plain Rails: 0.41–0.63× on CPU
   and mixed partials, 0.90× on I/O-heavy ones. A new integration test
   counts partial renders: 80 for 40 records before, 40 now.
2. **GVL-bound pages paid for threads they could not use.** For pure ERB the
   GVL serializes all workers; spreading the work across 12 threads only
   added hand-offs and contention (0.71–0.89× with `renderhive_collection`).
3. **The caller idled.** `Executor.map` posted every chunk to the pool and
   blocked on a latch. With `max_queue: 0` (unbounded) a busy pool made the
   request wait behind other requests' tasks; nested calls could deadlock.
4. **Escaping is not a bottleneck.** Replacing Rails' escaping with an
   identity function did not change the CPU benchmark beyond noise, so the
   native escaper stays opt-in. It was still fixed to stop losing to
   `CGI.escapeHTML`.
5. `Executor` raised `NoMethodError` when `Rails` was defined without
   railties.

### Changes

- **Whole-collection interception.** `render @records` and
  `render partial:, collection:, as:` return the pre-joined HTML when the
  records are exactly the pre-rendered ones (identity, same order) and no
  locals/block/extra options are given; anything else falls back to Rails.
  Ordered parts are kept for every delivery mode and joined lazily, once.
- **Adaptive `workload: :auto`, powered by a native GVL hook.** Thread CPU
  time cannot separate "waiting for the GVL" from "waiting for I/O" once
  several threads run. The Rust extension registers
  `rb_internal_thread_add_event_hook` (Ruby >= 3.3, Unix) and keeps, per
  Ruby thread (thread-specific storage keyed by `event_data->thread`, so it
  is M:N safe), the time spent holding and waiting for the GVL. Each unit of
  work is split into held / wait / off-GVL (`wall - held - wait`, clamped at
  0). `Renderhive::WorkloadProfile` smooths the off-GVL share per collection
  and predicts the best case `1 / max(1 - io_share, 1 / workers)`; below
  1.25× the collection renders inline as a single chunk on the request
  thread. Measurement continues in both modes, so a page that starts doing
  I/O fans out again. Without the hook the behaviour is unchanged.
- **Work-sharing executor.** Items sit in a shared queue drained by the pool
  and the caller. The caller does its share, a saturated pool degrades to
  inline execution, nested calls cannot deadlock and an error stops further
  claims (only in-flight items are awaited).
- **Native escape:** SSE2 16-byte scan, exact output size via `psadbw`,
  direct write into one Ruby string with the input's encoding, fixed-width
  stores (8-byte replacements, 16-byte short runs) over a 16-byte slack.
  Portable scalar fallback off x86_64.
- **Native join:** `memcpy` straight into a UTF-8 string (encoding set
  before `rb_str_set_len`, so invalid bytes are not reported as valid).

### End-to-end results

MRI 4.0.6, Rails 8.1.4, Linux x86_64, 12 CPUs; p50 of 20 runs after 3
warm-ups, speedup vs serial Rails. Raw output:
`benchmarks/rails-render-before.txt`, `benchmarks/rails-render-after.txt`.
"Before" is the previous code with only the `Rails.application` crash fix
applied so it can run.

| Partial | Cards | `render @cards` before | after | `renderhive_collection` before | after |
| ------- | ----: | ---------------------: | ----: | -----------------------------: | ----: |
| cpu     |   200 |                  0.41× | 1.04× |                          0.71× | 1.10× |
| cpu     | 1 000 |                  0.45× | 1.01× |                          0.89× | 1.08× |
| mixed   |   200 |                  0.59× | 1.27× |                          1.32× | 1.35× |
| mixed   | 1 000 |                  0.63× | 1.78× |                          1.78× | 1.79× |
| io      |   200 |                  0.90× | 9.35× |                          9.41× | 9.47× |
| io      | 1 000 |                  0.91× | 10.64× |                        10.86× | 10.75× |

The `renderhive_collection` path on I/O-heavy partials was already good and
is unchanged within noise; the gains are the default `render @cards` path
and GVL-bound pages, which no longer lose to serial rendering. The CPU rows
above 1.0× are within run-to-run noise: under the GVL pure ERB cannot beat
serial, the goal is to not lose.

### Native micro-benchmarks

`benchmarks/native-after.txt` (benchmark-ips, same machine):

| Benchmark | Before | After |
| --- | ---: | ---: |
| escape, no specials, vs `CGI.escapeHTML` | 1.28× | 3.0× |
| escape, ~2% specials, vs `CGI.escapeHTML` | 0.93× | 1.8× |
| escape, dense markup, vs `CGI.escapeHTML` | 0.48× | 1.14× |
| join vs `Array#join` | 0.89–1.17× | 1.0–1.6× |

Join numbers are noisy: three repeated runs gave 1.0–1.6×, while the run
recorded in `native-after.txt` shows one outlier (0.43× for 4 × 512 KB,
1.64× for 200 cards). Large allocations make it sensitive to allocator and
GC state; it is not on the critical path either way.

### Verification

- 90 tests, 0 failures with the extension; the full suite also passes with
  the extension hidden (6 native-only skips).
- Integration tests compare HTML byte-for-byte with serial Rails for
  `render @items`, `render partial:, collection:`, per-record `render item`,
  a subset render and `renderhive_collection`, for every delivery mode.
- `cargo clippy --all-targets -- -D warnings` and `cargo test` pass; the
  Rust test checks a special byte at every offset across 16-byte blocks.
- GVL accounting sanity: thread CPU time and `held` agree within 0.5 ms on a
  two-thread CPU loop; a mixed sleep/CPU run satisfies held + wait + sleep ≈
  wall. One edge case (a thread preempted by direct transfer under Ruby 4's
  scheduler) can report a wait interval that overlaps held time; it only
  biases towards "GVL bound", the conservative choice, and the clamp keeps
  off-GVL time non-negative.

### Remaining priorities

1. Run `rails_render_bench.rb`-style measurements on a production-like app
   under concurrent load (Puma threads competing for the same GVL): `io_share`
   measured under contention rises with other requests' GVL use, which makes
   `:auto` lean towards parallel.
2. Feed the adaptive profile to `parallelize_view_methods` too.
3. The batched `:fragments` path still stores a whole chunk under its first
   record; per-record `render record` in a different order produces wrong
   HTML (unchanged, documented caveat).
4. `max_queue: 0` remains unbounded; the shared queue makes it harmless for
   latency (the caller never waits for queued helpers), but idle helper tasks
   can still pile up under sustained overload.

---

## Round 1 — buffer assembly — 2026-10-23

### Decision

Optimize the existing Rust assembly path first. It is shared by collection
and deduplicated delivery, has a small correctness boundary, and can be
benchmarked independently. Rendering ERB still executes Ruby under the GVL;
sending Ruby callbacks to Rayon would not make that execution parallel.

The old implementation zero-filled a Rust Vec, scheduled fragment copies
through Rayon from 64 KiB, and copied the entire Vec into a Ruby string.
It held the GVL throughout. The new implementation calculates the checked
output size, reserves a Ruby string, and appends the bytes directly. It
eliminates the intermediate payload and Rayon dependency. It deliberately
keeps the GVL while accessing Ruby-owned strings.

Source byte slices are obtained only after allocating the destination, so
an allocation-triggered compaction cannot invalidate cached source pointers.
The implementation uses Magnus's documented preallocation and append APIs:
https://docs.rs/magnus/0.9.3/magnus/struct.Ruby.html#method.str_buf_new
https://docs.rs/magnus/0.9.3/magnus/struct.RString.html#method.cat

The pure-Ruby fallback now uses Array#join and shares the native contract:
inputs contain already-rendered, trusted HTML. Previously it escaped ordinary
String fragments while native assembly copied them unchanged. Neither path
should be used to sanitize user input. Rails collection output is UTF-8;
this change does not introduce general mixed-encoding support.

### Measurements

Local Linux x86_64, Ruby 4.0.6, Rails 8.1.4, Magnus 0.9.3, 12 logical CPUs,
release Rust build. benchmark-ips: 1 second warmup and 3 seconds measurement
per strategy. Raw outputs are in benchmarks/buffer-before.txt and
benchmarks/buffer-after.txt. Both runs use the original script from commit
7dde4a2, with the same fixtures and strategy order. An additional expanded
run in benchmarks/buffer-expanded.txt measures Array#join and four large
batches; this run is not used to calculate before/after ratios.

These are single-process exploratory runs, not production latency guarantees.
Some build/test activity overlapped the expanded four-batch case. No builds
or tests ran concurrently with the original-script after measurement. Re-run on deployment hardware before
choosing throughput or latency targets. The old implementation's published
Ruby 3.4 numbers are not directly comparable to this Ruby 4 environment.

| Original-script scenario | Old native (i/s) | New native (i/s) | Ratio |
| --- | ---: | ---: | ---: |
| 200 fragments × ~2 KiB | 9,258 | 22,434 | 2.42× |
| 1,000 fragments × ~2 KiB | 2,479 | 4,098 | 1.65× |
| 5,000 fragments × ~512 B | 1,457 | 3,081 | 2.11× |

These ratios apply only to buffer assembly. The expanded run measured only
1,629 i/s for the last native scenario, illustrating sensitivity to benchmark
order, allocator/GC state and machine noise. Its Array#join result was similar
(1,587 i/s); Rust does not universally beat Ruby's optimized C implementation.

### Verification

- Native suite: 53 tests, 94 assertions, no failures/errors; two native-only
  tests intentionally skipped in the fallback subclass.
- Entire suite with native disabled: 53 tests, 92 assertions, no failures/errors;
  four native-only skips.
- cargo clippy --all-targets -- -D warnings passed.
- Benchmarks check byte-identical output before timing.
- Regression coverage: output order, UTF-8, NUL bytes, frozen inputs, empty
  fragments, invalid native inputs, large payloads, and compacted inputs.

### Remaining priorities

1. Add an actual Rails integration benchmark with concurrent requests, p50/p95,
   allocations, RSS and DB pool contention. The referenced host Rails app in
   README is not present in this repository; existing local tests cannot
   establish end-to-end production gains.
2. Bound executor admission and test reentrant calls under saturation.
   max_queue: 0 currently means an unbounded queue, so caller_runs does not
   provide the documented overload protection during normal operation.
3. Audit collection semantics before expanding parallel execution: batching
   resets Rails counter/iteration locals per chunk, and fragment delivery
   stores whole chunks under their first record. Tests should compare actual
   Rails output for iteration locals, reordered consumption and repeated IDs.
4. For real off-GVL CPU parallelism, introduce a measured bulk operation over
   Rust-owned inputs (for example bulk escaping), with an explicit snapshot
   boundary and sufficient work to amortize copying and scheduling. Do not
   release the GVL while borrowing mutable Ruby string storage.
5. Preserve delivery: :collection and dedup as opt-in fast paths. Dedup keys
   must fully determine output, including locals and view context.
