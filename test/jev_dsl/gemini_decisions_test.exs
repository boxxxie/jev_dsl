defmodule JevDSL.GeminiDecisionsTest do
  use ExUnit.Case, async: true
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

  defmodule SecretCallbackHelper do
    def return_false, do: false
    def return_error, do: :error
  end

  describe "use JevDSL backend option validation" do
    test "accepts :system_one and :gemini_decisions backends with unified, native, and auth_mode :none" do
      for backend <- [:system_one, :gemini_decisions] do
        opts = JevDSL.__validate_use_opts__!(backend: backend)
        assert Keyword.get(opts, :backend) == backend
      end

      for mode <- [:unified, :native], auth <- [:bearer, :x_goog_api_key, :none] do
        opts =
          JevDSL.__validate_use_opts__!(
            backend: :gemini_decisions,
            decisions_mode: mode,
            auth_mode: auth,
            gemini_api_key: "test-key",
            model: "gemini-decision-1",
            base_url: "https://decisions.example.invalid"
          )

        assert Keyword.get(opts, :decisions_mode) == mode
        assert Keyword.get(opts, :auth_mode) == auth
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
              auth_mode <- member_of([:bearer, :x_goog_api_key, :none])
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

  describe "cache key isolation, unified base_url safety, and backend availability" do
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

    test "requires explicit/configured base_url for :unified mode without private IP default" do
      assert_raise ArgumentError, ~r/Missing :base_url/, fn ->
        GeminiDecisions.new_client(decisions_mode: :unified)
      end

      refute GeminiUnifiedContract.available?(gemini_api_key: "gk-123")

      assert {:error, %JevDSL.Error{type: :invalid_request, message: msg}} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "hi"},
                 gemini_api_key: "gk-123",
                 cache?: false
               )

      assert msg =~ "Missing :base_url"

      assert GeminiUnifiedContract.available?(
               gemini_api_key: "gk-123",
               base_url: "http://localhost:4000"
             )

      assert GeminiNativeContract.available?(api_key: "gk-456")
    end

    test "recognizes gemini_api_key and api_key and rejects false/atom secrets" do
      assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: "gk-123") ==
               "gk-123"

      assert JevDSL.Runner.api_key(backend: :gemini_decisions, api_key: "gk-456") == "gk-456"

      assert JevDSL.Runner.resolve_secret(false) == nil
      assert JevDSL.Runner.resolve_secret(true) == nil
      assert JevDSL.Runner.resolve_secret(:error) == nil

      assert JevDSL.Runner.api_key(backend: :gemini_decisions, gemini_api_key: false) == ""

      assert JevDSL.Runner.resolve_override_secret(
               [gemini_api_key: {SecretCallbackHelper, :return_false, []}],
               [:gemini_api_key],
               nil
             ) == nil

      assert JevDSL.Runner.resolve_override_secret(
               [gemini_api_key: {SecretCallbackHelper, :return_error, []}],
               [:gemini_api_key],
               nil
             ) == nil

      refute GeminiNativeContract.available?(gemini_api_key: false)

      assert {:error, :no_api_key} =
               GeminiNativeContract.evaluate(:is_spam, %{body: "x"},
                 gemini_api_key: false,
                 cache?: false
               )
    end

    test "attaches contract name when JevDSL.Error.from_reason/2 handles provider_error" do
      err = %JevDSL.Error{type: :provider_error, message: "boom"}

      assert %JevDSL.Error{type: :provider_error, contract: :is_spam} =
               JevDSL.Error.from_reason(err, :is_spam)
    end
  end

  describe "client retries, headers: nil, ErrorHandler isolation, and explicit keyless auth" do
    test "enables default RetryPolicy, tolerates headers: nil, and keeps error callbacks off GeminiDecisions" do
      client = GeminiDecisions.new_client(base_url: "http://localhost:4000", headers: nil)
      assert client.headers == %{}
      assert %SystemOneSDK.RetryPolicy{max_retries: 2} = client.retry

      no_retry = GeminiDecisions.new_client(base_url: "http://localhost:4000", retry: false)
      assert no_retry.retry == false

      refute function_exported?(GeminiDecisions, :from_response, 4)
      refute function_exported?(GeminiDecisions, :validation_error, 3)
      refute function_exported?(GeminiDecisions, :connection_error, 2)
    end

    test "does not falsely mark nil-key contracts available without auth_mode: :none or custom headers" do
      refute GeminiUnifiedContract.available?(
               base_url: "http://localhost:4000",
               api_key: nil
             )

      assert {:error, :no_api_key} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "hi"},
                 base_url: "http://localhost:4000",
                 api_key: nil,
                 cache?: false
               )

      refute GeminiNativeContract.available?(
               base_url: "https://generativelanguage.googleapis.com",
               gemini_api_key: nil
             )
    end

    test "supports auth_mode: :none and extra_headers-only auth for :gemini_decisions" do
      pid =
        Driver.start_stub(fn req ->
          refute Map.has_key?(req.headers, "Authorization")
          refute Map.has_key?(req.headers, "x-goog-api-key")
          {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.12}]}}
        end)

      assert GeminiUnifiedContract.available?(
               base_url: "http://localhost:4000",
               auth_mode: :none
             )

      assert {:ok, keyless_resp} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "hello auth none"},
                 base_url: "http://localhost:4000",
                 auth_mode: :none,
                 api_key: "ignored-when-none",
                 transport: Driver,
                 transport_opts: [stub_pid: pid],
                 cache?: false,
                 retry: false
               )

      assert {:ok, %{noul: 0.12}} = JevDSL.fetch_answer(keyless_resp, :is_spam)
      assert Driver.request_count(pid) == 1

      proxy_pid =
        Driver.start_stub(fn req ->
          refute Map.has_key?(req.headers, "Authorization")
          assert req.headers["X-Proxy-Token"] == "proxy-secret"

          {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.22}]}}
        end)

      assert GeminiUnifiedContract.available?(
               base_url: "http://localhost:4000",
               extra_headers: %{"X-Proxy-Token" => "proxy-secret"}
             )

      assert {:ok, resp} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "hello proxy"},
                 base_url: "http://localhost:4000",
                 api_key: "",
                 extra_headers: %{"X-Proxy-Token" => "proxy-secret"},
                 transport: Driver,
                 transport_opts: [stub_pid: proxy_pid],
                 cache?: false,
                 retry: false
               )

      assert {:ok, %{noul: 0.22}} = JevDSL.fetch_answer(resp, :is_spam)
      assert Driver.request_count(proxy_pid) == 1
    end
  end

  describe "pre-built :client cache namespace isolation, base_url overrides, and case-insensitive headers" do
    test "honors per-call :base_url override and case-insensitive extra_headers on pre-built :client" do
      pid =
        Driver.start_stub(fn req ->
          # Case-insensitive override replaces Authorization instead of emitting duplicate keys
          auth_keys =
            req.headers
            |> Map.keys()
            |> Enum.filter(&(String.downcase(&1) == "authorization"))

          assert length(auth_keys) <= 1

          case {req.url, req.path} do
            {"https://generativelanguage.googleapis.com/v1beta/decisions", "/v1beta/decisions"} ->
              assert req.headers["x-goog-api-key"] == "sk-google"
              {200, %{"answers" => %{"is_spam" => %{"noul" => 0.31}}}}

            {"https://override.example.invalid/v1/decisions", "/v1/decisions"} ->
              assert req.headers["authorization"] == "Bearer override-lower"
              assert req.headers["X-Num"] == "42"
              {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.41}]}}
          end
        end)

      uni_client =
        SystemOneSDK.new_client(
          provider: GeminiDecisions,
          provider_opts: [
            decisions_mode: :unified,
            model: "gemini-decision-1",
            api_key: "sk-initial",
            base_url: "https://initial.example.invalid",
            transport: Driver,
            transport_opts: [stub_pid: pid],
            retry: false
          ]
        )

      assert {:ok, google_resp} =
               SystemOneContract.evaluate(:is_spam, %{body: "base_url override to google"},
                 client: uni_client,
                 decisions_mode: :native,
                 base_url: "https://generativelanguage.googleapis.com",
                 api_key: "sk-google",
                 cache?: false
               )

      assert {:ok, %{noul: 0.31}} = JevDSL.fetch_answer(google_resp, :is_spam)

      assert {:ok, header_resp} =
               SystemOneContract.evaluate(:is_spam, %{body: "case-insensitive header override"},
                 client: uni_client,
                 base_url: "https://override.example.invalid",
                 extra_headers: %{"authorization" => "Bearer override-lower", "X-Num" => 42},
                 cache?: false
               )

      assert {:ok, %{noul: 0.41}} = JevDSL.fetch_answer(header_resp, :is_spam)
      assert Driver.request_count(pid) == 2
    end

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
              case req.headers["x-goog-api-key"] do
                "sk-nat" ->
                  {200, %{"answers" => %{"is_spam" => %{"noul" => 0.82}}}}

                "sk-direct-override" ->
                  {200, %{"answers" => %{"is_spam" => %{"noul" => 0.84}}}}
              end

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

      # Passing non-Gemini SystemOneSDK.Client with backend: :gemini_decisions still caches under :system_one
      assert SystemOneContract.cache_key(:is_spam, state,
               client: sys_client,
               backend: :gemini_decisions
             ) == k_sys

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

      # 7. Direct GeminiDecisions.system_one_prepared/4 honors per-call overrides and unresolved secret fallback
      assert {:ok, direct_resp} =
               GeminiDecisions.system_one_prepared(
                 uni_client.provider_client,
                 state,
                 prep,
                 decisions_mode: :native,
                 auth_mode: :x_goog_api_key,
                 api_key: "sk-direct-override"
               )

      assert {:ok, %{noul: 0.84}} = JevDSL.fetch_answer(direct_resp, :is_spam)
      assert Driver.request_count(pid) == 6

      assert {:ok, fallback_resp} =
               GeminiDecisions.system_one_prepared(
                 uni_client.provider_client,
                 state,
                 prep,
                 api_key: {:system, "MISSING_ENV_VAR_XYZ"}
               )

      assert {:ok, %{noul: 0.81}} = JevDSL.fetch_answer(fallback_resp, :is_spam)
      assert Driver.request_count(pid) == 7

      SystemOneSDK.Test.verify!(sys_client)
      SystemOneSDK.Test.close(sys_client)
    end
  end
end
