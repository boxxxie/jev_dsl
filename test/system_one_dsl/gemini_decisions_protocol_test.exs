defmodule SystemOneDSL.GeminiDecisionsProtocolTest do
  use ExUnit.Case, async: true

  alias SystemOneSDK.Answer.Choice
  alias SystemOneSDK.Error, as: SDKError
  alias SystemOneSDK.Providers.GeminiDecisions.Protocol
  alias SystemOneSDK.SemanticResponse

  defmodule SampleContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
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

    defscore :numeric_rating,
      ask: "Rate 1 to 3." do
      "1" -> "Poor"
      "2" -> "Okay"
      "3" -> "Great"
    end

    defchoice :quad_choice,
      ask: "Pick one of four." do
      opt_a -> "Option A"
      opt_b -> "Option B"
      opt_c -> "Option C"
      opt_d -> "Option D"
    end

    defchoice :penta_choice,
      ask: "Pick one of five." do
      c1 -> "One"
      c2 -> "Two"
      c3 -> "Three"
      c4 -> "Four"
      c5 -> "Five"
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

    test "builds auth headers for Bearer (unified), x-goog-api-key (native), and :none" do
      assert Protocol.auth_headers("secret-1", :bearer) == %{
               "Authorization" => "Bearer secret-1"
             }

      assert Protocol.auth_headers("secret-2", :x_goog_api_key) == %{
               "x-goog-api-key" => "secret-2"
             }

      assert Protocol.auth_headers("secret-3", :none) == %{}
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

      assert {:ok, %{noul: 0.99}} = SystemOneDSL.fetch_answer(resp, :urgent)
      assert {:ok, prio} = SystemOneDSL.fetch_answer(resp, :priority)
      assert SystemOneDSL.choice?(prio, :p0)
      assert {:ok, 0.95} = SystemOneDSL.probability(prio, :p0)
      assert {:ok, clarity} = SystemOneDSL.fetch_answer(resp, :clarity)
      assert clarity.score == 1.82
      assert clarity.probabilities == %{0 => 0.02, 1 => 0.07, 2 => 0.91}
      assert {:ok, enriched} = SystemOneSDK.SemanticResponse.enrich(resp, prep, 0.02)
      assert {:ok, enriched_clarity} = SystemOneDSL.fetch_answer(enriched, :clarity)
      assert enriched_clarity.label == "clear"
      assert enriched_clarity.level == 2
      assert SystemOneDSL.Cache.persistable?({:ok, enriched}, [])
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
      assert {:ok, prio} = SystemOneDSL.fetch_answer(resp, :priority)
      assert SystemOneDSL.choice?(prio, :p2)
      assert {:ok, clarity} = SystemOneDSL.fetch_answer(resp, :clarity)
      assert clarity.probabilities == %{0 => 0.06, 1 => 0.22, 2 => 0.72}
      assert {:ok, enriched} = SystemOneSDK.SemanticResponse.enrich(resp, prep, 0.02)
      assert SystemOneDSL.Cache.resolve_ttl({:ok, enriched}, min_confidence: 0.65) == {:ok, 300}
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

    test "decodes boolean noul responses without breaking or inverting polarity" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:ok, true_resp} =
               Protocol.decode_response(
                 %{"noul" => true, "confidence" => 0.98},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: true_prob}} = SystemOneDSL.fetch_answer(true_resp, :is_spam)
      assert_in_delta true_prob, 0.98, 1.0e-6

      assert {:ok, false_resp} =
               Protocol.decode_response(
                 %{"noul" => false, "confidence" => 0.98},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: false_prob}} = SystemOneDSL.fetch_answer(false_resp, :is_spam)
      assert false_prob < 0.2
      assert_in_delta false_prob, 0.02, 1.0e-6

      assert {:ok, decision_resp} =
               Protocol.decode_response(
                 %{"decision" => false, "confidence" => 0.95},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: decision_prob}} = SystemOneDSL.fetch_answer(decision_resp, :is_spam)
      assert decision_prob < 0.2
      assert_in_delta decision_prob, 0.05, 1.0e-6

      assert {:ok, decision_prob_resp} =
               Protocol.decode_response(
                 %{"decision" => false, "probability" => 0.04},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: decision_prob2}} =
               SystemOneDSL.fetch_answer(decision_prob_resp, :is_spam)

      assert decision_prob2 < 0.2
      assert_in_delta decision_prob2, 0.04, 1.0e-6

      assert {:ok, predicate_prob_resp} =
               Protocol.decode_response(
                 %{"predicate" => false, "probability" => 0.04},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: pred_prob}} =
               SystemOneDSL.fetch_answer(predicate_prob_resp, :is_spam)

      assert_in_delta pred_prob, 0.04, 1.0e-6

      assert {:ok, noul_prob_resp} =
               Protocol.decode_response(
                 %{"noul" => false, "probability" => 0.02},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: noul_prob2}} = SystemOneDSL.fetch_answer(noul_prob_resp, :is_spam)
      assert noul_prob2 < 0.2
      assert_in_delta noul_prob2, 0.02, 1.0e-6

      assert {:ok, true_prob_resp} =
               Protocol.decode_response(
                 %{"decision" => true, "probability" => 0.96},
                 prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: true_prob2}} = SystemOneDSL.fetch_answer(true_prob_resp, :is_spam)
      assert_in_delta true_prob2, 0.96, 1.0e-6

      assert {:error,
              %SDKError{
                type: :response_validation,
                details: %{reason: :contradictory_noul_polarity}
              }} =
               Protocol.decode_response(
                 %{"decision" => false, "probability" => 0.95},
                 prep,
                 "gemini-decision-1"
               )
    end

    test "rejects hallucinated choices, backfills omitted flat choice probabilities, and guards flat type mismatches" do
      choice_prep = SampleContracts.prepared(:sentiment)
      noul_prep = SampleContracts.prepared(:is_spam)

      assert {:error, %SDKError{type: :response_validation}} =
               Protocol.decode_response(
                 %{"choice" => "hallucinated", "confidence" => 0.95},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:ok, flat_choice_resp} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 0.92},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:ok, tone} = SystemOneDSL.fetch_answer(flat_choice_resp, :tone)
      assert SystemOneDSL.choice?(tone, :positive)
      assert {:ok, 0.92} = SystemOneDSL.probability(tone, :positive)
      assert {:ok, neg_prob} = SystemOneDSL.probability(tone, :negative)
      assert_in_delta neg_prob, 0.08, 1.0e-6

      assert {:ok, enriched_flat} =
               SystemOneSDK.SemanticResponse.enrich(flat_choice_resp, choice_prep, 0.02)

      assert {:ok, enriched_tone} = SystemOneDSL.fetch_answer(enriched_flat, :tone)
      assert SystemOneDSL.choice?(enriched_tone, :positive)

      assert {:error, %SDKError{type: :response_validation}} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 0.92},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:error, %SDKError{type: :response_validation}} =
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
      assert {:ok, idx_ans} = SystemOneDSL.fetch_answer(idx_enriched, :completeness)
      assert idx_ans.level == 2
      assert idx_ans.label == "complete"
      assert_in_delta idx_ans.score, 1.85, 1.0e-6

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
      assert {:ok, norm_ans} = SystemOneDSL.fetch_answer(norm_enriched, :completeness)
      assert norm_ans.level == 2
      assert norm_ans.label == "complete"
      assert_in_delta norm_ans.score, 1.85, 1.0e-6

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :score_out_of_range}}} =
               Protocol.decode_response(
                 %{"score" => 2.5, "confidence" => 0.9},
                 prep,
                 "gemini-decision-1"
               )

      modal_body = %{
        "answers" => [
          %{
            "name" => "completeness",
            "type" => "score",
            "score" => 0.88,
            "confidence" => 0.46,
            "probabilities" => [
              %{"value" => 0, "label" => "incomplete", "probability" => 0.10},
              %{"value" => 1, "label" => "partial", "probability" => 0.46},
              %{"value" => 2, "label" => "complete", "probability" => 0.44}
            ]
          }
        ]
      }

      assert {:ok, modal_resp} = Protocol.decode_response(modal_body, prep, "gemini-decision-1")
      assert {:ok, modal_enriched} = SystemOneSDK.SemanticResponse.enrich(modal_resp, prep, 0.02)
      assert {:ok, modal_ans} = SystemOneDSL.fetch_answer(modal_enriched, :completeness)
      assert modal_ans.level == 1
      assert modal_ans.label == "partial"
      assert_in_delta modal_ans.score, 0.88, 1.0e-6
    end

    test "clamps tiny float drift within epsilon and rejects negative or > 1.0 probabilities/confidences" do
      noul_prep = SampleContracts.prepared(:is_spam)
      choice_prep = SampleContracts.prepared(:sentiment)
      score_prep = SampleContracts.prepared(:completeness)

      assert {:ok, drift_noul} =
               Protocol.decode_response(
                 %{"noul" => 1.0000000000000002},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: 1.0}} = SystemOneDSL.fetch_answer(drift_noul, :is_spam)

      assert {:ok, drift_neg} =
               Protocol.decode_response(%{"noul" => -1.0e-12}, noul_prep, "gemini-decision-1")

      assert {:ok, %{noul: drift_neg_val}} = SystemOneDSL.fetch_answer(drift_neg, :is_spam)
      assert drift_neg_val == 0.0

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :invalid_confidence}}} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 1.2},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :invalid_probabilities}}} =
               Protocol.decode_response(
                 %{
                   "choice" => "positive",
                   "confidence" => 0.9,
                   "probabilities" => %{"positive" => 0.9, "negative" => -0.1}
                 },
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :invalid_confidence}}} =
               Protocol.decode_response(
                 %{"score" => 1.5, "confidence" => -0.2},
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :invalid_probabilities}}} =
               Protocol.decode_response(
                 %{
                   "score" => 1.5,
                   "confidence" => 0.9,
                   "probabilities" => %{"0" => 1.5, "1" => 0.0, "2" => 0.0}
                 },
                 score_prep,
                 "gemini-decision-1"
               )
    end

    test "returns invalid_response instead of Protocol.UndefinedError on non-stringifiable answer names" do
      noul_prep = SampleContracts.prepared(:is_spam)

      for bad_name <- [%{"bad" => 1}, ["x"], nil, ""] do
        assert {:error, %SDKError{type: :response_validation}} =
                 Protocol.decode_response(
                   %{"answers" => [%{"name" => bad_name, "probability" => 0.5}]},
                   noul_prep,
                   "gemini-decision-1"
                 )

        assert {:error, %SDKError{type: :response_validation}} =
                 Protocol.decode_response(
                   %{"answers" => %{bad_name => %{"probability" => 0.5}}},
                   noul_prep,
                   "gemini-decision-1"
                 )
      end
    end

    test "returns invalid_response instead of crashing on malformed probabilities or non-string probability keys" do
      choice_prep = SampleContracts.prepared(:sentiment)
      score_prep = SampleContracts.prepared(:completeness)

      assert {:error, %SDKError{type: :response_validation}} =
               Protocol.decode_response(
                 %{
                   "choice" => "positive",
                   "confidence" => 0.9,
                   "probabilities" => [%{"value" => %{"bad" => 1}, "probability" => 0.9}]
                 },
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error, %SDKError{type: :response_validation}} =
               Protocol.decode_response(
                 %{
                   "choice" => "positive",
                   "confidence" => 0.9,
                   "probabilities" => "not-a-map-or-list"
                 },
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:error, %SDKError{type: :response_validation}} =
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

      assert {:error, %SDKError{}} =
               Protocol.decode_response("not a map", prep, "gemini-decision-1")
    end

    test "backfills choice and score probabilities symmetrically without flipping winner" do
      two_prep = SampleContracts.prepared(:sentiment)
      four_prep = SampleContracts.prepared(:quad_choice)
      five_prep = SampleContracts.prepared(:penta_choice)
      score_prep = SampleContracts.prepared(:completeness)

      assert {:ok, resp2} =
               Protocol.decode_response(
                 %{"choice" => "positive", "confidence" => 0.40},
                 two_prep,
                 "gemini-decision-1"
               )

      assert {:ok, enriched2} = SemanticResponse.enrich(resp2, two_prep, 0.02)
      assert {:ok, tone2} = SystemOneDSL.fetch_answer(enriched2, :tone)
      assert tone2.confidence == 0.40
      assert tone2.probabilities[:positive] >= tone2.probabilities[:negative]
      assert Choice.margin(tone2) == 0.0

      assert {:ok, resp4} =
               Protocol.decode_response(
                 %{"choice" => "opt_a", "confidence" => 0.20, "probabilities" => %{}},
                 four_prep,
                 "gemini-decision-1"
               )

      assert {:ok, enriched4} = SemanticResponse.enrich(resp4, four_prep, 0.02)
      assert {:ok, ans4} = SystemOneDSL.fetch_answer(enriched4, :quad_choice)
      assert ans4.confidence == 0.20
      assert Enum.all?(ans4.probabilities, fn {_k, p} -> p <= ans4.probabilities[:opt_a] end)
      assert Choice.margin(ans4) == 0.0

      # 1/N <= conf < 0.5 (0.25 across 5 options) distributes remainder uniformly (0.1875 each, margin 0.0625)
      assert {:ok, resp5} =
               Protocol.decode_response(
                 %{"choice" => "c1", "confidence" => 0.25, "probabilities" => []},
                 five_prep,
                 "gemini-decision-1"
               )

      assert {:ok, enriched5} = SemanticResponse.enrich(resp5, five_prep, 0.02)
      assert {:ok, ans5} = SystemOneDSL.fetch_answer(enriched5, :penta_choice)
      assert_in_delta Choice.margin(ans5), 0.0625, 1.0e-6

      assert {:ok, score_resp} =
               Protocol.decode_response(
                 %{"score" => 1.75, "confidence" => 0.85},
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:ok, score_enriched} =
               SemanticResponse.enrich(score_resp, score_prep, 0.02)

      assert {:ok, score_ans} = SystemOneDSL.fetch_answer(score_enriched, :completeness)
      assert score_ans.probabilities == %{0 => 0.0, 1 => 0.25, 2 => 0.75}
    end

    test "does not fabricate confidence 1.0 when confidence is omitted" do
      score_prep = SampleContracts.prepared(:completeness)
      choice_prep = SampleContracts.prepared(:sentiment)
      noul_prep = SampleContracts.prepared(:is_spam)

      assert {:ok, even_score_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "completeness" => %{
                       "score" => 1.0,
                       "probabilities" => %{"0" => 0.34, "1" => 0.33, "2" => 0.33}
                     }
                   }
                 },
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:ok, even_score} = SystemOneDSL.fetch_answer(even_score_resp, :completeness)
      assert even_score.confidence == 0.34
      refute SystemOneDSL.Cache.cacheable?({:ok, even_score_resp}, min_confidence: 0.65)

      assert SystemOneDSL.Cache.resolve_ttl({:ok, even_score_resp}, min_confidence: 0.65) ==
               {:ok, 300}

      assert {:ok, bare_score_resp} =
               Protocol.decode_response(%{"score" => 1.0}, score_prep, "gemini-decision-1")

      assert {:ok, bare_score} = SystemOneDSL.fetch_answer(bare_score_resp, :completeness)
      assert bare_score.confidence == 0.0
      refute SystemOneDSL.Cache.cacheable?({:ok, bare_score_resp}, min_confidence: 0.65)

      assert {:ok, bare_choice_resp} =
               Protocol.decode_response(
                 %{"choice" => "positive"},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:ok, bare_choice} = SystemOneDSL.fetch_answer(bare_choice_resp, :tone)
      assert bare_choice.confidence == 0.0
      refute SystemOneDSL.Cache.cacheable?({:ok, bare_choice_resp}, min_confidence: 0.65)

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :missing_noul_confidence}}} =
               Protocol.decode_response(%{"noul" => true}, noul_prep, "gemini-decision-1")

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :missing_noul_confidence}}} =
               Protocol.decode_response(%{"decision" => false}, noul_prep, "gemini-decision-1")
    end

    test "handles numeric score labels, positional/criteria native score probs, 1-level bounds, and confidence-only payloads" do
      num_prep = SampleContracts.prepared(:numeric_rating)
      triage_prep = SampleContracts.prepared(:triage)
      score_prep = SampleContracts.prepared(:completeness)
      noul_prep = SampleContracts.prepared(:is_spam)

      assert {:ok, num_idx_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "numeric_rating" => %{
                       "score" => 1.80,
                       "confidence" => 0.85,
                       "probabilities" => %{"0" => 0.05, "1" => 0.10, "2" => 0.85}
                     }
                   }
                 },
                 num_prep,
                 "gemini-decision-1"
               )

      assert {:ok, num_idx_ans} = SystemOneDSL.fetch_answer(num_idx_resp, :numeric_rating)
      assert num_idx_ans.probabilities == %{0 => 0.05, 1 => 0.10, 2 => 0.85}

      assert {:ok, num_lbl_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "numeric_rating" => %{
                       "score" => 1.80,
                       "confidence" => 0.85,
                       "probabilities" => %{"1" => 0.05, "2" => 0.10, "3" => 0.85}
                     }
                   }
                 },
                 num_prep,
                 "gemini-decision-1"
               )

      assert {:ok, num_lbl_ans} = SystemOneDSL.fetch_answer(num_lbl_resp, :numeric_rating)
      assert num_lbl_ans.probabilities == %{0 => 0.05, 1 => 0.10, 2 => 0.85}

      assert {:ok, pos_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "completeness" => %{
                       "score" => 1.77,
                       "confidence" => 0.82,
                       "probabilities" => [0.05, 0.13, 0.82]
                     }
                   }
                 },
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:ok, pos_ans} = SystemOneDSL.fetch_answer(pos_resp, :completeness)
      assert pos_ans.probabilities == %{0 => 0.05, 1 => 0.13, 2 => 0.82}

      assert {:ok, crit_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "clarity" => %{
                       "score" => 1.77,
                       "confidence" => 0.82,
                       "probabilities" => %{"Unclear" => 0.05, "Partial" => 0.13, "Clear" => 0.82}
                     },
                     "urgent" => %{"noul" => 0.1},
                     "priority" => %{
                       "choice" => "p0",
                       "confidence" => 0.9,
                       "probabilities" => %{"p0" => 0.9, "p2" => 0.1}
                     }
                   }
                 },
                 triage_prep,
                 "gemini-decision-1"
               )

      assert {:ok, crit_ans} = SystemOneDSL.fetch_answer(crit_resp, :clarity)
      assert crit_ans.probabilities == %{0 => 0.05, 1 => 0.13, 2 => 0.82}

      assert {:ok, one_based_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => [
                     %{
                       "name" => "completeness",
                       "type" => "score",
                       "score" => 1.77,
                       "confidence" => 0.82,
                       "probabilities" => [
                         %{"value" => 1, "label" => "incomplete", "probability" => 0.05},
                         %{"value" => 2, "label" => "partial", "probability" => 0.13},
                         %{"value" => 3, "label" => "complete", "probability" => 0.82}
                       ]
                     }
                   ]
                 },
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:ok, one_based_ans} = SystemOneDSL.fetch_answer(one_based_resp, :completeness)
      assert one_based_ans.probabilities == %{0 => 0.05, 1 => 0.13, 2 => 0.82}

      one_level_prep = %{
        score_prep
        | ordered_keys: [:single],
          definitions: %{
            "single" => %{
              type: "score",
              levels: [%{index: 0, label: "only", description: "Only level"}]
            }
          }
      }

      assert {:error,
              %SDKError{type: :response_validation, details: %{reason: :score_out_of_range}}} =
               Protocol.decode_response(
                 %{"score" => 1.0, "confidence" => 0.9},
                 one_level_prep,
                 "gemini-decision-1"
               )

      assert {:ok, one_lvl_ok} =
               Protocol.decode_response(
                 %{"score" => 0.0, "confidence" => 0.9},
                 one_level_prep,
                 "gemini-decision-1"
               )

      assert {:ok, one_lvl_ans} = SystemOneDSL.fetch_answer(one_lvl_ok, :single)
      assert one_lvl_ans.score == 0.0

      # Probability-only score computes expected score from probabilities
      assert {:ok, prob_score_resp} =
               Protocol.decode_response(
                 %{
                   "answers" => %{
                     "completeness" => %{
                       "confidence" => 0.95,
                       "probabilities" => %{"0" => 0.05, "1" => 0.05, "2" => 0.90}
                     }
                   }
                 },
                 score_prep,
                 "gemini-decision-1"
               )

      assert {:ok, prob_score} = SystemOneDSL.fetch_answer(prob_score_resp, :completeness)
      assert_in_delta prob_score.score, 1.85, 1.0e-6

      # Confidence-only noul payloads decode consistently across flat and answers modes
      assert {:ok, proto_noul_resp} =
               Protocol.decode_response(
                 %{"answers" => %{"is_spam" => %{"confidence" => 0.98}}},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: 0.98}} = SystemOneDSL.fetch_answer(proto_noul_resp, :is_spam)

      assert {:ok, typed_proto_noul} =
               Protocol.decode_response(
                 %{"type" => "noul", "confidence" => 0.98},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:ok, %{noul: 0.98}} = SystemOneDSL.fetch_answer(typed_proto_noul, :is_spam)
    end

    test "guards flat fallback against answers: null and error envelopes, and accepts unnamed single-item answers list" do
      noul_prep = SampleContracts.prepared(:is_spam)
      choice_prep = SampleContracts.prepared(:sentiment)

      assert {:error, %SDKError{type: :response_validation}} =
               Protocol.decode_response(
                 %{"answers" => nil, "result" => 0.0},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:error, %SDKError{type: :api_error}} =
               Protocol.decode_response(
                 %{"error" => %{"message" => "Rate limit"}, "value" => 0.0},
                 noul_prep,
                 "gemini-decision-1"
               )

      assert {:ok, unnamed_list_resp} =
               Protocol.decode_response(
                 %{"answers" => [%{"choice" => "positive", "confidence" => 0.95}]},
                 choice_prep,
                 "gemini-decision-1"
               )

      assert {:ok, tone} = SystemOneDSL.fetch_answer(unnamed_list_resp, :tone)
      assert SystemOneDSL.choice?(tone, :positive)
    end

    test "encode_request_safe/4 returns structured error on unencodable input state" do
      prep = SampleContracts.prepared(:is_spam)

      assert {:error, %SDKError{type: :invalid_request}} =
               Protocol.encode_request_safe(%{pid: self()}, prep, "gemini-decision-1", :unified)

      assert {:error, %SDKError{type: :invalid_request}} =
               Protocol.encode_request_safe(<<255, 255>>, prep, "gemini-decision-1", :native)
    end
  end
end
