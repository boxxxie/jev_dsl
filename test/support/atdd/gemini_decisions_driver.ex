defmodule JevDSL.ATDD.GeminiDecisionsDriver do
  @moduledoc false
  @behaviour Pristine.Ports.Transport

  require ExUnit.Callbacks

  defmodule StubServer do
    @moduledoc false
    use Agent, restart: :temporary

    def start_link(responder) do
      Agent.start_link(fn -> %{responder: responder, requests: []} end)
    end

    def record_and_respond(pid, request) do
      responder =
        Agent.get_and_update(pid, fn state ->
          {state.responder, %{state | requests: [request | state.requests]}}
        end)

      responder.(request)
    end

    def requests(pid), do: Agent.get(pid, &Enum.reverse(&1.requests))
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
    ExUnit.Callbacks.start_supervised!({StubServer, responder}, id: {StubServer, make_ref()})
  end

  def request_count(pid), do: length(StubServer.requests(pid))
  def requests(pid), do: StubServer.requests(pid)

  def last_request_summary(pid) do
    req = pid |> requests() |> List.last()
    decoded = Jason.decode!(req.body)

    mode =
      case req.path do
        "/v1/decisions" -> :unified
        "/gemini/v1beta/decisions" -> :native
        "/v1beta/decisions" -> :native
        other -> other
      end

    auth_token =
      cond do
        auth = req.headers["Authorization"] -> String.replace_prefix(auth, "Bearer ", "")
        key = req.headers["x-goog-api-key"] -> key
        true -> nil
      end

    %{
      mode: mode,
      path: req.path,
      model: decoded["model"],
      auth_token: auth_token,
      body: decoded,
      headers: req.headers
    }
  end

  def encode_upstream_answers(req, answers_spec, opts \\ []) when is_list(answers_spec) do
    decoded = Jason.decode!(req.body)
    flat? = Keyword.get(opts, :flat, false)

    case req.path do
      "/v1/decisions" ->
        verify_unified_wire_request!(req, decoded, opts)

        body = %{
          "model" => Keyword.get(opts, :response_model, "gemini/gemini-decision-1"),
          "answers" => Enum.map(answers_spec, &encode_unified_answer/1),
          "usage" => %{"input_tokens" => 100, "output_tokens" => 0}
        }

        {200, body}

      path when path in ["/gemini/v1beta/decisions", "/v1beta/decisions"] ->
        verify_native_wire_request!(req, decoded, opts)

        body =
          if flat? and length(answers_spec) == 1 do
            answers_spec
            |> hd()
            |> encode_flat_native_answer()
            |> Map.merge(%{"total_input_tokens" => 94, "total_output_tokens" => 0})
          else
            %{
              "answers" => Map.new(answers_spec, &encode_native_answer/1),
              "usageMetadata" => %{"totalInputTokens" => 99, "totalOutputTokens" => 0}
            }
          end

        {200, body}
    end
  end

  defp verify_unified_wire_request!(req, decoded, opts) do
    expected_auth = Keyword.get(opts, :expected_auth_header, "Bearer test-gemini-key")

    if expected_auth && req.headers["Authorization"] != expected_auth do
      raise "Expected Authorization #{inspect(expected_auth)}, got #{inspect(req.headers["Authorization"])}"
    end

    if not is_list(decoded["questions"]) do
      raise "Expected unified questions list, got #{inspect(decoded["questions"])}"
    end
  end

  defp verify_native_wire_request!(req, decoded, opts) do
    expected_key = Keyword.get(opts, :expected_x_goog_key, "test-gemini-key")

    if expected_key && req.headers["x-goog-api-key"] != expected_key do
      raise "Expected x-goog-api-key #{inspect(expected_key)}, got #{inspect(req.headers["x-goog-api-key"])}"
    end

    if not is_map(decoded["questions"]) do
      raise "Expected native questions map, got #{inspect(decoded["questions"])}"
    end
  end

  defp encode_unified_answer({:noul, name, {:boolean_conf, bool_val, conf}}) do
    %{"name" => to_string(name), "type" => "predicate", "noul" => bool_val, "confidence" => conf}
  end

  defp encode_unified_answer({:noul, name, prob}) when is_number(prob) do
    %{"name" => to_string(name), "type" => "predicate", "probability" => prob}
  end

  defp encode_unified_answer({:choice, name, choice, conf, probs}) do
    %{
      "name" => to_string(name),
      "type" => "choice",
      "choice" => to_string(choice),
      "confidence" => conf,
      "probabilities" =>
        Enum.map(probs, fn {k, v} -> %{"value" => to_string(k), "probability" => v} end)
    }
  end

  defp encode_unified_answer({:score, name, score, conf, probs}) do
    encoded_probs =
      Enum.with_index(probs, fn {label, prob}, idx ->
        %{"value" => idx, "label" => to_string(label), "probability" => prob}
      end)

    %{
      "name" => to_string(name),
      "type" => "score",
      "score" => score,
      "confidence" => conf,
      "probabilities" => encoded_probs
    }
  end

  defp encode_native_answer({:noul, name, {:boolean_conf, bool_val, conf}}) do
    {to_string(name), %{"noul" => bool_val, "confidence" => conf}}
  end

  defp encode_native_answer({:noul, name, prob}) when is_number(prob) do
    {to_string(name), %{"noul" => prob}}
  end

  defp encode_native_answer({:choice, name, choice, conf, probs}) do
    {to_string(name),
     %{
       "type" => "choice",
       "choice" => to_string(choice),
       "confidence" => conf,
       "probabilities" => Map.new(probs, fn {k, v} -> {to_string(k), v} end)
     }}
  end

  defp encode_native_answer({:score, name, score, conf, probs}) do
    encoded_probs =
      probs
      |> Enum.with_index()
      |> Map.new(fn {{_label, prob}, idx} -> {Integer.to_string(idx), prob} end)

    {to_string(name),
     %{
       "type" => "score",
       "score" => score,
       "confidence" => conf,
       "probabilities" => encoded_probs
     }}
  end

  defp encode_flat_native_answer({:noul, _name, {:flat_confidence, conf}}) do
    %{"confidence" => conf}
  end

  defp encode_flat_native_answer({:noul, _name, prob}) when is_number(prob) do
    %{"confidence" => prob}
  end

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

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    {ref, handler_id}
  end

  def handle_telemetry(event, measurements, metadata, {parent, ref}) do
    callers = Process.get(:"$callers") || []

    if self() == parent or parent in callers do
      Kernel.send(parent, {:atdd_telemetry, ref, event, measurements, metadata})
    end
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
