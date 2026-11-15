defmodule JevDSL.GeminiDecisionsProtocolTest do
  use ExUnit.Case, async: true

  alias JevDSL.Providers.GeminiDecisions.Protocol

  defmodule SampleContracts do
    use JevDSL,
      otp_app: :jev_dsl,
      backend: :gemini_decisions

    defnoul :is_spam do
      "Does this message contain unsolicited promotional spam?"
    end

    defnoul :criteria_spam, ask: "Is this spam?" do
      true -> "Unsolicited promotional message."
      false -> "Expected conversation."
    end

    defchoice :sentiment,
      as: :tone,
      ask: "Classify the overall tone of the message." do
      positive -> "Constructive, appreciative, or favorable tone."
      negative -> "Critical, frustrated, or dissatisfied tone."
    end

    defscore :completeness,
      ask: "Rate how complete the submission is." do
      incomplete -> "Missing required fields."
      complete -> "All required fields are populated."
    end

    defjev :triage do
      noul :urgent do
        "Is this urgent?"
      end

      choice :priority, ask: "Select priority." do
        p0 -> "Outage"
        p2 -> "Routine"
      end

      score :clarity, ask: "Rate clarity." do
        vague -> "Unclear"
        clear -> "Clear"
      end
    end
  end

  describe "request payload encoding" do
    test "encodes unified /v1/decisions payload for noul, choice, score, and multi-question contracts" do
      prep = SampleContracts.prepared(:triage)

      payload =
        Protocol.encode_request(%{body: "502 on checkout"}, prep, "gemini-decision-1", :unified)

      assert payload["model"] == "gemini-decision-1"
      assert is_binary(payload["input"])
      assert Jason.decode!(payload["input"]) == %{"body" => "502 on checkout"}

      assert [
               %{"type" => "predicate", "name" => "urgent", "instructions" => "Is this urgent?"},
               %{
                 "type" => "choice",
                 "name" => "priority",
                 "instructions" => "Select priority.",
                 "choices" => [
                   %{"value" => "p0", "description" => "Outage"},
                   %{"value" => "p2", "description" => "Routine"}
                 ]
               },
               %{
                 "type" => "score",
                 "name" => "clarity",
                 "instructions" => "Rate clarity.",
                 "levels" => [
                   %{"label" => "vague", "description" => "Unclear"},
                   %{"label" => "clear", "description" => "Clear"}
                 ]
               }
             ] = payload["questions"]
    end

    test "encodes native /v1beta/decisions payload with map-keyed questions" do
      prep = SampleContracts.prepared(:triage)

      payload =
        Protocol.encode_request("raw input text", prep, "gemini-decision-1", :native)

      assert payload["model"] == "gemini-decision-1"
      assert payload["input"] == "raw input text"

      assert %{
               "urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"},
               "priority" => %{
                 "type" => "choice",
                 "instructions" => "Select priority.",
                 "criteria" => %{"p0" => "Outage", "p2" => "Routine"}
               },
               "clarity" => %{
                 "type" => "score",
                 "instructions" => "Rate clarity.",
                 "criteria" => ["Unclear", "Clear"]
               }
             } = payload["questions"]
    end

    test "folds noul true/false criteria into instructions without emitting a criteria key" do
      prep = SampleContracts.prepared(:criteria_spam)

      unified_payload =
        Protocol.encode_request(%{body: "Buy now!"}, prep, "gemini-decision-1", :unified)

      assert [q_uni] = unified_payload["questions"]
      assert q_uni["type"] == "predicate"
      assert q_uni["name"] == "criteria_spam"
      assert q_uni["instructions"] =~ "Is this spam?"
      assert q_uni["instructions"] =~ "true: Unsolicited promotional message."
      assert q_uni["instructions"] =~ "false: Expected conversation."
      refute Map.has_key?(q_uni, "criteria")

      native_payload =
        Protocol.encode_request(%{body: "Buy now!"}, prep, "gemini-decision-1", :native)

      assert %{"criteria_spam" => q_nat} = native_payload["questions"]
      assert q_nat["type"] == "noul"
      assert q_nat["instructions"] =~ "Is this spam?"
      assert q_nat["instructions"] =~ "true: Unsolicited promotional message."
      assert q_nat["instructions"] =~ "false: Expected conversation."
      refute Map.has_key?(q_nat, "criteria")
    end

    test "builds auth headers for Bearer (unified) vs x-goog-api-key (native)" do
      assert Protocol.auth_headers("secret-1", :bearer) == %{
               "Authorization" => "Bearer secret-1"
             }

      assert Protocol.auth_headers("secret-2", :x_goog_api_key) == %{
               "x-goog-api-key" => "secret-2"
             }
    end
  end

  describe "response decoding and normalization" do
    test "decodes unified /v1/decisions multi-question response with list-formatted probabilities" do
      prep = SampleContracts.prepared(:triage)

      body = %{
        "model" => "gemini/gemini-decision-1",
        "answers" => [
          %{"name" => "urgent", "type" => "predicate", "probability" => 0.99},
          %{
            "name" => "priority",
            "type" => "choice",
            "choice" => "p0",
            "confidence" => 0.95,
            "probabilities" => [
              %{"value" => "p0", "probability" => 0.95},
              %{"value" => "p2", "probability" => 0.05}
            ]
          },
          %{
            "name" => "clarity",
            "type" => "score",
            "score" => 0.91,
            "confidence" => 0.88,
            "probabilities" => [
              %{"value" => 0, "label" => "vague", "probability" => 0.09},
              %{"value" => 1, "label" => "clear", "probability" => 0.91}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 93, "output_tokens" => 0}
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert resp.model == "gemini/gemini-decision-1"
      assert resp.usage.input_tokens == 93
      assert resp.usage.output_tokens == 0

      assert {:ok, %{noul: 0.99}} = JevDSL.fetch_answer(resp, :urgent)
      assert {:ok, prio} = JevDSL.fetch_answer(resp, :priority)
      assert JevDSL.choice?(prio, :p0)
      assert {:ok, 0.95} = JevDSL.probability(prio, :p0)
      assert {:ok, clarity} = JevDSL.fetch_answer(resp, :clarity)
      assert clarity.score == 0.91
      assert clarity.probabilities == %{0 => 0.09, 1 => 0.91}
      assert {:ok, enriched} = SystemOneSDK.SemanticResponse.enrich(resp, prep, 0.02)
      assert {:ok, enriched_clarity} = JevDSL.fetch_answer(enriched, :clarity)
      assert enriched_clarity.label == "clear"
      assert JevDSL.Cache.persistable?({:ok, enriched}, [])
    end

    test "decodes native /v1beta/decisions map-keyed response with string indices and confidence" do
      prep = SampleContracts.prepared(:triage)

      body = %{
        "answers" => %{
          "urgent" => %{"noul" => 0.98, "confidence" => 0.98},
          "priority" => %{
            "choice" => "p2",
            "confidence" => 0.55,
            "probabilities" => %{"p0" => 0.45, "p2" => 0.55}
          },
          "clarity" => %{
            "score" => 0.72,
            "confidence" => 0.82,
            "probabilities" => %{"0" => 0.28, "1" => 0.72}
          }
        },
        "usage_metadata" => %{"total_input_tokens" => 94, "total_output_tokens" => 0}
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert resp.model == "gemini-decision-1"
      assert resp.usage.input_tokens == 94
      assert resp.usage.output_tokens == 0
      assert {:ok, prio} = JevDSL.fetch_answer(resp, :priority)
      assert JevDSL.choice?(prio, :p2)
      assert {:ok, clarity} = JevDSL.fetch_answer(resp, :clarity)
      assert clarity.probabilities == %{0 => 0.28, 1 => 0.72}
      assert {:ok, enriched} = SystemOneSDK.SemanticResponse.enrich(resp, prep, 0.02)
      assert JevDSL.Cache.resolve_ttl({:ok, enriched}, min_confidence: 0.65) == {:ok, 300}
    end

    test "decodes single-question flat confidence/probability response" do
      prep = SampleContracts.prepared(:is_spam)

      body = %{
        "confidence" => 0.9797708352463237,
        "total_input_tokens" => 94,
        "total_output_tokens" => 0
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert {:ok, %{noul: 0.9797708352463237}} = JevDSL.fetch_answer(resp, :is_spam)
      assert resp.usage.input_tokens == 94
      assert resp.usage.output_tokens == 0
    end

    test "returns structured error on malformed response body" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:error, %JevDSL.Error{}} =
               Protocol.decode_response("not a map", prep, "gemini-decision-1")
    end
  end
end
