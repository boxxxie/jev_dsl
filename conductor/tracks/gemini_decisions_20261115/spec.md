# Track `gemini_decisions_20261115`: Support Gemini Decisions API (`gemini-decision-1`)

## Overview
Add first-class support in `JevDSL` for evaluating semantic judgment contracts against Google's **Gemini Decisions API** (`gemini-decision-1`), supporting both:
1. **LiteLLM Unified Endpoint** (`POST /v1/decisions` with `"model": "gemini-decision-1"`), and
2. **Native Gemini Decisions Passthrough** (`POST /gemini/v1beta/decisions` or direct Google Gemini `v1beta/decisions` using `x-goog-api-key`).

Existing `SystemOneSDK` contracts (`defnoul`, `defchoice`, `defscore`, `defjev`, `defalias`), two-tier L1/L2 caching (`JevDSL.Cache.ETS` / `JevDSL.Cache`), `:telemetry` spans, and deterministic testing must continue to work seamlessly while allowing per-module or per-call backend selection.

## Background & Observed Wire Behavior
LiteLLM (`1.111.0.dev4`) and Caddy proxy are configured to route `gemini-decision-1` on:
- **Unified `/v1/decisions`**:
  - Request includes `"model": "gemini-decision-1"`.
  - Response returns `"model": "gemini/gemini-decision-1"`, `"probability"` (e.g., `0.99`), `"input_tokens"`, `"output_tokens"`.
- **Native Gemini `/gemini/v1beta/decisions`** (`x-goog-api-key` header):
  - Response returns `"confidence"` (e.g., `0.97977...`), `"total_input_tokens"`, `"total_output_tokens"`.

## Functional Requirements
1. **Backend / Transport Abstraction:**
   - Introduce a clean backend/adapter option (e.g., `:backend` or `:provider` configuration on `use JevDSL` and `evaluate/3` / `evaluate_many/3`) so contracts can target `:system_one` (default) or `:gemini_decisions` (unified `/v1/decisions` or native `/gemini/v1beta/decisions`).
   - Support configuring `base_url`, `model` (defaulting to `"gemini-decision-1"`), `api_key` (including `x-goog-api-key` for native passthrough vs Bearer auth for LiteLLM `/v1/decisions`), and request/response translation.
2. **Request Mapping (`JevDSL.Contract` -> Gemini Decisions Payload):**
   - Translate `JevDSL.Contract` questions (`:noul`, `:choice`, `:score`) and input `state` into the Gemini Decisions request schema without breaking compile-time `SystemOneSDK.prepare/1` validation or `:persistent_term` caching.
   - Include backend/model identity in cache keys (or ensure cache keys remain collision-free across backends/models).
3. **Response Normalization (`Gemini Decisions` -> `JevDSL` Answer Shape):**
   - Normalize both unified `/v1/decisions` (`probability`, `input_tokens`, `output_tokens`) and native `/v1beta/decisions` (`confidence`, `total_input_tokens`, `total_output_tokens`) responses into the standard `JevDSL` response/answer structure so `JevDSL.fetch_answer/2`, `JevDSL.choice?/2`, `JevDSL.probability/2`, and confidence-gated TTLs (`>= 0.65` vs `< 0.65`) work identically.
4. **Concurrency, Caching, and Telemetry:**
   - Support `evaluate/3`, `evaluate!/3`, and `evaluate_many/3` with L1/L2 caching (`cache_only: true`, `:eval_fn` stubs, and HTTP transport stubs).
   - Emit existing `[:jev_dsl, :evaluate, ...]` and `[:jev_dsl, :evaluate_many, ...]` telemetry events with backend/model metadata.
5. **Documentation & Usage Rules:**
   - Update `README.md`, module `@moduledoc`/`@doc`, and `usage-rules.md` with configuration and usage examples for `gemini-decision-1` (both LiteLLM unified and native passthrough).

## Non-Functional Requirements
- Maintain zero breaking changes to existing `SystemOneSDK` users.
- Keep unit tests 100% deterministic and offline using transport stubs / `:eval_fn`; isolate any live `gemini-decision-1` smoke tests behind an ExUnit tag (e.g., `@moduletag :live`).
- Pass `mix precommit` (`format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `test`) and `mix dialyzer`.

## Acceptance Criteria
- [ ] `JevDSL` supports configuring `:gemini_decisions` (unified `/v1/decisions` and native `/v1beta/decisions` passthrough) at module level (`use JevDSL`) and call level (`evaluate/3`, `evaluate_many/3`).
- [ ] Both unified (`probability`) and native (`confidence`) responses normalize cleanly to `JevDSL` answer structs/maps and work with `fetch_answer/2`, `choice?/2`, and `probability/2`.
- [ ] Content-addressed L1/L2 caching and confidence-gated TTLs work identically for `gemini-decision-1` evaluations.
- [ ] Full offline unit test suite passes with >80% coverage, and `mix precommit` passes with zero warnings.

## Out of Scope
- Modifying LiteLLM proxy or Caddy infrastructure (already deployed and verified).
- Removing or deprecating `SystemOneSDK` support.
