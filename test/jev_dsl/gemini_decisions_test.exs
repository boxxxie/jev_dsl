defmodule JevDSL.GeminiDecisionsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias JevDSL.ATDD.GeminiDecisionsDriver, as: Driver
  alias JevDSL.Providers.GeminiDecisions

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
    test "isolates cache keys across :system_one, :unified, :native, and model overrides" do
      state = %{body: "hello"}
      prep_sys = SystemOneContract.prepared(:is_spam)
      prep_uni = GeminiUnifiedContract.prepared(:is_spam)
      prep_nat = GeminiNativeContract.prepared(:is_spam)

      key_sys = JevDSL.Cache.key(state, prep_sys)

      key_uni =
        JevDSL.Cache.key(state, prep_uni,
          backend: :gemini_decisions,
          decisions_mode: :unified,
          model: "gemini-decision-1"
        )

      key_nat =
        JevDSL.Cache.key(state, prep_nat,
          backend: :gemini_decisions,
          decisions_mode: :native,
          model: "gemini-decision-1"
        )

      key_other_model =
        JevDSL.Cache.key(state, prep_uni,
          backend: :gemini_decisions,
          decisions_mode: :unified,
          model: "gemini-decision-2"
        )

      assert length(Enum.uniq([key_sys, key_uni, key_nat, key_other_model])) == 4

      assert GeminiUnifiedContract.cache_key(:is_spam, state) !=
               SystemOneContract.cache_key(:is_spam, state)

      assert GeminiUnifiedContract.cache_key(:is_spam, state) !=
               GeminiNativeContract.cache_key(:is_spam, state)

      assert GeminiUnifiedContract.cache_key(:is_spam, state, model: "gemini-decision-2") ==
               key_other_model
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

    test "recognizes gemini_api_key and api_key for :gemini_decisions" do
      assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: "gk-123") ==
               "gk-123"

      assert JevDSL.Runner.api_key(backend: :gemini_decisions, api_key: "gk-456") == "gk-456"
      assert GeminiUnifiedContract.available?(gemini_api_key: "gk-123")
      assert GeminiNativeContract.available?(api_key: "gk-456")
    end

    test "attaches contract name when JevDSL.Error.from_reason/2 handles provider_error" do
      err = %JevDSL.Error{type: :provider_error, message: "boom"}

      assert %JevDSL.Error{type: :provider_error, contract: :is_spam} =
               JevDSL.Error.from_reason(err, :is_spam)
    end
  end

  describe "client retries, headers: nil, :any secrets, app env fallback, and keyless proxies" do
    test "enables default RetryPolicy and tolerates headers: nil in new_client/1" do
      client = GeminiDecisions.new_client(headers: nil)
      assert client.headers == %{}
      assert %SystemOneSDK.RetryPolicy{max_retries: 2} = client.retry

      no_retry = GeminiDecisions.new_client(retry: false)
      assert no_retry.retry == false
    end

    test "resolves {:system, ENV}, 0-arity secret funs, and :jev_dsl application config" do
      env_var = "JEV_DSL_TEST_SECRET_#{System.unique_integer([:positive])}"
      System.put_env(env_var, "  sk-from-env  ")
      prev_jev = Application.get_env(:jev_dsl, :gemini_api_key)
      prev_litellm = System.get_env("LITELLM_API_KEY")
      prev_gemini = System.get_env("GEMINI_API_KEY")
      System.delete_env("LITELLM_API_KEY")
      System.delete_env("GEMINI_API_KEY")

      on_exit(fn ->
        System.delete_env(env_var)

        if is_nil(prev_jev),
          do: Application.delete_env(:jev_dsl, :gemini_api_key),
          else: Application.put_env(:jev_dsl, :gemini_api_key, prev_jev)

        if prev_litellm, do: System.put_env("LITELLM_API_KEY", prev_litellm)
        if prev_gemini, do: System.put_env("GEMINI_API_KEY", prev_gemini)
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

      assert OtherOtpAppContract.available?()

      # Explicit blank key overrides env/app-env fallback
      assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: nil) == ""
      assert JevDSL.Runner.api_key(backend: :gemini_decisions, api_key: "") == ""
    end

    test "supports keyless proxies and extra_headers-only auth for :gemini_decisions" do
      pid =
        Driver.start_stub(fn req ->
          refute Map.has_key?(req.headers, "Authorization")
          assert req.headers["X-Proxy-Token"] == "proxy-secret"

          {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.12}]}}
        end)

      assert GeminiUnifiedContract.available?(
               base_url: "http://localhost:4000",
               api_key: nil
             )

      assert GeminiUnifiedContract.available?(extra_headers: %{"X-Proxy-Token" => "proxy-secret"})

      assert {:ok, resp} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "hello proxy"},
                 base_url: "http://localhost:4000",
                 api_key: "",
                 extra_headers: %{"X-Proxy-Token" => "proxy-secret"},
                 transport: Driver,
                 transport_opts: [stub_pid: pid],
                 cache?: false,
                 retry: false
               )

      assert {:ok, %{noul: 0.12}} = JevDSL.fetch_answer(resp, :is_spam)
      assert Driver.request_count(pid) == 1
    end
  end

  describe "pre-built :client cache namespace isolation and per-call overrides" do
    test "isolates cache keys and runtime ETS hits across pre-built clients and per-call overrides" do
      state = %{body: "prebuilt client isolation check"}
      table = :"jev_prebuilt_iso_#{System.unique_integer([:positive])}"
      :ets.new(table, [:named_table, :public, :set, {:read_concurrency, true}])

      pid =
        Driver.start_stub(fn req ->
          decoded = Jason.decode!(req.body)

          case {req.path, decoded["model"]} do
            {"/v1/decisions", "gemini-decision-1"} ->
              assert req.headers["Authorization"] == "Bearer sk-uni"
              {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.81}]}}

            {"/gemini/v1beta/decisions", "gemini-decision-1"} ->
              assert req.headers["x-goog-api-key"] == "sk-nat"
              {200, %{"answers" => %{"is_spam" => %{"noul" => 0.82}}}}

            {"/gemini/v1beta/decisions", "gemini-decision-2"} ->
              assert req.headers["x-goog-api-key"] == "sk-override"
              {200, %{"answers" => %{"is_spam" => %{"noul" => 0.83}}}}
          end
        end)

      sys_client =
        SystemOneSDK.Test.client()
        |> SystemOneSDK.Test.stub(is_spam: {:noul, 0.11})

      uni_client =
        SystemOneSDK.new_client(
          provider: GeminiDecisions,
          provider_opts: [
            decisions_mode: :unified,
            model: "gemini-decision-1",
            api_key: "sk-uni",
            base_url: "https://decisions.test.invalid",
            transport: Driver,
            transport_opts: [stub_pid: pid],
            retry: false
          ]
        )

      nat_client =
        SystemOneSDK.new_client(
          provider: GeminiDecisions,
          provider_opts: [
            decisions_mode: :native,
            model: "gemini-decision-1",
            api_key: "sk-nat",
            base_url: "https://decisions.test.invalid",
            transport: Driver,
            transport_opts: [stub_pid: pid],
            retry: false
          ]
        )

      prep = SystemOneContract.prepared(:is_spam)
      k_sys = JevDSL.Cache.key(state, prep, client: sys_client)
      k_uni = JevDSL.Cache.key(state, prep, client: uni_client)
      k_nat = JevDSL.Cache.key(state, prep, client: nat_client)

      k_ovr =
        JevDSL.Cache.key(state, prep,
          client: uni_client,
          decisions_mode: :native,
          model: "gemini-decision-2"
        )

      assert length(Enum.uniq([k_sys, k_uni, k_nat, k_ovr])) == 4

      # 1. Evaluate with SystemOneSDK.Test client
      assert {:ok, sys_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: sys_client, ets_table: table)

      assert {:ok, %{noul: 0.11}} = JevDSL.fetch_answer(sys_resp, :is_spam)

      # 2. Evaluate with pre-built unified GeminiDecisions client (no backend/mode opts repeated)
      assert {:ok, uni_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: uni_client, ets_table: table)

      assert {:ok, %{noul: 0.81}} = JevDSL.fetch_answer(uni_resp, :is_spam)
      assert Driver.request_count(pid) == 1

      # 3. Evaluate with pre-built native GeminiDecisions client on the same ETS table
      assert {:ok, nat_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: nat_client, ets_table: table)

      assert {:ok, %{noul: 0.82}} = JevDSL.fetch_answer(nat_resp, :is_spam)
      assert Driver.request_count(pid) == 2

      # 4. Evaluate with per-call overrides on uni_client
      assert {:ok, ovr_resp} =
               SystemOneContract.evaluate(:is_spam, state,
                 client: uni_client,
                 decisions_mode: :native,
                 auth_mode: :x_goog_api_key,
                 api_key: "sk-override",
                 model: "gemini-decision-2",
                 ets_table: table
               )

      assert {:ok, %{noul: 0.83}} = JevDSL.fetch_answer(ovr_resp, :is_spam)
      assert Driver.request_count(pid) == 3

      # 5. Re-evaluating hits ETS cache with 0 extra network requests
      assert {:ok, ^uni_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: uni_client, ets_table: table)

      assert {:ok, ^nat_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: nat_client, ets_table: table)

      assert Driver.request_count(pid) == 3

      # 6. evaluate_many also isolates and honors overrides on pre-built client
      batch_state = %{body: "prebuilt batch isolation"}

      assert [{:ok, batch_uni}] =
               SystemOneContract.evaluate_many(:is_spam, [batch_state],
                 client: uni_client,
                 ets_table: table
               )

      assert {:ok, %{noul: 0.81}} = JevDSL.fetch_answer(batch_uni, :is_spam)
      assert Driver.request_count(pid) == 4

      assert [{:ok, batch_ovr}] =
               SystemOneContract.evaluate_many(:is_spam, [batch_state],
                 client: uni_client,
                 decisions_mode: :native,
                 api_key: "sk-override",
                 model: "gemini-decision-2",
                 ets_table: table
               )

      assert {:ok, %{noul: 0.83}} = JevDSL.fetch_answer(batch_ovr, :is_spam)
      assert Driver.request_count(pid) == 5

      SystemOneSDK.Test.verify!(sys_client)
      SystemOneSDK.Test.close(sys_client)
    end
  end
end
