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
               workload: :io

  def index
    @cars = Car.all.to_a.freeze
  end
end
```

In the view, write the loop as usual:

```erb
<% cars_records.each do |car| %>
  <%= render car %>
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

#### `parallelize_partial_collection(collection_name, partial:, as:, locals:, only:, except:, max_threads:, min_size:, batch_size:, workload:)`

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
- `only:` / `except:` / `max_threads:` — same as above.

### Choosing a workload profile

- `:auto` — default mode. Keeps the configured worker count and is the best
  starting point when the partial mixes rendering and I/O.
- `:io` — prefer this when helpers or partials trigger lazy queries, cache
  reads, asset path resolution or other wait-heavy work.
- `:cpu` — prefer this for ERB-heavy, string-heavy partials on MRI. Renderhive
  becomes conservative and avoids spinning extra Ruby workers when the GVL
  would mostly serialize the work anyway.

## Instrumentation

Renderhive emits `ActiveSupport::Notifications` events:

| Event                          | Payload keys |
| ------------------------------ | --- |
| `view_methods.renderhive`      | `controller`, `action`, `methods`, `workload`, `workers`, `elapsed_ms` |
| `view_collection.renderhive`   | `controller`, `action`, `collection`, `partial`, `size`, `min_size`, `skipped`, `render_mode`, `batch_count`, `chunk_size`, `workers`, `workload`, `elapsed_ms`, `reason` |

## Caveats

- See the [Benchmarks](#benchmarks) section for realistic expectations
  on MRI — the GVL caps the speedup at roughly 1.4–1.6× for pure
  rendering workloads.
- If a partial is mostly ERB/string work on MRI, prefer `workload: :cpu`
  so Renderhive stays conservative about extra workers.
- The batched collection path assumes the view iterates the collection
  in its original order (the typical `each do |record|` pattern).
- `view_context.dup` is shallow; if your helpers maintain mutable
  per-render state outside of `@output_buffer`, prefer the dynamic-locals
  path or skip pre-rendering for those partials.

## Development

```sh
cd gems/renderhive
bundle install
bundle exec rake test
```

## License

[MIT](LICENSE.txt).
