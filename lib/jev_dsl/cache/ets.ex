defmodule JevDSL.Cache.ETS do
  @moduledoc """
  Built-in zero-dependency ETS cache adapter implementing `JevDSL.Cache`.

  Provides concurrent read/write access with monotonic TTL expiration so `JevDSL`
  works out of the box in any Elixir application without external cache dependencies.

  ## Supervision & ETS Table Ownership

  `JevDSL.Cache.ETS` can be used in two modes:

  1. **Supervised Mode (Recommended for Production & `async: true` Tests):**
     Add `{JevDSL.Cache.ETS, name: MyApp.JevCache, table: :my_app_jev_cache}` to your
     application's supervision tree (or `start_supervised!/1` in tests). The GenServer
     owns the ETS table and periodically prunes expired keys.

  2. **Zero-Config On-Demand Mode:**
     If `get/2` or `put/3` is called before a server is started, `ensure_table/1`
     creates the named ETS table and attaches a lightweight heir receiver so the table
     survives even if the first caller was a short-lived `Task` or request process.
  """

  use GenServer
  @behaviour JevDSL.Cache

  @default_table :jev_dsl_ets_cache
  @default_ttl 3600 * 24 * 7
  @default_cleanup_interval :timer.minutes(5)
  @heir_name :jev_dsl_ets_heir

  @start_schema NimbleOptions.new!(
                  name: [
                    type: {:or, [:atom, {:tuple, [:atom, :atom, :any]}]},
                    default: __MODULE__,
                    doc: "Process registration name for the ETS owner server."
                  ],
                  table: [
                    type: :atom,
                    default: @default_table,
                    doc: "Named ETS table atom."
                  ],
                  cleanup_interval: [
                    type: {:or, [:pos_integer, {:in, [:infinity]}]},
                    default: @default_cleanup_interval,
                    doc: "Interval in milliseconds between automatic expired-entry sweeps."
                  ]
                )

  @doc """
  Returns a child specification with `:id` scoped to `:name` or `:table` so multiple
  `JevDSL.Cache.ETS` instances can be supervised in the same tree or test.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    id = opts[:name] || opts[:table] || __MODULE__

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts an ETS cache owner process linked to the caller's supervision tree.

  ## Options

  #{NimbleOptions.docs(@start_schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    validated = NimbleOptions.validate!(opts, @start_schema)
    GenServer.start_link(__MODULE__, validated, name: validated[:name])
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    interval = Keyword.fetch!(opts, :cleanup_interval)
    create_owned_table(table)
    schedule_cleanup(interval)
    {:ok, %{table: table, cleanup_interval: interval}}
  end

  @impl GenServer
  def handle_info(:prune_expired, %{table: table, cleanup_interval: interval} = state) do
    prune_expired(table)
    schedule_cleanup(interval)
    {:noreply, state}
  end

  def handle_info({:"ETS-TRANSFER", _table, _from_pid, _heir_data}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_cleanup(:infinity), do: :ok

  defp schedule_cleanup(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :prune_expired, interval)
    :ok
  end

  @impl JevDSL.Cache
  def get(key, opts \\ []) when is_binary(key) do
    table = resolve_table(opts)
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

  @impl JevDSL.Cache
  def put(key, value, opts \\ []) when is_binary(key) do
    table = resolve_table(opts)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    ensure_table(table)
    expires_at = System.monotonic_time(:second) + max(ttl, 1)
    :ets.insert(table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> {:error, :ets_unavailable}
  end

  @impl JevDSL.Cache
  def get_many(keys, opts \\ []) when is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case get(key, opts) do
        {:ok, val} -> Map.put(acc, key, val)
        _ -> acc
      end
    end)
  end

  @impl JevDSL.Cache
  def put_many(entries, opts \\ []) when is_list(entries) do
    table = resolve_table(opts)
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
  Deletes all expired entries from `table` and returns the number of evicted keys.
  """
  @spec prune_expired(atom()) :: non_neg_integer()
  def prune_expired(table \\ @default_table) when is_atom(table) do
    if :ets.whereis(table) != :undefined do
      now = System.monotonic_time(:second)
      match_spec = [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
      :ets.select_delete(table, match_spec)
    else
      0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Clears all cached entries in the ETS cache table.
  """
  @spec clear(atom()) :: :ok
  def clear(table \\ @default_table) when is_atom(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp resolve_table(opts) do
    Keyword.get(opts, :ets_table, Keyword.get(opts, :table, @default_table))
  end

  defp create_owned_table(table) do
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

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      try do
        :ets.new(
          table,
          [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ] ++ heir_option()
        )
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp heir_option do
    case ensure_heir_pid() do
      pid when is_pid(pid) -> [{:heir, pid, nil}]
      _ -> []
    end
  end

  defp ensure_heir_pid do
    case Process.whereis(@heir_name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        pid = spawn(&heir_loop/0)

        try do
          Process.register(pid, @heir_name)
          pid
        rescue
          ArgumentError ->
            Process.exit(pid, :normal)
            Process.whereis(@heir_name)
        end
    end
  end

  defp heir_loop do
    receive do
      _ -> heir_loop()
    end
  end
end
