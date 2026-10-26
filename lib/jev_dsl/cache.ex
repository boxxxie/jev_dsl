defmodule JevDSL.Cache do
  @moduledoc """
  Deterministic identity hashing, confidence-aware cacheability rules, and pluggable
  two-tier (L1 fast key-value + L2 durable store) caching behaviour for `JevDSL`.

  ## Cache Key Invariance & Auto-Invalidation

  Every cache key (`"jev_<sha256>"`) is derived deterministically from:
  1. The recursively canonicalized input `state` map (`canonicalize/1`).
  2. The compile-time `%SystemOneSDK.Prepared{fingerprint: fp}` SHA-256 digest of the contract's
     instructions, question types, and criteria.

  Because `prepared.fingerprint` changes whenever a prompt or criterion is edited in `defnoul`,
  `defchoice`, `defscore`, or `defjev`, stale cached evaluations are invalidated automatically
  at compile time without manual cache flushing.

  ## Telemetry Events

  `JevDSL.Cache` emits the following `:telemetry` events:
  * `[:jev_dsl, :cache, :hit]` — Measurements: `%{duration: native_time}`. Metadata: `%{cache_key: String.t(), adapter: module(), tier: :l1 | :l2, contract: atom() | String.t() | nil}`.
  * `[:jev_dsl, :cache, :miss]` — Measurements: `%{duration: native_time}`. Metadata: `%{cache_key: String.t(), adapter: module(), tier: :l1 | :l2, contract: atom() | String.t() | nil}`.
  * `[:jev_dsl, :cache, :write]` — Measurements: `%{duration: native_time}`. Metadata: `%{cache_key: String.t(), adapter: module(), tier: :l1 | :l2, contract: atom() | String.t() | nil}`.

  ## Implementing a Custom Cache Adapter

      defmodule MyApp.JevCacheAdapter do
        @behaviour JevDSL.Cache

        @impl true
        def get(key, _opts) do
          case MyApp.Cache.get(key) do
            {:ok, value} when not is_nil(value) -> {:ok, value}
            _ -> :miss
          end
        end

        @impl true
        def put(key, value, opts) do
          ttl = Keyword.get(opts, :ttl, 604_800)
          MyApp.Cache.put(key, value, ttl: ttl)
        end
      end
  """

  @type cache_key :: String.t()
  @type batch_entry :: {cache_key(), atom() | String.t(), map(), term()}

  @callback get(key :: cache_key(), opts :: keyword()) ::
              {:ok, term()} | :miss | {:error, term()}
  @callback put(key :: cache_key(), value :: term(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback get_many(keys :: [cache_key()], opts :: keyword()) :: %{
              optional(cache_key()) => term()
            }
  @callback put_many(entries :: [batch_entry()], opts :: keyword()) :: :ok | {:error, term()}

  @optional_callbacks [get_many: 2, put_many: 2]

  @default_min_confidence 0.65
  @default_ttl 3600 * 24 * 7
  @low_confidence_ttl 300

  @doc """
  Computes a deterministic `"jev_<sha256>"` cache key from `state` and a `%SystemOneSDK.Prepared{}`
  contract (or fingerprint string / contract key with `:contract_module`).

  ## Examples

      iex> key1 = JevDSL.Cache.key(%{a: 1, b: [%{c: 2}]}, "fp_1")
      iex> key2 = JevDSL.Cache.key(%{"a" => 1, "b" => [%{"c" => 2}]}, "fp_1")
      iex> key1 == key2
      true
      iex> String.starts_with?(key1, "jev_")
      true
  """
  @spec key(term(), SystemOneSDK.Prepared.t() | String.t() | term(), keyword()) :: cache_key()
  def key(state, prepared, opts \\ []) do
    hash_identity("jev", identity(state, prepared, opts))
  end

  @doc """
  Builds the canonical identity map combining the evaluation `state` and contract `fingerprint`.
  """
  @spec identity(term(), SystemOneSDK.Prepared.t() | String.t() | term(), keyword()) :: map()
  def identity(state, prepared, opts \\ []) do
    %{
      service: :system_one,
      state: state,
      fingerprint: extract_fingerprint(prepared, opts)
    }
  end

  defp extract_fingerprint(%SystemOneSDK.Prepared{fingerprint: fp}, _opts) when is_binary(fp),
    do: fp

  defp extract_fingerprint(%SystemOneSDK.Prepared{json: json}, _opts) when is_binary(json),
    do: json

  defp extract_fingerprint(contract_key, opts)
       when is_atom(contract_key) or is_binary(contract_key) do
    mod = Keyword.get(opts, :contract_module)

    if is_atom(mod) and not is_nil(mod) and Code.ensure_loaded?(mod) and
         function_exported?(mod, :contract_fingerprint, 1) do
      case mod.contract_fingerprint(contract_key) do
        {:ok, fp} -> fp
        :error -> contract_key
      end
    else
      contract_key
    end
  end

  defp extract_fingerprint(questions, _opts) when is_list(questions) do
    case SystemOneSDK.prepare(questions) do
      {:ok, %SystemOneSDK.Prepared{fingerprint: fp}} when is_binary(fp) -> fp
      _ -> questions
    end
  end

  defp extract_fingerprint(other, _opts), do: other

  @doc """
  Recursively normalizes structs, maps, lists, and tuples into a canonical form with string keys
  for deterministic binary serialization.

  ## Examples

      iex> JevDSL.Cache.canonicalize(%{a: 1, nested: {%{b: 2}}})
      %{"a" => 1, "nested" => {:__tuple__, [%{"b" => 2}]}}
  """
  @spec canonicalize(term()) :: term()
  def canonicalize(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> canonicalize()
  def canonicalize(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), canonicalize(v)} end)
  def canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  def canonicalize(tuple) when is_tuple(tuple),
    do: {:__tuple__, tuple |> Tuple.to_list() |> canonicalize()}

  def canonicalize(val), do: val

  @doc """
  Computes a deterministic `<prefix>_<sha256>` key for any map structure.
  """
  @spec hash_identity(String.t(), map()) :: cache_key()
  def hash_identity(prefix, identity_map) when is_binary(prefix) and is_map(identity_map) do
    binary =
      identity_map
      |> canonicalize()
      |> :erlang.term_to_binary([:deterministic])

    hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    "#{prefix}_#{hash}"
  end

  @doc """
  Returns `true` if a `SystemOneSDK` response meets the minimum confidence threshold
  for long-lived caching (`:min_confidence`, default `0.65`).
  """
  @spec cacheable?(term(), keyword()) :: boolean()
  def cacheable?(result, opts \\ [])

  def cacheable?({:ok, %SystemOneSDK.SystemOneResponse{answers: answers}}, opts)
      when is_map(answers) and map_size(answers) > 0 do
    min_conf = Keyword.get(opts, :min_confidence, @default_min_confidence)
    Enum.all?(Map.values(answers), &answer_confident?(&1, min_conf))
  end

  def cacheable?({:ok, %{answers: answers}}, opts)
      when is_map(answers) and map_size(answers) > 0 do
    min_conf = Keyword.get(opts, :min_confidence, @default_min_confidence)
    Enum.all?(Map.values(answers), &answer_confident?(&1, min_conf))
  end

  def cacheable?(_, _opts), do: false

  @doc """
  Returns `true` if the evaluation result is a valid `SystemOneResponse` eligible for
  durable Tier-2 persistence.
  """
  @spec persistable?(term(), keyword()) :: boolean()
  def persistable?({:ok, %SystemOneSDK.SystemOneResponse{}}, _opts), do: true
  def persistable?(result, opts), do: cacheable?(result, opts)

  @doc """
  Determines the appropriate TTL in seconds for an evaluation result (`:ok` tuple),
  or `:skip` if the result is an error that should not be cached.
  """
  @spec resolve_ttl(term(), keyword()) :: {:ok, pos_integer()} | :skip
  def resolve_ttl(result, opts \\ []) do
    base_ttl = Keyword.get(opts, :cache_ttl, Keyword.get(opts, :ttl, @default_ttl))

    cond do
      cacheable?(result, opts) ->
        {:ok, base_ttl}

      match?({:ok, %SystemOneSDK.SystemOneResponse{}}, result) ->
        {:ok, min(base_ttl, @low_confidence_ttl)}

      true ->
        :skip
    end
  end

  defp answer_confident?(%SystemOneSDK.ChoiceAnswer{probabilities: probs}, min_conf)
       when is_map(probs) and map_size(probs) > 0 do
    Enum.max(Map.values(probs)) >= min_conf
  end

  defp answer_confident?(%SystemOneSDK.NoulAnswer{noul: noul}, min_conf)
       when is_number(noul) do
    max(noul, 1.0 - noul) >= min_conf
  end

  defp answer_confident?(%SystemOneSDK.ScoreAnswer{confidence: conf}, min_conf)
       when is_number(conf) do
    conf >= min_conf
  end

  defp answer_confident?(%SystemOneSDK.ScoreAnswer{probabilities: probs}, min_conf)
       when is_map(probs) and map_size(probs) > 0 do
    Enum.max(Map.values(probs)) >= min_conf
  end

  defp answer_confident?(%SystemOneSDK.ScoreAnswer{score: score}, _min_conf)
       when is_number(score),
       do: true

  defp answer_confident?(%{confidence: conf, score: score}, min_conf)
       when is_number(conf) and is_number(score) do
    conf >= min_conf
  end

  defp answer_confident?(%{probabilities: probs}, min_conf)
       when is_map(probs) and map_size(probs) > 0 do
    Enum.max(Map.values(probs)) >= min_conf
  end

  defp answer_confident?(%{noul: noul}, min_conf) when is_number(noul) do
    max(noul, 1.0 - noul) >= min_conf
  end

  defp answer_confident?(_, _min_conf), do: true

  @doc """
  Reads a key from the given `adapter` module implementing `JevDSL.Cache`.
  """
  @spec adapter_get(module() | nil, cache_key(), keyword()) :: {:ok, term()} | :miss
  def adapter_get(nil, _key, _opts), do: :miss

  def adapter_get(adapter, key, opts) when is_atom(adapter) do
    start_t = System.monotonic_time()

    case adapter.get(key, opts) do
      {:ok, value} ->
        emit_cache_telemetry(:hit, start_t, key, adapter, opts)
        {:ok, value}

      _ ->
        emit_cache_telemetry(:miss, start_t, key, adapter, opts)
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Batch-reads `keys` from `adapter` using `get_many/2` if exported, falling back to `adapter_get/3`.
  Returns a map of `%{cache_key => cached_value}` for all hits.
  """
  @spec adapter_get_many(module() | nil, [cache_key()], keyword()) :: %{
          optional(cache_key()) => term()
        }
  def adapter_get_many(nil, _keys, _opts), do: %{}
  def adapter_get_many(_adapter, [], _opts), do: %{}

  def adapter_get_many(adapter, keys, opts) when is_atom(adapter) and is_list(keys) do
    uniq_keys = Enum.uniq(keys)
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :get_many, 2) do
      fetch_many_via_callback(adapter, uniq_keys, opts)
    else
      fallback_get_many(adapter, uniq_keys, opts)
    end
  rescue
    _ -> %{}
  end

  defp fetch_many_via_callback(adapter, uniq_keys, opts) do
    start_t = System.monotonic_time()

    case adapter.get_many(uniq_keys, opts) do
      hits when is_map(hits) ->
        emit_batch_read_telemetry(uniq_keys, hits, start_t, adapter, opts)
        hits

      _ ->
        fallback_get_many(adapter, uniq_keys, opts)
    end
  end

  defp emit_batch_read_telemetry(keys, hits, start_t, adapter, opts) do
    Enum.each(keys, fn k ->
      event = if Map.has_key?(hits, k), do: :hit, else: :miss
      emit_cache_telemetry(event, start_t, k, adapter, opts)
    end)
  end

  defp fallback_get_many(adapter, keys, opts) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case adapter_get(adapter, key, opts) do
        {:ok, val} -> Map.put(acc, key, val)
        :miss -> acc
      end
    end)
  end

  @doc """
  Writes a key/value to the given `adapter` module if `resolve_ttl/2` approves caching.
  """
  @spec adapter_put(module() | nil, cache_key(), term(), keyword()) :: :ok
  def adapter_put(nil, _key, _value, _opts), do: :ok

  def adapter_put(adapter, key, value, opts) when is_atom(adapter) do
    case resolve_ttl(value, opts) do
      {:ok, ttl} ->
        start_t = System.monotonic_time()
        _ = adapter.put(key, value, Keyword.put(opts, :ttl, ttl))
        emit_cache_telemetry(:write, start_t, key, adapter, opts)
        :ok

      :skip ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Batch-writes `[batch_entry()]` to an adapter via `put_many/2` if exported, falling back to `put/3`.
  """
  @spec adapter_put_many(module() | nil, [batch_entry()], keyword()) :: :ok
  def adapter_put_many(nil, _entries, _opts), do: :ok
  def adapter_put_many(_adapter, [], _opts), do: :ok

  def adapter_put_many(adapter, entries, opts) when is_atom(adapter) and is_list(entries) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :put_many, 2) do
      start_t = System.monotonic_time()
      _ = adapter.put_many(entries, opts)

      Enum.each(entries, fn {key, _contract, _state, _value} ->
        emit_cache_telemetry(:write, start_t, key, adapter, opts)
      end)

      :ok
    else
      Enum.each(entries, fn {key, _contract, _state, value} ->
        adapter_put(adapter, key, value, opts)
      end)
    end
  rescue
    _ -> :ok
  end

  defp emit_cache_telemetry(event, start_t, key, adapter, opts) do
    duration = System.monotonic_time() - start_t

    :telemetry.execute(
      [:jev_dsl, :cache, event],
      %{duration: duration},
      %{
        cache_key: key,
        adapter: adapter,
        tier: Keyword.get(opts, :telemetry_tier, :l1),
        contract: Keyword.get(opts, :telemetry_contract)
      }
    )
  end
end
