defmodule JevDSL.Cache.ETS do
  @moduledoc """
  Built-in zero-dependency ETS cache adapter implementing `JevDSL.Cache`.

  Provides concurrent read/write access with monotonic TTL expiration so `JevDSL`
  works out of the box in any Elixir application without external cache dependencies.
  """

  @behaviour JevDSL.Cache

  @default_table :jev_dsl_ets_cache
  @default_ttl 3600 * 24 * 7

  @impl true
  def get(key, opts \\ []) when is_binary(key) do
    table = Keyword.get(opts, :ets_table, @default_table)
    ensure_table(table)
    now = System.monotonic_time(:second)

    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expired}] ->
        :ets.delete(table, key)
        :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @impl true
  def put(key, value, opts \\ []) when is_binary(key) do
    table = Keyword.get(opts, :ets_table, @default_table)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    ensure_table(table)
    expires_at = System.monotonic_time(:second) + max(ttl, 1)
    :ets.insert(table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> {:error, :ets_unavailable}
  end

  @impl true
  def get_many(keys, opts \\ []) when is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case get(key, opts) do
        {:ok, val} -> Map.put(acc, key, val)
        _ -> acc
      end
    end)
  end

  @impl true
  def put_many(entries, opts \\ []) when is_list(entries) do
    table = Keyword.get(opts, :ets_table, @default_table)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    ensure_table(table)
    expires_at = System.monotonic_time(:second) + max(ttl, 1)

    rows =
      Enum.map(entries, fn {key, _contract_key, _state, value} ->
        {key, value, expires_at}
      end)

    :ets.insert(table, rows)
    :ok
  rescue
    ArgumentError -> {:error, :ets_unavailable}
  end

  @doc """
  Clears all cached entries in the ETS cache table.
  """
  @spec clear(atom()) :: :ok
  def clear(table \\ @default_table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      try do
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
