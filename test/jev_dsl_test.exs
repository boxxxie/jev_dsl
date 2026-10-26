defmodule JevDSLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Igniter.Test

  alias JevDSL.{Cache, Contract, Error, Question}
  alias JevDSL.Cache.ETS

  doctest JevDSL
  doctest JevDSL.Cache
  doctest JevDSL.CUE

  defmodule TestTier2Cache do
    @behaviour JevDSL.Cache

    @default_table :jev_dsl_test_tier2_ets

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
    use JevDSL,
      otp_app: :jev_dsl,
      cache: JevDSL.Cache.ETS,
      tier2_cache: JevDSLTest.TestTier2Cache

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

  describe "JevDSL compile-time contract compilation & atom/string interoperability" do
    test "compiles defnoul, defchoice, defscore, defjev, and defalias into typed %JevDSL.Contract{} structs" do
      contracts = SampleContracts.__contracts__()
      assert map_size(contracts) == 8

      for key <- [
            :is_spam,
            :is_urgent_noul,
            :sentiment,
            :csv_column_mapping,
            :completeness,
            :ticket_triage,
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

    test "preserves stab-clause declaration order in defchoice" do
      prep = SampleContracts.prepared(:sentiment)
      tone_def = prep.definitions["tone"]
      assert tone_def.option_order == ["positive", "neutral", "negative"]

      csv_prep = SampleContracts.prepared("csv_column_mapping")
      csv_def = csv_prep.definitions["mapped_field"]
      assert csv_def.option_order == ["given_name", "Needs Review", "UNMAPPED"]
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
      assert_raise CompileError, ~r/Duplicate JevDSL contract :dup/, fn ->
        Code.compile_string("""
        defmodule JevDSLTest.DupContracts do
          use JevDSL
          defnoul :dup do "First" end
          defnoul :dup do "Second" end
        end
        """)
      end

      assert_raise CompileError, ~r/requires 2\.\.255 entries/, fn ->
        Code.compile_string("""
        defmodule JevDSLTest.SingleChoiceContract do
          use JevDSL
          defchoice :bad_choice, ask: "Pick one" do
            only_one -> "Not enough options"
          end
        end
        """)
      end

      assert_raise CompileError, ~r/references unknown contract :missing_target/, fn ->
        Code.compile_string("""
        defmodule JevDSLTest.BadAliasContract do
          use JevDSL
          defnoul :valid do "Valid?" end
          defalias :broken, :missing_target
        end
        """)
      end

      assert_raise CompileError, ~r/conflicts with an existing contract/, fn ->
        Code.compile_string("""
        defmodule JevDSLTest.ConflictingAliasContract do
          use JevDSL
          defnoul :existing do "Valid?" end
          defalias :existing, :existing
        end
        """)
      end
    end
  end

  describe "JevDSL.Cache deterministic hashing, property invariants & ETS resilience" do
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

  describe "JevDSL.Runner evaluation, SystemOneSDK.Test transport, and L1/L2 cache orchestration" do
    test "executes end-to-end through SystemOneSDK.Test transport with both string and atom key modes",
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

      assert {:ok, tone_ans} = JevDSL.fetch_answer(resp, :tone)
      assert {:ok, ^tone_ans} = JevDSL.fetch_answer(resp, "tone")
      assert JevDSL.choice?(tone_ans, :positive)
      assert JevDSL.choice?(tone_ans, "positive")
      assert {:ok, 0.91} = JevDSL.probability(tone_ans, :positive)
      assert {:ok, 0.91} = JevDSL.probability(tone_ans, "positive")

      # Second call with `keys: :atoms` hits L1 cache and transforms keys to atoms without another HTTP call
      {:ok, atom_resp} =
        SampleContracts.evaluate(
          "sentiment",
          state,
          [client: client, keys: :atoms] ++ cache_opts
        )

      assert atom_resp.answers.tone.choice == :positive
      assert atom_resp.answers.tone.probabilities.positive == 0.91

      SystemOneSDK.Test.verify!(client)
      assert length(SystemOneSDK.Test.requests(client)) == 1
      SystemOneSDK.Test.close(client)
    end

    test "supports cache_only: true, evaluate!/3 structured JevDSL.Error exceptions, and unknown contract checks",
         %{cache_opts: cache_opts} do
      opts = [cache_only: true] ++ cache_opts

      assert SampleContracts.evaluate(:is_spam, %{text: "buy now"}, opts) ==
               {:error, :cache_miss}

      assert_raise Error, ~r/Cache miss while evaluating in cache_only mode/, fn ->
        SampleContracts.evaluate!(:is_spam, %{text: "buy now"}, opts)
      end

      assert SampleContracts.evaluate(:nonexistent_contract, %{text: "x"}, opts) ==
               {:error, {:unknown_contract, :nonexistent_contract}}

      assert_raise Error, ~r/Unknown JevDSL contract :nonexistent_contract/, fn ->
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
          [:jev_dsl, :evaluate, :stop],
          [:jev_dsl, :cache, :write],
          [:jev_dsl, :cache, :hit]
        ],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:jev_dsl, SampleContracts, api_key: "app-config-key")
      on_exit(fn -> Application.delete_env(:jev_dsl, SampleContracts) end)

      assert SampleContracts.available?(cache_opts)

      client =
        SystemOneSDK.Test.client()
        |> SystemOneSDK.Test.stub(spam_detected: {:noul, 0.92})

      state = %{text: "Telemetry test payload"}

      assert {:ok, _} =
               SampleContracts.evaluate(:is_spam, state, [client: client] ++ cache_opts)

      assert_receive {:telemetry_event, [:jev_dsl, :cache, :write], %{duration: _},
                      %{tier: :l1, contract: :is_spam}}

      assert_receive {:telemetry_event, [:jev_dsl, :evaluate, :stop], %{duration: _},
                      %{module: SampleContracts, contract: :is_spam, status: :ok}}

      # Second call hits L1 cache
      assert {:ok, _} =
               SampleContracts.evaluate(:is_spam, state, [client: client] ++ cache_opts)

      assert_receive {:telemetry_event, [:jev_dsl, :cache, :hit], %{duration: _},
                      %{tier: :l1, contract: :is_spam}}

      SystemOneSDK.Test.verify!(client)
      SystemOneSDK.Test.close(client)
    end
  end

  describe "Mix.Tasks.JevDsl.Install Igniter task" do
    test "patches .formatter.exs with :jev_dsl and optionally creates a contract module" do
      test_project()
      |> Igniter.compose_task("jev_dsl.install", ["--module", "Test.TriageContracts"])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:jev_dsl]
      """)
      |> assert_creates("lib/test/triage_contracts.ex", """
      defmodule Test.TriageContracts do
        use JevDSL,
          otp_app: :test,
          cache: JevDSL.Cache.ETS

        defnoul :is_actionable do
          "Does this item require follow-up action?"
        end
      end
      """)
      |> assert_has_notice("Created JevDSL contract module Test.TriageContracts.")
    end

    test "is idempotent when run twice" do
      project =
        test_project()
        |> Igniter.compose_task("jev_dsl.install", ["--module", "Test.TriageContracts"])
        |> apply_igniter!()

      project
      |> Igniter.compose_task("jev_dsl.install", ["--module", "Test.TriageContracts"])
      |> assert_unchanged()
    end
  end
end
