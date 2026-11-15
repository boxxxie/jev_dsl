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
      partial -> "Partial"
      clear -> "Clear and complete"
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
        partial -> "Partial"
        clear -> "Clear and complete"
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
      partial -> "Partial"
      clear -> "Clear and complete"
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
        partial -> "Partial"
        clear -> "Clear and complete"
      end
    end
  end

  test "evaluates noul, choice, score, and defjev on gemini-decision-1 via unified /v1/decisions" do
    base_url = System.get_env("LITELLM_BASE_URL") || "http://100.88.180.12:4000"
    api_opts = litellm_api_key_opt()

    assert {:ok, resp} =
             LiveUnifiedContracts.evaluate(
               :is_spam,
               %{body: "Buy cheap followers now!"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: prob}} = JevDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)
    assert prob > 0.8

    assert {:ok, neg_resp} =
             LiveUnifiedContracts.evaluate(
               :is_spam,
               %{body: "Hi, could you please help reset my account password?"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: neg_prob}} = JevDSL.fetch_answer(neg_resp, :is_spam)
    assert is_number(neg_prob)
    assert neg_prob < 0.2

    assert {:ok, choice_resp} =
             LiveUnifiedContracts.evaluate(
               :sentiment,
               %{body: "Thanks for the great fix!"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, tone} = JevDSL.fetch_answer(choice_resp, :tone)
    assert JevDSL.choice?(tone, :positive)

    assert {:ok, score_resp} =
             LiveUnifiedContracts.evaluate(
               :clarity,
               %{body: "1. Open app. 2. Click save. 3. Observe 500 error with full stacktrace."},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, clarity} = JevDSL.fetch_answer(score_resp, :clarity)
    assert is_number(clarity.score)
    assert clarity.score > 1.0 and clarity.score <= 2.0
    assert clarity.level in [1, 2]
    assert is_binary(clarity.label)

    assert {:ok, jev_resp} =
             LiveUnifiedContracts.evaluate(
               :triage,
               %{body: "Production DB is down! Steps: 1. Open app 2. Observe 502"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: urgent_prob}} = JevDSL.fetch_answer(jev_resp, :urgent)
    assert is_number(urgent_prob)
    assert urgent_prob > 0.8
    assert {:ok, prio} = JevDSL.fetch_answer(jev_resp, :priority)
    assert JevDSL.choice?(prio, :p0)
    assert {:ok, jev_clarity} = JevDSL.fetch_answer(jev_resp, :clarity)
    assert is_number(jev_clarity.score)
    assert jev_clarity.score >= 0.0 and jev_clarity.score <= 2.0
    assert jev_clarity.level in 0..2

    assert {:ok, routine_jev_resp} =
             LiveUnifiedContracts.evaluate(
               :triage,
               %{
                 body: "Question: Could you update the copyright year in the footer next release?"
               },
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: routine_urgent_prob}} = JevDSL.fetch_answer(routine_jev_resp, :urgent)
    assert is_number(routine_urgent_prob)
    assert routine_urgent_prob < 0.2
    assert {:ok, routine_prio} = JevDSL.fetch_answer(routine_jev_resp, :priority)
    assert JevDSL.choice?(routine_prio, :p2)
  end

  test "evaluates noul, choice, score, and defjev on gemini-decision-1 via native /gemini/v1beta/decisions passthrough" do
    base_url = System.get_env("GEMINI_DECISIONS_BASE_URL") || "https://2-29-102-196.sslip.io"
    api_opts = native_api_key_opt(base_url)

    assert {:ok, resp} =
             LiveNativeContracts.evaluate(
               :is_spam,
               %{body: "Buy cheap followers now!"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: prob}} = JevDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)
    assert prob > 0.8

    assert {:ok, neg_resp} =
             LiveNativeContracts.evaluate(
               :is_spam,
               %{body: "Hi, could you please help reset my account password?"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: neg_prob}} = JevDSL.fetch_answer(neg_resp, :is_spam)
    assert is_number(neg_prob)
    assert neg_prob < 0.2

    assert {:ok, choice_resp} =
             LiveNativeContracts.evaluate(
               :sentiment,
               %{body: "Thanks for the great fix!"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, tone} = JevDSL.fetch_answer(choice_resp, :tone)
    assert JevDSL.choice?(tone, :positive)

    assert {:ok, score_resp} =
             LiveNativeContracts.evaluate(
               :clarity,
               %{body: "1. Open app. 2. Click save. 3. Observe 500 error with full stacktrace."},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, clarity} = JevDSL.fetch_answer(score_resp, :clarity)
    assert is_number(clarity.score)
    assert clarity.score > 1.0 and clarity.score <= 2.0
    assert clarity.level in [1, 2]
    assert is_binary(clarity.label)

    assert {:ok, jev_resp} =
             LiveNativeContracts.evaluate(
               :triage,
               %{body: "Production DB is down! Steps: 1. Open app 2. Observe 502"},
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: urgent_prob}} = JevDSL.fetch_answer(jev_resp, :urgent)
    assert is_number(urgent_prob)
    assert urgent_prob > 0.8
    assert {:ok, prio} = JevDSL.fetch_answer(jev_resp, :priority)
    assert JevDSL.choice?(prio, :p0)
    assert {:ok, jev_clarity} = JevDSL.fetch_answer(jev_resp, :clarity)
    assert is_number(jev_clarity.score)
    assert jev_clarity.score >= 0.0 and jev_clarity.score <= 2.0
    assert jev_clarity.level in 0..2

    assert {:ok, routine_jev_resp} =
             LiveNativeContracts.evaluate(
               :triage,
               %{
                 body: "Question: Could you update the copyright year in the footer next release?"
               },
               [base_url: base_url, cache?: false] ++ api_opts
             )

    assert {:ok, %{noul: routine_urgent_prob}} = JevDSL.fetch_answer(routine_jev_resp, :urgent)
    assert is_number(routine_urgent_prob)
    assert routine_urgent_prob < 0.2
    assert {:ok, routine_prio} = JevDSL.fetch_answer(routine_jev_resp, :priority)
    assert JevDSL.choice?(routine_prio, :p2)
  end

  defp litellm_api_key_opt do
    key =
      Enum.find(
        [
          System.get_env("LITELLM_API_KEY"),
          System.get_env("LITELLM_MASTER_KEY"),
          System.get_env("GEMINI_API_KEY")
        ],
        fn
          val when is_binary(val) -> String.starts_with?(val, "sk-")
          _ -> false
        end
      )

    if key, do: [api_key: key], else: []
  end

  defp native_api_key_opt(base_url) do
    if String.contains?(base_url, "generativelanguage.googleapis.com") do
      case System.get_env("GEMINI_API_KEY") do
        val when is_binary(val) and val != "" -> [api_key: val]
        _ -> []
      end
    else
      litellm_api_key_opt()
    end
  end
end
