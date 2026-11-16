defmodule SystemOneDSLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Igniter.Test

  alias SystemOneDSL.{Cache, Contract, Error, Question}
  alias SystemOneDSL.Cache.ETS

  doctest SystemOneDSL
  doctest SystemOneDSL.Cache
  doctest SystemOneDSL.CUE

  defmodule TestTier2Cache do
    @behaviour SystemOneDSL.Cache

    @default_table :system_one_dsl_test_tier2_ets

    @impl true
    def get(key, opts) do
      table = Keyword.get(opts, :tier2_ets_table, @default_table)
      ETS.get(key, Keyword.put(opts, :ets_table, table))
    end

    @impl true
    def get_many(keys, opts) do
      table = Keyword.get(opts, :tier2_ets_table, @default_table)
      ETS.get_many(keys, Keyword.put(opts, :ets_table, table))
    end

    @impl true
    def put(key, value, opts) do
      table = Keyword.get(opts, :tier2_ets_table, @default_table)
      ETS.put(key, value, Keyword.put(opts, :ets_table, table))
    end

    @impl true
    def put_many(entries, opts) do
      table = Keyword.get(opts, :tier2_ets_table, @default_table)
      ETS.put_many(entries, Keyword.put(opts, :ets_table, table))
    end
  end

  defmodule SampleContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      cache: SystemOneDSL.Cache.ETS,
      tier2_cache: SystemOneDSLTest.TestTier2Cache

    defnoul :is_spam, as: :spam_detected do
      """
      Does this message contain unsolicited promotional spam?
      """
    end

    defnoul "is_urgent_noul", ask: "Is this ticket time-critical?" do
      true -> "Production outage or active security breach."
      false -> "Routine question or non-blocking request."
    end

    defchoice :sentiment,
      as: :tone,
      ask: "Classify the overall tone of the message." do
      positive -> "Constructive, appreciative, or favorable tone."
      :neutral -> "Factual or informational without strong emotion."
      "negative" -> "Critical, frustrated, or dissatisfied tone."
    end

    defchoice "csv_column_mapping",
      as: "mapped_field",
      ask: "Map the CSV column header." do
      "given_name" -> "First name of the user."
      "Needs Review" -> "Ambiguous column."
      UNMAPPED -> "Does not map to a known field."
    end

    defscore :completeness,
      ask: "Rate how complete the submission is." do
      incomplete -> "Missing required fields."
      partial -> "Core fields are present with minor gaps."
      complete -> "All required and optional fields are populated."
    end

    defjev :ticket_triage do
      noul :requires_escalation do
        "Does this issue require immediate engineering escalation?"
      end

      noul(:is_vip, ask: "Is the requester an enterprise VIP?")

      choice :priority,
        ask: "Select the appropriate response priority." do
        urgent -> "Production outage or security incident."
        normal -> "Standard bug report or feature question."
      end

      score :clarity,
        ask: "Rate the clarity of the reproduction steps." do
        vague -> "No reproduction steps provided."
        clear -> "Includes clear steps and expected vs actual behavior."
      end
    end

    defcontract :contract_bundle do
      noul :is_valid do
        "Is this submission valid?"
      end
    end

    defalias(:legacy_triage, :ticket_triage)
    defalias("string_triage_alias", "ticket_triage")
  end

  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  setup do
    uid = System.unique_integer([:positive])
    l1_table = :"jev_l1_#{uid}"
    l2_table = :"jev_l2_#{uid}"
    server_name = :"jev_ets_server_#{uid}"

    start_supervised!({ETS, name: server_name, table: l1_table, cleanup_interval: :infinity})

    start_supervised!(
      {ETS, name: :"#{server_name}_l2", table: l2_table, cleanup_interval: :infinity}
    )

    {:ok, cache_opts: [ets_table: l1_table, tier2_ets_table: l2_table]}
  end

  describe "SystemOneDSL compile-time contract compilation & atom/string interoperability" do
    test "compiles defnoul, defchoice, defscore, defcontract, defjev, and defalias into typed %SystemOneDSL.Contract{} structs" do
      contracts = SampleContracts.__contracts__()
      assert map_size(contracts) == 9

      for key <- [
            :is_spam,
            :is_urgent_noul,
            :sentiment,
            :csv_column_mapping,
            :completeness,
            :ticket_triage,
            :contract_bundle,
            :legacy_triage,
            :string_triage_alias
          ] do
        str_key = Atom.to_string(key)
        assert SampleContracts.has_contract?(key)
        assert SampleContracts.has_contract?(str_key)
        assert {:ok, %Contract{} = contract} = SampleContracts.contract(key)
        assert {:ok, ^contract} = SampleContracts.contract(str_key)
        assert {:ok, fp} = SampleContracts.contract_fingerprint(key)
        assert {:ok, ^fp} = SampleContracts.contract_fingerprint(str_key)
        assert %Contract{questions: [%Question{} | _], prepared: prep} = contracts[key]
        assert %SystemOneSDK.Prepared{fingerprint: ^fp} = prep
        assert SampleContracts.prepared(key) == prep
        assert SampleContracts.prepared(str_key) == prep
      end

      assert SampleContracts.prepared(:legacy_triage) == SampleContracts.prepared(:ticket_triage)

      assert SampleContracts.prepared("string_triage_alias") ==
               SampleContracts.prepared(:ticket_triage)

      refute SampleContracts.has_contract?(:nonexistent)
      assert SampleContracts.contract(:nonexistent) == :error
      assert SampleContracts.contract_fingerprint(:nonexistent) == :error
    end

    test "preserves stab-clause declaration order in defchoice and compiles option keys as atoms" do
      prep = SampleContracts.prepared(:sentiment)
      tone_def = prep.definitions["tone"]
      assert tone_def.option_order == [:positive, :neutral, :negative]

      csv_prep = SampleContracts.prepared("csv_column_mapping")
      csv_def = csv_prep.definitions["mapped_field"]
      assert csv_def.option_order == [:given_name, :"Needs Review", :UNMAPPED]
    end

    test "exports noul, choice, and score contracts to CUE schema via __export_cue__/0" do
      cue = SampleContracts.__export_cue__()
      assert is_binary(cue)
      assert cue =~ "is_spam: {"
      assert cue =~ "is_urgent_noul: {"
      assert cue =~ "sentiment: {"
      assert cue =~ "completeness: {"
      assert cue =~ "ticket_triage: {"
      assert cue =~ ~s(type: "score")
    end

    test "raises CompileError on duplicate contracts, invalid options, or broken aliases" do
      assert_raise CompileError, ~r/Duplicate SystemOneDSL contract :dup/, fn ->
        Code.compile_string("""
        defmodule SystemOneDSLTest.DupContracts do
          use SystemOneDSL
          defnoul :dup do "First" end
          defnoul :dup do "Second" end
        end
        """)
      end

      assert_raise CompileError, ~r/requires 2\.\.255 entries/, fn ->
        Code.compile_string("""
        defmodule SystemOneDSLTest.SingleChoiceContract do
          use SystemOneDSL
          defchoice :bad_choice, ask: "Pick one" do
            only_one -> "Not enough options"
          end
        end
        """)
      end

      assert_raise CompileError, ~r/references unknown contract :missing_target/, fn ->
        Code.compile_string("""
        defmodule SystemOneDSLTest.BadAliasContract do
          use SystemOneDSL
          defnoul :valid do "Valid?" end
          defalias :broken, :missing_target
        end
        """)
      end

      assert_raise CompileError, ~r/conflicts with an existing contract/, fn ->
        Code.compile_string("""
        defmodule SystemOneDSLTest.ConflictingAliasContract do
          use SystemOneDSL
          defnoul :existing do "Valid?" end
          defalias :existing, :existing
        end
        """)
      end
    end
  end

  describe "SystemOneDSL.Cache deterministic hashing, property invariants & ETS resilience" do
    property "canonicalize/1 and key/3 produce identical hashes for atom-keyed and string-keyed maps/tuples" do
      check all(
              text <- string(:printable, max_length: 40),
              count <- integer(-1_000..1_000),
              flag <- boolean(),
              tags <- list_of(string(:alphanumeric, min_length: 1, max_length: 10), max_length: 5)
            ) do
        state_atoms = %{
          text: text,
          meta: %{count: count, active: flag, tuple_pair: {%{nested_key: text}, tags}}
        }

        state_strings = %{
          "text" => text,
          "meta" => %{
            "count" => count,
            "active" => flag,
            "tuple_pair" => {%{"nested_key" => text}, tags}
          }
        }

        assert SampleContracts.cache_key(:sentiment, state_atoms) ==
                 SampleContracts.cache_key("sentiment", state_strings)
      end
    end

    test "distinguishes high-confidence vs low-confidence responses for Choice, Noul, and Score TTLs" do
      high_choice =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             tone: %SystemOneSDK.ChoiceAnswer{
               choice: "positive",
               confidence: 0.92,
               probabilities: %{"positive" => 0.92, "neutral" => 0.08}
             }
           }
         }}

      low_choice =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             tone: %SystemOneSDK.ChoiceAnswer{
               choice: "positive",
               confidence: 0.52,
               probabilities: %{"positive" => 0.52, "neutral" => 0.48}
             }
           }
         }}

      low_score =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             completeness: %SystemOneSDK.ScoreAnswer{
               score: 1.0,
               confidence: 0.40,
               legend: %{0 => "incomplete", 1 => "complete"},
               probabilities: %{0 => 0.6, 1 => 0.4}
             }
           }
         }}

      assert Cache.cacheable?(high_choice)
      refute Cache.cacheable?(low_choice)
      refute Cache.cacheable?(low_score)
      assert Cache.resolve_ttl(high_choice, ttl: 86_400) == {:ok, 86_400}
      assert Cache.resolve_ttl(low_choice, ttl: 86_400) == {:ok, 300}
      assert Cache.resolve_ttl(low_score, ttl: 86_400) == {:ok, 300}
      assert Cache.resolve_ttl({:error, :timeout}) == :skip
    end

    test "unsupervised on-demand ETS table survives after ephemeral creator process exits and prunes expired keys" do
      ephemeral_table = :"jev_ephemeral_#{System.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          ETS.put("k_live", {:ok, :alive}, ets_table: ephemeral_table, ttl: 3600)
        end)

      assert :ok = Task.await(task)
      assert ETS.get("k_live", ets_table: ephemeral_table) == {:ok, {:ok, :alive}}

      # Insert an already-expired entry directly and verify prune_expired/1 evicts it
      :ets.insert(
        ephemeral_table,
        {"k_expired", {:ok, :old}, System.monotonic_time(:second) - 10}
      )

      assert ETS.prune_expired(ephemeral_table) == 1
      assert ETS.get("k_expired", ets_table: ephemeral_table) == :miss
      assert ETS.get("k_live", ets_table: ephemeral_table) == {:ok, {:ok, :alive}}
    end
  end

  describe "SystemOneDSL.Runner evaluation, SystemOneSDK.Test transport, and L1/L2 cache orchestration" do
    test "executes end-to-end through SystemOneSDK.Test transport and caches atom-keyed responses",
         %{cache_opts: cache_opts} do
      client = SystemOneSDK.Test.client()

      client =
        SystemOneSDK.Test.stub(client,
          tone: {:choice, "positive", 0.91}
        )

      state = %{text: "SystemOneSDK.Test end-to-end check"}

      assert SampleContracts.available?([client: client] ++ cache_opts)

      {:ok, resp} =
        SampleContracts.evaluate(
          :sentiment,
          state,
          [client: client] ++ cache_opts
        )

      assert resp.answers.tone.choice == :positive
      assert resp.answers.tone.probabilities.positive == 0.91
      assert {:ok, tone_ans} = SystemOneDSL.fetch_answer(resp, :tone)
      assert {:ok, ^tone_ans} = SystemOneDSL.fetch_answer(resp, "tone")
      assert SystemOneDSL.choice?(tone_ans, :positive)
      assert SystemOneDSL.choice?(tone_ans, "positive")
      assert {:ok, 0.91} = SystemOneDSL.probability(tone_ans, :positive)
      assert {:ok, 0.91} = SystemOneDSL.probability(tone_ans, "positive")

      # Second call hits L1 cache without another HTTP call
      {:ok, cached_resp} =
        SampleContracts.evaluate(
          "sentiment",
          state,
          [client: client] ++ cache_opts
        )

      assert cached_resp == resp

      SystemOneSDK.Test.verify!(client)
      assert length(SystemOneSDK.Test.requests(client)) == 1
      SystemOneSDK.Test.close(client)
    end

    test "supports cache_only: true, evaluate!/3 structured SystemOneDSL.Error exceptions, and unknown contract checks",
         %{cache_opts: cache_opts} do
      opts = [cache_only: true] ++ cache_opts

      assert SampleContracts.evaluate(:is_spam, %{text: "buy now"}, opts) ==
               {:error, :cache_miss}

      assert_raise Error, ~r/Cache miss while evaluating in cache_only mode/, fn ->
        SampleContracts.evaluate!(:is_spam, %{text: "buy now"}, opts)
      end

      assert SampleContracts.evaluate(:nonexistent_contract, %{text: "x"}, opts) ==
               {:error, {:unknown_contract, :nonexistent_contract}}

      assert_raise Error, ~r/Unknown SystemOneDSL contract :nonexistent_contract/, fn ->
        SampleContracts.evaluate!(:nonexistent_contract, %{text: "x"}, opts)
      end

      mock_fn = fn state ->
        {:ok,
         %{answers: %{spam_detected: %{noul: if(state.text =~ "spam", do: 0.95, else: 0.05)}}}}
      end

      assert {:ok, %{answers: %{spam_detected: %{noul: 0.95}}}} =
               SampleContracts.evaluate(
                 :is_spam,
                 %{text: "free spam"},
                 [eval_fn: mock_fn] ++ cache_opts
               )
    end

    test "serves Tier-2 cache hits when offline (including persist_tier2: false), warms L1, and backfills Tier-2",
         %{cache_opts: cache_opts} do
      state = %{text: "Offline regression sample"}
      cache_key = SampleContracts.cache_key(:sentiment, state)

      cached_resp =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             tone: %SystemOneSDK.ChoiceAnswer{
               choice: "positive",
               confidence: 0.95,
               probabilities: %{"positive" => 0.95, "neutral" => 0.05, "negative" => 0.0}
             }
           }
         }}

      # 1. Seed Tier-2 only (L1 is empty) and evaluate offline with persist_tier2: false (read-only L2)
      assert ETS.get(cache_key, cache_opts) == :miss
      assert :ok = TestTier2Cache.put(cache_key, cached_resp, cache_opts)

      assert SampleContracts.evaluate(
               :sentiment,
               state,
               [typesafe_api_key: "", cache_only: true, persist_tier2: false] ++ cache_opts
             ) == cached_resp

      # L1 was automatically warmed from Tier-2
      assert ETS.get(cache_key, cache_opts) == {:ok, cached_resp}

      # 2. Verify use_tier2_cache: false skips L2 when L1 misses
      state_skip = %{text: "Skip L2 sample"}
      cache_key_skip = SampleContracts.cache_key(:sentiment, state_skip)
      assert :ok = TestTier2Cache.put(cache_key_skip, cached_resp, cache_opts)

      assert SampleContracts.evaluate(
               :sentiment,
               state_skip,
               [typesafe_api_key: "", cache_only: true, use_tier2_cache: false] ++ cache_opts
             ) == {:error, :cache_miss}

      # 3. Seed L1 only for a second state and verify evaluate_many backfills Tier-2
      state_2 = %{text: "L1 backfill sample"}
      cache_key_2 = SampleContracts.cache_key(:sentiment, state_2)
      assert :ok = ETS.put(cache_key_2, cached_resp, cache_opts)
      assert TestTier2Cache.get(cache_key_2, cache_opts) == :miss

      assert SampleContracts.evaluate_many(
               :sentiment,
               [state, state_2],
               [typesafe_api_key: "", cache_only: true] ++ cache_opts
             ) == [cached_resp, cached_resp]

      assert TestTier2Cache.get(cache_key_2, cache_opts) == {:ok, cached_resp}
    end

    test "emits telemetry spans and reads module application config", %{cache_opts: cache_opts} do
      test_pid = self()
      handler_id = "jev-telemetry-test-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:system_one_dsl, :evaluate, :stop],
          [:system_one_dsl, :cache, :write],
          [:system_one_dsl, :cache, :hit]
        ],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:system_one_dsl, SampleContracts, api_key: "app-config-key")
      on_exit(fn -> Application.delete_env(:system_one_dsl, SampleContracts) end)

      assert SampleContracts.available?(cache_opts)

      client =
        SystemOneSDK.Test.client()
        |> SystemOneSDK.Test.stub(spam_detected: {:noul, 0.92})

      state = %{text: "Telemetry test payload"}

      assert {:ok, _} =
               SampleContracts.evaluate(:is_spam, state, [client: client] ++ cache_opts)

      assert_receive {:telemetry_event, [:system_one_dsl, :cache, :write], %{duration: _},
                      %{tier: :l1, contract: :is_spam}}

      assert_receive {:telemetry_event, [:system_one_dsl, :evaluate, :stop], %{duration: _},
                      %{module: SampleContracts, contract: :is_spam, status: :ok}}

      # Second call hits L1 cache
      assert {:ok, _} =
               SampleContracts.evaluate(:is_spam, state, [client: client] ++ cache_opts)

      assert_receive {:telemetry_event, [:system_one_dsl, :cache, :hit], %{duration: _},
                      %{tier: :l1, contract: :is_spam}}

      SystemOneSDK.Test.verify!(client)
      SystemOneSDK.Test.close(client)
    end
  end

  describe "Mix.Tasks.SystemOneDsl.Install Igniter task" do
    test "patches .formatter.exs with :system_one_dsl and optionally creates a contract module" do
      test_project()
      |> Igniter.compose_task("system_one_dsl.install", ["--module", "Test.TriageContracts"])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:system_one_dsl]
      """)
      |> assert_creates("lib/test/triage_contracts.ex", """
      defmodule Test.TriageContracts do
        use SystemOneDSL,
          otp_app: :test,
          cache: SystemOneDSL.Cache.ETS

        defnoul :is_actionable do
          "Does this item require follow-up action?"
        end
      end
      """)
      |> assert_has_notice("Created SystemOneDSL contract module Test.TriageContracts.")
    end

    test "is idempotent when run twice" do
      project =
        test_project()
        |> Igniter.compose_task("system_one_dsl.install", ["--module", "Test.TriageContracts"])
        |> apply_igniter!()

      project
      |> Igniter.compose_task("system_one_dsl.install", ["--module", "Test.TriageContracts"])
      |> assert_unchanged()
    end
  end

  defmodule InlineSubquestionContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl

    defcontract :inline_bundle do
      noul(:is_urgent,
        ask: "Page immediately?",
        do: (
          true -> "Outage or active breach."
          false -> "Normal ticket."
        )
      )

      noul(:is_aliased, as: :aliased_noul, do: "Aliased inline prompt?")

      choice(:priority,
        ask: "Priority level?",
        do: (
          urgent -> "Handle immediately."
          normal -> "Handle in queue."
        )
      )

      score(:clarity,
        ask: "Clarity level?",
        do: (
          vague -> "Unclear steps."
          clear -> "Clear steps."
        )
      )
    end
  end

  defmodule PartialOverrideLowerContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl

    defnoul :is_spam do
      "Is this spam?"
    end

    def evaluate(key, state) do
      evaluate(key, state, eval_fn: fn _ -> {:ok, %{from: :lower_override}} end)
    end

    def available?(opts) do
      Keyword.get(opts, :force_available, false) or available?(opts, :eval_fn)
    end
  end

  defmodule PartialOverrideUpperContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl

    defnoul :is_spam do
      "Is this spam?"
    end

    def evaluate(key, state, opts) do
      SystemOneDSL.Runner.evaluate(
        __MODULE__,
        key,
        state,
        Keyword.put_new(opts, :eval_fn, fn _ -> {:ok, %{from: :upper_override}} end)
      )
    end

    def evaluate!(key, state) do
      evaluate!(key, state, eval_fn: fn _ -> {:ok, %{from: :bang_lower}} end)
    end

    def evaluate_many(key, states) do
      evaluate_many(key, states, eval_fn: fn s -> {:ok, %{echo: s}} end)
    end
  end

  defmodule ModuleBackendKeyContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      backend: :gemini_decisions,
      decisions_mode: :unified,
      base_url: "http://localhost:4000",
      gemini_api_key: "mod-gemini-secret",
      tier2_cache: SystemOneDSLTest.TestTier2Cache

    defnoul :is_spam do
      "Is this spam?"
    end
  end

  defmodule CustomEvalKeyContracts do
    use SystemOneDSL,
      otp_app: :system_one_dsl,
      eval_fn_key: :my_eval_fn

    defnoul :is_spam do
      "Is this spam?"
    end
  end

  defmodule SpyPutManyCache do
    @behaviour SystemOneDSL.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def put(_key, _value, _opts), do: :ok

    @impl true
    def put_many(entries, opts) do
      if pid = Keyword.get(opts, :spy_pid) do
        send(pid, {:spy_put_many, entries, Keyword.get(opts, :ttl)})
      end

      :ok
    end
  end

  describe "bug audit regressions" do
    test "BUG-001: defcontract supports inline do: combined with keyword options for noul, choice, and score" do
      {:ok, contract} = InlineSubquestionContracts.contract(:inline_bundle)
      [q_urgent, q_aliased, q_priority, q_clarity] = contract.questions

      assert q_urgent.name == :is_urgent
      assert q_urgent.instructions == "Page immediately?"
      assert q_urgent.criteria == [{true, "Outage or active breach."}, {false, "Normal ticket."}]

      assert q_aliased.name == :aliased_noul
      assert q_aliased.instructions == "Aliased inline prompt?"
      assert q_aliased.criteria == %{}

      assert q_priority.name == :priority
      assert q_priority.instructions == "Priority level?"
      assert q_priority.criteria == [urgent: "Handle immediately.", normal: "Handle in queue."]

      assert q_clarity.name == :clarity
      assert q_clarity.instructions == "Clarity level?"
      assert q_clarity.criteria == [vague: "Unclear steps.", clear: "Clear steps."]

      prep = InlineSubquestionContracts.prepared(:inline_bundle)
      assert prep.definitions["priority"].option_order == [:urgent, :normal]
      assert Enum.map(prep.definitions["clarity"].levels, & &1.label) == ["vague", "clear"]
    end

    test "BUG-002: quote_runner_api preserves complementary arities on partial overrides", %{
      cache_opts: cache_opts
    } do
      eval_opts = [eval_fn: fn _ -> {:ok, %{ok: true}} end] ++ cache_opts

      assert {:ok, %{from: :lower_override}} =
               PartialOverrideLowerContracts.evaluate(:is_spam, %{text: "a"})

      assert {:ok, %{ok: true}} =
               PartialOverrideLowerContracts.evaluate(:is_spam, %{text: "a"}, eval_opts)

      refute PartialOverrideLowerContracts.available?()
      assert PartialOverrideLowerContracts.available?(force_available: true)
      assert PartialOverrideLowerContracts.available?(eval_opts, :eval_fn)

      assert {:ok, %{from: :upper_override}} =
               PartialOverrideUpperContracts.evaluate(:is_spam, %{text: "b"})

      assert %{from: :bang_lower} =
               PartialOverrideUpperContracts.evaluate!(:is_spam, %{text: "b"})

      assert %{ok: true} =
               PartialOverrideUpperContracts.evaluate!(:is_spam, %{text: "b"}, eval_opts)

      assert [{:ok, %{echo: %{text: "c"}}}] =
               PartialOverrideUpperContracts.evaluate_many(:is_spam, [%{text: "c"}])

      assert [{:ok, %{ok: true}}] =
               PartialOverrideUpperContracts.evaluate_many(:is_spam, [%{text: "c"}], eval_opts)
    end

    test "BUG-003 & BUG-014: adapter_put_many/3 enforces resolve_ttl/2 and nil TTL/confidence fallbacks",
         %{cache_opts: cache_opts} do
      high_choice =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             tone: %SystemOneSDK.ChoiceAnswer{
               choice: "positive",
               confidence: 0.9,
               probabilities: %{"positive" => 0.9}
             }
           }
         }}

      low_choice =
        {:ok,
         %SystemOneSDK.SystemOneResponse{
           model: "jev-test",
           usage: %{},
           answers: %{
             tone: %SystemOneSDK.ChoiceAnswer{
               choice: "positive",
               confidence: 0.3,
               probabilities: %{"positive" => 0.55, "neutral" => 0.45}
             }
           }
         }}

      assert Cache.resolve_ttl(high_choice, cache_ttl: nil, ttl: 120) == {:ok, 120}
      assert Cache.resolve_ttl(high_choice, cache_ttl: nil, ttl: nil) == {:ok, 604_800}
      assert Cache.cacheable?(high_choice, min_confidence: nil)
      assert :ok = ETS.put("nil_ttl_key", :ok_val, [ttl: nil, cache_ttl: nil] ++ cache_opts)
      assert {:ok, :ok_val} = ETS.get("nil_ttl_key", cache_opts)

      entries = [
        {"k_err", :sentiment, %{text: "e"}, {:error, :timeout}},
        {"k_low", :sentiment, %{text: "l"}, low_choice},
        {"k_high", :sentiment, %{text: "h"}, high_choice}
      ]

      assert :ok =
               Cache.adapter_put_many(
                 SpyPutManyCache,
                 entries,
                 spy_pid: self(),
                 cache_ttl: 7200
               )

      assert_receive {:spy_put_many, [{"k_low", :sentiment, %{text: "l"}, ^low_choice}], 300}
      assert_receive {:spy_put_many, [{"k_high", :sentiment, %{text: "h"}, ^high_choice}], 7200}

      assert :ok = Cache.adapter_put_many(ETS, entries, [cache_ttl: 7200] ++ cache_opts)
      assert ETS.get("k_err", cache_opts) == :miss
      assert ETS.get("k_low", cache_opts) == {:ok, low_choice}
      assert ETS.get("k_high", cache_opts) == {:ok, high_choice}
    end

    test "BUG-004 & BUG-012: ETS atomic expired deletion preserves newer writes and heir_loop does not leak",
         %{cache_opts: cache_opts} do
      table = Keyword.fetch!(cache_opts, :ets_table)
      expired_at = System.monotonic_time(:second) - 10
      future_at = System.monotonic_time(:second) + 600

      :ets.insert(table, {"atomic_key", :fresh_val, future_at})
      refute :ets.match_delete(table, {"atomic_key", :_, expired_at}) == false
      assert ETS.get("atomic_key", cache_opts) == {:ok, :fresh_val}

      # Ensure stale match pattern does not delete newer entry while expired entry is evicted
      :ets.insert(table, {"expired_key", :stale_val, expired_at})
      assert ETS.get("expired_key", cache_opts) == :miss
      assert :ets.lookup(table, "expired_key") == []

      race_table = :"jev_heir_race_#{System.unique_integer([:positive])}"

      1..8
      |> Task.async_stream(
        fn idx ->
          ETS.put("k_#{idx}", idx, ets_table: race_table, ttl: 60)
        end,
        max_concurrency: 8
      )
      |> Stream.run()

      heir_procs =
        Enum.filter(Process.list(), fn pid ->
          case Process.info(pid, [:current_function, :registered_name]) do
            [current_function: {ETS, :heir_loop, 0}, registered_name: _] -> true
            _ -> false
          end
        end)

      assert length(heir_procs) <= 1
    end

    test "BUG-005: CUE.export/1 quotes non-identifier labels while preserving valid identifiers" do
      q = %Question{
        name: :"question-1",
        type: :choice,
        instructions: "Pick one",
        criteria: [{"Needs Review", "Ambiguous"}, {:_internal, "Hidden"}, {:ok_opt, "Good"}]
      }

      prep = SystemOneSDK.prepare!(ok: SystemOneSDK.noul("Ok?"))
      contract = %Contract{name: :"ticket-triage", questions: [q], prepared: prep}

      cue = SystemOneDSL.CUE.export(%{"ticket-triage" => contract})
      assert cue =~ ~s("ticket-triage": {)
      assert cue =~ ~s("question-1": {)
      assert cue =~ ~s("Needs Review": "Ambiguous")
      assert cue =~ ~s("_internal": "Hidden")
      assert cue =~ ~s(ok_opt: "Good")
    end

    test "BUG-006: per-call :api_key overrides module-level backend-specific API keys" do
      driver = SystemOneDSL.ATDD.GeminiDecisionsDriver

      refute ModuleBackendKeyContracts.available?(api_key: false, use_tier2_cache: false)

      assert {:error, :no_api_key} =
               ModuleBackendKeyContracts.evaluate(
                 :is_spam,
                 %{body: "blank"},
                 api_key: false,
                 use_tier2_cache: false,
                 cache?: false
               )

      stub_pid =
        driver.start_stub(fn req ->
          assert req.headers["Authorization"] == "Bearer call-override-key"
          {200, %{"answers" => [%{"name" => "is_spam", "probability" => 0.1}]}}
        end)

      assert {:ok, resp} =
               ModuleBackendKeyContracts.evaluate(
                 :is_spam,
                 %{body: "override"},
                 api_key: "call-override-key",
                 transport: driver,
                 transport_opts: [stub_pid: stub_pid],
                 cache?: false,
                 retry: false
               )

      assert {:ok, %{noul: 0.1}} = SystemOneDSL.fetch_answer(resp, :is_spam)
      assert driver.request_count(stub_pid) == 1
    end

    test "BUG-007: tier2_cache: false disables Tier-2 cache in available? and evaluate", %{
      cache_opts: cache_opts
    } do
      refute ModuleBackendKeyContracts.available?(
               [api_key: false, tier2_cache: false] ++ cache_opts
             )

      client =
        SystemOneSDK.Test.client()
        |> SystemOneSDK.Test.stub(is_spam: {:noul, 0.85})

      assert {:ok, resp} =
               ModuleBackendKeyContracts.evaluate(
                 :is_spam,
                 %{body: "no tier2"},
                 [client: client, tier2_cache: false] ++ cache_opts
               )

      assert resp.answers.is_spam.noul == 0.85
      SystemOneSDK.Test.verify!(client)
      SystemOneSDK.Test.close(client)
    end

    test "BUG-008: cacheable?/2 checks numeric :confidence on plain-map answers without :score" do
      low_plain = {:ok, %{answers: %{tone: %{choice: :positive, confidence: 0.2}}}}
      high_plain = {:ok, %{answers: %{tone: %{choice: :positive, confidence: 0.9}}}}

      refute Cache.cacheable?(low_plain)
      assert Cache.cacheable?(high_plain)
    end

    test "BUG-011 & BUG-013: fetch_answer!/2 handles non-map answers and nil never matches empty strings" do
      assert_raise KeyError, fn ->
        SystemOneDSL.fetch_answer!(%{answers: nil}, :tone)
      end

      assert_raise KeyError, fn ->
        SystemOneDSL.fetch_answer!(%{answers: [:not_a_map]}, :tone)
      end

      refute SystemOneDSL.choice?(%{choice: nil}, "")
      refute SystemOneDSL.choice?(%{choice: ""}, nil)
      refute SystemOneDSL.choice?(%{choice: nil}, nil)
      refute SystemOneDSL.choice?(nil, "")

      assert :error = SystemOneDSL.fetch_answer(%{answers: %{"" => :x}}, nil)
      assert :error = SystemOneDSL.fetch_answer(%{answers: %{nil => :x}}, "")
      assert :error = SystemOneDSL.probability(%{probabilities: %{"" => 0.5}}, nil)
      assert :error = SystemOneDSL.probability(%{probabilities: %{nil => 0.5}}, "")
    end

    test "BUG-015: evaluate_many deduplicates identical states across live misses and L2 batch writes",
         %{cache_opts: cache_opts} do
      state_a = %{text: "dup state a"}
      state_b = %{text: "unique state b"}

      client =
        SystemOneSDK.Test.client()
        |> SystemOneSDK.Test.stub(tone: {:choice, "positive", 0.95})
        |> SystemOneSDK.Test.stub(tone: {:choice, "negative", 0.92})

      results =
        SampleContracts.evaluate_many(
          :sentiment,
          [state_a, state_b, state_a],
          [client: client, tier2_cache: SpyPutManyCache, spy_pid: self()] ++ cache_opts
        )

      assert [res_a1, res_b, res_a2] = results
      assert res_a1 == res_a2
      refute res_a1 == res_b
      assert length(SystemOneSDK.Test.requests(client)) == 2

      assert_receive {:spy_put_many, live_l2_entries, _ttl}
      assert length(live_l2_entries) == 2

      # L1 hit + L2 backfill with duplicate states also deduplicates L2 entries
      assert :ok =
               TestTier2Cache.put(
                 SampleContracts.cache_key(:sentiment, state_b),
                 res_b,
                 cache_opts
               )

      backfill_results =
        SampleContracts.evaluate_many(
          :sentiment,
          [state_a, state_a],
          [client: client, tier2_cache: SpyPutManyCache, spy_pid: self()] ++ cache_opts
        )

      assert backfill_results == [res_a1, res_a1]
      assert_receive {:spy_put_many, backfill_l2_entries, _ttl}
      assert length(backfill_l2_entries) == 1

      SystemOneSDK.Test.verify!(client)
      SystemOneSDK.Test.close(client)
    end

    test "BUG-016: available?/2 respects :eval_fn_key from module and call options", %{
      cache_opts: cache_opts
    } do
      mock = fn _ -> {:ok, %{answers: %{is_spam: %{noul: 0.1}}}} end

      refute CustomEvalKeyContracts.available?(cache_opts)
      assert CustomEvalKeyContracts.available?([my_eval_fn: mock] ++ cache_opts)

      assert {:ok, %{answers: %{is_spam: %{noul: 0.1}}}} =
               CustomEvalKeyContracts.evaluate(
                 :is_spam,
                 %{text: "hi"},
                 [my_eval_fn: mock] ++ cache_opts
               )

      assert SampleContracts.available?([eval_fn_key: :call_eval, call_eval: mock] ++ cache_opts)
    end
  end
end
