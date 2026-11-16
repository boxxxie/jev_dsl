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
  alias SystemOneSDK.Providers.GeminiDecisions

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
  Computes the deterministic SHA-256 cache key (`"jev_<sha256>"`) for `contract_key` and `state`,
  merging module-level, `otp_app` runtime, and per-call options.
  """
  @spec cache_key(module(), atom() | String.t(), term(), keyword()) :: String.t()
  def cache_key(contract_mod, contract_key, state, opts \\ []) do
    merged = merge_module_opts!(contract_mod, opts)
    Cache.key(state, contract_mod.prepared(contract_key), merged)
  end

  @doc """
  Returns `true` if the contract module can execute evaluations — either via an injected
  1-arity test function (`:eval_fn` or `:eval_fn_key`), an explicit `%SystemOneSDK.Client{}` (`:client`),
  a configured `TYPESAFE_API_KEY`, or an enabled Tier-2 cache (`:tier2_cache`).
  """
  @spec available?(module(), keyword(), atom()) :: boolean()
  def available?(contract_mod, opts \\ [], eval_fn_key \\ :eval_fn) do
    case merge_module_opts(contract_mod, opts) do
      {:ok, merged} -> merged_available?(merged, eval_fn_key)
      {:error, _} -> false
    end
  end

  defp merged_available?(merged, eval_fn_key) do
    has_eval_fn?(merged, eval_fn_key) or
      has_client?(merged) or
      can_build_provider_client?(merged) or
      (Keyword.get(merged, :use_tier2_cache, true) and has_tier2_cache?(merged))
  end

  defp has_eval_fn?(merged, eval_fn_key) do
    Enum.any?([eval_fn_key, :eval_fn, :jev_eval_fn], fn key ->
      is_function(Keyword.get(merged, key), 1)
    end)
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
      case merge_module_opts(contract_mod, opts) do
        {:ok, merged} ->
          run_single_evaluate(contract_mod, contract_key, state, merged)

        {:error, _} = err ->
          err
      end
    else
      {:error, {:unknown_contract, contract_key}}
    end
  rescue
    err in [Error, SystemOneSDK.Error] ->
      {:error, err}

    err ->
      {:error,
       %Error{
         type: :evaluation_failed,
         contract: contract_key,
         message: Exception.message(err),
         details: err
       }}
  end

  defp run_single_evaluate(contract_mod, contract_key, state, merged) do
    eval_fn = resolve_eval_fn(merged)

    cond do
      is_function(eval_fn, 1) ->
        eval_state = Keyword.get(merged, :eval_fn_state, state)
        eval_fn.(eval_state)

      can_run_or_tier2?(merged) ->
        dispatch_single(contract_mod, contract_key, state, merged)

      true ->
        {:error, :no_api_key}
    end
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
    with true <- valid_contract?(contract_mod, contract_key),
         {:ok, merged} <- merge_module_opts(contract_mod, opts) do
      run_evaluate_many(contract_mod, contract_key, states, merged)
    else
      false ->
        Enum.map(states, fn _ -> {:error, {:unknown_contract, contract_key}} end)

      {:error, _} = err ->
        Enum.map(states, fn _ -> err end)
    end
  rescue
    err in [Error, SystemOneSDK.Error] ->
      Enum.map(states, fn _ -> {:error, err} end)

    err ->
      wrapped = %Error{
        type: :evaluation_failed,
        contract: contract_key,
        message: Exception.message(err),
        details: err
      }

      Enum.map(states, fn _ -> {:error, wrapped} end)
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
  Resolves the trimmed API key from `opts`, application config, or environment.
  """
  @spec api_key(keyword()) :: String.t()
  def api_key(opts \\ []) do
    otp_app = Keyword.get(opts, :otp_app)

    raw =
      case Keyword.get(opts, :backend, :system_one) do
        :gemini_decisions ->
          gemini_api_key(opts, otp_app)

        backend when backend in [:system_one, nil] ->
          system_one_api_key(opts, otp_app)

        other ->
          raise Error.invalid_options(
                  "Invalid :backend #{inspect(other)}. Expected :system_one or :gemini_decisions.",
                  %{backend: other}
                )
      end

    resolve_secret(raw) || ""
  end

  @doc false
  def resolve_secret(atom) when is_atom(atom), do: nil
  def resolve_secret(str) when is_binary(str), do: String.trim(str)

  def resolve_secret({:system, env_var}) when is_binary(env_var) do
    resolve_secret(System.get_env(env_var))
  end

  def resolve_secret({:system, env_var, default}) when is_binary(env_var) do
    non_blank_secret(System.get_env(env_var)) || resolve_secret(default)
  end

  def resolve_secret(fun) when is_function(fun, 0), do: resolve_secret(fun.())

  def resolve_secret({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, args) |> resolve_secret()
  end

  def resolve_secret(other) do
    if String.Chars.impl_for(other) do
      other |> to_string() |> String.trim()
    else
      ""
    end
  end

  defp gemini_api_key(opts, otp_app) do
    decisions_mode =
      case Keyword.get(opts, :decisions_mode) do
        nil ->
          :unified

        mode when mode in [:unified, :native] ->
          mode

        other ->
          raise Error.invalid_options(
                  "Invalid :decisions_mode #{inspect(other)}. Expected :unified or :native.",
                  %{decisions_mode: other}
                )
      end

    base_url =
      resolve_gemini_base_url(
        Keyword.put_new(opts, :otp_app, otp_app),
        decisions_mode
      )

    env_fallbacks =
      if decisions_mode == :native and (is_nil(base_url) or google_decisions_host?(base_url)) do
        [
          fn -> System.get_env("GEMINI_API_KEY") end,
          fn -> System.get_env("LITELLM_API_KEY") end,
          fn -> System.get_env("LITELLM_MASTER_KEY") end
        ]
      else
        [
          fn -> System.get_env("LITELLM_API_KEY") end,
          fn -> System.get_env("LITELLM_MASTER_KEY") end,
          fn -> System.get_env("GEMINI_API_KEY") end
        ]
      end

    resolve_key_candidates(
      opts,
      [:gemini_api_key, :api_key],
      [
        fn -> otp_app && Application.get_env(otp_app, :gemini_api_key) end,
        fn -> otp_app && Application.get_env(otp_app, :api_key) end,
        fn -> Application.get_env(:jev_dsl, :gemini_api_key) end,
        fn -> Application.get_env(:jev_dsl, :api_key) end
      ] ++ env_fallbacks
    )
  end

  defp google_decisions_host?(base_url) do
    case URI.parse(to_string(base_url)).host do
      host when is_binary(host) ->
        String.downcase(host) == "generativelanguage.googleapis.com"

      _ ->
        false
    end
  end

  defp system_one_api_key(opts, otp_app) do
    resolve_key_candidates(
      opts,
      [:typesafe_api_key, :api_key],
      [
        fn -> otp_app && Application.get_env(otp_app, :typesafe_api_key) end,
        fn -> Application.get_env(:system_one_sdk, :api_key) end,
        fn -> Application.get_env(:typesafe_api_sdk, :api_key) end,
        fn -> System.get_env("TYPESAFE_API_KEY") end
      ]
    )
  end

  defp resolve_key_candidates(opts, opt_keys, fallback_funs) do
    opt_val = Enum.find_value(opt_keys, &non_blank_secret(Keyword.get(opts, &1)))

    cond do
      is_binary(opt_val) ->
        opt_val

      explicit_blank_opt?(opts, opt_keys) ->
        ""

      true ->
        Enum.find_value(fallback_funs, fn fun -> non_blank_secret(fun.()) end)
    end
  end

  @doc false
  def resolve_override_secret(opts, keys, fallback_raw) do
    opt_val = Enum.find_value(keys, &non_blank_secret(Keyword.get(opts, &1)))

    cond do
      is_binary(opt_val) -> opt_val
      explicit_blank_opt?(opts, keys) -> nil
      true -> resolve_secret(fallback_raw)
    end
  end

  defp explicit_blank_opt?(opts, keys) do
    Enum.any?(keys, fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, false} -> true
        {:ok, bin} when is_binary(bin) -> String.trim(bin) == ""
        _ -> false
      end
    end)
  end

  defp non_blank_secret(raw) do
    case resolve_secret(raw) do
      val when is_binary(val) and val != "" -> val
      _ -> nil
    end
  end

  @doc """
  Returns `true` if a non-empty API key is available.
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

  defp merge_module_opts!(contract_mod, opts) do
    case merge_module_opts(contract_mod, opts) do
      {:ok, merged} -> merged
      {:error, %Error{} = err} -> raise err
    end
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

    module_opts = Keyword.merge(base_opts, app_mod_opts)
    raw_merged = Keyword.merge(module_opts, opts)

    with :ok <- validate_runtime_opts(raw_merged) do
      {:ok, sync_client_opts(raw_merged, module_opts, opts)}
    end
  end

  defp validate_runtime_opts(opts) do
    with :ok <- validate_backend_opt(opts) do
      case GeminiDecisions.validate_provider_opts(opts) do
        :ok ->
          :ok

        {:error, %SystemOneSDK.Error{message: msg, details: details}} ->
          {:error, Error.invalid_options(msg, details)}
      end
    end
  end

  defp validate_backend_opt(opts) do
    case Keyword.get(opts, :backend) do
      val when val in [nil, :system_one, :gemini_decisions] ->
        :ok

      other ->
        {:error,
         Error.invalid_options(
           "Invalid :backend #{inspect(other)}. Expected :system_one or :gemini_decisions.",
           %{backend: other}
         )}
    end
  end

  defp sync_client_opts(merged, module_opts, opts) do
    case Keyword.get(merged, :client) do
      %SystemOneSDK.Client{
        provider: GeminiDecisions,
        provider_client: %GeminiDecisions.Client{} = pclient
      } = client ->
        sync_gemini_client_opts(merged, module_opts, opts, client, pclient)

      %SystemOneSDK.Client{} ->
        Keyword.put(merged, :backend, :system_one)

      _ ->
        merged
    end
  end

  defp sync_gemini_client_opts(
         merged,
         module_opts,
         opts,
         %SystemOneSDK.Client{} = client,
         %GeminiDecisions.Client{} = pclient
       ) do
    call_opts =
      opts
      |> Keyword.put_new(:otp_app, Keyword.get(merged, :otp_app))
      |> maybe_inherit_module_opt(:decisions_mode, module_opts, pclient, :decisions_mode)
      |> maybe_inherit_module_opt(:auth_mode, module_opts, pclient, :auth_mode)
      |> maybe_inherit_module_opt(:decisions_path, module_opts, pclient, :decisions_path)
      |> maybe_inherit_module_opt(:base_url, module_opts, pclient, :base_url)
      |> maybe_inherit_module_model(module_opts, client, pclient)
      |> maybe_inherit_module_api_key(module_opts, client, pclient)

    updated_pclient = GeminiDecisions.apply_call_opts(pclient, call_opts)

    updated_client = %SystemOneSDK.Client{
      client
      | provider_client: updated_pclient,
        default_model: updated_pclient.default_model,
        api_key: updated_pclient.api_key,
        base_url: updated_pclient.base_url,
        context: updated_pclient.context,
        pristine_client: updated_pclient.pristine_client
    }

    merged
    |> Keyword.drop([:gemini_api_key, :api_key, :decisions_path, :base_url])
    |> Keyword.put(:backend, :gemini_decisions)
    |> Keyword.put(:decisions_mode, updated_pclient.decisions_mode)
    |> Keyword.put(:auth_mode, updated_pclient.auth_mode)
    |> Keyword.put(:model, updated_pclient.default_model)
    |> maybe_put_kw(:decisions_path, updated_pclient.decisions_path)
    |> maybe_put_kw(:base_url, updated_pclient.base_url)
    |> maybe_put_kw(:api_key, updated_pclient.api_key)
    |> Keyword.put(:client, updated_client)
  end

  defp maybe_inherit_module_opt(call_opts, opt_key, module_opts, pclient, client_field) do
    cond do
      Keyword.get(call_opts, opt_key) != nil ->
        call_opts

      GeminiDecisions.explicit_field?(pclient, client_field) ->
        call_opts

      (mod_val = Keyword.get(module_opts, opt_key)) != nil ->
        Keyword.put(call_opts, opt_key, mod_val)

      true ->
        call_opts
    end
  end

  defp maybe_inherit_module_model(
         call_opts,
         module_opts,
         %SystemOneSDK.Client{} = client,
         pclient
       ) do
    cond do
      Keyword.get(call_opts, :model) != nil ->
        call_opts

      GeminiDecisions.explicit_field?(pclient, :default_model) ->
        maybe_put_kw(call_opts, :model, client.default_model || pclient.default_model)

      (mod_model = Keyword.get(module_opts, :model)) != nil ->
        Keyword.put(call_opts, :model, mod_model)

      true ->
        maybe_put_kw(call_opts, :model, client.default_model || pclient.default_model)
    end
  end

  defp maybe_inherit_module_api_key(
         call_opts,
         module_opts,
         %SystemOneSDK.Client{} = client,
         pclient
       ) do
    call_has_key? =
      Enum.any?(
        [:api_key, :gemini_api_key],
        &(non_blank_secret(Keyword.get(call_opts, &1)) != nil)
      ) or
        explicit_blank_opt?(call_opts, [:api_key, :gemini_api_key])

    client_has_key? =
      GeminiDecisions.explicit_field?(pclient, :api_key) or
        non_blank_secret(client.api_key) != nil

    cond do
      call_has_key? or client_has_key? ->
        call_opts

      (mod_gemini = Keyword.get(module_opts, :gemini_api_key)) != nil ->
        Keyword.put(call_opts, :gemini_api_key, mod_gemini)

      (mod_api = Keyword.get(module_opts, :api_key)) != nil ->
        Keyword.put(call_opts, :api_key, mod_api)

      true ->
        call_opts
    end
  end

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)

  defp can_run_or_tier2?(opts) do
    use_tier2? = Keyword.get(opts, :use_tier2_cache, true)
    cache_only? = Keyword.get(opts, :cache_only, false)

    has_client?(opts) or has_auth_for_provider?(opts) or cache_only? or
      (use_tier2? and has_tier2_cache?(opts))
  end

  defp can_build_provider_client?(opts) do
    has_auth_for_provider?(opts) and has_provider_base_url?(opts)
  end

  defp has_auth_for_provider?(opts) do
    has_api_key?(opts) or keyless_gemini_decisions?(opts)
  end

  defp has_provider_base_url?(opts) do
    case Keyword.get(opts, :backend, :system_one) do
      :gemini_decisions ->
        decisions_mode = Keyword.get(opts, :decisions_mode) || :unified
        base_url = resolve_gemini_base_url(opts, decisions_mode)
        is_binary(base_url) and String.trim(base_url) != ""

      backend when backend in [:system_one, nil] ->
        true

      _ ->
        false
    end
  end

  defp keyless_gemini_decisions?(opts) do
    Keyword.get(opts, :backend) == :gemini_decisions and
      (Keyword.get(opts, :auth_mode) == :none or
         has_non_empty_headers?(Keyword.get(opts, :extra_headers)) or
         has_non_empty_headers?(Keyword.get(opts, :headers)))
  end

  defp has_non_empty_headers?(headers) when is_map(headers), do: map_size(headers) > 0
  defp has_non_empty_headers?(headers) when is_list(headers), do: headers != []
  defp has_non_empty_headers?(_), do: false

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
        {:ok, client}

      _ ->
        if not cache_only? and has_auth_for_provider?(opts) do
          build_provider_client(opts)
        else
          {:ok, nil}
        end
    end
  end

  defp build_provider_client(opts) do
    with :ok <- validate_runtime_opts(opts) do
      case Keyword.get(opts, :backend, :system_one) do
        :gemini_decisions -> build_gemini_provider_client(opts)
        backend when backend in [:system_one, nil] -> build_system_one_provider_client(opts)
      end
    end
  end

  defp build_gemini_provider_client(opts) do
    decisions_mode = Keyword.get(opts, :decisions_mode) || :unified
    base_url = resolve_gemini_base_url(opts, decisions_mode)

    if is_binary(base_url) and String.trim(base_url) != "" do
      provider_opts =
        opts
        |> Keyword.take(
          @client_sdk_options ++ [:decisions_mode, :auth_mode, :decisions_path, :otp_app]
        )
        |> Keyword.put(:base_url, base_url)
        |> Keyword.put(:api_key, api_key(opts))

      {:ok,
       SystemOneSDK.new_client(
         provider: GeminiDecisions,
         provider_opts: provider_opts
       )}
    else
      {:error,
       %Error{
         type: :invalid_request,
         message:
           "Missing :base_url for :gemini_decisions in #{inspect(decisions_mode)} mode. " <>
             "Pass :base_url, configure :litellm_base_url/:base_url, or set LITELLM_BASE_URL.",
         details: %{decisions_mode: decisions_mode}
       }}
    end
  end

  defp build_system_one_provider_client(opts) do
    client_opts =
      opts
      |> Keyword.take(@client_sdk_options)
      |> Keyword.put(:api_key, api_key(opts))

    {:ok, SystemOneSDK.new_client(client_opts)}
  end

  defp resolve_gemini_base_url(opts, decisions_mode) do
    explicit = resolve_secret(Keyword.get(opts, :base_url))

    if is_binary(explicit) and String.trim(explicit) != "" do
      explicit
    else
      otp_app_base_url(Keyword.get(opts, :otp_app), decisions_mode) ||
        jev_app_base_url(decisions_mode) ||
        GeminiDecisions.resolve_base_url(opts, decisions_mode)
    end
  end

  defp otp_app_base_url(nil, _mode), do: nil

  defp otp_app_base_url(otp_app, :native) do
    non_blank_secret(Application.get_env(otp_app, :gemini_decisions_base_url)) ||
      non_blank_secret(Application.get_env(otp_app, :base_url))
  end

  defp otp_app_base_url(otp_app, :unified) do
    non_blank_secret(Application.get_env(otp_app, :litellm_base_url)) ||
      non_blank_secret(Application.get_env(otp_app, :base_url))
  end

  defp otp_app_base_url(_otp_app, _mode), do: nil

  defp jev_app_base_url(:native) do
    non_blank_secret(Application.get_env(:jev_dsl, :gemini_decisions_base_url)) ||
      non_blank_secret(Application.get_env(:jev_dsl, :base_url))
  end

  defp jev_app_base_url(:unified) do
    non_blank_secret(Application.get_env(:jev_dsl, :litellm_base_url)) ||
      non_blank_secret(Application.get_env(:jev_dsl, :base_url))
  end

  defp jev_app_base_url(_), do: nil

  defp dispatch_single(contract_mod, contract_key, state, opts) do
    prep = contract_mod.prepared(contract_key)

    if Keyword.get(opts, :cache?, true) do
      evaluate_single_cached(contract_key, state, prep, opts)
    else
      case build_optional_client(opts) do
        {:ok, client} -> evaluate_single_uncached(client, state, prep, opts)
        {:error, _} = err -> err
      end
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

  defp evaluate_single_cached(contract_key, state, prep, opts) do
    hash_key = Cache.key(state, prep, opts)
    ctx = build_cache_ctx(contract_key, opts)

    case Cache.adapter_get(ctx.l1, hash_key, ctx.l1_opts) do
      {:ok, l1_result} ->
        maybe_backfill_l2(ctx, hash_key, state, l1_result)
        l1_result

      :miss ->
        resolve_l1_miss(ctx, hash_key, state, prep)
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

  defp resolve_l1_miss(ctx, hash_key, state, prep) do
    case ctx.use_l2? && Cache.adapter_get(ctx.l2, hash_key, ctx.l2_opts) do
      {:ok, l2_result} ->
        Cache.adapter_put(ctx.l1, hash_key, l2_result, ctx.l1_opts)
        l2_result

      _ ->
        evaluate_live_and_persist(ctx, hash_key, state, prep)
    end
  end

  defp evaluate_live_and_persist(ctx, hash_key, state, prep) do
    case build_optional_client(ctx.opts) do
      {:ok, nil} ->
        missing_client_error(ctx.opts)

      {:ok, client} ->
        result = evaluate_single_uncached(client, state, prep, ctx.opts)
        Cache.adapter_put(ctx.l1, hash_key, result, ctx.l1_opts)

        if ctx.persist_l2? and Cache.persistable?(result, ctx.opts) do
          Cache.adapter_put_many(
            ctx.l2,
            [{hash_key, ctx.contract_key, state, result}],
            ctx.l2_opts
          )
        end

        result

      {:error, _} = err ->
        err
    end
  end

  defp dispatch_many(contract_mod, contract_key, states, opts) do
    prep = contract_mod.prepared(contract_key)

    if Keyword.get(opts, :cache?, true) do
      evaluate_many_cached(contract_key, states, prep, opts)
    else
      dispatch_many_uncached(states, prep, opts)
    end
  end

  defp dispatch_many_uncached(states, prep, opts) do
    case build_optional_client(opts) do
      {:ok, client} when not is_nil(client) ->
        SystemOneSDK.evaluate_many(client, states, prep, build_batch_sdk_opts(opts))

      {:ok, nil} ->
        err = missing_client_error(opts)
        Enum.map(states, fn _ -> err end)

      {:error, _} = err ->
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

  defp evaluate_many_cached(contract_key, states, prep, opts) do
    ctx = build_cache_ctx(contract_key, opts)

    indexed_states =
      states
      |> Enum.with_index()
      |> Enum.map(fn {st, idx} -> {idx, st, Cache.key(st, prep, opts)} end)

    {cached_map, misses, l1_backfills} = partition_many_cache(indexed_states, ctx)

    if ctx.persist_l2? and l1_backfills != [] do
      Cache.adapter_put_many(ctx.l2, l1_backfills, ctx.l2_opts)
    end

    final_map = resolve_many_misses(misses, cached_map, prep, ctx)
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

  defp resolve_many_misses([], cached_map, _prep, _ctx), do: cached_map

  defp resolve_many_misses(misses, cached_map, prep, ctx) do
    case build_optional_client(ctx.opts) do
      {:ok, nil} ->
        fill_many_error(misses, cached_map, missing_client_error(ctx.opts))

      {:ok, client} ->
        execute_many_misses(misses, cached_map, client, prep, ctx)

      {:error, _} = err ->
        fill_many_error(misses, cached_map, err)
    end
  end

  defp fill_many_error(misses, cached_map, err) do
    Enum.reduce(misses, cached_map, fn {idx, _st, _hk}, acc ->
      Map.put(acc, idx, err)
    end)
  end

  defp execute_many_misses(misses, cached_map, client, prep, ctx) do
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
end
