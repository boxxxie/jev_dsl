defmodule SystemOneDSL.ATDD.GeminiDecisionsDSL do
  @moduledoc false

  alias SystemOneDSL.ATDD.GeminiDecisionsDriver, as: Driver

  def given_decision_backend(contract_mod, opts \\ []) do
    {default_l1, default_l2} =
      if Keyword.has_key?(opts, :l1_table) and Keyword.has_key?(opts, :l2_table) do
        {Keyword.fetch!(opts, :l1_table), Keyword.fetch!(opts, :l2_table)}
      else
        Driver.unique_ets_tables()
      end

    l1 = Keyword.get(opts, :l1_table, default_l1)
    l2 = Keyword.get(opts, :l2_table, default_l2)
    mode = Keyword.get(opts, :decisions_mode, :unified)
    model = Keyword.get(opts, :model, "gemini-decision-1")

    auth_mode =
      Keyword.get(opts, :auth_mode, if(mode == :native, do: :x_goog_api_key, else: :bearer))

    %{
      contract_mod: contract_mod,
      mode: mode,
      auth_mode: auth_mode,
      model: model,
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

  def given_upstream_choice(ctx, question_key, choice, opts \\ []) do
    conf = Keyword.get(opts, :confidence, 0.95)
    probs = Keyword.get(opts, :probs, %{choice => conf})

    given_upstream_answers(ctx, [{:choice, question_key, choice, conf, probs}], opts)
  end

  def given_upstream_noul(ctx, question_key, prob, opts \\ []) do
    given_upstream_answers(ctx, [{:noul, question_key, prob}], opts)
  end

  def given_upstream_score(ctx, question_key, score, opts \\ []) do
    conf = Keyword.get(opts, :confidence, 0.9)
    probs = Keyword.fetch!(opts, :probs)

    given_upstream_answers(ctx, [{:score, question_key, score, conf, probs}], opts)
  end

  def given_upstream_answers(ctx, answers_spec, opts \\ []) when is_list(answers_spec) do
    given_stubbed_responder(ctx, fn req ->
      Driver.encode_upstream_answers(req, answers_spec, opts)
    end)
  end

  def given_upstream_route_answers(ctx, route_map) when is_map(route_map) do
    given_stubbed_responder(ctx, fn req ->
      decoded = Jason.decode!(req.body)

      mode =
        case req.path do
          "/v1/decisions" -> :unified
          "/gemini/v1beta/decisions" -> :native
          "/v1beta/decisions" -> :native
        end

      {answers_spec, opts} = Map.fetch!(route_map, {mode, decoded["model"]})
      Driver.encode_upstream_answers(req, answers_spec, opts)
    end)
  end

  def given_upstream_choice_by_text(ctx, question_key, classifier_fn)
      when is_function(classifier_fn, 1) do
    given_stubbed_responder(ctx, fn req ->
      decoded = Jason.decode!(req.body)
      {choice, conf, probs} = classifier_fn.(decoded["input"])
      Driver.encode_upstream_answers(req, [{:choice, question_key, choice, conf, probs}])
    end)
  end

  def given_upstream_http_error(ctx, status, body) do
    given_stubbed_responder(ctx, fn _req -> {status, body} end)
  end

  def given_upstream_malformed_response(ctx, raw_body) when is_binary(raw_body) do
    given_stubbed_responder(ctx, fn _req -> {200, raw_body} end)
  end

  def when_switching_backend_mode(ctx, mode) when mode in [:unified, :native] do
    when_switching_backend_mode(ctx, decisions_mode: mode)
  end

  def when_switching_backend_mode(ctx, opts) when is_list(opts) do
    mode = Keyword.get(opts, :decisions_mode, ctx.mode)

    auth_mode =
      Keyword.get(
        opts,
        :auth_mode,
        if(mode != ctx.mode,
          do: if(mode == :native, do: :x_goog_api_key, else: :bearer),
          else: ctx.auth_mode
        )
      )

    model = Keyword.get(opts, :model, ctx.model)
    %{ctx | mode: mode, auth_mode: auth_mode, model: model}
  end

  def when_evaluating(ctx, contract_key, state, extra_opts \\ []) do
    opts = build_eval_opts(ctx, translate_domain_eval_opts(ctx, extra_opts))
    result = ctx.contract_mod.evaluate(contract_key, state, opts)
    %{ctx | last_result: result}
  end

  def when_evaluating_many(ctx, contract_key, states, extra_opts \\ []) do
    opts = build_eval_opts(ctx, translate_domain_eval_opts(ctx, extra_opts))
    results = ctx.contract_mod.evaluate_many(contract_key, states, opts)
    %{ctx | last_batch: results}
  end

  def when_replaying_offline(ctx, contract_key, state) do
    when_evaluating(ctx, contract_key, state, cache_only: true)
  end

  defmacro then_choice_is(ctx_ast, question_key, expected_choice, min_prob \\ 0.0) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert {:ok, response} = ctx.last_result
      assert {:ok, answer} = SystemOneDSL.fetch_answer(response, unquote(question_key))
      assert SystemOneDSL.choice?(answer, unquote(expected_choice))
      assert {:ok, prob} = SystemOneDSL.probability(answer, unquote(expected_choice))
      assert prob >= unquote(min_prob)
      ctx
    end
  end

  defmacro then_noul_is(ctx_ast, question_key, min_prob) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert {:ok, response} = ctx.last_result
      assert {:ok, %{noul: prob}} = SystemOneDSL.fetch_answer(response, unquote(question_key))
      assert prob >= unquote(min_prob)
      ctx
    end
  end

  defmacro then_score_is(ctx_ast, question_key, expected_label, min_conf \\ 0.0) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert {:ok, response} = ctx.last_result
      assert {:ok, answer} = SystemOneDSL.fetch_answer(response, unquote(question_key))
      assert answer.label == to_string(unquote(expected_label))
      assert is_integer(answer.level)
      assert is_number(answer.score)
      assert answer.confidence >= unquote(min_conf)
      ctx
    end
  end

  defmacro then_batch_choices_are(ctx_ast, question_key, expected_choices) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      expected = unquote(expected_choices)
      assert is_list(ctx.last_batch)
      assert length(ctx.last_batch) == length(expected)

      Enum.zip(ctx.last_batch, expected)
      |> Enum.each(fn {res, choice} ->
        assert {:ok, response} = res
        assert {:ok, answer} = SystemOneDSL.fetch_answer(response, unquote(question_key))
        assert SystemOneDSL.choice?(answer, choice)
      end)

      ctx
    end
  end

  defmacro then_offline_miss(ctx_ast) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert {:error, :cache_miss} = ctx.last_result
      ctx
    end
  end

  defmacro then_error_is(ctx_ast, expected_type) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      expected = unquote(expected_type)

      assert {:error, err} = ctx.last_result
      assert err.__struct__ in [SystemOneDSL.Error, SystemOneSDK.Error]
      assert err.type == expected
      ctx
    end
  end

  defmacro then_noul_below(ctx_ast, question_key, max_prob) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert {:ok, response} = ctx.last_result
      assert {:ok, %{noul: prob}} = SystemOneDSL.fetch_answer(response, unquote(question_key))
      assert prob < unquote(max_prob)
      ctx
    end
  end

  defmacro then_network_calls(ctx_ast, expected_count) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      assert Driver.request_count(ctx.stub_pid) == unquote(expected_count)
      ctx
    end
  end

  defmacro then_telemetry_recorded(ctx_ast, expected_events) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      events = Driver.drain_telemetry(ctx.telemetry)
      recorded_names = Enum.map(events, &elem(&1, 0))

      Enum.each(unquote(expected_events), fn ev ->
        assert ev in recorded_names
      end)

      ctx
    end
  end

  defmacro then_last_upstream_request_had(ctx_ast, expected_attrs) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx_ast)
      summary = Driver.last_request_summary(ctx.stub_pid)

      Enum.each(unquote(expected_attrs), fn
        {:mode, mode} ->
          assert summary.mode == mode

        {:model, model} ->
          assert summary.model == model

        {:auth_token, token} ->
          assert summary.auth_token == token

        {:metadata, meta} ->
          Enum.each(meta, fn {k, v} ->
            assert summary.body[to_string(k)] == v
          end)
      end)

      ctx
    end
  end

  defp translate_domain_eval_opts(ctx, opts) do
    {metadata, opts} = Keyword.pop(opts, :request_metadata)
    {auth_override, opts} = Keyword.pop(opts, :auth_override)

    opts =
      if metadata do
        Keyword.put(opts, :extra_body, metadata)
      else
        opts
      end

    if auth_override do
      header =
        if ctx.auth_mode == :x_goog_api_key do
          %{"x-goog-api-key" => auth_override}
        else
          %{"Authorization" => "Bearer #{auth_override}"}
        end

      Keyword.put(opts, :extra_headers, header)
    else
      opts
    end
  end

  defp build_eval_opts(ctx, extra_opts) do
    [
      backend: :gemini_decisions,
      decisions_mode: ctx.mode,
      auth_mode: ctx.auth_mode,
      gemini_api_key: "test-gemini-key",
      base_url: "https://decisions.test.invalid",
      model: ctx.model,
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
