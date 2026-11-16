defmodule JevDSL.GeminiDecisionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JevDSL.ATDD.GeminiDecisionsDriver, as: Driver
  alias SystemOneSDK.Providers.GeminiDecisions

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

      refute GeminiNativeContract.available?(gemini_api_key: false)

      assert {:error, :no_api_key} =
               GeminiNativeContract.evaluate(:is_spam, %{body: "x"},
                 gemini_api_key: false,
                 cache?: false
               )

      err = %JevDSL.Error{type: :provider_error, message: "boom"}

      assert %JevDSL.Error{type: :provider_error, contract: :is_spam} =
               JevDSL.Error.from_reason(err, :is_spam)
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
    end
  end

  describe "pre-built :client integration, runtime validation, and error safety" do
    test "isolates cache keys and runtime ETS hits across pre-built clients" do
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

            {"/v1beta/decisions", "gemini-decision-1"} ->
              assert req.headers["x-goog-api-key"] == "sk-nat"
              {200, %{"answers" => %{"is_spam" => %{"noul" => 0.82}}}}
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

      assert length(Enum.uniq([k_sys, k_uni, k_nat])) == 3

      assert SystemOneContract.cache_key(:is_spam, state,
               client: sys_client,
               backend: :gemini_decisions
             ) == k_sys

      assert {:ok, sys_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: sys_client, ets_table: table)

      assert {:ok, %{noul: 0.11}} = JevDSL.fetch_answer(sys_resp, :is_spam)

      assert {:ok, uni_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: uni_client, ets_table: table)

      assert {:ok, %{noul: 0.81}} = JevDSL.fetch_answer(uni_resp, :is_spam)
      assert Driver.request_count(pid) == 1

      assert {:ok, nat_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: nat_client, ets_table: table)

      assert {:ok, %{noul: 0.82}} = JevDSL.fetch_answer(nat_resp, :is_spam)
      assert Driver.request_count(pid) == 2

      # Re-evaluating hits ETS cache with 0 extra network requests
      assert {:ok, ^uni_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: uni_client, ets_table: table)

      assert {:ok, ^nat_resp} =
               SystemOneContract.evaluate(:is_spam, state, client: nat_client, ets_table: table)

      assert Driver.request_count(pid) == 2

      batch_state = %{body: "prebuilt batch isolation"}

      assert [{:ok, batch_uni}] =
               SystemOneContract.evaluate_many(:is_spam, [batch_state],
                 client: uni_client,
                 ets_table: table
               )

      assert {:ok, %{noul: 0.81}} = JevDSL.fetch_answer(batch_uni, :is_spam)
      assert Driver.request_count(pid) == 3

      SystemOneSDK.Test.verify!(sys_client)
      SystemOneSDK.Test.close(sys_client)
    end

    test "returns invalid_options on runtime typos in :backend, :decisions_mode, or :auth_mode" do
      assert {:error, %JevDSL.Error{type: :invalid_options}} =
               SystemOneContract.evaluate(:is_spam, %{body: "x"},
                 backend: :gemini_decision,
                 cache?: false
               )

      assert {:error, %JevDSL.Error{type: :invalid_options}} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "x"},
                 decisions_mode: :natve,
                 base_url: "http://localhost:4000",
                 gemini_api_key: "sk-1",
                 cache?: false
               )

      assert {:error, %JevDSL.Error{type: :invalid_options}} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "x"},
                 auth_mode: :typo,
                 base_url: "http://localhost:4000",
                 gemini_api_key: "sk-1",
                 cache?: false
               )

      assert [{:error, %JevDSL.Error{type: :invalid_options}}] =
               SystemOneContract.evaluate_many(:is_spam, [%{body: "x"}],
                 backend: :gemini_decision,
                 cache?: false
               )

      refute SystemOneContract.available?(backend: :gemini_decision)
      refute GeminiUnifiedContract.available?(decisions_mode: :natve, base_url: "http://x")
      refute GeminiUnifiedContract.available?(auth_mode: :typo, base_url: "http://x")

      assert_raise JevDSL.Error, fn ->
        JevDSL.Runner.api_key(backend: :gemini_decision)
      end

      assert_raise JevDSL.Error, fn ->
        JevDSL.Cache.key(%{body: "x"}, SystemOneContract.prepared(:is_spam),
          backend: :gemini_decision
        )
      end
    end

    test "returns structured errors instead of raising on unencodable state values" do
      pid = Driver.start_stub(fn _ -> {200, %{}} end)

      client =
        SystemOneSDK.new_client(
          provider: GeminiDecisions,
          provider_opts: [
            decisions_mode: :unified,
            api_key: "sk-1",
            base_url: "http://localhost:4000",
            transport: Driver,
            transport_opts: [stub_pid: pid],
            retry: false
          ]
        )

      for bad_map <- [%{pid: self()}, %{tuple: {1, 2}}, %{bin: <<255, 255>>}] do
        assert {:error, _reason} =
                 GeminiUnifiedContract.evaluate(:is_spam, bad_map, client: client, cache?: false)

        assert [{:error, _reason}] =
                 GeminiUnifiedContract.evaluate_many(:is_spam, [bad_map],
                   client: client,
                   cache?: false
                 )
      end

      assert {:error, %JevDSL.Error{type: :evaluation_failed}} =
               GeminiUnifiedContract.evaluate(:is_spam, %{body: "x"},
                 eval_fn: fn _ -> Jason.encode!(%{pid: self()}) end
               )
    end
  end
end
