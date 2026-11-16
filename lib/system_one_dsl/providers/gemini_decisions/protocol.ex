defmodule SystemOneDSL.Providers.GeminiDecisions.Protocol do
  @moduledoc """
  Wire protocol encoder and response decoder for the Gemini Decisions API (`gemini-decision-1`),
  supporting both LiteLLM's unified `/v1/decisions` format and Google's native
  `/v1beta/decisions` (or `/gemini/v1beta/decisions` passthrough) format.
  """

  alias SystemOneDSL.Error
  alias SystemOneSDK.{ChoiceAnswer, NoulAnswer, Prepared, ScoreAnswer, SystemOneResponse, Usage}

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

  @doc """
  Decodes a Gemini Decisions API JSON response body (unified `/v1/decisions`,
  native `/v1beta/decisions`, or single-question flat format) into a
  `%SystemOneSDK.SystemOneResponse{}`.
  """
  @spec decode_response(term(), Prepared.t(), String.t()) ::
          {:ok, SystemOneResponse.t()} | {:error, Error.t()}
  def decode_response(body, %Prepared{} = prepared, default_model) when is_map(body) do
    model =
      case body["model"] do
        m when is_binary(m) and m != "" -> m
        _ -> default_model
      end

    usage = decode_usage(body)

    with {:ok, raw_answers} <- extract_raw_answers(body, prepared),
         {:ok, answers} <- normalize_answers(raw_answers, prepared) do
      {:ok,
       %SystemOneResponse{
         model: model,
         usage: usage,
         answers: answers,
         raw: body,
         prepared_fingerprint: prepared.fingerprint
       }}
    end
  end

  def decode_response(body, _prepared, _default_model) do
    {:error,
     %Error{
       type: :invalid_response,
       message: "Expected Gemini Decisions response to be a JSON object",
       details: %{body: body}
     }}
  end

  defp decode_usage(body) do
    usage_map = body["usage"] || body["usage_metadata"] || body

    input_tokens =
      usage_map["input_tokens"] ||
        usage_map["total_input_tokens"] ||
        usage_map["prompt_tokens"]

    output_tokens =
      usage_map["output_tokens"] ||
        usage_map["total_output_tokens"] ||
        usage_map["completion_tokens"]

    %Usage{input_tokens: input_tokens, output_tokens: output_tokens}
  end

  defp extract_raw_answers(%{"answers" => list}, _prepared) when is_list(list) do
    by_name =
      Enum.reduce(list, %{}, fn
        %{"name" => name} = item, acc -> Map.put(acc, to_string(name), item)
        _, acc -> acc
      end)

    {:ok, by_name}
  end

  defp extract_raw_answers(%{"answers" => map}, _prepared) when is_map(map) do
    {:ok, Map.new(map, fn {k, v} -> {to_string(k), v} end)}
  end

  defp extract_raw_answers(body, %Prepared{ordered_keys: [single_key]}) do
    if has_flat_decision_fields?(body) do
      {:ok, %{to_string(single_key) => body}}
    else
      {:error,
       %Error{
         type: :invalid_response,
         message: "Gemini Decisions response missing 'answers'",
         details: %{body: body}
       }}
    end
  end

  defp extract_raw_answers(body, _prepared) do
    {:error,
     %Error{
       type: :invalid_response,
       message: "Gemini Decisions response missing 'answers'",
       details: %{body: body}
     }}
  end

  defp has_flat_decision_fields?(body) do
    Enum.any?(
      ["noul", "probability", "confidence", "choice", "score"],
      &Map.has_key?(body, &1)
    )
  end

  defp normalize_answers(raw_answers, %Prepared{} = prepared) do
    Enum.reduce_while(prepared.ordered_keys, {:ok, %{}}, fn caller_key, {:ok, acc} ->
      wire_key = to_string(caller_key)

      case normalize_one_answer(caller_key, raw_answers, prepared) do
        {:ok, ans} -> {:cont, {:ok, Map.put(acc, wire_key, ans)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_one_answer(caller_key, raw_answers, %Prepared{} = prepared) do
    wire_key = to_string(caller_key)
    defn = Map.fetch!(prepared.definitions, wire_key)

    case Map.fetch(raw_answers, wire_key) do
      {:ok, raw_ans} when is_map(raw_ans) ->
        normalize_question_answer(caller_key, defn, raw_ans)

      _ ->
        {:error,
         %Error{
           type: :invalid_response,
           message: "Missing answer for question #{inspect(caller_key)}",
           details: %{question: caller_key, answers: raw_answers}
         }}
    end
  end

  defp normalize_question_answer(caller_key, %{type: "noul"}, raw_ans) do
    prob = raw_ans["noul"] || raw_ans["probability"] || raw_ans["confidence"]

    if is_number(prob) do
      {:ok, %NoulAnswer{noul: prob, id: caller_key, raw: raw_ans}}
    else
      {:error,
       %Error{
         type: :invalid_response,
         message: "Invalid noul probability for #{inspect(caller_key)}",
         details: %{answer: raw_ans}
       }}
    end
  end

  defp normalize_question_answer(caller_key, %{type: "choice"} = defn, raw_ans) do
    option_order = Map.get(defn, :option_order, [])
    choice_raw = raw_ans["choice"]
    choice_str = if is_nil(choice_raw), do: nil, else: to_string(choice_raw)
    probs = normalize_probabilities(raw_ans["probabilities"] || %{})
    conf = raw_ans["confidence"] || Map.get(probs, choice_str, 1.0)

    if is_nil(choice_str) do
      {:error,
       %Error{
         type: :invalid_response,
         message: "Missing choice for #{inspect(caller_key)}",
         details: %{answer: raw_ans}
       }}
    else
      {:ok,
       %ChoiceAnswer{
         choice: choice_str,
         confidence: conf,
         probabilities: probs,
         id: caller_key,
         raw: raw_ans,
         option_order: option_order
       }}
    end
  end

  defp normalize_question_answer(caller_key, %{type: "score"} = defn, raw_ans) do
    levels = Map.get(defn, :levels, [])
    legend = Map.new(levels, fn lvl -> {lvl.index, lvl.label} end)
    probs = normalize_probabilities(raw_ans["probabilities"] || %{})
    score = raw_ans["score"]
    conf = raw_ans["confidence"] || 1.0

    if is_number(score) do
      {:ok,
       %ScoreAnswer{
         score: score,
         confidence: conf,
         legend: legend,
         probabilities: probs,
         id: caller_key,
         raw: raw_ans,
         levels: levels
       }}
    else
      {:error,
       %Error{
         type: :invalid_response,
         message: "Invalid score for #{inspect(caller_key)}",
         details: %{answer: raw_ans}
       }}
    end
  end

  defp normalize_probabilities(probs) when is_map(probs) do
    Map.new(probs, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_probabilities(_), do: %{}
end
