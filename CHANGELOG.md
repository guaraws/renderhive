# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Optional Rust extension (`renderhive_native`) that joins pre-rendered HTML
  fragments with a single allocation and a parallel, off-GVL byte copy
  (via `rayon`) for large payloads. Exposed through `Renderhive::Buffer.join`
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
- Collection pre-rendering now accumulates fragments and assembles the final
  buffer in a single pass via `Renderhive::Buffer.join` instead of repeated
  `SafeBuffer#<<` appends.
- CPU-bound workloads on MRI now use a conservative worker count to reduce
  thread overhead.
- Executor error propagation now stores only the first worker exception,
  cutting allocations on the failure path.

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
