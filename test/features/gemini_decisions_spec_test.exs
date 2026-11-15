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
             "probabilities" => %{"positive" => 0.96, "negative" => 0.04}
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
             "probabilities" => %{"positive" => 0.91, "negative" => 0.09}
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

  test "returns :cache_miss during offline replay when judgment is uncached" do
    TriageContracts
    |> given_decision_backend(decisions_mode: :unified)
    |> when_replaying_offline(:sentiment, %{body: "never evaluated"})
    |> then_offline_miss()
  end
end
