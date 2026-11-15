defmodule JevDSL.GeminiDecisionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "use JevDSL backend option validation" do
    test "accepts :system_one and :gemini_decisions backends with unified or native modes" do
      for backend <- [:system_one, :gemini_decisions] do
        opts = JevDSL.__validate_use_opts__!(backend: backend)
        assert Keyword.get(opts, :backend) == backend
      end

      for mode <- [:unified, :native] do
        opts =
          JevDSL.__validate_use_opts__!(
            backend: :gemini_decisions,
            decisions_mode: mode,
            auth_mode: :x_goog_api_key,
            gemini_api_key: "test-key",
            model: "gemini-decision-1",
            base_url: "https://2-29-102-196.sslip.io"
          )

        assert Keyword.get(opts, :decisions_mode) == mode
        assert Keyword.get(opts, :auth_mode) == :x_goog_api_key
        assert Keyword.get(opts, :gemini_api_key) == "test-key"
      end
    end

    test "rejects invalid :backend, :decisions_mode, or :auth_mode values" do
      assert_raise NimbleOptions.ValidationError, fn ->
        JevDSL.__validate_use_opts__!(backend: :unknown_backend)
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        JevDSL.__validate_use_opts__!(decisions_mode: :invalid_mode)
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        JevDSL.__validate_use_opts__!(auth_mode: :invalid_auth)
      end
    end

    property "validates any combination of valid backend, decisions_mode, and auth_mode" do
      check all(
              backend <- member_of([:system_one, :gemini_decisions]),
              decisions_mode <- member_of([:unified, :native]),
              auth_mode <- member_of([:bearer, :x_goog_api_key])
            ) do
        opts =
          JevDSL.__validate_use_opts__!(
            backend: backend,
            decisions_mode: decisions_mode,
            auth_mode: auth_mode
          )

        assert Keyword.get(opts, :backend) == backend
        assert Keyword.get(opts, :decisions_mode) == decisions_mode
        assert Keyword.get(opts, :auth_mode) == auth_mode
      end
    end
  end

  describe "cache key isolation and backend availability" do
    defmodule GeminiUnifiedContract do
      use JevDSL,
        otp_app: :jev_dsl,
        backend: :gemini_decisions,
        decisions_mode: :unified,
        model: "gemini-decision-1"

      defnoul :is_spam do
        "Is this spam?"
      end
    end

    defmodule GeminiNativeContract do
      use JevDSL,
        otp_app: :jev_dsl,
        backend: :gemini_decisions,
        decisions_mode: :native,
        model: "gemini-decision-1"

      defnoul :is_spam do
        "Is this spam?"
      end
    end

    defmodule SystemOneContract do
      use JevDSL,
        otp_app: :jev_dsl

      defnoul :is_spam do
        "Is this spam?"
      end
    end

    test "isolates cache keys across :system_one, :unified, :native, and model overrides" do
      state = %{body: "hello"}
      prep_sys = SystemOneContract.prepared(:is_spam)
      prep_uni = GeminiUnifiedContract.prepared(:is_spam)
      prep_nat = GeminiNativeContract.prepared(:is_spam)

      key_sys = JevDSL.Cache.key(state, prep_sys)
      key_uni = JevDSL.Cache.key(state, prep_uni, backend: :gemini_decisions, decisions_mode: :unified, model: "gemini-decision-1")
      key_nat = JevDSL.Cache.key(state, prep_nat, backend: :gemini_decisions, decisions_mode: :native, model: "gemini-decision-1")
      key_other_model = JevDSL.Cache.key(state, prep_uni, backend: :gemini_decisions, decisions_mode: :unified, model: "gemini-decision-2")

      assert length(Enum.uniq([key_sys, key_uni, key_nat, key_other_model])) == 4
      assert GeminiUnifiedContract.cache_key(:is_spam, state) != SystemOneContract.cache_key(:is_spam, state)
      assert GeminiUnifiedContract.cache_key(:is_spam, state) != GeminiNativeContract.cache_key(:is_spam, state)
    end

    test "recognizes gemini_api_key and api_key for :gemini_decisions" do
      assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: "gk-123") ==
               "gk-123"

      assert JevDSL.Runner.api_key(backend: :gemini_decisions, api_key: "gk-456") == "gk-456"
      assert GeminiUnifiedContract.available?(gemini_api_key: "gk-123")
      assert GeminiNativeContract.available?(api_key: "gk-456")
    end
  end
end
