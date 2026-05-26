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
                           only: :index

  parallelize_partial_collection :cars,
                                 only: :index,
                                 min_size: 6

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

#### `parallelize_view_methods(*method_names, only:, except:, max_threads:)`

Marks zero-argument helper methods for parallel pre-computation. The
method must be defined **before** the call.

- `only:` / `except:` — restrict to specific actions.
- `max_threads:` — cap the worker count for this group.

#### `parallelize_partial_collection(collection_name, partial:, as:, locals:, only:, except:, max_threads:, min_size:, batch_size:)`

Marks an instance variable (`@#{collection_name}`) for parallel
pre-rendering.

- `partial:` — override the partial path (default: `record.to_partial_path`).
- `as:` — local name inside the partial (default: derived from partial).
- `locals:` — `Hash` (static) or `Proc` (dynamic per record). Dynamic
  locals use a slightly slower single-record render path.
- `min_size:` — only kick in when the collection has at least this many
  items (default: `0`).
- `batch_size:` — override automatic chunk sizing.
- `only:` / `except:` / `max_threads:` — same as above.

## Instrumentation

Renderhive emits `ActiveSupport::Notifications` events:

| Event                          | Payload keys |
| ------------------------------ | --- |
| `view_methods.renderhive`      | `controller`, `action`, `methods` |
| `view_collection.renderhive`   | `controller`, `action`, `collection`, `partial`, `size`, `min_size`, `skipped`, `render_mode`, `batch_count`, `reason` |

## Caveats

- **MRI / GVL.** ERB rendering is CPU-bound Ruby and the GVL serializes
  pure Ruby execution. Gains are highest when partials trigger I/O
  (lazy associations, cache reads, etc.). Expect roughly **1.4–1.6×** on
  wide pages with hundreds of cards.
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
