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
Ruby execution. The measurable gains come from:

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
2. Pre-render `@cars` in parallel chunks and intercept the per-record
   `render car` calls in the view.

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

- `:auto` — default mode. Keeps the configured worker count and is the best
  starting point when the partial mixes rendering and I/O.
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

Renderhive ships an **optional** Rust extension (`renderhive_native`) that
accelerates the final step of collection pre-rendering: joining the many
HTML fragments into a single buffer.

- The whole result is allocated **once** (no incremental `SafeBuffer#<<`
  reallocations) and filled in a single pass.
- For large payloads the byte copy is spread across CPU cores with
  [`rayon`](https://crates.io/crates/rayon), giving **true parallelism**
  that is not serialized by the GVL (each worker only touches disjoint
  byte ranges of pre-rendered, immutable strings).

The extension is **fully optional**: if no Rust toolchain is available at
install time, Renderhive transparently falls back to a pure-Ruby join, so
the gem keeps working everywhere. You can check what is active at runtime:

```ruby
Renderhive.native? # => true when the compiled extension is loaded
```

### Buffer-join benchmark

Joining pre-rendered fragments into the final collection buffer
(`benchmark/buffer_join_bench.rb`, MRI 3.4.6, 12 cores). `SafeBuffer#<<`
is the pure-Ruby path Renderhive used before the extension:

| Scenario             | `SafeBuffer#<<` | `Renderhive::Buffer.join` (native) | Speedup |
| -------------------- | --------------: | ---------------------------------: | ------: |
| 200 cards × ~2 KB    |       ~3.3k i/s |                          ~5.5k i/s |  ~1.68× |
| 1000 cards × ~2 KB   |       ~1.5k i/s |                          ~1.5k i/s |    ~1×  |
| 5000 cards × ~512 B  |       ~0.4k i/s |                          ~1.0k i/s |  ~2.19× |

```sh
bundle exec ruby benchmark/buffer_join_bench.rb
```

### Native HTML escaping

`Renderhive::HTML.escape` is a native, allocation-light HTML escaper that
matches `ERB::Util.html_escape` / `CGI.escapeHTML` byte-for-byte (escapes
`& < > " '`). When there is nothing to escape it returns the input
unchanged with **zero allocation**; otherwise it copies the safe runs in
bulk and allocates the result once. It falls back to `CGI.escapeHTML`
without the extension.

There is also `Renderhive::HTML.unwrapped_html_escape`, which mirrors
Action View's output-escaping semantics (honours the `html_safe`
short-circuit and returns a `SafeBuffer`). Renderhive does **not** patch
`ERB::Util` globally — wiring these primitives into your view layer is an
explicit, opt-in decision left to the application.

Benchmark (`benchmark/html_escape_bench.rb`, MRI 3.4.6):

| Workload                              | vs `ERB::Util.html_escape` | vs `CGI.escapeHTML` |
| ------------------------------------- | -------------------------: | ------------------: |
| Typical text (no specials)            |                    ~1.21×  |             ~1.13×  |
| Render-like (1000 rows × 5 fields)    |                    ~2.39×  |                 —   |
| Escape-heavy markup                   |                    ~0.95×  |  ~0.58× (CGI wins)  |

The headline gain is against `ERB::Util.html_escape` — the method Action
View actually calls per output — driven by the common “no specials” case
and lower per-call overhead. The stdlib `CGI.escapeHTML` (hand-tuned C)
still wins on escape-heavy strings, so this is an optimisation for
render-dominated, mostly-plain output rather than a universal win.

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
| `view_collection.renderhive`   | `controller`, `action`, `collection`, `partial`, `size`, `min_size`, `skipped`, `render_mode`, `batch_count`, `chunk_size`, `workers`, `workload`, `delivery`, `deduped`, `distinct_count`, `elapsed_ms`, `reason` |

## Caveats

- See the [Benchmarks](#benchmarks) section for realistic expectations
  on MRI — the GVL caps the speedup at roughly 1.4–1.6× for pure
  rendering workloads.
- If a partial is mostly ERB/string work on MRI, prefer `workload: :cpu`
  so Renderhive stays conservative about extra workers.
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
