# JevDSL

[![Hex.pm](https://img.shields.io/hexpm/v/jev_dsl.svg)](https://hex.pm/packages/jev_dsl)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/jev_dsl)

**Compile-time contract DSL, two-tier content-addressed caching layer, and execution runner for [TypeSafe Jev (`SystemOneSDK`)](https://hex.pm/packages/system_one_sdk).**

`JevDSL` compiles semantic judgment contracts (`noul`, `choice`, `score`, and multi-question `defjev` bundles) into validated `%SystemOneSDK.Prepared{}` structs at compile time, caches their pre-encoded `Jason.Fragment` wire payloads in `:persistent_term`, and provides content-addressed SHA-256 L1/L2 caching so prompt or rubric edits automatically invalidate stale cache entries.

---

## Features

- **Compile-Time Validation**: Every `defnoul`, `defchoice`, `defscore`, `defjev`, and `defalias` block is validated at compile time via `SystemOneSDK.prepare/1`. Invalid criteria, duplicate contract names, or broken aliases raise a `CompileError` with exact file and line numbers before your app boots.
- **Atom & String Interoperability**: Contract keys, question keys, stab-clause keys, `evaluate/3` lookups, and answer helpers (`JevDSL.fetch_answer/2`, `JevDSL.choice?/2`, `JevDSL.probability/2`) accept atoms and strings interchangeably, plus `keys: :strings | :atoms` response key transformation.
- **Zero Re-Serialization Overhead**: Prepared wire payloads (`Jason.Fragment`) are rehydrated once and cached in `:persistent_term` for $O(1)$ access across all BEAM processes.
- **Content-Addressed SHA-256 Caching (`JevDSL.Cache`)**: Cache keys (`"jev_<sha256>"`) combine the recursively canonicalized input `state` (maps, structs, lists, tuples) and the compiled `SystemOneSDK.Prepared.fingerprint`. Editing a prompt or rubric immediately produces a new fingerprint and cache key—never serving stale judgments.
- **Confidence-Gated TTLs**: High-confidence judgments (`>= 0.65`) are cached for the full TTL (default 7 days), ambiguous judgments (`< 0.65`) receive a short 5-minute TTL, and transient errors are never cached.
- **Two-Tier (L1 + L2) Execution (`JevDSL.Runner`)**: Ships with a concurrent ETS L1 cache (`JevDSL.Cache.ETS`) supporting both caller supervision (`start_link/1` + periodic TTL pruning) and zero-config `:kernel_sup` heir protection, plus pluggable L1/L2 adapters (`get_many/2` / `put_many/2`) with automatic L2 $\to$ L1 warming, L1 $\to$ L2 backfill, and offline replay (`cache_only: true`).
- **First-Class Testing (`SystemOneSDK.Test` & `:eval_fn`)**: Works seamlessly with `SystemOneSDK.Test.client()` transport stubs, 1-arity `:eval_fn` mocks, or `cache_only: true` offline fixtures.
- **Igniter Installer (`Mix.Tasks.JevDsl.Install`)**: Run `mix igniter.install jev_dsl` to automatically configure `.formatter.exs` and optionally scaffold a contract module.
- **CUE Schema Export (`JevDSL.CUE`)**: Export all contracts in a module to a deterministic CUE schema via `__export_cue__/0`.

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

  # 2. Single Choice (stab clauses compile to atoms by default: :positive, :neutral, :negative)
  defchoice :sentiment,
    as: :tone,
    ask: "Classify the overall tone of the message." do
    positive -> "Constructive, appreciative, or favorable tone."
    neutral -> "Factual or informational without strong emotion."
    negative -> "Critical, frustrated, or dissatisfied tone."
  end

  # 2b. Explicit `keys: :strings` when you want string choice keys (or string keys with spaces)
  defchoice :csv_column_mapping,
    as: :mapped_field,
    keys: :strings,
    ask: "Map the CSV column header to a canonical user schema field." do
    "given_name" -> "First or given name of the user."
    "family_name" -> "Last name or surname of the user."
    "Needs Review" -> "Ambiguous header that requires human review."
    "UNMAPPED" -> "Does not correspond to any known schema field."
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
# Single evaluation (choice answers return atoms by default: response.answers.tone.choice == :positive)
{:ok, response} =
  MyApp.TriageContracts.evaluate(:sentiment, %{
    subject: "Thank you!",
    body: "The new release is super fast."
  })

# Pattern match directly on atom keys:
%{choice: :positive, probabilities: %{positive: prob}} = response.answers.tone

# Or use atom/string-safe answer helpers:
{:ok, tone} = JevDSL.fetch_answer(response, :tone)
true = JevDSL.choice?(tone, :positive)
{:ok, ^prob} = JevDSL.probability(tone, :positive)

# Or override at runtime with `keys: :strings` (or `keys: :atoms`)
{:ok, str_resp} =
  MyApp.TriageContracts.evaluate(:sentiment, %{body: "Great!"}, keys: :strings)
# str_resp.answers.tone.choice => "positive"

# Concurrent batch evaluation (resolves L1/L2 cache hits via get_many/2 first, dispatches only misses)
results =
  MyApp.TriageContracts.evaluate_many(:is_spam, [
    %{body: "Buy cheap followers now"},
    %{body: "Can we schedule our Q4 architecture review?"}
  ])
```

### Configuration & Supervision

Configure your API key via application config, runtime options, or `TYPESAFE_API_KEY`:

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
