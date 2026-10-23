# Renderhive

[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-red.svg)](https://rubyonrails.org/)

> Parallel pre-rendering for Rails partial collections and helper methods.

Renderhive is a tiny Rails concern that pre-computes controller helper
methods and pre-renders partial collections concurrently across a persistent
thread pool, then transparently swaps the results into the normal view
rendering path — **no changes to existing templates required**.

## Why?

A typical Rails `index` action ends up rendering N partials sequentially
while also calling several helper methods that each touch the database or
do non-trivial work. On wide pages with hundreds of cards and several
"summary" cards, the render phase becomes the bottleneck.

Renderhive lets you declaratively mark which helper methods and which
partial collections can be computed in parallel, and takes care of:

- Spinning up a persistent thread pool (no `Thread.new` per request).
- Pre-resolving the partial template once.
- Duplicating the view context per worker so renders don't share mutable
  state (`@output_buffer`, etc.).
- Batching the collection so each worker calls the Rails collection
  renderer once per chunk (1 render per worker instead of 1 per record).
- Wrapping workers in `Rails.application.executor` so query caching,
  CurrentAttributes and the AR connection lifecycle behave correctly.
- Falling back to `:caller_runs` when the pool is saturated.

Internally the rendered HTML is cached and `render(record)` calls inside
the view simply return the pre-baked SafeBuffer — your templates stay
untouched.

## Benchmarks

### In-repo end-to-end benchmark

`benchmark/rails_render_bench.rb` drives a real `ActionController::Base` +
Action View stack (in-memory templates) through `Rack::MockRequest`, checks
that every strategy produces byte-identical HTML, and reports p50 latency.
Three partial flavours: **cpu** (pure ERB), **mixed** (every 10th card adds a
~50 µs blocking call, ~40% off-GVL) and **io** (a 0.2 ms blocking call per
card, standing in for a lazy association or cache read).

MRI 4.0.6, Linux x86_64, 12 CPUs, 20 runs after 3 warm-ups. Speedup vs serial
Rails rendering (higher is better):

| Partial | Cards | Serial p50 | `render @cards` (`:fragments`) | `renderhive_collection` |
| ------- | ----: | ---------: | -----------------------------: | ----------------------: |
| cpu     |   200 |    1.64 ms |                          1.01× |                   1.06× |
| cpu     | 1 000 |    7.03 ms |                          1.00× |                   1.02× |
| mixed   |   200 |    3.68 ms |                          1.27× |                   1.28× |
| mixed   | 1 000 |   18.03 ms |                          1.81× |                   1.80× |
| io      |   200 |   53.71 ms |                          9.41× |                   9.42× |
| io      | 1 000 |  266.36 ms |                         10.76× |                  10.80× |

```sh
bundle exec ruby benchmark/rails_render_bench.rb
SIZES=200,1000 KINDS=io BENCH_RUNS=30 bundle exec ruby benchmark/rails_render_bench.rb
```

CPU-bound pages break even instead of getting slower: the adaptive `:auto`
workload notices the GVL is saturated and renders inline (see
[Choosing a workload profile](#choosing-a-workload-profile)). The
[optimization report](docs/performance.md) has the before/after numbers.

### Reference application

Numbers below come from the reference Rails 8.1 app shipped alongside
this gem (`script/bench_cars_index.rb`), hitting the full Rack stack via
`Rails.application.call(env)` against the `CarsController#index` action.
The page renders three "summary" helper methods plus a partial collection
of `Car` records (one ERB partial per card, ~2 KB of HTML each).

Environment: MRI 3.4.6, Linux, `RAILS_ENV=test`, single process, warm
caches. Each row is the mean of 20 runs after 3 warm-up calls.

| Records | Serial (no Renderhive) | Renderhive | Speedup |
| ------: | ---------------------: | ---------: | ------: |
|     200 |                ~42 ms |     ~30 ms |  ~1.4× |
|   1 000 |               ~188 ms |    ~118 ms | ~1.59× |

Reproduce locally from the host app:

```sh
RAILS_ENV=test bundle exec ruby script/bench_cars_index.rb
# status=200 body_bytes=2281901
# parallel     min=101.72ms avg=118.09ms max=161.02ms
# serial       min=173.20ms avg=188.41ms max=209.24ms
```

### Why the gain is not "Nx workers"

ERB rendering on MRI is CPU-bound Ruby and the **GVL** serializes pure
Ruby execution. Only time spent off the GVL (I/O, DB, cache, sleeps) can
overlap, so the ceiling is `1 / (share of time holding the GVL)`. The
measurable gains come from:

1. Overlapping I/O performed inside partials (lazy AR associations,
   `Rails.cache` reads, `image_url`/`asset_path` lookups).
2. Parallelizing helper methods that themselves trigger queries
   (`parallelize_view_methods`).
3. Reducing per-fragment overhead by pre-resolving the template once
   and reusing a duplicated view context per worker.

Expect roughly **1.4–1.6×** on wide pages with hundreds of cards on
MRI. Workloads dominated by AR query latency (cache misses, N+1 reads)
can push the ratio higher; pages that are pure string interpolation
will see smaller gains.

### When it is worth adopting

- `index`/dashboard pages with **dozens to hundreds** of cards or rows
  rendered from a single collection.
- Controllers that compute several **independent** summary/aggregate
  helper methods before rendering.
- Pages where partials trigger lazy DB or cache reads.

### When it is *not* worth it

- Small collections (use `min_size:` to short-circuit — Renderhive
  already skips below the threshold).
- Pages already covered by HTTP/fragment caching with a high hit ratio.
- JSON or API endpoints (the concern is HTML-only).

## Installation

```ruby
# Gemfile
gem "renderhive"
```

```sh
bundle install
```

## Usage

```ruby
class CarsController < ApplicationController
  include Renderhive::ViewParallelism

  helper_method :total_cars_card, :brands_count_card, :latest_year_card

  def total_cars_card
    # ... runs in parallel before the view is rendered
  end

  def brands_count_card
    # ...
  end

  def latest_year_card
    # ...
  end

  parallelize_view_methods :total_cars_card,
                           :brands_count_card,
                           :latest_year_card,
             only: :index,
             workload: :io

  parallelize_partial_collection :cars,
                                 only: :index,
               min_size: 6,
                                 workload: :io,
                                 delivery: :fragments

  def index
    @cars = Car.all.to_a.freeze
  end
end
```

If you want the lowest-overhead path, let Renderhive emit the full HTML for
the collection in one shot:

```erb
<%= renderhive_collection(:cars) do %>
  <% cars_records.each do |car| %>
    <%= render car %>
  <% end %>
<% end %>
```

That's it. On the next request Renderhive will:

1. Pre-compute `total_cars_card`, `brands_count_card` and
   `latest_year_card` in parallel and memoize the results.
2. Pre-render `@cars` in parallel chunks and intercept both the
   whole-collection `render @cars` / `render partial: "cars/car",
   collection: @cars` calls and the per-record `render car` calls in the
   view, so nothing is rendered twice.

### DSL reference

#### `parallelize_view_methods(*method_names, only:, except:, max_threads:, workload:)`

Marks zero-argument helper methods for parallel pre-computation. The
method must be defined **before** the call.

- `only:` / `except:` — restrict to specific actions.
- `max_threads:` — cap the worker count for this group.
- `workload:` — hint for the scheduler: `:auto` (default), `:io` or `:cpu`.

#### `parallelize_partial_collection(collection_name, partial:, as:, locals:, only:, except:, max_threads:, min_size:, batch_size:, workload:, delivery:)`

Marks an instance variable (`@#{collection_name}`) for parallel
pre-rendering.

- `partial:` — override the partial path (default: `record.to_partial_path`).
- `as:` — local name inside the partial (default: derived from partial).
- `locals:` — `Hash` (static) or `Proc` (dynamic per record). Dynamic
  locals use a slightly slower single-record render path.
- `min_size:` — only kick in when the collection has at least this many
  items (default: `0`).
- `batch_size:` — override automatic chunk sizing.
- `workload:` — hint for the scheduler: `:auto` (default), `:io` or `:cpu`.
- `delivery:` — `:fragments` (default, compatible with `render record`),
  `:collection` (optimized for `renderhive_collection`) or `:both`.
- `only:` / `except:` / `max_threads:` — same as above.

### Choosing a workload profile

- `:auto` — default mode. **Adaptive** when the native extension is loaded on
  Ruby >= 3.3 (Unix): every render is split into time holding the GVL, time
  waiting for it, and time off it (I/O), measured by a native GVL event hook.
  If the observed I/O share cannot buy at least a 1.25× speedup, the
  collection renders inline on the request thread (no hand-offs, no GVL
  contention); when I/O shows up again it fans back out. Without GVL
  accounting it keeps the configured worker count.
- `:io` — prefer this when helpers or partials trigger lazy queries, cache
  reads, asset path resolution or other wait-heavy work.
- `:cpu` — prefer this for ERB-heavy, string-heavy partials on MRI. Renderhive
  becomes conservative and avoids spinning extra Ruby workers when the GVL
  would mostly serialize the work anyway.

### Choosing a delivery mode

- `:fragments` — default, keeps the transparent interceptor for `render(record)`.
- `:collection` — optimized path for `renderhive_collection(:items)`, skipping
  the per-record fragment map.
- `:both` — stores both representations during migrations or mixed usage.

## Native extension (Rust)

Renderhive ships an **optional** Rust extension (`renderhive_native`) with
three pieces:

- **GVL accounting** (Ruby >= 3.3, Unix) — a thread-event hook records, per
  Ruby thread, the time spent holding and waiting for the GVL. It is what
  lets `workload: :auto` tell I/O-bound partials (parallelize) from
  GVL-bound ones (render inline). Threads that never ask for stats only pay
  one thread-specific lookup per GVL transition.
- **Buffer join** — computes the output size with overflow checks, allocates
  one UTF-8 Ruby string and `memcpy`s every fragment straight into it. The
  fallback uses `Array#join`. Both paths trust the fragments as already
  rendered HTML and return a `SafeBuffer`; do not pass unescaped user input.
- **HTML escaping** — SSE2-vectorized (portable scalar fallback), see below.

The GVL stays held whenever Ruby strings are accessed; Rust does not make
ERB execution itself run outside the GVL.

The extension is **fully optional**: if no Rust toolchain is available at
install time, Renderhive transparently falls back to a pure-Ruby join, so
the gem keeps working everywhere. You can check what is active at runtime:

```ruby
Renderhive.native? # => true when the compiled extension is loaded
```

### Buffer-join benchmark

The benchmark includes `Array#join`, `String#<<`, `SafeBuffer#<<`, and the
native path, with both many small fragments and a few large worker batches.
It verifies byte-identical output before measuring. Run it on your deployment
hardware; assembly throughput is not an end-to-end Rails rendering speedup.

```sh
bundle exec ruby benchmark/buffer_join_bench.rb
# Shorter exploratory run:
BENCH_TIME=1 BENCH_WARMUP=0.5 bundle exec ruby benchmark/buffer_join_bench.rb
```

Measured on MRI 4.0.6 it is on par with or ahead of `Array#join`
(1.0–1.6× across repeated runs; individual runs are noisy): joining a few hundred fragments takes tens of microseconds, so
it is never the bottleneck of a request. See [the optimization
report](docs/performance.md) for details and remaining limitations.

### Native HTML escaping

`Renderhive::HTML.escape` is a native HTML escaper that matches
`ERB::Util.html_escape` / `CGI.escapeHTML` byte-for-byte (escapes
`& < > " '`). It scans 16 bytes per step with SSE2 compares, sums the exact
output size with `psadbw`, and writes the result straight into one Ruby
allocation carrying the input's encoding, using fixed-width stores for
replacements and short runs. When there is nothing to escape it returns the
input unchanged with **zero allocation**. It falls back to `CGI.escapeHTML`
without the extension.

There is also `Renderhive::HTML.unwrapped_html_escape`, which mirrors
Action View's output-escaping semantics (honours the `html_safe`
short-circuit and returns a `SafeBuffer`). Renderhive does **not** patch
`ERB::Util` globally — wiring these primitives into your view layer is an
explicit, opt-in decision left to the application.

Benchmark (`benchmark/html_escape_bench.rb`, MRI 4.0.6, x86_64):

| Workload                              | vs `ERB::Util.html_escape` | vs `CGI.escapeHTML` |
| ------------------------------------- | -------------------------: | ------------------: |
| Typical text (no specials)            |                    ~3.5×   |             ~3.0×   |
| Light (~2% specials)                  |                    ~2.5×   |             ~1.8×   |
| Escape-heavy markup                   |                    ~2.0×   |             ~1.14×  |
| Render-like (1000 rows × 5 fields)    |                    ~2.7×   |                 —   |

Escaping is a small share of a typical partial's render time (removing it
entirely did not move the end-to-end benchmark beyond noise), which is why
Renderhive does not patch it in globally.

```sh
bundle exec ruby benchmark/html_escape_bench.rb
```

## Fragment de-duplication

When many records in a collection render to the **same** HTML (a repeated
pattern that depends only on a low-cardinality attribute), there is no point
re-rendering identical output for every record. Pass a `dedup:` callable to
`parallelize_partial_collection`: Renderhive renders **one representative per
distinct key** (in parallel) and reuses the resulting fragment for every
record that shares the key, so the render cost scales with the number of
**distinct outputs** instead of the collection size.

```ruby
parallelize_partial_collection :badges,
  only: :index,
  dedup: ->(badge) { badge.status }   # output depends only on status
```

Correctness contract: the key **must** fully determine the rendered output
(same idea as the cache key in Rails collection caching). If two records can
produce different HTML for the same key, do not dedup them.

Benchmark (`benchmark/dedup_bench.rb`, MRI 3.4.6) — output verified
byte-identical to the full render:

| Workload                          | Speed-up vs full render |
| --------------------------------- | ----------------------: |
| 1000 rows, 5 distinct outputs     |                  ~7.3×  |
| 1000 rows, 2 distinct outputs     |                  ~7.2×  |
| 5000 rows, 5 distinct outputs     |                  ~8.1×  |

```sh
bundle exec ruby benchmark/dedup_bench.rb
```

## Instrumentation

Renderhive emits `ActiveSupport::Notifications` events:

| Event                          | Payload keys |
| ------------------------------ | --- |
| `view_methods.renderhive`      | `controller`, `action`, `methods`, `workload`, `workers`, `elapsed_ms` |
| `view_collection.renderhive`   | `controller`, `action`, `collection`, `partial`, `size`, `min_size`, `skipped`, `render_mode`, `batch_count`, `chunk_size`, `workers`, `workload`, `delivery`, `deduped`, `distinct_count`, `io_share`, `elapsed_ms`, `reason` |

`io_share` is the smoothed fraction of render time spent off the GVL as
learned by the adaptive `:auto` workload (`nil` until measured or when GVL
accounting is unavailable); `workers: 1` means it chose to render inline.

## Caveats

- See the [Benchmarks](#benchmarks) section for realistic expectations
  on MRI — pure ERB rendering cannot go faster than serial under the GVL;
  gains come from overlapping I/O.
- Without GVL accounting (no extension, Ruby < 3.3, Windows), `:auto` does
  not adapt: use `workload: :cpu` for partials that are mostly ERB/string
  work so Renderhive stays conservative about extra workers.
- Whole-collection interception only applies when the view renders exactly
  the pre-rendered records in the same order with no extra locals; any other
  call (a subset, a different order, extra locals) falls back to a regular
  render.
- If you control the template, prefer `delivery: :collection` with
  `renderhive_collection(:items)` to remove the per-record render loop from
  the hot path.
- The batched collection path assumes the view iterates the collection
  in its original order (the typical `each do |record|` pattern).
- `view_context.dup` is shallow; if your helpers maintain mutable
  per-render state outside of `@output_buffer`, prefer the dynamic-locals
  path or skip pre-rendering for those partials.

## Development

```sh
cd gems/renderhive
bundle install
bundle exec rake compile  # builds the optional Rust extension
bundle exec rake test
bundle exec ruby benchmark/buffer_join_bench.rb
```

Building the extension requires a Rust toolchain (`cargo`/`rustc`). If it is
missing, skip `rake compile`; the tests and the gem run on the pure-Ruby
fallback.

## License

[MIT](LICENSE.txt).
