defmodule JevDSL.ATDD.GeminiDecisionsDriver do
  @moduledoc false
  @behaviour Pristine.Ports.Transport

  defmodule StubServer do
    @moduledoc false
    use Agent

    def start_link(responder) do
      Agent.start_link(fn -> %{responder: responder, requests: []} end)
    end

    def record_and_respond(pid, request) do
      responder =
        Agent.get_and_update(pid, fn state ->
          {state.responder, %{state | requests: state.requests ++ [request]}}
        end)

      responder.(request)
    end

    def requests(pid), do: Agent.get(pid, & &1.requests)
  end

  defmodule Tier2ETS do
    @moduledoc false
    @behaviour JevDSL.Cache

    alias JevDSL.Cache.ETS

    @impl true
    def get(key, opts) do
      ETS.get(key, Keyword.put(opts, :ets_table, Keyword.fetch!(opts, :tier2_table)))
    end

    @impl true
    def get_many(keys, opts) do
      ETS.get_many(
        keys,
        Keyword.put(opts, :ets_table, Keyword.fetch!(opts, :tier2_table))
      )
    end

    @impl true
    def put(key, value, opts) do
      ETS.put(
        key,
        value,
        Keyword.put(opts, :ets_table, Keyword.fetch!(opts, :tier2_table))
      )
    end

    @impl true
    def put_many(entries, opts) do
      ETS.put_many(
        entries,
        Keyword.put(opts, :ets_table, Keyword.fetch!(opts, :tier2_table))
      )
    end
  end

  @impl true
  def capabilities(_context), do: %{}

  @impl true
  def send(request, context) do
    pid = Keyword.fetch!(context.transport_opts, :stub_pid)

    normalized_req = %{
      path: request.metadata.path,
      url: request.url,
      headers: request.headers,
      body: request.body
    }

    pid
    |> StubServer.record_and_respond(normalized_req)
    |> stub_response_to_core()
  end

  defp stub_response_to_core({:error, _} = err), do: err

  defp stub_response_to_core({status, body}) when is_integer(status) do
    {:ok, build_core_response(status, body, nil)}
  end

  defp stub_response_to_core({status, body, headers})
       when is_integer(status) and is_map(headers) do
    {:ok, build_core_response(status, body, headers)}
  end

  defp build_core_response(status, body_map, headers) when is_map(body_map) do
    %Pristine.Core.Response{
      status: status,
      headers: headers || %{"content-type" => "application/json"},
      body: Jason.encode!(body_map)
    }
  end

  defp build_core_response(status, body_bin, headers) when is_binary(body_bin) do
    %Pristine.Core.Response{
      status: status,
      headers: headers || %{"content-type" => "text/plain"},
      body: body_bin
    }
  end

  def start_stub(responder) do
    {:ok, pid} = StubServer.start_link(responder)
    pid
  end

  def request_count(pid), do: length(StubServer.requests(pid))
  def requests(pid), do: StubServer.requests(pid)

  def unique_ets_tables do
    id = System.unique_integer([:positive])
    l1 = :"atdd_l1_#{id}"
    l2 = :"atdd_l2_#{id}"
    :ets.new(l1, [:named_table, :public, :set, {:read_concurrency, true}])
    :ets.new(l2, [:named_table, :public, :set, {:read_concurrency, true}])
    {l1, l2}
  end

  def attach_telemetry do
    ref = make_ref()
    parent = self()
    handler_id = "atdd-telemetry-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      [[:jev_dsl, :evaluate, :stop], [:jev_dsl, :evaluate_many, :stop]],
      &__MODULE__.handle_telemetry/4,
      {parent, ref}
    )

    {ref, handler_id}
  end

  def handle_telemetry(event, measurements, metadata, {parent, ref}) do
    Kernel.send(parent, {:atdd_telemetry, ref, event, measurements, metadata})
  end

  def drain_telemetry({ref, handler_id}) do
    :telemetry.detach(handler_id)
    collect_messages(ref, [])
  end

  defp collect_messages(ref, acc) do
    receive do
      {:atdd_telemetry, ^ref, event, _meas, meta} ->
        collect_messages(ref, [{event, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
