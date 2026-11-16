# JevDSL

[![CI](https://github.com/boxxxie/jev_dsl/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/jev_dsl/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/jev_dsl.svg?logo=elixir&logoColor=white)](https://hex.pm/packages/jev_dsl)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/jev_dsl)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E%201.18-4B275F.svg?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![SystemOneSDK](https://img.shields.io/badge/SystemOneSDK-~%3E%200.6.0-3882D2.svg)](https://hex.pm/packages/system_one_sdk)
[![Gemini Decisions](https://img.shields.io/badge/Gemini-gemini--decision--1-4285F4.svg?logo=googlegemini&logoColor=white)](#gemini-decisions-api-gemini-decision-1)
[![Cache](https://img.shields.io/badge/cache-L1%20ETS%20%2B%20L2-orange.svg)](lib/jev_dsl/cache.ex)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Declarative Elixir DSL, multi-backend runner, and two-tier caching layer for [TypeSafe Jev (`SystemOneSDK`)](https://hex.pm/packages/system_one_sdk) and the [Gemini Decisions API (`gemini-decision-1`)](#gemini-decisions-api-gemini-decision-1).**

Write semantic judgment contracts (`defnoul`, `defchoice`, `defscore`, `defjev`) once as clean Elixir macros. `JevDSL` validates every contract at compile time, executes against either TypeSafe Jev or Google's Gemini Decisions API (via unified LiteLLM `/v1/decisions` or native `/v1beta/decisions`), caches wire payloads in `:persistent_term`, and provides content-addressed L1/L2 caching out of the box.

---

## Features

| Feature | Highlights |
| :--- | :--- |
| **Compile-Time DSL** | Define `defnoul`, `defchoice`, `defscore`, `defjev`, and `defalias` blocks validated at build time via `SystemOneSDK.prepare/1`. Invalid rubrics or broken aliases raise a `CompileError` with exact file and line numbers. |
| **Multi-Backend Runner** | Switch seamlessly between `:system_one` (TypeSafe Jev) and `:gemini_decisions` (`gemini-decision-1`) via LiteLLM unified `/v1/decisions` (`decisions_mode: :unified`) or native `/v1beta/decisions` / `/gemini/v1beta/decisions` (`decisions_mode: :native`), with `:bearer`, `:x_goog_api_key`, or `:none` auth. |
| **Predictable Atom Keys** | Choice clauses (`positive -> "..."`) compile to atoms (`:positive`) in declaration order for clean pattern matching. Contract lookups and helpers (`fetch_answer/2`, `choice?/2`, `probability/2`) accept both atoms and strings. |
| **Zero-Copy Wire Payloads** | Pre-encoded `Jason.Fragment` payloads are rehydrated once and stored in `:persistent_term` for `O(1)` access across all BEAM processes. |
| **Namespace-Isolated Cache** | SHA-256 cache keys (`"jev_<sha256>"`) combine the canonicalized input `state`, the contract's `Prepared.fingerprint`, and backend identity (`:system_one` vs `:gemini_decisions`, `decisions_mode`, `model`). Editing a prompt or changing models never collides or serves stale entries. |
| **Confidence-Gated TTLs** | High-confidence judgments (`>= 0.65`) cache for the full TTL (7 days), ambiguous judgments (`< 0.65`) cache for 5 minutes, and transient errors are never cached. |
| **Two-Tier L1 + L2 Runner** | Built-in ETS L1 cache (`JevDSL.Cache.ETS`) plus pluggable L2 storage (`get_many/2` / `put_many/2`) with automatic L2 → L1 warming, L1 → L2 backfill, and `cache_only: true` offline replay. |
| **First-Class Testing** | Test deterministically with `SystemOneSDK.Test.client()` transport stubs, custom `Pristine.Ports.Transport` stubs, 1-arity `:eval_fn` mocks, or offline cache fixtures. |
| **Igniter & CUE Tooling** | Install in one command with `mix igniter.install jev_dsl` and export contracts to deterministic CUE schemas via `__export_cue__/0`. |

---

## Installation

Install via [Igniter](https://hex.pm/packages/igniter):

```bash
mix igniter.install jev_dsl --module MyApp.TriageContracts --yes
```

Or add `jev_dsl` manually to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jev_dsl, "~> 0.1.0"}
  ]
end
```

And add `:jev_dsl` to `import_deps` in your `.formatter.exs`:

```elixir
[
  import_deps: [:jev_dsl],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

---

## Quick Start

Define a contract module with `use JevDSL`:

```elixir
defmodule MyApp.TriageContracts do
  use JevDSL,
    otp_app: :my_app,
    cache: JevDSL.Cache.ETS

  # 1. Single Noul (boolean probability 0.0..1.0)
  defnoul :is_spam do
    "Does this message contain unsolicited promotional spam?"
  end

  # 1b. Noul with explicit true/false criteria
  defnoul :is_urgent, ask: "Does this ticket require immediate paging?" do
    true -> "Production outage or active security breach."
    false -> "Routine bug report or feature request."
  end

  # 2. Single Choice (stab clauses compile to atoms: :positive, :neutral, :negative)
  defchoice :sentiment,
    as: :tone,
    ask: "Classify the overall tone of the message." do
    positive -> "Constructive, appreciative, or favorable tone."
    neutral -> "Factual or informational without strong emotion."
    negative -> "Critical, frustrated, or dissatisfied tone."
  end

  # 3. Single Score (ordered rubric scale 2..10 levels)
  defscore :completeness,
    ask: "Rate how complete the submission is." do
    incomplete -> "Missing required identity or contact fields."
    partial -> "Core fields are present but optional context is missing."
    complete -> "All identity, contact, and biographical fields are populated."
  end

  # 4. Multi-question contract evaluated in a single request
  defjev :ticket_triage do
    noul :requires_escalation do
      "Does this issue require immediate engineering escalation?"
    end

    choice :priority,
      ask: "Select the appropriate response priority." do
      urgent -> "Production outage or security incident."
      normal -> "Standard bug report or feature question."
    end

    score :clarity,
      ask: "Rate the clarity of the reproduction steps." do
      vague -> "No steps or environment details provided."
      clear -> "Includes clear steps and expected vs actual behavior."
    end
  end

  # 5. Alias an existing contract
  defalias :triage, :ticket_triage
end
```

---

## Evaluating Contracts

Every `use JevDSL` module automatically generates `evaluate/3`, `evaluate!/3`, `evaluate_many/3`, `available?/2`, `cache_key/2`, `contract/1`, `prepared/1`, `has_contract?/1`, `contract_fingerprint/1`, `__contracts__/0`, and `__export_cue__/0`:

```elixir
# Single evaluation (choice answers return atoms: response.answers.tone.choice == :positive)
{:ok, response} =
  MyApp.TriageContracts.evaluate(:sentiment, %{
    subject: "Thank you!",
    body: "The new release is super fast."
  })

# Pattern match directly on atom keys:
%{choice: :positive, probabilities: %{positive: prob}} = response.answers.tone

# Or use answer helpers:
{:ok, tone} = JevDSL.fetch_answer(response, :tone)
true = JevDSL.choice?(tone, :positive)
{:ok, ^prob} = JevDSL.probability(tone, :positive)

# Concurrent batch evaluation (resolves L1/L2 cache hits via get_many/2 first, dispatches only misses)
results =
  MyApp.TriageContracts.evaluate_many(:is_spam, [
    %{body: "Buy cheap followers now"},
    %{body: "Can we schedule our Q4 architecture review?"}
  ])
```

### Configuration & Supervision

Configure credentials and endpoints via `use JevDSL` options, `otp_app` runtime config, per-call overrides, or environment variables (`TYPESAFE_API_KEY` for `:system_one`; `LITELLM_API_KEY` / `LITELLM_BASE_URL` or `GEMINI_API_KEY` / `GEMINI_DECISIONS_BASE_URL` for `:gemini_decisions`):

```elixir
# config/runtime.exs
config :my_app, MyApp.TriageContracts,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  base_url: System.get_env("TYPESAFE_BASE_URL")
```

To supervise the ETS L1 cache with automatic periodic TTL pruning, add `JevDSL.Cache.ETS` to your application supervision tree:

```elixir
children = [
  {JevDSL.Cache.ETS, name: MyApp.JevCache, table: :jev_dsl_ets_cache}
]
```

### Gemini Decisions API (`gemini-decision-1`)

`JevDSL` supports Google's **Gemini Decisions API** (`gemini-decision-1`) via `backend: :gemini_decisions` (`SystemOneSDK.Providers.GeminiDecisions`) in two wire modes:

* **Unified LiteLLM (`decisions_mode: :unified`, default)** — sends `/v1/decisions` requests with `Authorization: Bearer <token>`. Requires an explicit `:base_url`, `otp_app` `:litellm_base_url`/`:base_url`, or `LITELLM_BASE_URL`.
* **Native Gemini (`decisions_mode: :native`)** — sends `/v1beta/decisions` (against `generativelanguage.googleapis.com`, the default native host, or proxies/gateways; pass `decisions_path: "/gemini/v1beta/decisions"` or a `/gemini` base URL for LiteLLM passthrough) with `x-goog-api-key`.
* **Keyless & Proxy Auth (`auth_mode: :none`)** — omits `Authorization` and `x-goog-api-key` headers for local proxies or mTLS/custom-header gateways (`extra_headers` / `headers`).

```elixir
# LiteLLM unified /v1/decisions (Authorization: Bearer)
defmodule MyApp.UnifiedGeminiContracts do
  use JevDSL,
    otp_app: :my_app,
    backend: :gemini_decisions,
    decisions_mode: :unified,
    model: "gemini-decision-1",
    base_url: "http://localhost:4000"

  defnoul :is_spam do
    "Does this message contain unsolicited promotional spam?"
  end
end

# Native /v1beta/decisions (x-goog-api-key)
defmodule MyApp.NativeGeminiContracts do
  use JevDSL,
    otp_app: :my_app,
    backend: :gemini_decisions,
    decisions_mode: :native,
    auth_mode: :x_goog_api_key,
    model: "gemini-decision-1",
    base_url: "https://generativelanguage.googleapis.com"

  defnoul :is_spam do
    "Does this message contain unsolicited promotional spam?"
  end
end
```

Key & endpoint resolution details:
* **API keys:** Resolved from `:gemini_api_key` / `:api_key` (supporting strings, `{:system, "ENV"}`, 0-arity functions, or `{mod, fun, args}`), `otp_app` / `:jev_dsl` app config, and environment variables. In `:native` mode targeting Google, `GEMINI_API_KEY` takes precedence over `LITELLM_API_KEY` / `LITELLM_MASTER_KEY`; in `:unified` or proxy modes, `LITELLM_*` takes precedence.
* **Per-call overrides & pre-built clients:** Pass `backend:`, `decisions_mode:`, `auth_mode:`, `decisions_path:`, `base_url:`, `model:`, `extra_body:`, or `extra_headers:` per `evaluate/3` or `evaluate_many/3` call—even when reusing a pre-built `SystemOneSDK.new_client(provider: SystemOneSDK.Providers.GeminiDecisions, ...)` client. Cache keys automatically isolate across backend, mode, and model.

---

## Custom L1 & Tier-2 Cache Adapters (`JevDSL.Cache`)

By default, `JevDSL` caches evaluations in [`JevDSL.Cache.ETS`](lib/jev_dsl/cache/ets.ex). You can plug in your own L1 cache (e.g., Memcached/Cachex/Redis) and/or a persistent Tier-2 cache (e.g., DuckDB, Parquet, or Postgres) by implementing `@behaviour JevDSL.Cache`:

```elixir
defmodule MyApp.Tier2ParquetCache do
  @behaviour JevDSL.Cache

  @impl true
  def get(cache_key, _opts) do
    case MyApp.Lakehouse.lookup_jev_hash(cache_key) do
      {:ok, response} -> {:ok, response}
      :miss -> :miss
    end
  end

  @impl true
  def get_many(cache_keys, _opts) do
    MyApp.Lakehouse.lookup_jev_hashes(cache_keys)
  end

  @impl true
  def put(cache_key, value, opts) do
    put_many([{cache_key, nil, %{}, value}], opts)
  end

  @impl true
  def put_many(entries, _opts) do
    # Each entry is {cache_key, contract_key, state, result}
    MyApp.Lakehouse.append_jev_evaluations(entries)
    :ok
  end
end
```

---

## Testing & Mocking

`JevDSL` supports three complementary testing modes:

1. **`SystemOneSDK.Test` Transport Stubs (Full Wire + Semantic Validation)**:
   ```elixir
   client =
     SystemOneSDK.Test.client()
     |> SystemOneSDK.Test.stub(tone: {:choice, "positive", 0.92})

   assert {:ok, resp} =
            MyApp.TriageContracts.evaluate(:sentiment, %{body: "Great!"}, client: client)

   SystemOneSDK.Test.verify!(client)
   SystemOneSDK.Test.close(client)
   ```

2. **1-Arity `:eval_fn` Injection**:
   ```elixir
   mock_fn = fn state ->
     {:ok, %{answers: %{is_spam: %{noul: if(state.body =~ "spam", do: 0.98, else: 0.02)}}}}
   end

   assert {:ok, %{answers: %{is_spam: %{noul: 0.98}}}} =
            MyApp.TriageContracts.evaluate(:is_spam, %{body: "free spam"}, eval_fn: mock_fn)
   ```

3. **Offline Cache Replay (`cache_only: true`)**:
   ```elixir
   assert {:error, :cache_miss} =
            MyApp.TriageContracts.evaluate(:is_spam, %{body: "uncached"}, cache_only: true)
   ```

---

## License

Released under the [MIT License](LICENSE).
