defmodule JevDSL.Live.GeminiDecisionsLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  defmodule LiveUnifiedContracts do
    use JevDSL,
      otp_app: :jev_dsl,
      backend: :gemini_decisions,
      decisions_mode: :unified,
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
      clear -> "Clear"
    end

    defjev :triage do
      noul :urgent, ask: "Is this urgent?" do
        true -> "Production outage."
        false -> "Routine."
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

  defmodule LiveNativeContracts do
    use JevDSL,
      otp_app: :jev_dsl,
      backend: :gemini_decisions,
      decisions_mode: :native,
      auth_mode: :x_goog_api_key,
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
      clear -> "Clear"
    end

    defjev :triage do
      noul :urgent, ask: "Is this urgent?" do
        true -> "Production outage."
        false -> "Routine."
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

  test "evaluates noul, choice, score, and defjev on gemini-decision-1 via unified /v1/decisions" do
    base_url = System.get_env("LITELLM_BASE_URL") || "http://100.88.180.12:4000"

    assert {:ok, resp} =
             LiveUnifiedContracts.evaluate(:is_spam, %{body: "Buy cheap followers now!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: prob}} = JevDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)

    assert {:ok, choice_resp} =
             LiveUnifiedContracts.evaluate(:sentiment, %{body: "Thanks for the great fix!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, tone} = JevDSL.fetch_answer(choice_resp, :tone)
    assert JevDSL.choice?(tone, :positive)

    assert {:ok, score_resp} =
             LiveUnifiedContracts.evaluate(
               :clarity,
               %{body: "1. Run mix test. 2. See 200 OK."},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, clarity} = JevDSL.fetch_answer(score_resp, :clarity)
    assert is_number(clarity.score)
    assert is_binary(clarity.label)

    assert {:ok, jev_resp} =
             LiveUnifiedContracts.evaluate(
               :triage,
               %{body: "Production DB is down! Steps: 1. Open app 2. Observe 502"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: urgent_prob}} = JevDSL.fetch_answer(jev_resp, :urgent)
    assert is_number(urgent_prob)
    assert {:ok, prio} = JevDSL.fetch_answer(jev_resp, :priority)
    assert JevDSL.choice?(prio, :p0)
    assert {:ok, jev_clarity} = JevDSL.fetch_answer(jev_resp, :clarity)
    assert is_number(jev_clarity.score)
  end

  test "evaluates noul, choice, score, and defjev on gemini-decision-1 via native /gemini/v1beta/decisions passthrough" do
    base_url = System.get_env("GEMINI_DECISIONS_BASE_URL") || "https://2-29-102-196.sslip.io"

    assert {:ok, resp} =
             LiveNativeContracts.evaluate(:is_spam, %{body: "Buy cheap followers now!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: prob}} = JevDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)

    assert {:ok, choice_resp} =
             LiveNativeContracts.evaluate(:sentiment, %{body: "Thanks for the great fix!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, tone} = JevDSL.fetch_answer(choice_resp, :tone)
    assert JevDSL.choice?(tone, :positive)

    assert {:ok, score_resp} =
             LiveNativeContracts.evaluate(
               :clarity,
               %{body: "1. Run mix test. 2. See 200 OK."},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, clarity} = JevDSL.fetch_answer(score_resp, :clarity)
    assert is_number(clarity.score)
    assert is_binary(clarity.label)

    assert {:ok, jev_resp} =
             LiveNativeContracts.evaluate(
               :triage,
               %{body: "Production DB is down! Steps: 1. Open app 2. Observe 502"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: urgent_prob}} = JevDSL.fetch_answer(jev_resp, :urgent)
    assert is_number(urgent_prob)
    assert {:ok, prio} = JevDSL.fetch_answer(jev_resp, :priority)
    assert JevDSL.choice?(prio, :p0)
    assert {:ok, jev_clarity} = JevDSL.fetch_answer(jev_resp, :clarity)
    assert is_number(jev_clarity.score)
  end
end
