<!-- jev_dsl-start -->
# JevDSL Usage Rules

Rules for LLMs and developers working with `jev_dsl` — the compile-time contract DSL, two-tier content-addressed cache, and execution runner for TypeSafe Jev (`SystemOneSDK`).

## Core Principles

- **Define all contracts at compile time (`use JevDSL`):** Never construct ad-hoc question maps at runtime or load `.json` prompt files when a contract can be declared with `defnoul`, `defchoice`, `defscore`, or `defjev`. Compile-time contracts validate question definitions via `SystemOneSDK.prepare/1` during compilation and cache `Jason.Fragment` wire payloads in `:persistent_term`.
- **Stab-clause keys are `:atoms` by default (`keys: :atoms | :strings`):** In `defchoice` and `choice`, `positive -> "..."` compiles to the `:positive` atom by default so `response.answers.tone.choice == :positive` and `response.answers.tone.probabilities.positive` work with standard Elixir pattern matching. Pass `keys: :strings` on `defchoice`, `choice`, `defjev`, `use JevDSL`, or `evaluate/3` when you explicitly want string keys (`"positive"`). Contract names, question names, and answer helpers (`JevDSL.fetch_answer/2`, `JevDSL.choice?/2`, `JevDSL.probability/2`) accept both atoms and strings interchangeably.
- **Never hash `state` without the contract fingerprint:** Always compute cache keys via `MyContracts.cache_key(contract_key, state)` or `JevDSL.Cache.key(state, prepared)`. Editing a prompt or rubric criterion changes `prepared.fingerprint` at compile time and automatically invalidates stale cached judgments.
- **Always use `evaluate_many/3` for batches:** Never wrap single `evaluate/3` calls in `Task.async_stream/3` (which bottlenecks on `:httpc` connection serialization). `MyContracts.evaluate_many/3` resolves L1/L2 cache hits in bulk (`get_many/2`) and fans out only uncached misses via `SystemOneSDK.evaluate_many/4`.

## Canonical Usage (`# ✅ DO` vs `# ❌ DON'T`)

### 1. Defining Contracts (`defnoul`, `defchoice`, `defscore`, `defjev`, `defalias`)

```elixir
# ✅ DO: Define contracts at compile time with use JevDSL
defmodule MyApp.TriageContracts do
  use JevDSL,
    otp_app: :my_app,
    cache: JevDSL.Cache.ETS,
    tier2_cache: MyApp.JevParquetCache

  # Single boolean probability (0.0..1.0)
  defnoul :is_spam, as: :spam_detected do
    "Does this message contain unsolicited promotional spam?"
  end

  # Noul with explicit true/false criteria
  defnoul :is_urgent, ask: "Does this ticket require immediate paging?" do
    true -> "Production outage or active security breach."
    false -> "Routine bug report or feature request."
  end

  # Mutually exclusive classification (stab clauses compile to atoms by default: :positive, :neutral, :negative)
  defchoice :sentiment,
    as: :tone,
    keys: :atoms, # default (:atoms | :strings)
    ask: "Classify the overall tone of the message." do
    positive -> "Constructive, appreciative, or favorable tone."
    neutral -> "Factual or informational without strong emotion."
    negative -> "Critical, frustrated, or dissatisfied tone."
  end

  # Explicit `keys: :strings` when string choice keys are desired
  defchoice :csv_column_mapping,
    as: :mapped_field,
    keys: :strings,
    ask: "Map the CSV column header to a schema field." do
    "given_name" -> "First name of the user."
    "Needs Review" -> "Ambiguous column requiring manual check."
    "UNMAPPED" -> "Does not map to a known field."
  end

  # Ordered rubric grading scale (2..10 levels)
  defscore :completeness,
    ask: "Rate how complete the submission is." do
    incomplete -> "Missing required identity or contact fields."
    partial -> "Core fields are present but optional context is missing."
    complete -> "All required and optional fields are populated."
  end

  # Multi-question bundle evaluated in a single HTTP request
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
      vague -> "No reproduction steps provided."
      clear -> "Includes clear steps and expected vs actual behavior."
    end
  end

  defalias :triage, :ticket_triage
end
```

### 2. Evaluating & Reading Answers

```elixir
# ✅ DO: Pattern match directly on atom keys (default `keys: :atoms`) or use helpers
{:ok, response} = MyApp.TriageContracts.evaluate(:sentiment, %{text: "Great work!"})
%{choice: :positive, probabilities: %{positive: p}} = response.answers.tone

# Or use atom/string-safe helpers
{:ok, tone} = JevDSL.fetch_answer(response, :tone)
if JevDSL.choice?(tone, :positive) do
  {:ok, ^p} = JevDSL.probability(tone, :positive)
end

# ✅ DO: Pass `keys: :strings` (on `defchoice` or `evaluate/3`) when you want string choice keys
{:ok, str_resp} = MyApp.TriageContracts.evaluate(:sentiment, %{text: "Great work!"}, keys: :strings)
# str_resp.answers.tone.choice => "positive"

# ✅ DO: Use evaluate_many/3 for concurrent batch evaluation
results = MyApp.TriageContracts.evaluate_many(:is_spam, [%{text: "a"}, %{text: "b"}])

# ❌ DON'T: Never wrap single evaluate/3 calls in Task.async_stream
Task.async_stream(states, &MyApp.TriageContracts.evaluate(:is_spam, &1))
```

### 3. Testing with `SystemOneSDK.Test`, `:eval_fn`, and `async: true`

```elixir
# ✅ DO: Isolate ETS tables per test for `async: true` and use SystemOneSDK.Test or :eval_fn
setup do
  uid = System.unique_integer([:positive])
  table = :"jev_test_#{uid}"
  start_supervised!({JevDSL.Cache.ETS, name: :"ets_#{uid}", table: table})
  {:ok, cache_opts: [ets_table: table]}
end

test "evaluates through SystemOneSDK.Test transport", %{cache_opts: cache_opts} do
  client =
    SystemOneSDK.Test.client()
    |> SystemOneSDK.Test.stub(tone: {:choice, "positive", 0.92})

  assert {:ok, resp} =
           MyApp.TriageContracts.evaluate(:sentiment, %{text: "hi"}, [client: client] ++ cache_opts)

  assert JevDSL.choice?(JevDSL.fetch_answer!(resp, :tone), :positive)
  SystemOneSDK.Test.verify!(client)
  SystemOneSDK.Test.close(client)
end
```
<!-- jev_dsl-end -->
