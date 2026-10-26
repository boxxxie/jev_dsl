# JevDSL

[![Hex.pm](https://img.shields.io/hexpm/v/jev_dsl.svg)](https://hex.pm/packages/jev_dsl)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/jev_dsl)

**Declarative Elixir DSL and two-tier caching layer for [TypeSafe Jev (`SystemOneSDK`)](https://hex.pm/packages/system_one_sdk).**

Write semantic judgment contracts (`defnoul`, `defchoice`, `defscore`, `defjev`) as clean Elixir macros. `JevDSL` validates every contract at compile time, caches wire payloads in `:persistent_term`, and provides content-addressed L1/L2 caching out of the box.

---

## Features

| Feature | Highlights |
| :--- | :--- |
| **Compile-Time DSL** | Define `defnoul`, `defchoice`, `defscore`, `defjev`, and `defalias` blocks validated at build time via `SystemOneSDK.prepare/1`. Invalid rubrics or broken aliases raise a `CompileError` with exact file and line numbers. |
| **Predictable Atom Keys** | Choice clauses (`positive -> "..."`) compile to atoms (`:positive`) in declaration order for clean pattern matching. Contract lookups and helpers (`fetch_answer/2`, `choice?/2`, `probability/2`) accept both atoms and strings. |
| **Zero-Copy Wire Payloads** | Pre-encoded `Jason.Fragment` payloads are rehydrated once and stored in `:persistent_term` for `O(1)` access across all BEAM processes. |
| **Content-Addressed Cache** | SHA-256 cache keys (`"jev_<sha256>"`) combine the canonicalized input `state` with the contract's `Prepared.fingerprint`. Editing a prompt or rubric automatically invalidates stale entries. |
| **Confidence-Gated TTLs** | High-confidence judgments (`>= 0.65`) cache for the full TTL (7 days), ambiguous judgments (`< 0.65`) cache for 5 minutes, and transient errors are never cached. |
| **Two-Tier L1 + L2 Runner** | Built-in ETS L1 cache (`JevDSL.Cache.ETS`) plus pluggable L2 storage (`get_many/2` / `put_many/2`) with automatic L2 → L1 warming, L1 → L2 backfill, and `cache_only: true` offline replay. |
| **First-Class Testing** | Test deterministically with `SystemOneSDK.Test.client()` transport stubs, 1-arity `:eval_fn` mocks, or offline cache fixtures. |
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
