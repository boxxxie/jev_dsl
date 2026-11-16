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

  test "evaluates a single judgment in unified mode and replays cached hits offline across L1/L2" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_upstream_choice(:tone, :positive,
      confidence: 0.96,
      probs: %{positive: 0.96, negative: 0.04}
    )
    |> when_evaluating(:sentiment, %{body: "Thanks for the fast fix!"})
    |> then_choice_is(:tone, :positive, 0.95)
    |> then_network_calls(1)
    |> when_replaying_offline(:sentiment, %{body: "Thanks for the fast fix!"})
    |> then_choice_is(:tone, :positive, 0.95)
    |> then_network_calls(1)
    |> then_telemetry_recorded([[:jev_dsl, :evaluate, :stop]])
  end

  test "evaluates 3-level defscore end-to-end across unified and native modes on shared cache" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_upstream_route_answers(%{
      {:unified, "gemini-decision-1"} => {
        [{:score, :clarity, 1.72, 0.85, [vague: 0.05, partial: 0.10, clear: 0.85]}],
        []
      },
      {:native, "gemini-decision-1"} => {
        [{:score, :clarity, 1.69, 0.82, [vague: 0.05, partial: 0.13, clear: 0.82]}],
        []
      }
    })
    |> when_evaluating(:clarity, %{body: "Step 1: click save. Step 2: observe 500."})
    |> then_score_is(:clarity, :clear, 0.8)
    |> then_last_upstream_request_had(mode: :unified, model: "gemini-decision-1")
    |> then_network_calls(1)
    |> when_switching_backend_mode(:native)
    |> when_evaluating(:clarity, %{body: "Step 1: click save. Step 2: observe 500."})
    |> then_score_is(:clarity, :clear, 0.8)
    |> then_last_upstream_request_had(mode: :native, model: "gemini-decision-1")
    |> then_network_calls(2)
  end

  test "evaluates multi-question defjev contracts with request metadata and auth override precedence" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_upstream_answers(
      [
        {:noul, :urgent, 0.94},
        {:choice, :priority, :p0, 0.92, %{p0: 0.92, p2: 0.08}},
        {:score, :completeness, 1.75, 0.78, [incomplete: 0.05, partial: 0.17, complete: 0.78]}
      ],
      expected_auth_header: "Bearer override-token"
    )
    |> when_evaluating(:full_triage, %{body: "Production DB is down"},
      request_metadata: %{"trace_id" => "req-123"},
      auth_override: "override-token"
    )
    |> then_noul_is(:urgent, 0.9)
    |> then_choice_is(:priority, :p0, 0.9)
    |> then_score_is(:completeness, :complete, 0.7)
    |> then_last_upstream_request_had(
      mode: :unified,
      model: "gemini-decision-1",
      auth_token: "override-token",
      metadata: %{"trace_id" => "req-123"}
    )
    |> then_network_calls(1)
  end

  test "evaluates single-question judgments in native mode" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :native)
    |> given_upstream_noul(:is_spam, {:flat_confidence, 0.9797708352463237}, flat: true)
    |> when_evaluating(:is_spam, %{body: "Win a free prize now"})
    |> then_noul_is(:is_spam, 0.97)
    |> then_last_upstream_request_had(mode: :native, auth_token: "test-gemini-key")
    |> then_network_calls(1)
  end

  test "evaluates batches concurrently, serving cached hits and dispatching only misses" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_upstream_choice_by_text(:tone, fn text ->
      if String.contains?(text, "happy") do
        {:positive, 0.91, %{positive: 0.91, negative: 0.09}}
      else
        {:negative, 0.91, %{positive: 0.09, negative: 0.91}}
      end
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
    |> given_upstream_route_answers(%{
      {:unified, "gemini-decision-1"} => {[{:noul, :is_spam, 0.04}], []},
      {:native, "gemini-decision-1"} => {[{:noul, :is_spam, {:boolean_conf, false, 0.96}}], []},
      {:native, "gemini-decision-2"} => {[{:noul, :is_spam, 0.02}], []}
    })
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
    |> given_upstream_http_error(502, "Bad Gateway")
    |> when_evaluating(:is_spam, %{body: "upstream 502"})
    |> then_error_is(:provider_error)
    |> then_network_calls(1)

    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> given_upstream_malformed_response("not-valid-json")
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
