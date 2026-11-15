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
      partial -> "Some fields are populated."
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
        partial -> "Partial"
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
                   %{"label" => "partial", "description" => "Partial"},
                   %{"label" => "clear", "description" => "Clear"}
                 ]
               }
             ] = payload["questions"]
    end

    test "preserves non-alphabetical defchoice declaration order in unified /v1/decisions payloads" do
      prep = SampleContracts.prepared(:sentiment)
      tone_defn = Map.fetch!(prep.definitions, "tone")

      assert tone_defn.option_order == [:positive, :negative]

      payload =
        Protocol.encode_request(%{body: "Great job!"}, prep, "gemini-decision-1", :unified)

      assert [
               %{
                 "type" => "choice",
                 "name" => "tone",
                 "choices" => [
                   %{"value" => "positive", "description" => _},
                   %{"value" => "negative", "description" => _}
                 ]
               }
             ] = payload["questions"]

      # Also verify when criteria is an unordered Erlang map
      map_criteria_prep =
        put_in(prep.definitions["tone"].criteria, %{
          negative: "Critical, frustrated, or dissatisfied tone.",
          positive: "Constructive, appreciative, or favorable tone."
        })

      map_payload =
        Protocol.encode_request(
          %{body: "Great job!"},
          map_criteria_prep,
          "gemini-decision-1",
          :unified
        )

      assert [
               %{
                 "choices" => [
                   %{"value" => "positive"},
                   %{"value" => "negative"}
                 ]
               }
             ] = map_payload["questions"]
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
                 "criteria" => ["Unclear", "Partial", "Clear"]
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
            "score" => 1.82,
            "confidence" => 0.91,
            "probabilities" => [
              %{"value" => 0, "label" => "vague", "probability" => 0.02},
              %{"value" => 1, "label" => "partial", "probability" => 0.07},
              %{"value" => 2, "label" => "clear", "probability" => 0.91}
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
      assert clarity.score == 1.82
      assert clarity.probabilities == %{0 => 0.02, 1 => 0.07, 2 => 0.91}
      assert {:ok, enriched} = SystemOneSDK.SemanticResponse.enrich(resp, prep, 0.02)
      assert {:ok, enriched_clarity} = JevDSL.fetch_answer(enriched, :clarity)
      assert enriched_clarity.label == "clear"
      assert enriched_clarity.level == 2
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
            "score" => 1.66,
            "confidence" => 0.72,
            "probabilities" => %{"0" => 0.06, "1" => 0.22, "2" => 0.72}
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
      assert clarity.probabilities == %{0 => 0.06, 1 => 0.22, 2 => 0.72}
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

    test "decodes boolean noul responses without breaking or inverting polarity" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:ok, true_resp} =
               Protocol.decode_response(
                 %{"noul" => true, "confidence" => 0.98},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: true_prob}} = JevDSL.fetch_answer(true_resp, :is_spam)
      assert_in_delta true_prob, 0.98, 1.0e-6

      assert {:ok, false_resp} =
               Protocol.decode_response(
                 %{"noul" => false, "confidence" => 0.98},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: false_prob}} = JevDSL.fetch_answer(false_resp, :is_spam)
      assert false_prob < 0.2
      assert_in_delta false_prob, 0.02, 1.0e-6

      assert {:ok, decision_resp} =
               Protocol.decode_response(
                 %{"decision" => false, "confidence" => 0.95},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: decision_prob}} = JevDSL.fetch_answer(decision_resp, :is_spam)
      assert decision_prob < 0.2
      assert_in_delta decision_prob, 0.05, 1.0e-6

      assert {:ok, decision_prob_resp} =
               Protocol.decode_response(
                 %{"decision" => false, "probability" => 0.95},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: decision_prob2}} = JevDSL.fetch_answer(decision_prob_resp, :is_spam)
      assert decision_prob2 < 0.2
      assert_in_delta decision_prob2, 0.05, 1.0e-6

      assert {:ok, noul_prob_resp} =
               Protocol.decode_response(
                 %{"noul" => false, "probability" => 0.98},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: noul_prob2}} = JevDSL.fetch_answer(noul_prob_resp, :is_spam)
      assert noul_prob2 < 0.2
      assert_in_delta noul_prob2, 0.02, 1.0e-6
    end

    test "rejects hallucinated choices, backfills omitted flat choice probabilities, and guards flat type mismatches" do
      choice_prep = SampleContracts.prepared(:sentiment)
      noul_prep = SampleContracts.prepared(:is_spam)

      # Out-of-contract choice rejected
      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{"choice" => "hallucinated", "confidence" => 0.95},
                 choice_prep,
                 "gemini-decision-1"
               )

      # Flat choice without probabilities backfills %{choice => confidence} and remainder across valid options
      assert {:ok, flat_choice_resp} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 0.92},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:ok, tone} = JevDSL.fetch_answer(flat_choice_resp, :tone)
      assert JevDSL.choice?(tone, :positive)
      assert {:ok, 0.92} = JevDSL.probability(tone, :positive)
      assert {:ok, neg_prob} = JevDSL.probability(tone, :negative)
      assert_in_delta neg_prob, 0.08, 1.0e-6

      assert {:ok, enriched_flat} =
               SystemOneSDK.SemanticResponse.enrich(flat_choice_resp, choice_prep, 0.02)

      assert {:ok, enriched_tone} = JevDSL.fetch_answer(enriched_flat, :tone)
      assert JevDSL.choice?(enriched_tone, :positive)

      # Flat choice or score payload rejected on single-question noul contract
      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 0.92},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{"score" => 1.5, "confidence" => 0.92},
                 noul_prep,
                 "gemini-decision-1"
               )
    end

    test "decodes Google Proto3 camelCase usageMetadata and skips empty usage maps" do
      prep = SampleContracts.prepared(:is_spam)

      camel_body = %{
        "answers" => %{"is_spam" => %{"noul" => 0.91}},
        "usageMetadata" => %{"totalInputTokens" => 111, "totalOutputTokens" => 7}
      }

      assert {:ok, camel_resp} = Protocol.decode_response(camel_body, prep, "gemini-decision-1")
      assert camel_resp.usage.input_tokens == 111
      assert camel_resp.usage.output_tokens == 7

      prompt_candidates_body = %{
        "answers" => %{"is_spam" => %{"noul" => 0.12}},
        "usage" => %{},
        "usageMetadata" => %{"promptTokenCount" => 88, "candidatesTokenCount" => 4}
      }

      assert {:ok, pc_resp} =
               Protocol.decode_response(prompt_candidates_body, prep, "gemini-decision-1")

      assert pc_resp.usage.input_tokens == 88
      assert pc_resp.usage.output_tokens == 4

      empty_usage_top_fallback = %{
        "usage" => %{},
        "confidence" => 0.9,
        "totalInputTokens" => 52,
        "totalOutputTokens" => 3
      }

      assert {:ok, top_resp} =
               Protocol.decode_response(empty_usage_top_fallback, prep, "gemini-decision-1")

      assert top_resp.usage.input_tokens == 52
      assert top_resp.usage.output_tokens == 3
    end

    test "normalizes 3-level defscore index-scaled and normalized [0, 1] scores and rejects out-of-range scores" do
      prep = SampleContracts.prepared(:completeness)

      # Index-scaled score in [0.0, 2.0]
      index_body = %{
        "answers" => [
          %{
            "name" => "completeness",
            "type" => "score",
            "score" => 1.85,
            "confidence" => 0.9,
            "probabilities" => [
              %{"value" => 0, "label" => "incomplete", "probability" => 0.05},
              %{"value" => 1, "label" => "partial", "probability" => 0.05},
              %{"value" => 2, "label" => "complete", "probability" => 0.90}
            ]
          }
        ]
      }

      assert {:ok, idx_resp} = Protocol.decode_response(index_body, prep, "gemini-decision-1")
      assert {:ok, idx_enriched} = SystemOneSDK.SemanticResponse.enrich(idx_resp, prep, 0.02)
      assert {:ok, idx_ans} = JevDSL.fetch_answer(idx_enriched, :completeness)
      assert idx_ans.level == 2
      assert idx_ans.label == "complete"
      assert_in_delta idx_ans.score, 1.85, 1.0e-6

      # Normalized [0.0, 1.0] score rescaled to [0.0, 2.0]
      normalized_body = %{
        "answers" => %{
          "completeness" => %{
            "type" => "score",
            "score" => 0.925,
            "confidence" => 0.9,
            "probabilities" => %{"0" => 0.05, "1" => 0.05, "2" => 0.90}
          }
        }
      }

      assert {:ok, norm_resp} =
               Protocol.decode_response(normalized_body, prep, "gemini-decision-1")

      assert {:ok, norm_enriched} = SystemOneSDK.SemanticResponse.enrich(norm_resp, prep, 0.02)
      assert {:ok, norm_ans} = JevDSL.fetch_answer(norm_enriched, :completeness)
      assert norm_ans.level == 2
      assert norm_ans.label == "complete"
      assert_in_delta norm_ans.score, 1.85, 1.0e-6

      # Out-of-range score rejected
      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{"score" => 2.5, "confidence" => 0.9},
                 prep,
                 "gemini-decision-1"
               )
    end

    test "returns invalid_response instead of crashing on malformed probabilities or non-string probability keys" do
      choice_prep = SampleContracts.prepared(:sentiment)
      score_prep = SampleContracts.prepared(:completeness)

      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{
                   "choice" => "positive",
                   "confidence" => 0.9,
                   "probabilities" => [%{"value" => %{"bad" => 1}, "probability" => 0.9}]
                 },
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{
                   "choice" => "positive",
                   "confidence" => 0.9,
                   "probabilities" => "not-a-map-or-list"
                 },
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error, %JevDSL.Error{type: :invalid_response}} =
               Protocol.decode_response(
                 %{
                   "score" => 1.5,
                   "confidence" => 0.9,
                   "probabilities" => "not-a-map-or-list"
                 },
                 score_prep,
                 "gemini-decision-1"
               )
    end

    test "returns structured error on malformed response body" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:error, %JevDSL.Error{}} =
               Protocol.decode_response("not a map", prep, "gemini-decision-1")
    end
  end
end
