# Implementation Plan: Support Gemini Decisions API (`gemini-decision-1`)

## Phase 1: Design & Backend Abstraction
- [x] Task: Audit `SystemOneSDK` transport/provider hooks and define `JevDSL` backend configuration schema bc2d559
    - [x] Write Tests: Add unit tests for backend option validation (`:backend`, `:base_url`, `:model`, `:auth_mode` / `x-goog-api-key` vs `Bearer`) in `NimbleOptions`
    - [x] Implement: Extend `JevDSL` and `JevDSL.Runner` option schemas to accept Gemini Decisions backend configuration without breaking existing `SystemOneSDK` defaults
- [x] Task: Define request/response adapter behaviour for decision backends 95a2e94
    - [x] Write Tests: Add unit tests covering backend resolution (`:system_one` vs `:gemini_decisions`) and cache key isolation across backends/models
    - [x] Implement: Introduce internal backend adapter module/behaviour and wire `JevDSL.Runner.available?/3` and `cache_key/2`
- [x] Task: Conductor - User Manual Verification 'Design & Backend Abstraction' (Protocol in workflow.md)

## Phase 2: Gemini Decisions Wire Protocol & Response Normalization
- [x] Task: Implement request payload builder for Gemini Decisions (`/v1/decisions` and `/v1beta/decisions`) bccc4f8
    - [x] Write Tests: Write unit tests verifying `:noul`, `:choice`, and `:score` (plus multi-question `defjev`) translation into Gemini Decisions request payloads and headers (`Authorization: Bearer` vs `x-goog-api-key`)
    - [x] Implement: Build the Gemini Decisions request encoder and header builder
- [x] Task: Implement response normalizer for unified (`/v1/decisions`) and native (`/v1beta/decisions`) formats 38b4054
    - [x] Write Tests: Write unit tests verifying normalization of `probability` + `input_tokens`/`output_tokens` (unified) and `confidence` + `total_input_tokens`/`total_output_tokens` (native) into `JevDSL` answer shapes (`fetch_answer/2`, `choice?/2`, `probability/2`, and confidence-gated TTLs)
    - [x] Implement: Build the response parser and error mapper (`JevDSL.Error`) for Gemini Decisions HTTP/API errors
- [x] Task: Conductor - User Manual Verification 'Gemini Decisions Wire Protocol & Response Normalization' (Protocol in workflow.md)

## Phase 3: Runner Integration, Caching, Batching & Docs
- [x] Task: Integrate Gemini Decisions adapter into `JevDSL.Runner` (`evaluate/3`, `evaluate!/3`, `evaluate_many/3`) 51a5efa
    - [x] Write Tests: Write 4-layer ATDD executable specifications (Layer 1 domain specs + Layer 2 DSL + Layer 3 stubbed HTTP/cache drivers, `async: true`) covering single evaluation, concurrent `evaluate_many/3`, L1/L2 cache hits/backfill, `cache_only: true`, and `:telemetry` events
    - [x] Implement: Wire the Gemini Decisions adapter into `JevDSL.Runner` execution and batching pipeline
- [x] Task: Add tagged live smoke test and update documentation 699e63c
    - [x] Write Tests: Add an excluded-by-default `@tag :live` smoke test for `gemini-decision-1` (unified and native passthrough)
    - [x] Implement: Update `README.md`, `usage-rules.md`, and `@moduledoc`/`@doc` examples; run `mix precommit` and verify >80% coverage
- [x] Task: Conductor - User Manual Verification 'Runner Integration, Caching, Batching & Docs' (Protocol in workflow.md)
