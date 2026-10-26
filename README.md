# JevDSL

[![Hex.pm](https://img.shields.io/hexpm/v/jev_dsl.svg)](https://hex.pm/packages/jev_dsl)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/jev_dsl)

**Compile-time contract DSL, two-tier content-addressed caching layer, and execution runner for [TypeSafe Jev (`SystemOneSDK`)](https://hex.pm/packages/system_one_sdk).**

`JevDSL` compiles semantic judgment contracts (`noul`, `choice`, `score`, and multi-question `defjev` bundles) into validated `%SystemOneSDK.Prepared{}` structs at compile time, caches their pre-encoded `Jason.Fragment` wire payloads in `:persistent_term`, and provides content-addressed SHA-256 L1/L2 caching so prompt or rubric edits automatically invalidate stale cache entries.

---

## Features

- **Compile-Time Validation**: Every `defnoul`, `defchoice`, `defscore`, and `defjev` block is validated at compile time via `SystemOneSDK.prepare/1`. Invalid criteria, duplicate option keys, or malformed instructions raise a `CompileError` with exact file and line numbers before your app boots.
- **Zero Re-Serialization Overhead**: Prepared wire payloads (`Jason.Fragment`) are rehydrated once and cached in `:persistent_term` for $O(1)$ access across all BEAM processes.
- **Content-Addressed SHA-256 Caching (`JevDSL.Cache`)**: Cache keys (`"jev_<sha256>"`) combine the canonicalized input `state` and the compiled `SystemOneSDK.Prepared.fingerprint`. Editing a prompt or rubric immediately produces a new fingerprint and cache key—never serving stale judgments.
- **Confidence-Gated TTLs**: High-confidence judgments (`>= 0.65`) are cached for the full TTL (default 7 days), ambiguous judgments (`< 0.65`) receive a short 5-minute TTL, and transient errors are never cached.
- **Two-Tier (L1 + L2) Execution (`JevDSL.Runner`)**: Ships with a zero-dependency concurrent ETS L1 cache (`JevDSL.Cache.ETS`) and supports pluggable L1/L2 adapters (e.g. Memcached/Cachex L1 + DuckDB/Parquet or Postgres L2) with automatic L2 $\to$ L1 warming, L1 $\to$ L2 backfill, and offline cache-only replay (`cache_only: true`).
- **Deterministic Test Mocking**: Inject `:eval_fn` (a 1-arity function) or `cache_only: true` in tests without touching global state or network mocks.
- **CUE Schema Export (`JevDSL.CUE`)**: Export all contracts in a module to a deterministic CUE schema via `__export_cue__/0`.

---

## Installation

Add `jev_dsl` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jev_dsl, "~> 0.1.0"}
  ]
end
```

To format `defnoul`, `defchoice`, `defscore`, `defjev`, and `defalias` without parentheses, add `:jev_dsl` to `import_deps` in your `.formatter.exs`:

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

  # 2. Single Choice (mutually exclusive options)
  defchoice :sentiment,
    ask: "Classify the overall tone of the message." do
    positive -> "Constructive, appreciative, or favorable tone."
    neutral -> "Factual or informational without strong emotion."
    negative -> "Critical, frustrated, or dissatisfied tone."
  end

  # 3. Single Score (ordered rubric scale)
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

Every `use JevDSL` module automatically generates `evaluate/3`, `evaluate_many/3`, `available?/2`, `cache_key/2`, `prepared/1`, `has_contract?/1`, `contract_fingerprint/1`, `__contracts__/0`, and `__export_cue__/0`:

```elixir
# Single evaluation (automatically checks L1/L2 cache by state + fingerprint)
{:ok, response} =
  MyApp.TriageContracts.evaluate(:sentiment, %{
    subject: "Thank you!",
    body: "The new release is super fast."
  })

# Concurrent batch evaluation (resolves L1/L2 cache hits first, dispatches only misses)
results =
  MyApp.TriageContracts.evaluate_many(:is_spam, [
    %{body: "Buy cheap followers now"},
    %{body: "Can we schedule our Q4 architecture review?"}
  ])
```

### Configuration

Configure your API key via application config, runtime options, or `TYPESAFE_API_KEY`:

```elixir
# config/runtime.exs
config :my_app, MyApp.TriageContracts,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  base_url: System.get_env("TYPESAFE_BASE_URL")
```

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

Wire both tiers in `use JevDSL`:

```elixir
defmodule MyApp.Contracts do
  use JevDSL,
    otp_app: :my_app,
    cache: JevDSL.Cache.ETS,
    tier2_cache: MyApp.Tier2ParquetCache
end
```

When `cache_only: true` is passed (or when running offline in CI with a committed Tier-2 fixture), `JevDSL.Runner` serves deterministic hits from L1/`tier2_cache`, warms L1 from Tier-2, and returns `{:error, :cache_miss}` on misses without requiring an API key.

---

## Testing & Mocking

In unit and ATDD tests, inject a 1-arity `:eval_fn` function or pass `cache_only: true`:

```elixir
# Inject a deterministic 1-arity function
mock_fn = fn state ->
  {:ok, %{answers: %{is_spam: %{noul: if(state.body =~ "spam", do: 0.98, else: 0.02)}}}}
end

assert {:ok, %{answers: %{is_spam: %{noul: 0.98}}}} =
         MyApp.TriageContracts.evaluate(:is_spam, %{body: "free spam"}, eval_fn: mock_fn)

# Or run strictly against L1/L2 cached fixtures without making network calls
assert {:error, :cache_miss} =
         MyApp.TriageContracts.evaluate(:is_spam, %{body: "uncached"}, cache_only: true)
```

---

## License

Released under the [MIT License](LICENSE).
