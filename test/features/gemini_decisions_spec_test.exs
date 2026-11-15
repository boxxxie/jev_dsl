defmodule JevDSL.Features.GeminiDecisionsSpecTest do
  use ExUnit.Case, async: true

  import JevDSL.ATDD.GeminiDecisionsDSL

  defmodule TriageContracts do
    use JevDSL,
      otp_app: :jev_dsl,
      backend: :gemini_decisions,
      model: "gemini-decision-1"

    defnoul :is_spam do
      "Does this message contain unsolicited promotional spam?"
    end

    defchoice :sentiment,
      as: :tone,
      ask: "Classify the overall tone of the message." do
      positive -> "Constructive or appreciative."
      negative -> "Critical or frustrated."
    end

    defscore :clarity,
      ask: "Rate the clarity of the reproduction steps." do
      vague -> "Unclear"
      partial -> "Partial"
      clear -> "Clear"
    end

    defjev :full_triage do
      noul :urgent, ask: "Is this urgent?" do
        true -> "Production outage or blocking bug."
        false -> "Non-urgent request."
      end

      choice :priority, ask: "Select priority." do
        p0 -> "Outage"
        p2 -> "Routine"
      end

      score :completeness, ask: "Rate completeness." do
        incomplete -> "Missing fields"
        partial -> "Partial fields"
        complete -> "Complete"
      end
    end
  end

  test "evaluates a single judgment via unified /v1/decisions and caches hits across L1/L2" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn req ->
      assert req.path == "/v1/decisions"
      assert req.headers["Authorization"] == "Bearer test-gemini-key"

      {200,
       %{
         "model" => "gemini/gemini-decision-1",
         "answers" => [
           %{
             "name" => "tone",
             "choice" => "positive",
             "confidence" => 0.96,
             "probabilities" => [
               %{"value" => "positive", "probability" => 0.96},
               %{"value" => "negative", "probability" => 0.04}
             ]
           }
         ],
         "usage" => %{"input_tokens" => 93, "output_tokens" => 0}
       }}
    end)
    |> when_evaluating(:sentiment, %{body: "Thanks for the fast fix!"})
    |> then_choice_is(:tone, :positive, 0.95)
    |> then_network_calls(1)
    |> when_replaying_offline(:sentiment, %{body: "Thanks for the fast fix!"})
    |> then_choice_is(:tone, :positive, 0.95)
    |> then_network_calls(1)
    |> then_telemetry_recorded([[:jev_dsl, :evaluate, :stop]])
  end

  test "evaluates 3-level defscore end-to-end via unified /v1/decisions and native /gemini/v1beta/decisions on shared cache" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn req ->
      decoded = Jason.decode!(req.body)

      case req.path do
        "/v1/decisions" ->
          assert [%{"type" => "score", "name" => "clarity", "levels" => [_, _, _]}] =
                   decoded["questions"]

          {200,
           %{
             "model" => "gemini/gemini-decision-1",
             "answers" => [
               %{
                 "name" => "clarity",
                 "type" => "score",
                 "score" => 1.72,
                 "confidence" => 0.85,
                 "probabilities" => [
                   %{"value" => 0, "label" => "vague", "probability" => 0.05},
                   %{"value" => 1, "label" => "partial", "probability" => 0.10},
                   %{"value" => 2, "label" => "clear", "probability" => 0.85}
                 ]
               }
             ],
             "usage" => %{"input_tokens" => 102, "output_tokens" => 0}
           }}

        "/gemini/v1beta/decisions" ->
          assert %{
                   "clarity" => %{
                     "type" => "score",
                     "criteria" => ["Unclear", "Partial", "Clear"]
                   }
                 } = decoded["questions"]

          refute Map.has_key?(decoded["questions"]["clarity"], "levels")

          {200,
           %{
             "answers" => %{
               "clarity" => %{
                 "type" => "score",
                 "score" => 1.69,
                 "confidence" => 0.82,
                 "probabilities" => %{"0" => 0.05, "1" => 0.13, "2" => 0.82}
               }
             },
             "usageMetadata" => %{"totalInputTokens" => 99, "totalOutputTokens" => 0}
           }}
      end
    end)
    |> when_evaluating(:clarity, %{body: "Step 1: click save. Step 2: observe 500."})
    |> then_score_is(:clarity, :clear, 0.8)
    |> then_network_calls(1)
    |> when_switching_backend_mode(:native)
    |> when_evaluating(:clarity, %{body: "Step 1: click save. Step 2: observe 500."})
    |> then_score_is(:clarity, :clear, 0.8)
    |> then_network_calls(2)
  end

  test "evaluates multi-question defjev contracts with extra_body and extra_headers precedence" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn req ->
      decoded = Jason.decode!(req.body)
      assert decoded["trace_id"] == "req-123"
      assert decoded["model"] == "gemini-decision-1"
      assert req.headers["Authorization"] == "Bearer override-token"

      [urgent_q | _] = decoded["questions"]
      assert urgent_q["instructions"] =~ "Is this urgent?"
      assert urgent_q["instructions"] =~ "true: Production outage or blocking bug."
      refute Map.has_key?(urgent_q, "criteria")

      {200,
       %{
         "model" => "gemini/gemini-decision-1",
         "answers" => [
           %{"name" => "urgent", "type" => "predicate", "probability" => 0.94},
           %{
             "name" => "priority",
             "type" => "choice",
             "choice" => "p0",
             "confidence" => 0.92,
             "probabilities" => [
               %{"value" => "p0", "probability" => 0.92},
               %{"value" => "p2", "probability" => 0.08}
             ]
           },
           %{
             "name" => "completeness",
             "type" => "score",
             "score" => 1.75,
             "confidence" => 0.78,
             "probabilities" => [
               %{"value" => 0, "label" => "incomplete", "probability" => 0.05},
               %{"value" => 1, "label" => "partial", "probability" => 0.17},
               %{"value" => 2, "label" => "complete", "probability" => 0.78}
             ]
           }
         ],
         "usage" => %{"input_tokens" => 140, "output_tokens" => 0}
       }}
    end)
    |> when_evaluating(:full_triage, %{body: "Production DB is down"},
      extra_body: %{"trace_id" => "req-123"},
      extra_headers: %{"Authorization" => "Bearer override-token"}
    )
    |> then_noul_is(:urgent, 0.9)
    |> then_choice_is(:priority, :p0, 0.9)
    |> then_score_is(:completeness, :complete, 0.7)
    |> then_network_calls(1)
  end

  test "evaluates native /gemini/v1beta/decisions passthrough with x-goog-api-key" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :native)
    |> given_stubbed_responder(fn req ->
      assert req.path == "/gemini/v1beta/decisions"
      assert req.headers["x-goog-api-key"] == "test-gemini-key"

      {200,
       %{
         "confidence" => 0.9797708352463237,
         "total_input_tokens" => 94,
         "total_output_tokens" => 0
       }}
    end)
    |> when_evaluating(:is_spam, %{body: "Win a free prize now"})
    |> then_noul_is(:is_spam, 0.97)
    |> then_network_calls(1)
  end

  test "evaluates batches concurrently, serving cached hits and dispatching only misses" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn req ->
      decoded = Jason.decode!(req.body)

      choice =
        if String.contains?(decoded["input"], "happy"), do: "positive", else: "negative"

      {200,
       %{
         "model" => "gemini/gemini-decision-1",
         "answers" => [
           %{
             "name" => "tone",
             "choice" => choice,
             "confidence" => 0.91,
             "probabilities" => [
               %{"value" => "positive", "probability" => 0.91},
               %{"value" => "negative", "probability" => 0.09}
             ]
           }
         ],
         "usage" => %{"input_tokens" => 50, "output_tokens" => 0}
       }}
    end)
    |> when_evaluating(:sentiment, %{body: "happy customer"})
    |> then_network_calls(1)
    |> when_evaluating_many(:sentiment, [
      %{body: "happy customer"},
      %{body: "frustrated customer"}
    ])
    |> then_batch_choices_are(:tone, [:positive, :negative])
    |> then_network_calls(2)
    |> then_telemetry_recorded([[:jev_dsl, :evaluate_many, :stop]])
  end

  test "isolates runtime cache across :unified, :native, and model overrides on evaluate and evaluate_many" do
    state = %{body: "Please reset my password."}

    TriageContracts
    |> given_decision_backend(decisions_mode: :unified, model: "gemini-decision-1")
    |> given_stubbed_responder(fn req ->
      decoded = Jason.decode!(req.body)

      case {req.path, decoded["model"]} do
        {"/v1/decisions", "gemini-decision-1"} ->
          {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.04}]}}

        {"/gemini/v1beta/decisions", "gemini-decision-1"} ->
          {200, %{"answers" => %{"is_spam" => %{"noul" => false, "confidence" => 0.96}}}}

        {"/gemini/v1beta/decisions", "gemini-decision-2"} ->
          {200, %{"answers" => %{"is_spam" => %{"noul" => 0.02}}}}
      end
    end)
    |> when_evaluating(:is_spam, state)
    |> then_noul_below(:is_spam, 0.2)
    |> then_network_calls(1)
    |> when_switching_backend_mode(decisions_mode: :native, model: "gemini-decision-1")
    |> when_evaluating(:is_spam, state)
    |> then_noul_below(:is_spam, 0.2)
    |> then_network_calls(2)
    |> when_switching_backend_mode(decisions_mode: :native, model: "gemini-decision-2")
    |> when_evaluating(:is_spam, state)
    |> then_noul_below(:is_spam, 0.2)
    |> then_network_calls(3)
    |> when_evaluating_many(:is_spam, [state, %{body: "Another normal message"}])
    |> then_network_calls(4)
    |> when_switching_backend_mode(decisions_mode: :unified, model: "gemini-decision-1")
    |> when_evaluating_many(:is_spam, [state, %{body: "Another normal message"}])
    |> then_network_calls(5)
  end

  test "handles binary non-JSON HTTP error and malformed text bodies without crashing" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn _req -> {502, "Bad Gateway"} end)
    |> when_evaluating(:is_spam, %{body: "upstream 502"})
    |> then_error_is(:provider_error)
    |> then_network_calls(1)

    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_stubbed_responder(fn _req -> {200, "not-valid-json"} end)
    |> when_evaluating(:is_spam, %{body: "bad json"})
    |> then_error_is(:invalid_response)
    |> then_network_calls(1)
  end

  test "returns :cache_miss during offline replay when judgment is uncached" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> when_replaying_offline(:sentiment, %{body: "never evaluated"})
    |> then_offline_miss()
  end
end
