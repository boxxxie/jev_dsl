# Changelog

All notable changes to `jev_dsl` are documented in this file.

## [0.1.0] - 2026-10-26

### Added
- **`JevDSL` Compile-Time Contract DSL**:
  - `defnoul/2` for single probability (`0.0..1.0`) Noul contracts.
  - `defchoice/2..3` for mutually exclusive multi-option classification contracts (`option -> "criteria"`).
  - `defscore/2..3` for ordered rubric grading scale contracts (`level -> "criteria"`).
  - `defjev/2` for multi-question contracts combining `noul`, `choice`, and `score` questions in a single request.
  - `defalias/2` for zero-cost compile-time contract aliasing.
  - Compile-time validation via `SystemOneSDK.prepare/1` and `:persistent_term` `Jason.Fragment` wire payload rehydration.
- **`JevDSL.Cache` & `JevDSL.Cache.ETS`**:
  - Pluggable `@behaviour JevDSL.Cache` (`get/2`, `put/3`, optional `get_many/2`, `put_many/2`).
  - Content-addressed SHA-256 cache key generation (`JevDSL.Cache.key/3`) combining canonicalized input state and the contract's `SystemOneSDK.Prepared` fingerprint.
  - Confidence-gated TTL resolution (`>= 0.65` full TTL, `< 0.65` short `300s` TTL, errors never cached).
  - Built-in concurrent ETS L1 cache (`JevDSL.Cache.ETS`).
- **`JevDSL.Runner`**:
  - Single (`evaluate/3`) and concurrent batch (`evaluate_many/3`) execution with automatic L1/L2 cache lookup, L2 -> L1 warming, L1 -> L2 backfill, offline cache-only replay (`cache_only: true`), and deterministic test mocking (`:eval_fn`).
- **`JevDSL.CUE`**:
  - Deterministic CUE schema exporter (`__export_cue__/0`).
