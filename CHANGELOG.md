# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `workload:` hints for `parallelize_view_methods` and `parallelize_partial_collection`
  with `:auto`, `:io` and `:cpu` modes.
- Richer `ActiveSupport::Notifications` payloads including `workload`, `workers`,
  `chunk_size` and `elapsed_ms`.

### Changed
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
