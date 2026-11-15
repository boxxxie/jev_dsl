defmodule JevDSL.Providers.GeminiDecisions.Protocol do
  @moduledoc """
  Wire protocol encoder and response decoder for the Gemini Decisions API (`gemini-decision-1`),
  supporting both LiteLLM's unified `/v1/decisions` format and Google's native
  `/v1beta/decisions` (or `/gemini/v1beta/decisions` passthrough) format.
  """

  alias SystemOneSDK.Prepared

  @type mode :: :unified | :native
  @type auth_mode :: :bearer | :x_goog_api_key

  @doc """
  Builds authentication headers for the given `api_key` and `auth_mode`.
  """
  @spec auth_headers(String.t() | nil, auth_mode()) :: %{optional(String.t()) => String.t()}
  def auth_headers(nil, _auth_mode), do: %{}
  def auth_headers("", _auth_mode), do: %{}
  def auth_headers(api_key, :bearer), do: %{"Authorization" => "Bearer #{api_key}"}
  def auth_headers(api_key, :x_goog_api_key), do: %{"x-goog-api-key" => api_key}

  @doc """
  Encodes an input `state` and compiled `%SystemOneSDK.Prepared{}` contract into a
  Gemini Decisions JSON-serializable map for either `:unified` (`/v1/decisions`)
  or `:native` (`/v1beta/decisions`) endpoints.
  """
  @spec encode_request(term(), Prepared.t(), String.t(), mode()) :: map()
  def encode_request(state, %Prepared{} = prepared, model, mode)
      when mode in [:unified, :native] do
    %{
      "model" => model,
      "input" => encode_input(state),
      "questions" => encode_questions(prepared, mode)
    }
  end

  defp encode_input(state) when is_binary(state), do: state
  defp encode_input(state), do: Jason.encode!(state)

  defp encode_questions(%Prepared{} = prepared, :unified) do
    Enum.map(prepared.ordered_keys, fn caller_key ->
      wire_key = to_string(caller_key)
      defn = Map.fetch!(prepared.definitions, wire_key)
      encode_unified_question(wire_key, defn)
    end)
  end

  defp encode_questions(%Prepared{} = prepared, :native) do
    Map.new(prepared.ordered_keys, fn caller_key ->
      wire_key = to_string(caller_key)
      defn = Map.fetch!(prepared.definitions, wire_key)
      {wire_key, encode_native_question(defn)}
    end)
  end

  defp encode_unified_question(name, %{type: "noul", wire: wire} = defn) do
    base = %{"type" => "predicate", "name" => name}
    base = maybe_put_instructions(base, wire["instructions"])
    maybe_put_noul_criteria(base, defn[:criteria])
  end

  defp encode_unified_question(name, %{type: "choice", wire: wire, criteria: criteria}) do
    choices =
      Enum.map(criteria, fn {k, desc} ->
        %{"value" => to_string(k), "description" => desc}
      end)

    %{"type" => "choice", "name" => name, "choices" => choices}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp encode_unified_question(name, %{type: "score", wire: wire, levels: levels}) do
    encoded_levels =
      Enum.map(levels, fn lvl ->
        %{"label" => lvl.label, "description" => lvl.description}
      end)

    %{"type" => "score", "name" => name, "levels" => encoded_levels}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp encode_native_question(%{type: "noul", wire: wire} = defn) do
    %{"type" => "noul"}
    |> maybe_put_instructions(wire["instructions"])
    |> maybe_put_noul_criteria(defn[:criteria])
  end

  defp encode_native_question(%{type: "choice", wire: wire, criteria: criteria}) do
    criteria_map = Map.new(criteria, fn {k, desc} -> {to_string(k), desc} end)

    %{"type" => "choice", "criteria" => criteria_map}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp encode_native_question(%{type: "score", wire: wire, levels: levels}) do
    encoded_levels =
      Enum.map(levels, fn lvl ->
        %{"label" => lvl.label, "description" => lvl.description}
      end)

    %{"type" => "score", "levels" => encoded_levels}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp maybe_put_instructions(map, nil), do: map
  defp maybe_put_instructions(map, instructions), do: Map.put(map, "instructions", instructions)

  defp maybe_put_noul_criteria(map, nil), do: map

  defp maybe_put_noul_criteria(map, criteria) when is_map(criteria) do
    Map.put(map, "criteria", Map.new(criteria, fn {k, v} -> {to_string(k), v} end))
  end

  defp maybe_put_noul_criteria(map, criteria) when is_list(criteria) do
    Map.put(map, "criteria", Map.new(criteria, fn {k, v} -> {to_string(k), v} end))
  end
end
