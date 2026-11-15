# Product Guide: JevDSL

## Overview
**JevDSL** (`jev_dsl`) is a declarative Elixir DSL and two-tier content-addressed caching layer for semantic judgment contracts, built initially on top of TypeSafe Jev (`SystemOneSDK`) and extensible to compatible decision backends such as the Gemini Decisions API.

## Target Users
- Elixir and Phoenix application developers building LLM-backed classification, scoring, triage, and routing workflows.
- Teams needing compile-time validated judgment contracts, deterministic testing, and low-latency content-addressed caching.

## Core Goals
1. **Compile-Time Contract Safety:** Validate rubrics, choice/score clauses, and aliases at compile time with clear `CompileError` diagnostics.
2. **Predictable Ergonomics:** Compile choice/score clauses to atoms in declaration order, provide ergonomic answer helpers (`fetch_answer/2`, `choice?/2`, `probability/2`), and support CUE schema export (`__export_cue__/0`).
3. **Zero-Copy & Two-Tier Caching:** Store pre-encoded wire payloads in `:persistent_term` for `O(1)` access and provide SHA-256 content-addressed L1 (`JevDSL.Cache.ETS`) + pluggable L2 caching with confidence-gated TTLs and offline replay (`cache_only: true`).
4. **Backend Extensibility & Testability:** Support deterministic testing (`SystemOneSDK.Test`, `:eval_fn`, offline cache replay) and multiple decision API backends (e.g., TypeSafe Jev and Gemini Decisions API via LiteLLM or native passthrough).
