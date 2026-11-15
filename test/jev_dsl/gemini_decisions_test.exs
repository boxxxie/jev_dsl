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
end
