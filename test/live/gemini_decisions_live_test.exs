defmodule SystemOneDSL.Live.GeminiDecisionsLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  defmodule LiveUnifiedContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      backend: :gemini_decisions,
      decisions_mode: :unified,
      model: "gemini-decision-1"

    defnoul :is_spam do
      "Does this message contain unsolicited promotional spam?"
    end
  end

  defmodule LiveNativeContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      backend: :gemini_decisions,
      decisions_mode: :native,
      auth_mode: :x_goog_api_key,
      model: "gemini-decision-1"

    defnoul :is_spam do
      "Does this message contain unsolicited promotional spam?"
    end
  end

  test "evaluates gemini-decision-1 via unified /v1/decisions" do
    base_url = System.get_env("LITELLM_BASE_URL") || "http://100.88.180.12:4000"

    assert {:ok, resp} =
             LiveUnifiedContracts.evaluate(:is_spam, %{body: "Buy cheap followers now!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: prob}} = SystemOneDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)
  end

  test "evaluates gemini-decision-1 via native /gemini/v1beta/decisions passthrough" do
    base_url = System.get_env("GEMINI_DECISIONS_BASE_URL") || "https://2-29-102-196.sslip.io"

    assert {:ok, resp} =
             LiveNativeContracts.evaluate(:is_spam, %{body: "Buy cheap followers now!"},
               base_url: base_url,
               cache?: false
             )

    assert {:ok, %{noul: prob}} = SystemOneDSL.fetch_answer(resp, :is_spam)
    assert is_number(prob)
  end
end
