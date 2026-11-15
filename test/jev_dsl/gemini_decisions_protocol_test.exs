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
end
