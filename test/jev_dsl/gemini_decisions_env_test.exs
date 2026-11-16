defmodule JevDSL.GeminiDecisionsEnvTest do
  use ExUnit.Case, async: false

  defmodule RuntimeConfiguredContract do
    use JevDSL,
      otp_app: :jev_dsl

    defnoul :is_spam do
      "Is this spam?"
    end
  end

  defmodule OtherOtpAppContract do
    use JevDSL,
      otp_app: :some_other_app,
      backend: :gemini_decisions

    defnoul :is_spam do
      "Is this spam?"
    end
  end

  defmodule KeylessUnsetEnvContract do
    use JevDSL,
      otp_app: :jev_dsl,
      backend: :gemini_decisions,
      decisions_mode: :native,
      gemini_api_key: {:system, "JEV_DSL_ALWAYS_UNSET_KEY_XYZ"},
      base_url: "https://generativelanguage.googleapis.com"

    defnoul :is_spam do
      "Is this spam?"
    end
  end

  defmodule SecretCallbackHelper do
    def return_false, do: false
    def return_error, do: :error
  end

  test "cache_key/2 and cache_key/3 respect otp_app runtime config and per-call options" do
    state = %{body: "runtime config"}

    Application.put_env(:jev_dsl, RuntimeConfiguredContract,
      backend: :gemini_decisions,
      decisions_mode: :native,
      model: "gemini-decision-9"
    )

    on_exit(fn -> Application.delete_env(:jev_dsl, RuntimeConfiguredContract) end)

    prep = RuntimeConfiguredContract.prepared(:is_spam)

    expected =
      JevDSL.Cache.key(state, prep,
        backend: :gemini_decisions,
        decisions_mode: :native,
        model: "gemini-decision-9"
      )

    assert RuntimeConfiguredContract.cache_key(:is_spam, state) == expected

    override_expected =
      JevDSL.Cache.key(state, prep,
        backend: :gemini_decisions,
        decisions_mode: :unified,
        model: "gemini-decision-1"
      )

    assert RuntimeConfiguredContract.cache_key(:is_spam, state,
             decisions_mode: :unified,
             model: "gemini-decision-1"
           ) == override_expected
  end

  test "resolves {:system, ENV}, LITELLM_BASE_URL, 0-arity funs, and :jev_dsl app config" do
    env_var = "JEV_DSL_TEST_SECRET_#{System.unique_integer([:positive])}"
    System.put_env(env_var, "  sk-from-env  ")
    prev_jev = Application.get_env(:jev_dsl, :gemini_api_key)
    prev_base = Application.get_env(:jev_dsl, :litellm_base_url)
    prev_litellm_url = System.get_env("LITELLM_BASE_URL")
    prev_litellm = System.get_env("LITELLM_API_KEY")
    prev_master = System.get_env("LITELLM_MASTER_KEY")
    prev_gemini = System.get_env("GEMINI_API_KEY")
    System.delete_env("LITELLM_BASE_URL")
    System.delete_env("LITELLM_API_KEY")
    System.delete_env("LITELLM_MASTER_KEY")
    System.delete_env("GEMINI_API_KEY")

    on_exit(fn ->
      System.delete_env(env_var)

      if is_nil(prev_jev),
        do: Application.delete_env(:jev_dsl, :gemini_api_key),
        else: Application.put_env(:jev_dsl, :gemini_api_key, prev_jev)

      if is_nil(prev_base),
        do: Application.delete_env(:jev_dsl, :litellm_base_url),
        else: Application.put_env(:jev_dsl, :litellm_base_url, prev_base)

      if prev_litellm_url,
        do: System.put_env("LITELLM_BASE_URL", prev_litellm_url),
        else: System.delete_env("LITELLM_BASE_URL")

      if prev_litellm,
        do: System.put_env("LITELLM_API_KEY", prev_litellm),
        else: System.delete_env("LITELLM_API_KEY")

      if prev_master,
        do: System.put_env("LITELLM_MASTER_KEY", prev_master),
        else: System.delete_env("LITELLM_MASTER_KEY")

      if prev_gemini,
        do: System.put_env("GEMINI_API_KEY", prev_gemini),
        else: System.delete_env("GEMINI_API_KEY")
    end)

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             gemini_api_key: {:system, env_var}
           ) == "sk-from-env"

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             gemini_api_key: fn -> "  sk-from-fun  " end
           ) == "sk-from-fun"

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             gemini_api_key: {:system, "MISSING_ENV_VAR_XYZ"},
             api_key: "sk-fallback"
           ) == "sk-fallback"

    Application.put_env(:jev_dsl, :gemini_api_key, "sk-jev-app-env")

    assert JevDSL.Runner.api_key(backend: :gemini_decisions, otp_app: :some_other_app) ==
             "sk-jev-app-env"

    # Without unified base_url, available? is false even with an API key
    refute OtherOtpAppContract.available?()

    # Setting LITELLM_BASE_URL or app env :litellm_base_url makes unified available
    System.put_env("LITELLM_BASE_URL", "http://localhost:4000")
    assert OtherOtpAppContract.available?()
    System.delete_env("LITELLM_BASE_URL")
    refute OtherOtpAppContract.available?()

    Application.put_env(:jev_dsl, :litellm_base_url, "http://localhost:4001")
    assert OtherOtpAppContract.available?()

    # nil falls through to app config / env fallback, while "" and false explicitly override fallback
    assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: nil) ==
             "sk-jev-app-env"

    assert JevDSL.Runner.api_key(backend: :gemini_decisions, api_key: "") == ""
    assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: false) == ""

    # Empty env var in {:system, env_var, default} falls back to default
    empty_env_var = "JEV_DSL_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    System.put_env(empty_env_var, "   ")
    on_exit(fn -> System.delete_env(empty_env_var) end)
    assert JevDSL.Runner.resolve_secret({:system, empty_env_var, "default-sk"}) == "default-sk"

    # Unset app config + env makes api_key: nil unavailable without auth_mode: :none
    Application.delete_env(:jev_dsl, :gemini_api_key)
    assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: nil) == ""

    refute OtherOtpAppContract.available?(
             base_url: "http://localhost:4000",
             api_key: nil
           )

    # :system_one api_key: nil / typesafe_api_key: nil falls through to TYPESAFE_API_KEY
    prev_typesafe = System.get_env("TYPESAFE_API_KEY")
    System.put_env("TYPESAFE_API_KEY", "ts-env-fallback")

    on_exit(fn ->
      if prev_typesafe,
        do: System.put_env("TYPESAFE_API_KEY", prev_typesafe),
        else: System.delete_env("TYPESAFE_API_KEY")
    end)

    assert JevDSL.Runner.api_key(backend: :system_one, api_key: nil) == "ts-env-fallback"
    assert JevDSL.Runner.api_key(backend: :system_one, typesafe_api_key: nil) == "ts-env-fallback"

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             gemini_api_key: {SecretCallbackHelper, :return_false, []}
           ) == ""

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             gemini_api_key: {SecretCallbackHelper, :return_error, []}
           ) == ""

    refute KeylessUnsetEnvContract.available?()

    assert {:error, :no_api_key} =
             KeylessUnsetEnvContract.evaluate(:is_spam, %{body: "hi"}, cache?: false)
  end

  test "prioritizes GEMINI_API_KEY over LITELLM_* for :native Google endpoints" do
    prev_litellm = System.get_env("LITELLM_API_KEY")
    prev_master = System.get_env("LITELLM_MASTER_KEY")
    prev_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      if prev_litellm,
        do: System.put_env("LITELLM_API_KEY", prev_litellm),
        else: System.delete_env("LITELLM_API_KEY")

      if prev_master,
        do: System.put_env("LITELLM_MASTER_KEY", prev_master),
        else: System.delete_env("LITELLM_MASTER_KEY")

      if prev_gemini,
        do: System.put_env("GEMINI_API_KEY", prev_gemini),
        else: System.delete_env("GEMINI_API_KEY")
    end)

    System.put_env("LITELLM_API_KEY", "sk-litellm")
    System.put_env("LITELLM_MASTER_KEY", "sk-master")
    System.put_env("GEMINI_API_KEY", "AIza-native-key")

    # Unified mode prefers LITELLM_API_KEY
    assert JevDSL.Runner.api_key(backend: :gemini_decisions, decisions_mode: :unified) ==
             "sk-litellm"

    # Native mode targeting non-Google proxy prefers LITELLM_API_KEY
    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             decisions_mode: :native,
             base_url: "https://litellm-proxy.example.com"
           ) == "sk-litellm"

    # Native mode targeting default Google or explicit Google URL prefers GEMINI_API_KEY
    assert JevDSL.Runner.api_key(backend: :gemini_decisions, decisions_mode: :native) ==
             "AIza-native-key"

    assert JevDSL.Runner.api_key(
             backend: :gemini_decisions,
             decisions_mode: :native,
             base_url: "https://generativelanguage.googleapis.com"
           ) == "AIza-native-key"
  end
end
