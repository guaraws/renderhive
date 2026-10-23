# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `render @collection` and `render partial: ..., collection: ...` in the view
  rendered the whole collection a second time on top of the parallel
  pre-render (only per-record `render record` calls were intercepted). They
  now return the pre-joined HTML when they target exactly the pre-rendered
  records, falling back to a regular render otherwise. On the in-repo
  benchmark this turns 0.40–0.92× (slower than serial) into 1.0–10.8×.
- `Renderhive::Executor` crashed with `NoMethodError` when the `Rails`
  module was defined without railties (e.g. Action Pack/Action View only).
- Native escape/join results with invalid UTF-8 bytes are no longer reported
  as valid; the encoding is set before the length so Ruby derives the
  coderange under the right encoding.

### Added
- Adaptive `workload: :auto` for partial collections: a native GVL event hook
  (Ruby >= 3.3, Unix) splits each render into time holding, waiting for and
  off the GVL. Collections whose I/O share cannot buy a 1.25× speedup render
  inline on the request thread; they fan out again when I/O appears.
  Exposed as `Renderhive::WorkloadProfile` and the `io_share` notification key.
- `benchmark/rails_render_bench.rb`: end-to-end ActionController + Action View
  benchmark (cpu / mixed / io partials) with byte-identical output checks.
- Integration tests against a real controller stack covering every view
  idiom and delivery mode, including a render-count check for double renders.
- Optional Rust extension (`renderhive_native`) that joins pre-rendered HTML
  fragments directly into a pre-sized Ruby string. Exposed through `Renderhive::Buffer.join`
  with a pure-Ruby fallback and a `Renderhive.native?` runtime check.
- Native HTML escaper (`Renderhive::HTML.escape` / `unwrapped_html_escape`)
  matching `ERB::Util.html_escape`, with a zero-allocation fast path when
  nothing needs escaping and a `CGI.escapeHTML` fallback.
- In-request fragment de-duplication for `parallelize_partial_collection`
  via the `dedup:` option. When several records map to the same key, only
  one representative per distinct key is rendered (in parallel) and the
  resulting fragment is reused for every record that shares the key, so the
  render cost scales with the number of distinct outputs instead of the
  collection size.
- `benchmark/buffer_join_bench.rb` and `benchmark/html_escape_bench.rb`
  comparing the native paths against the pure-Ruby/stdlib strategies.
- `workload:` hints for `parallelize_view_methods` and `parallelize_partial_collection`
  with `:auto`, `:io` and `:cpu` modes.
- `delivery:` modes for collection rendering with an optimized `:collection`
  fast path exposed through `renderhive_collection(:items)`.
- Richer `ActiveSupport::Notifications` payloads including `workload`, `workers`,
  `chunk_size`, `delivery` and `elapsed_ms`.

### Changed
- `Renderhive::Executor.map` uses a shared work queue drained by the pool
  *and* the calling thread: the caller does its share instead of idling on a
  latch, a saturated pool degrades to inline execution instead of queueing
  behind other requests, nested calls cannot deadlock, and an error stops
  remaining items from being claimed.
- `Renderhive::HTML.escape` is SSE2-vectorized (portable scalar fallback),
  sizes its output exactly, writes straight into one Ruby string and keeps the
  input's encoding. Now ahead of `CGI.escapeHTML` on every benchmark sample
  (1.14–3.0×), where it previously lost on escape-heavy markup (0.48×).
- Native buffer join `memcpy`s straight into a UTF-8 Ruby string instead of
  appending fragment by fragment; the Ruby side no longer re-tags encodings.
- Ordered collection parts are kept for every delivery mode and joined lazily,
  only when a view asks for the whole collection.
- Native buffer assembly no longer zero-fills a temporary Rust buffer or copies
  it back to Ruby. Removed Rayon from this memory-copy path and added checked
  size arithmetic. The GVL remains held while Ruby strings are accessed.
- The Ruby buffer fallback uses `Array#join`, matching the native contract for
  already-rendered HTML instead of escaping ordinary String fragments again.
- Buffer tests exercise native and fallback paths, embedded NULs, frozen inputs,
  empty fragments, and compacted Ruby objects. Benchmarks include `Array#join`
  and the few-large-batches case.
- Collection pre-rendering now accumulates fragments and assembles the final
  buffer in a single pass via `Renderhive::Buffer.join` instead of repeated
  `SafeBuffer#<<` appends.
- CPU-bound workloads on MRI now use a conservative worker count to reduce
  thread overhead.
- Executor error propagation now stores only the first worker exception,
  cutting allocations on the failure path.
- The native extension now depends on `magnus` 0.9 (was 0.7), which builds
  against Ruby 4.0. magnus 0.7 failed to compile there (`RTypedData` layout
  changed). Still builds on Ruby 3.4.

## [0.1.0] - 2026-05-26

### Added
- Initial release.
- `Renderhive::ViewParallelism` controller concern with the `parallelize_view_methods`
  and `parallelize_partial_collection` DSL.
- Persistent thread-pool executor (`Renderhive::Executor`) with
  `caller_runs` fallback and optional `needs_db:` toggle.
- Pre-resolved template + per-worker `view_context.dup` rendering pipeline.
- `view_methods.renderhive` and `view_collection.renderhive`
  ActiveSupport::Notifications instrumentation.
