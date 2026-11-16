defmodule SystemOneDSL.GeminiDecisionsProtocolTest do
  use ExUnit.Case, async: true

  alias SystemOneDSL.Providers.GeminiDecisions.Protocol

  defmodule SampleContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      backend: :gemini_decisions

    defnoul :is_spam do
      "Does this message contain unsolicited promotional spam?"
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
                 "levels" => [
                   %{"label" => "vague", "description" => "Unclear"},
                   %{"label" => "clear", "description" => "Clear"}
                 ]
               }
             } = payload["questions"]
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
    test "decodes unified /v1/decisions multi-question response into SystemOneResponse with atom keys" do
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
            "probabilities" => %{"p0" => 0.95, "p2" => 0.05}
          },
          %{
            "name" => "clarity",
            "type" => "score",
            "score" => 0.91,
            "confidence" => 0.88,
            "probabilities" => %{"vague" => 0.09, "clear" => 0.91}
          }
        ],
        "usage" => %{"input_tokens" => 93, "output_tokens" => 0}
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert resp.model == "gemini/gemini-decision-1"
      assert resp.usage.input_tokens == 93
      assert resp.usage.output_tokens == 0

      assert {:ok, %{noul: 0.99}} = SystemOneDSL.fetch_answer(resp, :urgent)
      assert {:ok, prio} = SystemOneDSL.fetch_answer(resp, :priority)
      assert SystemOneDSL.choice?(prio, :p0)
      assert {:ok, 0.95} = SystemOneDSL.probability(prio, :p0)
      assert {:ok, clarity} = SystemOneDSL.fetch_answer(resp, :clarity)
      assert clarity.score == 0.91
      assert SystemOneDSL.Cache.persistable?({:ok, resp}, [])
    end

    test "decodes native /v1beta/decisions map-keyed response with total_input_tokens and confidence" do
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
            "probabilities" => %{"vague" => 0.28, "clear" => 0.72}
          }
        },
        "usage_metadata" => %{"total_input_tokens" => 94, "total_output_tokens" => 0}
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert resp.model == "gemini-decision-1"
      assert resp.usage.input_tokens == 94
      assert resp.usage.output_tokens == 0
      assert {:ok, prio} = SystemOneDSL.fetch_answer(resp, :priority)
      assert SystemOneDSL.choice?(prio, :p2)
      assert SystemOneDSL.Cache.resolve_ttl({:ok, resp}, min_confidence: 0.65) == {:ok, 300}
    end

    test "decodes single-question flat confidence/probability response" do
      prep = SampleContracts.prepared(:is_spam)

      body = %{
        "confidence" => 0.9797708352463237,
        "total_input_tokens" => 94,
        "total_output_tokens" => 0
      }

      assert {:ok, resp} = Protocol.decode_response(body, prep, "gemini-decision-1")
      assert {:ok, %{noul: 0.9797708352463237}} = SystemOneDSL.fetch_answer(resp, :is_spam)
      assert resp.usage.input_tokens == 94
      assert resp.usage.output_tokens == 0
    end

    test "returns structured error on malformed response body" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:error, %SystemOneDSL.Error{}} =
               Protocol.decode_response("not a map", prep, "gemini-decision-1")
    end
  end
end
