defmodule JevDSL.Runner do
  @moduledoc """
  Runtime evaluation, batch execution, two-tier (L1 + L2) cache orchestration,
  and deterministic test stubbing for `JevDSL` contract modules.

  Every module that invokes `use JevDSL` automatically receives `evaluate/3`,
  `evaluate!/3`, `evaluate_many/3`, `available?/2`, and `cache_key/2` delegated
  to `JevDSL.Runner`.

  ## Telemetry Events

  `JevDSL.Runner` emits `:telemetry.span/3` events:
  * `[:jev_dsl, :evaluate, :start | :stop | :exception]` — Metadata: `%{module: module(), contract: atom() | String.t(), status: :ok | :error}`.
  * `[:jev_dsl, :evaluate_many, :start | :stop | :exception]` — Metadata: `%{module: module(), contract: atom() | String.t(), count: non_neg_integer()}`.
  """

  alias JevDSL.{Cache, Error}

  @client_sdk_options [
    :base_url,
    :model,
    :timeout,
    :timeout_ms,
    :retry,
    :headers,
    :provider,
    :provider_opts,
    :response_contract,
    :max_request_bytes,
    :runtime_requirements,
    :transport,
    :transport_opts
  ]

  @eval_sdk_options [
    :model,
    :timeout,
    :timeout_ms,
    :retry,
    :extra_body,
    :extra_headers,
    :probability_tolerance,
    :telemetry_metadata,
    :cancellation,
    :response_contract,
    :max_request_bytes
  ]

  @batch_sdk_options [
    :max_concurrency,
    :max_pending,
    :task_timeout_ms,
    :attempt_timeout_ms
  ]

  @doc """
  Returns `true` if the contract module can execute evaluations — either via an injected
  1-arity test function (`:eval_fn` or `:eval_fn_key`), an explicit `%SystemOneSDK.Client{}` (`:client`),
  a configured `TYPESAFE_API_KEY`, or an enabled Tier-2 cache (`:tier2_cache`).
  """
  @spec available?(module(), keyword(), atom()) :: boolean()
  def available?(contract_mod, opts \\ [], eval_fn_key \\ :eval_fn) do
    merged = merge_module_opts(contract_mod, opts)

    cond do
      is_function(Keyword.get(merged, eval_fn_key), 1) -> true
      is_function(Keyword.get(merged, :eval_fn), 1) -> true
      is_function(Keyword.get(merged, :jev_eval_fn), 1) -> true
      has_client?(merged) -> true
      has_api_key?(merged) -> true
      Keyword.get(merged, :use_tier2_cache, true) and has_tier2_cache?(merged) -> true
      true -> false
    end
  end

  @doc """
  Evaluates a single `state` map against `contract_key` defined in `contract_mod`.

  ## Options

    * `:cache?` - Enables L1/L2 caching (default: `true`).
    * `:cache` - L1 cache module implementing `JevDSL.Cache` (default: module's configured `:cache` or `JevDSL.Cache.ETS`).
    * `:tier2_cache` - Optional L2 durable cache module implementing `JevDSL.Cache`.
    * `:use_tier2_cache` - Allows serving L2 cache hits even when `TYPESAFE_API_KEY` is unset (default: `true`).
    * `:persist_tier2` - Persists new live evaluations and backfills L1 hits into L2 (default: `true`).
    * `:cache_only` - When `true`, resolves only from L1/L2 caches without making live network calls, returning `{:error, :cache_miss}` on misses.
    * `:eval_fn` - A 1-arity mock function `fn state -> {:ok, resp} end` for deterministic unit testing.
    * `:eval_fn_key` - Custom option key holding a 1-arity mock function (default: `:eval_fn`).
    * `:eval_fn_state` - Custom state map passed to the mock `eval_fn` when test assertions inspect extra fields.
    * `:client` - Pre-configured `%SystemOneSDK.Client{}` (including `SystemOneSDK.Test.client()`).
    * `:typesafe_api_key` / `:api_key` - Explicit API key override.
    * `:base_url` / `:model` / `:timeout` / `:timeout_ms` / `:retry` - Forwarded to `SystemOneSDK`.
  """
  @spec evaluate(module(), atom() | String.t(), map(), keyword()) ::
          {:ok, SystemOneSDK.SystemOneResponse.t() | map()} | {:error, term()}
  def evaluate(contract_mod, contract_key, state, opts \\ []) when is_map(state) do
    meta = %{module: contract_mod, contract: contract_key}

    :telemetry.span([:jev_dsl, :evaluate], meta, fn ->
      result = do_evaluate(contract_mod, contract_key, state, opts)
      status = if match?({:ok, _}, result), do: :ok, else: :error
      {result, Map.put(meta, :status, status)}
    end)
  end

  @doc """
  Evaluates a single `state` map against `contract_key` or raises `JevDSL.Error` / `SystemOneSDK.Error`.
  """
  @spec evaluate!(module(), atom() | String.t(), map(), keyword()) ::
          SystemOneSDK.SystemOneResponse.t() | map()
  def evaluate!(contract_mod, contract_key, state, opts \\ []) when is_map(state) do
    case evaluate(contract_mod, contract_key, state, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise Error.from_reason(reason, contract_key)
    end
  end

  defp do_evaluate(contract_mod, contract_key, state, opts) do
    if valid_contract?(contract_mod, contract_key) do
      merged = merge_module_opts(contract_mod, opts)
      eval_fn = resolve_eval_fn(merged)

      cond do
        is_function(eval_fn, 1) ->
          eval_state = Keyword.get(merged, :eval_fn_state, state)
          eval_fn.(eval_state)

        can_run_or_tier2?(merged) ->
          result = dispatch_single(contract_mod, contract_key, state, merged)
          maybe_transform_keys(result, opts)

        true ->
          {:error, :no_api_key}
      end
    else
      {:error, {:unknown_contract, contract_key}}
    end
  rescue
    err -> {:error, err}
  end

  @doc """
  Evaluates a list of `states` concurrently against `contract_key` using `SystemOneSDK.evaluate_many/4`.
  Resolves L1 and L2 cache hits first and only dispatches uncached misses over the network,
  returning results in the exact order of `states`.
  """
  @spec evaluate_many(module(), atom() | String.t(), [map()], keyword()) ::
          [{:ok, SystemOneSDK.SystemOneResponse.t() | map()} | {:error, term()}]
  def evaluate_many(contract_mod, contract_key, states, opts \\ [])
  def evaluate_many(_contract_mod, _contract_key, [], _opts), do: []

  def evaluate_many(contract_mod, contract_key, states, opts) when is_list(states) do
    meta = %{module: contract_mod, contract: contract_key, count: length(states)}

    :telemetry.span([:jev_dsl, :evaluate_many], meta, fn ->
      results = do_evaluate_many(contract_mod, contract_key, states, opts)
      {results, meta}
    end)
  end

  defp do_evaluate_many(contract_mod, contract_key, states, opts) do
    if valid_contract?(contract_mod, contract_key) do
      merged = merge_module_opts(contract_mod, opts)

      contract_mod
      |> run_evaluate_many(contract_key, states, merged)
      |> Enum.map(&maybe_transform_keys(&1, opts))
    else
      Enum.map(states, fn _ -> {:error, {:unknown_contract, contract_key}} end)
    end
  rescue
    err -> Enum.map(states, fn _ -> {:error, err} end)
  end

  defp run_evaluate_many(contract_mod, contract_key, states, merged) do
    eval_fn = resolve_eval_fn(merged)

    cond do
      is_function(eval_fn, 1) ->
        Enum.map(states, eval_fn)

      can_run_or_tier2?(merged) ->
        dispatch_many(contract_mod, contract_key, states, merged)

      true ->
        Enum.map(states, fn _ -> {:error, :no_api_key} end)
    end
  end

  @doc """
  Resolves the trimmed `TYPESAFE_API_KEY` from `opts`, application config, or environment.
  """
  @spec api_key(keyword()) :: String.t()
  def api_key(opts \\ []) do
    otp_app = Keyword.get(opts, :otp_app)

    raw =
      Keyword.get(opts, :typesafe_api_key) ||
        Keyword.get(opts, :api_key) ||
        (otp_app && Application.get_env(otp_app, :typesafe_api_key)) ||
        Application.get_env(:system_one_sdk, :api_key) ||
        Application.get_env(:typesafe_api_sdk, :api_key) ||
        System.get_env("TYPESAFE_API_KEY") ||
        ""

    String.trim(to_string(raw))
  end

  @doc """
  Returns `true` if a non-empty `TYPESAFE_API_KEY` is available.
  """
  @spec has_api_key?(keyword()) :: boolean()
  def has_api_key?(opts \\ []), do: api_key(opts) != ""

  defp valid_contract?(contract_mod, contract_key) do
    Code.ensure_loaded(contract_mod)

    if function_exported?(contract_mod, :has_contract?, 1) do
      contract_mod.has_contract?(contract_key)
    else
      true
    end
  end

  defp resolve_eval_fn(opts) do
    eval_fn_key = Keyword.get(opts, :eval_fn_key, :eval_fn)

    Keyword.get(opts, eval_fn_key) || Keyword.get(opts, :eval_fn) ||
      Keyword.get(opts, :jev_eval_fn)
  end

  defp merge_module_opts(contract_mod, opts) do
    Code.ensure_loaded(contract_mod)

    base_opts =
      if function_exported?(contract_mod, :__jev_dsl_opts__, 0) do
        contract_mod.__jev_dsl_opts__()
      else
        []
      end

    otp_app = Keyword.get(opts, :otp_app) || Keyword.get(base_opts, :otp_app)

    app_mod_opts =
      case otp_app && Application.get_env(otp_app, contract_mod) do
        kw when is_list(kw) -> kw
        _ -> []
      end

    base_opts
    |> Keyword.merge(app_mod_opts)
    |> Keyword.merge(opts)
  end

  defp can_run_or_tier2?(opts) do
    use_tier2? = Keyword.get(opts, :use_tier2_cache, true)
    cache_only? = Keyword.get(opts, :cache_only, false)

    has_client?(opts) or has_api_key?(opts) or cache_only? or
      (use_tier2? and has_tier2_cache?(opts))
  end

  defp has_client?(opts) do
    match?(%SystemOneSDK.Client{}, Keyword.get(opts, :client))
  end

  defp has_tier2_cache?(opts) do
    case Keyword.get(opts, :tier2_cache) do
      nil -> false
      mod when is_atom(mod) -> true
    end
  end

  defp build_optional_client(opts) do
    cache_only? = Keyword.get(opts, :cache_only, false)

    case Keyword.get(opts, :client) do
      %SystemOneSDK.Client{} = client when not cache_only? ->
        client

      _ ->
        if not cache_only? and has_api_key?(opts) do
          client_opts =
            opts
            |> Keyword.take(@client_sdk_options)
            |> Keyword.put(:api_key, api_key(opts))

          SystemOneSDK.new_client(client_opts)
        else
          nil
        end
    end
  end

  defp dispatch_single(contract_mod, contract_key, state, opts) do
    prep = contract_mod.prepared(contract_key)
    client = build_optional_client(opts)

    if Keyword.get(opts, :cache?, true) do
      evaluate_single_cached(contract_key, client, state, prep, opts)
    else
      evaluate_single_uncached(client, state, prep, opts)
    end
  end

  defp evaluate_single_uncached(nil, _state, _prep, opts), do: missing_client_error(opts)

  defp evaluate_single_uncached(client, state, prep, opts) do
    sdk_opts = Keyword.take(opts, @eval_sdk_options)
    SystemOneSDK.evaluate(client, state, prep, sdk_opts)
  end

  defp missing_client_error(opts) do
    if Keyword.get(opts, :cache_only, false) do
      {:error, :cache_miss}
    else
      {:error, :no_api_key}
    end
  end

  defp evaluate_single_cached(contract_key, client, state, prep, opts) do
    hash_key = Cache.key(state, prep)
    ctx = build_cache_ctx(contract_key, opts)

    case Cache.adapter_get(ctx.l1, hash_key, ctx.l1_opts) do
      {:ok, l1_result} ->
        maybe_backfill_l2(ctx, hash_key, state, l1_result)
        l1_result

      :miss ->
        resolve_l1_miss(ctx, hash_key, client, state, prep)
    end
  end

  defp build_cache_ctx(contract_key, opts) do
    l1 = Keyword.get(opts, :cache, JevDSL.Cache.ETS)
    l2 = Keyword.get(opts, :tier2_cache)

    %{
      contract_key: contract_key,
      l1: l1,
      l2: l2,
      use_l2?: Keyword.get(opts, :use_tier2_cache, true) and not is_nil(l2),
      persist_l2?: Keyword.get(opts, :persist_tier2, true) and not is_nil(l2),
      opts: opts,
      l1_opts:
        opts
        |> Keyword.put(:telemetry_tier, :l1)
        |> Keyword.put(:telemetry_contract, contract_key),
      l2_opts:
        opts
        |> Keyword.put(:telemetry_tier, :l2)
        |> Keyword.put(:telemetry_contract, contract_key)
    }
  end

  defp maybe_backfill_l2(%{persist_l2?: false}, _hk, _st, _res), do: :ok

  defp maybe_backfill_l2(ctx, hash_key, state, result) do
    if Cache.persistable?(result, ctx.opts) and
         Cache.adapter_get(ctx.l2, hash_key, ctx.l2_opts) == :miss do
      Cache.adapter_put_many(ctx.l2, [{hash_key, ctx.contract_key, state, result}], ctx.l2_opts)
    end
  end

  defp resolve_l1_miss(ctx, hash_key, client, state, prep) do
    case ctx.use_l2? && Cache.adapter_get(ctx.l2, hash_key, ctx.l2_opts) do
      {:ok, l2_result} ->
        Cache.adapter_put(ctx.l1, hash_key, l2_result, ctx.l1_opts)
        l2_result

      _ ->
        evaluate_live_and_persist(ctx, hash_key, client, state, prep)
    end
  end

  defp evaluate_live_and_persist(ctx, _hk, nil, _st, _prep), do: missing_client_error(ctx.opts)

  defp evaluate_live_and_persist(ctx, hash_key, client, state, prep) do
    result = evaluate_single_uncached(client, state, prep, ctx.opts)
    Cache.adapter_put(ctx.l1, hash_key, result, ctx.l1_opts)

    if ctx.persist_l2? and Cache.persistable?(result, ctx.opts) do
      Cache.adapter_put_many(ctx.l2, [{hash_key, ctx.contract_key, state, result}], ctx.l2_opts)
    end

    result
  end

  defp dispatch_many(contract_mod, contract_key, states, opts) do
    prep = contract_mod.prepared(contract_key)
    client = build_optional_client(opts)

    cond do
      Keyword.get(opts, :cache?, true) ->
        evaluate_many_cached(contract_key, client, states, prep, opts)

      not is_nil(client) ->
        SystemOneSDK.evaluate_many(client, states, prep, build_batch_sdk_opts(opts))

      true ->
        err = missing_client_error(opts)
        Enum.map(states, fn _ -> err end)
    end
  end

  defp build_batch_sdk_opts(opts) do
    eval_opts =
      if Keyword.has_key?(opts, :attempt_timeout_ms) do
        Keyword.take(opts, @eval_sdk_options -- [:timeout, :timeout_ms])
      else
        Keyword.take(opts, @eval_sdk_options)
      end

    batch_opts = Keyword.take(opts, @batch_sdk_options)

    eval_opts
    |> Keyword.merge(batch_opts)
    |> Keyword.put_new(:max_concurrency, 10)
    |> Keyword.put(:ordered, true)
    |> Keyword.put(:on_error, :collect)
  end

  defp evaluate_many_cached(contract_key, client, states, prep, opts) do
    ctx = build_cache_ctx(contract_key, opts)

    indexed_states =
      states
      |> Enum.with_index()
      |> Enum.map(fn {st, idx} -> {idx, st, Cache.key(st, prep)} end)

    {cached_map, misses, l1_backfills} = partition_many_cache(indexed_states, ctx)

    if ctx.persist_l2? and l1_backfills != [] do
      Cache.adapter_put_many(ctx.l2, l1_backfills, ctx.l2_opts)
    end

    final_map = resolve_many_misses(misses, cached_map, client, prep, ctx)
    Enum.map(0..(length(states) - 1), fn idx -> Map.fetch!(final_map, idx) end)
  end

  defp partition_many_cache(indexed_states, ctx) do
    all_keys = Enum.map(indexed_states, &elem(&1, 2))
    l1_hits = Cache.adapter_get_many(ctx.l1, all_keys, ctx.l1_opts)
    {existing_l2_for_l1, l2_hits} = preload_l2_maps(indexed_states, l1_hits, ctx)

    {cached_map, rev_misses, rev_bf} =
      Enum.reduce(indexed_states, {%{}, [], []}, fn item, acc ->
        classify_many_item(item, acc, l1_hits, existing_l2_for_l1, l2_hits, ctx)
      end)

    {cached_map, Enum.reverse(rev_misses), Enum.reverse(rev_bf)}
  end

  defp preload_l2_maps(indexed_states, l1_hits, ctx) do
    l1_hit_keys = Map.keys(l1_hits)

    existing_l2 =
      if ctx.persist_l2? and l1_hit_keys != [] do
        Cache.adapter_get_many(ctx.l2, l1_hit_keys, ctx.l2_opts)
      else
        %{}
      end

    l1_miss_keys =
      indexed_states
      |> Enum.reject(fn {_idx, _st, hk} -> Map.has_key?(l1_hits, hk) end)
      |> Enum.map(&elem(&1, 2))

    l2_hits =
      if ctx.use_l2? and l1_miss_keys != [] do
        Cache.adapter_get_many(ctx.l2, l1_miss_keys, ctx.l2_opts)
      else
        %{}
      end

    {existing_l2, l2_hits}
  end

  defp classify_many_item(
         {idx, st, hk},
         {acc_map, acc_misses, acc_bf},
         l1_hits,
         existing_l2,
         l2_hits,
         ctx
       ) do
    cond do
      Map.has_key?(l1_hits, hk) ->
        l1_res = Map.fetch!(l1_hits, hk)
        bf = maybe_prepend_backfill(acc_bf, hk, st, l1_res, existing_l2, ctx)
        {Map.put(acc_map, idx, l1_res), acc_misses, bf}

      Map.has_key?(l2_hits, hk) ->
        l2_res = Map.fetch!(l2_hits, hk)
        Cache.adapter_put(ctx.l1, hk, l2_res, ctx.l1_opts)
        {Map.put(acc_map, idx, l2_res), acc_misses, acc_bf}

      true ->
        {acc_map, [{idx, st, hk} | acc_misses], acc_bf}
    end
  end

  defp maybe_prepend_backfill(acc_bf, hk, st, l1_res, existing_l2, ctx) do
    if ctx.persist_l2? and Cache.persistable?(l1_res, ctx.opts) and
         not Map.has_key?(existing_l2, hk) do
      [{hk, ctx.contract_key, st, l1_res} | acc_bf]
    else
      acc_bf
    end
  end

  defp resolve_many_misses([], cached_map, _client, _prep, _ctx), do: cached_map

  defp resolve_many_misses(misses, cached_map, nil, _prep, ctx) do
    err = missing_client_error(ctx.opts)

    Enum.reduce(misses, cached_map, fn {idx, _st, _hk}, acc ->
      Map.put(acc, idx, err)
    end)
  end

  defp resolve_many_misses(misses, cached_map, client, prep, ctx) do
    miss_states = Enum.map(misses, fn {_idx, st, _hk} -> st end)

    live_results =
      SystemOneSDK.evaluate_many(client, miss_states, prep, build_batch_sdk_opts(ctx.opts))

    {updated_map, to_persist} =
      Enum.zip(misses, live_results)
      |> Enum.reduce({cached_map, []}, fn {{idx, st, hash_key}, res}, {acc, persist_acc} ->
        Cache.adapter_put(ctx.l1, hash_key, res, ctx.l1_opts)

        if ctx.persist_l2? and Cache.persistable?(res, ctx.opts) do
          {Map.put(acc, idx, res), [{hash_key, ctx.contract_key, st, res} | persist_acc]}
        else
          {Map.put(acc, idx, res), persist_acc}
        end
      end)

    if ctx.persist_l2? and to_persist != [] do
      Cache.adapter_put_many(ctx.l2, Enum.reverse(to_persist), ctx.l2_opts)
    end

    updated_map
  end

  defp maybe_transform_keys({:ok, %SystemOneSDK.SystemOneResponse{} = resp} = ok_tuple, opts) do
    case Keyword.get(opts, :keys) do
      :atoms -> {:ok, transform_response_keys(resp, :atoms)}
      :strings -> {:ok, transform_response_keys(resp, :strings)}
      _ -> ok_tuple
    end
  end

  defp maybe_transform_keys(other, _opts), do: other

  defp transform_response_keys(%SystemOneSDK.SystemOneResponse{answers: answers} = resp, mode) do
    updated_answers =
      Map.new(answers, fn {k, ans} ->
        {k, transform_answer_keys(ans, mode)}
      end)

    %{resp | answers: updated_answers}
  end

  defp transform_answer_keys(%SystemOneSDK.ChoiceAnswer{} = ans, mode) do
    %{
      ans
      | choice: convert_key(ans.choice, mode),
        probabilities: Map.new(ans.probabilities, fn {k, v} -> {convert_key(k, mode), v} end),
        option_order: Enum.map(ans.option_order, &convert_key(&1, mode))
    }
  end

  defp transform_answer_keys(%SystemOneSDK.ScoreAnswer{} = ans, mode) do
    %{
      ans
      | label: if(ans.label, do: convert_key(ans.label, mode), else: nil),
        levels: Enum.map(ans.levels, fn {lbl, p} -> {convert_key(lbl, mode), p} end)
    }
  end

  defp transform_answer_keys(other, _mode), do: other

  defp convert_key(key, :strings) when is_atom(key), do: Atom.to_string(key)
  defp convert_key(key, :strings) when is_binary(key), do: key
  defp convert_key(key, :atoms) when is_atom(key), do: key

  defp convert_key(key, :atoms) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
