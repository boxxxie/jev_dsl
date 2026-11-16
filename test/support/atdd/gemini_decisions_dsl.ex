defmodule SystemOneDSL.ATDD.GeminiDecisionsDSL do
  @moduledoc false

  import ExUnit.Assertions

  alias SystemOneDSL.ATDD.GeminiDecisionsDriver, as: Driver

  def given_decision_backend(contract_mod, opts \\ []) do
    {l1, l2} = Driver.unique_ets_tables()
    mode = Keyword.get(opts, :decisions_mode, :unified)

    auth_mode =
      Keyword.get(opts, :auth_mode, if(mode == :native, do: :x_goog_api_key, else: :bearer))

    %{
      contract_mod: contract_mod,
      mode: mode,
      auth_mode: auth_mode,
      l1_table: l1,
      l2_table: l2,
      stub_pid: nil,
      last_result: nil,
      last_batch: nil,
      telemetry: Driver.attach_telemetry()
    }
  end

  def given_stubbed_responder(ctx, responder) when is_function(responder, 1) do
    pid = Driver.start_stub(responder)
    %{ctx | stub_pid: pid}
  end

  def when_evaluating(ctx, contract_key, state, extra_opts \\ []) do
    opts = build_eval_opts(ctx, extra_opts)
    result = ctx.contract_mod.evaluate(contract_key, state, opts)
    %{ctx | last_result: result}
  end

  def when_evaluating_many(ctx, contract_key, states, extra_opts \\ []) do
    opts = build_eval_opts(ctx, extra_opts)
    results = ctx.contract_mod.evaluate_many(contract_key, states, opts)
    %{ctx | last_batch: results}
  end

  def when_replaying_offline(ctx, contract_key, state) do
    when_evaluating(ctx, contract_key, state, cache_only: true)
  end

  def then_choice_is(ctx, question_key, expected_choice, min_prob \\ 0.0) do
    assert {:ok, response} = ctx.last_result
    assert {:ok, answer} = SystemOneDSL.fetch_answer(response, question_key)
    assert SystemOneDSL.choice?(answer, expected_choice)
    assert {:ok, prob} = SystemOneDSL.probability(answer, expected_choice)
    assert prob >= min_prob
    ctx
  end

  def then_noul_is(ctx, question_key, min_prob) do
    assert {:ok, response} = ctx.last_result
    assert {:ok, %{noul: prob}} = SystemOneDSL.fetch_answer(response, question_key)
    assert prob >= min_prob
    ctx
  end

  def then_batch_choices_are(ctx, question_key, expected_choices) do
    assert is_list(ctx.last_batch)
    assert length(ctx.last_batch) == length(expected_choices)

    Enum.zip(ctx.last_batch, expected_choices)
    |> Enum.each(fn {res, expected} ->
      assert {:ok, response} = res
      assert {:ok, answer} = SystemOneDSL.fetch_answer(response, question_key)
      assert SystemOneDSL.choice?(answer, expected)
    end)

    ctx
  end

  def then_offline_miss(ctx) do
    assert {:error, :cache_miss} = ctx.last_result
    ctx
  end

  def then_network_calls(ctx, expected_count) do
    assert Driver.request_count(ctx.stub_pid) == expected_count
    ctx
  end

  def then_telemetry_recorded(ctx, expected_events) do
    events = Driver.drain_telemetry(ctx.telemetry)
    recorded_names = Enum.map(events, &elem(&1, 0))

    Enum.each(expected_events, fn ev ->
      assert ev in recorded_names
    end)

    ctx
  end

  defp build_eval_opts(ctx, extra_opts) do
    [
      backend: :gemini_decisions,
      decisions_mode: ctx.mode,
      auth_mode: ctx.auth_mode,
      gemini_api_key: "test-gemini-key",
      base_url: "https://decisions.test.invalid",
      model: "gemini-decision-1",
      transport: Driver,
      transport_opts: [stub_pid: ctx.stub_pid],
      ets_table: ctx.l1_table,
      tier2_cache: Driver.Tier2ETS,
      tier2_table: ctx.l2_table,
      retry: false
    ]
    |> Keyword.merge(extra_opts)
  end
end
