<!-- system_one_dsl-start -->
# SystemOneDSL Usage Rules

Rules for LLMs and developers working with `system_one_dsl` — the compile-time contract DSL, two-tier content-addressed cache, and execution runner for `SystemOneSDK` (TypeSafe Jev) and compatible decision backends (`gemini-decision-1`).

## Core Principles

- **Define all contracts at compile time (`use SystemOneDSL`):** Never construct ad-hoc question maps at runtime or load `.json` prompt files when a contract can be declared with `defnoul`, `defchoice`, `defscore`, `defcontract`, or `defjev`. Compile-time contracts validate question definitions via `SystemOneSDK.prepare/1` during compilation and cache `Jason.Fragment` wire payloads in `:persistent_term`.
- **Choice stab-clause symbols compile to atoms:** In `defchoice` and `choice`, `positive -> "..."` compiles to the `:positive` atom so `response.answers.tone.choice == :positive` and `response.answers.tone.probabilities.positive` work directly with standard Elixir pattern matching. Contract names, question names, and answer helpers (`SystemOneDSL.fetch_answer/2`, `SystemOneDSL.choice?/2`, `SystemOneDSL.probability/2`) accept both atoms and strings.
- **Never hash `state` without the contract fingerprint:** Always compute cache keys via `MyContracts.cache_key(contract_key, state)` or `SystemOneDSL.Cache.key(state, prepared)`. Editing a prompt or rubric criterion changes `prepared.fingerprint` at compile time and automatically invalidates stale cached judgments.
- **Always use `evaluate_many/3` for batches:** Never wrap single `evaluate/3` calls in `Task.async_stream/3` (which bottlenecks on `:httpc` connection serialization). `MyContracts.evaluate_many/3` resolves L1/L2 cache hits in bulk (`get_many/2`) and fans out only uncached misses via `SystemOneSDK.evaluate_many/4`.

## Canonical Usage (`# ✅ DO` vs `# ❌ DON'T`)

### 1. Defining Contracts (`defnoul`, `defchoice`, `defscore`, `defcontract`, `defjev`, `defalias`)

```elixir
# ✅ DO: Define contracts at compile time with use SystemOneDSL
defmodule MyApp.TriageContracts do
  use SystemOneDSL,
    otp_app: :my_app,
    cache: SystemOneDSL.Cache.ETS,
    tier2_cache: MyApp.ContractParquetCache

  # Single boolean probability (0.0..1.0)
  defnoul :is_spam, as: :spam_detected do
    "Does this message contain unsolicited promotional spam?"
  end

  # Noul with explicit true/false criteria
  defnoul :is_urgent, ask: "Does this ticket require immediate paging?" do
    true -> "Production outage or active security breach."
    false -> "Routine bug report or feature request."
  end

  # Mutually exclusive classification (stab clauses compile to atoms: :positive, :neutral, :negative)
  defchoice :sentiment,
    as: :tone,
    ask: "Classify the overall tone of the message." do
    positive -> "Constructive, appreciative, or favorable tone."
    neutral -> "Factual or informational without strong emotion."
    negative -> "Critical, frustrated, or dissatisfied tone."
  end

  # Ordered rubric grading scale (2..10 levels)
  defscore :completeness,
    ask: "Rate how complete the submission is." do
    incomplete -> "Missing required identity or contact fields."
    partial -> "Core fields are present but optional context is missing."
    complete -> "All required and optional fields are populated."
  end

  # Multi-question bundle evaluated in a single HTTP request (`defjev` is an alias)
  defcontract :ticket_triage do
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
# ✅ DO: Pattern match directly on atom keys or use helpers
{:ok, response} = MyApp.TriageContracts.evaluate(:sentiment, %{text: "Great work!"})
%{choice: :positive, probabilities: %{positive: p}} = response.answers.tone

# Or use atom/string-safe helpers
{:ok, tone} = SystemOneDSL.fetch_answer(response, :tone)
if SystemOneDSL.choice?(tone, :positive) do
  {:ok, ^p} = SystemOneDSL.probability(tone, :positive)
end

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
  table = :"s1_test_#{uid}"
  start_supervised!({SystemOneDSL.Cache.ETS, name: :"ets_#{uid}", table: table})
  {:ok, cache_opts: [ets_table: table]}
end

test "evaluates through SystemOneSDK.Test transport", %{cache_opts: cache_opts} do
  client =
    SystemOneSDK.Test.client()
    |> SystemOneSDK.Test.stub(tone: {:choice, "positive", 0.92})

  assert {:ok, resp} =
           MyApp.TriageContracts.evaluate(:sentiment, %{text: "hi"}, [client: client] ++ cache_opts)

  assert SystemOneDSL.choice?(SystemOneDSL.fetch_answer!(resp, :tone), :positive)
  SystemOneSDK.Test.verify!(client)
  SystemOneSDK.Test.close(client)
end
```

### 4. Gemini Decisions Backend (`gemini-decision-1`)

- Set `backend: :gemini_decisions` on `use SystemOneDSL` or per-call options.
- Use `decisions_mode: :unified` (default, `/v1/decisions`, `Authorization: Bearer`) or `decisions_mode: :native` (`/gemini/v1beta/decisions` or `/v1beta/decisions`, `x-goog-api-key`).
- Cache keys automatically include backend, `decisions_mode`, and `model` so cached entries never collide across providers.
<!-- system_one_dsl-end -->
