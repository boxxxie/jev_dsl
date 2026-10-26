# Changelog

All notable changes to `jev_dsl` are documented in this file.

## [0.1.0] - 2026-10-26

### Added
- **`JevDSL` Compile-Time Contract DSL**:
  - `defnoul/1..3` for single probability (`0.0..1.0`) Noul contracts, supporting prompt blocks, `ask: "..."`, and `true -> "..."` / `false -> "..."` criteria stab clauses.
  - `defchoice/2..3` for mutually exclusive multi-option classification contracts (`option -> "criteria"`), preserving stab-clause declaration order via `SystemOneSDK.Question.Choice`.
  - `defscore/2..3` for ordered rubric grading scale contracts (`level -> "criteria"`) via `SystemOneSDK.Question.Score`.
  - `defjev/2` for multi-question contracts combining `noul`, `choice`, and `score` questions in a single request.
  - `defalias/2` for zero-cost compile-time contract aliasing with duplicate/collision detection.
  - Atom-by-default stab-clause compilation (`keys: :atoms`, configurable via `keys: :atoms | :strings` on `defchoice`, `defscore`, `defjev`, `use JevDSL`, and `evaluate/3`), plus full atom/string interoperability across contract names, question names, and dual-key answer helpers (`JevDSL.fetch_answer/2`, `JevDSL.fetch_answer!/2`, `JevDSL.choice?/2`, `JevDSL.probability/2`).
  - Compile-time option validation via `NimbleOptions` and `SystemOneSDK.prepare/1` validation raising `CompileError` with caller file/line numbers, plus `:persistent_term` `Jason.Fragment` wire payload rehydration.
- **`JevDSL.Cache` & `JevDSL.Cache.ETS`**:
  - Pluggable `@behaviour JevDSL.Cache` (`get/2`, `put/3`, optional `get_many/2`, `put_many/2`) with `adapter_get_many/3` and `adapter_put_many/3`.
  - Content-addressed SHA-256 cache key generation (`JevDSL.Cache.key/3`) combining recursively canonicalized input state (structs, maps, lists, tuples) and the contract's `SystemOneSDK.Prepared` fingerprint.
  - Confidence-gated TTL resolution (`>= 0.65` full TTL, `< 0.65` short `300s` TTL for `ChoiceAnswer`, `NoulAnswer`, and `ScoreAnswer`, errors never cached).
  - Built-in concurrent ETS L1 cache (`JevDSL.Cache.ETS`) with `GenServer` supervision (`start_link/1`, `child_spec/1`), `:kernel_sup` `:heir` protection for unsupervised on-demand tables, and `prune_expired/1`.
- **`JevDSL.Runner` & `JevDSL.Error`**:
  - Single (`evaluate/3`, `evaluate!/3`) and concurrent batch (`evaluate_many/3`) execution with batch L1/L2 lookup (`get_many/2`), L2 -> L1 warming, L1 -> L2 backfill, independent `:use_tier2_cache` and `:persist_tier2` controls, offline cache-only replay (`cache_only: true`), `SystemOneSDK.Test` client support, and `:eval_fn` mocking.
  - Structured `JevDSL.Error` exception (`defexception [:type, :message, :contract, :details]`) and `:telemetry.span/3` instrumentation (`[:jev_dsl, :evaluate, *]`, `[:jev_dsl, :evaluate_many, *]`, `[:jev_dsl, :cache, :hit | :miss | :write]`).
- **`JevDSL.CUE` & `Mix.Tasks.JevDsl.Install`**:
  - Deterministic CUE schema exporter (`__export_cue__/0`).
  - Optional Igniter installer task (`mix igniter.install jev_dsl`).
