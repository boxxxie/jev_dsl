defmodule JevDSLTest do
  use ExUnit.Case, async: false

  alias JevDSL.{Cache, Contract, Question}
  alias JevDSL.Cache.ETS

  defmodule TestTier2Cache do
    @behaviour JevDSL.Cache

    @table :jev_dsl_test_tier2_ets

    @impl true
    def get(key, opts) do
      ETS.get(key, Keyword.put(opts, :ets_table, @table))
    end

    @impl true
    def put(key, value, opts) do
      ETS.put(key, value, Keyword.put(opts, :ets_table, @table))
    end

    @impl true
    def put_many(entries, opts) do
      ETS.put_many(entries, Keyword.put(opts, :ets_table, @table))
    end

    def clear, do: ETS.clear(@table)
  end

  defmodule SampleContracts do
    use JevDSL,
      cache: JevDSL.Cache.ETS,
      tier2_cache: JevDSLTest.TestTier2Cache

    defnoul :is_spam, as: :spam_detected do
      """
      Does this message contain unsolicited promotional spam?
      """
    end

    defchoice :sentiment,
      as: :tone,
      ask: "Classify the overall tone of the message." do
      positive -> "Constructive, appreciative, or favorable tone."
      neutral -> "Factual or informational without strong emotion."
      negative -> "Critical, frustrated, or dissatisfied tone."
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
  end

  setup do
    ETS.clear()
    TestTier2Cache.clear()
    :ok
  end

  describe "JevDSL compile-time contract compilation" do
    test "compiles defnoul, defchoice, defscore, defjev, and defalias into typed %JevDSL.Contract{} structs" do
      contracts = SampleContracts.__contracts__()
      assert map_size(contracts) == 5

      for key <- [:is_spam, :sentiment, :completeness, :ticket_triage, :legacy_triage] do
        assert SampleContracts.has_contract?(key)
        assert SampleContracts.has_contract?(Atom.to_string(key))
        assert {:ok, fp} = SampleContracts.contract_fingerprint(key)
        assert {:ok, ^fp} = SampleContracts.contract_fingerprint(Atom.to_string(key))
        assert %Contract{questions: [%Question{} | _], prepared: prep} = contracts[key]
        assert %SystemOneSDK.Prepared{fingerprint: ^fp} = prep
        assert SampleContracts.prepared(key) == prep
        assert SampleContracts.prepared(Atom.to_string(key)) == prep
      end

      assert SampleContracts.prepared(:legacy_triage) == SampleContracts.prepared(:ticket_triage)
      refute SampleContracts.has_contract?(:nonexistent)
      assert SampleContracts.contract_fingerprint(:nonexistent) == :error
    end

    test "exports noul, choice, and score contracts to CUE schema via __export_cue__/0" do
      cue = SampleContracts.__export_cue__()
      assert is_binary(cue)
      assert cue =~ "is_spam: {"
      assert cue =~ "sentiment: {"
      assert cue =~ "completeness: {"
      assert cue =~ "ticket_triage: {"
      assert cue =~ ~s(type: "score")
    end
  end

  describe "JevDSL.Cache deterministic hashing & confidence TTL gating" do
    test "produces identical SHA-256 cache keys regardless of atom vs string map keys" do
      key_atoms = SampleContracts.cache_key(:sentiment, %{text: "Hello", author: %{name: "Ada"}})

      key_strings =
        SampleContracts.cache_key(:sentiment, %{"text" => "Hello", "author" => %{"name" => "Ada"}})

      assert key_atoms == key_strings
      assert String.starts_with?(key_atoms, "jev_")

      diff_contract_key =
        SampleContracts.cache_key(:is_spam, %{text: "Hello", author: %{name: "Ada"}})

      assert key_atoms != diff_contract_key
    end

    test "distinguishes high-confidence vs low-confidence responses for TTL resolution" do
      high_conf =
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

      low_conf =
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

      assert Cache.cacheable?(high_conf)
      refute Cache.cacheable?(low_conf)
      assert Cache.resolve_ttl(high_conf, ttl: 86_400) == {:ok, 86_400}
      assert Cache.resolve_ttl(low_conf, ttl: 86_400) == {:ok, 300}
      assert Cache.resolve_ttl({:error, :timeout}) == :skip
    end
  end

  describe "JevDSL.Runner evaluation, mocking, and L1/L2 cache orchestration" do
    test "supports cache_only: true and custom eval_fn mock injection" do
      assert SampleContracts.evaluate(:is_spam, %{text: "buy now"}, cache_only: true) ==
               {:error, :cache_miss}

      assert SampleContracts.evaluate_many(:is_spam, [%{text: "a"}, %{text: "b"}],
               cache_only: true
             ) ==
               [{:error, :cache_miss}, {:error, :cache_miss}]

      mock_fn = fn state ->
        {:ok,
         %{answers: %{spam_detected: %{noul: if(state.text =~ "spam", do: 0.95, else: 0.05)}}}}
      end

      assert SampleContracts.available?(eval_fn: mock_fn)

      assert {:ok, %{answers: %{spam_detected: %{noul: 0.95}}}} =
               SampleContracts.evaluate(:is_spam, %{text: "free spam"}, eval_fn: mock_fn)
    end

    test "serves Tier-2 cache hits when offline, warms L1 ETS cache, and backfills Tier-2 from L1" do
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
               probabilities: %{"positive" => 0.95, "neutral" => 0.05}
             }
           }
         }}

      # 1. Seed Tier-2 only (L1 is empty) and evaluate offline without an API key
      assert ETS.get(cache_key) == :miss
      assert :ok = TestTier2Cache.put(cache_key, cached_resp, [])

      assert SampleContracts.evaluate(:sentiment, state,
               typesafe_api_key: "",
               cache_only: true
             ) == cached_resp

      # L1 was automatically warmed from Tier-2
      assert ETS.get(cache_key) == {:ok, cached_resp}

      # 2. Seed L1 only for a second state, clear Tier-2, and verify evaluate_many backfills Tier-2
      state_2 = %{text: "L1 backfill sample"}
      cache_key_2 = SampleContracts.cache_key(:sentiment, state_2)
      assert :ok = ETS.put(cache_key_2, cached_resp)
      assert TestTier2Cache.get(cache_key_2, []) == :miss

      assert SampleContracts.evaluate_many(:sentiment, [state, state_2],
               typesafe_api_key: "",
               cache_only: true
             ) == [cached_resp, cached_resp]

      assert TestTier2Cache.get(cache_key_2, []) == {:ok, cached_resp}
    end
  end
end
