defmodule JevDSL.Providers.GeminiDecisions.Protocol do
  @moduledoc """
  Wire protocol encoder and response decoder for the Gemini Decisions API (`gemini-decision-1`),
  supporting both LiteLLM's unified `/v1/decisions` format and Google's native
  `/v1beta/decisions` (or `/gemini/v1beta/decisions` passthrough) format.
  """

  alias JevDSL.Error
  alias SystemOneSDK.{ChoiceAnswer, NoulAnswer, Prepared, ScoreAnswer, SystemOneResponse, Usage}

  @type mode :: :unified | :native
  @type auth_mode :: :bearer | :x_goog_api_key

  @noul_boolean_keys ["noul", "decision", "answer", "value", "result", "predicate", "probability"]
  @noul_numeric_keys [
    "noul",
    "probability",
    "predicate",
    "decision",
    "answer",
    "value",
    "result",
    "confidence"
  ]

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
    %{"type" => "predicate", "name" => name}
    |> maybe_put_instructions(merge_noul_instructions(wire["instructions"], defn[:criteria]))
  end

  defp encode_unified_question(name, %{type: "choice", wire: wire, criteria: criteria} = defn) do
    criteria_map = Map.new(criteria, fn {k, desc} -> {to_string(k), desc} end)

    choices =
      case Map.get(defn, :option_order) do
        order when is_list(order) and order != [] ->
          Enum.map(order, fn k ->
            val = to_string(k)
            %{"value" => val, "description" => Map.fetch!(criteria_map, val)}
          end)

        _ ->
          Enum.map(criteria, fn {k, desc} ->
            %{"value" => to_string(k), "description" => desc}
          end)
      end

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
    |> maybe_put_instructions(merge_noul_instructions(wire["instructions"], defn[:criteria]))
  end

  defp encode_native_question(%{type: "choice", wire: wire, criteria: criteria}) do
    criteria_map = Map.new(criteria, fn {k, desc} -> {to_string(k), desc} end)

    %{"type" => "choice", "criteria" => criteria_map}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp encode_native_question(%{type: "score", wire: wire, levels: levels}) do
    encoded_criteria = Enum.map(levels, & &1.description)

    %{"type" => "score", "criteria" => encoded_criteria}
    |> maybe_put_instructions(wire["instructions"])
  end

  defp maybe_put_instructions(map, nil), do: map
  defp maybe_put_instructions(map, instructions), do: Map.put(map, "instructions", instructions)

  defp merge_noul_instructions(instructions, criteria) when criteria in [nil, [], %{}],
    do: instructions

  defp merge_noul_instructions(instructions, criteria) do
    formatted = Enum.map_join(criteria, "\n", fn {k, v} -> "#{k}: #{v}" end)

    case instructions do
      nil -> formatted
      "" -> formatted
      inst -> "#{inst}\n#{formatted}"
    end
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
    candidates =
      [body["usage"], body["usage_metadata"], body["usageMetadata"], body]
      |> Enum.filter(&(is_map(&1) and map_size(&1) > 0))

    input_tokens =
      find_usage_tokens(candidates, [
        "input_tokens",
        "total_input_tokens",
        "prompt_tokens",
        "prompt_token_count",
        "totalInputTokens",
        "promptTokenCount",
        "inputTokens"
      ])

    output_tokens =
      find_usage_tokens(candidates, [
        "output_tokens",
        "total_output_tokens",
        "completion_tokens",
        "candidates_token_count",
        "totalOutputTokens",
        "candidatesTokenCount",
        "outputTokens"
      ])

    %Usage{input_tokens: input_tokens, output_tokens: output_tokens}
  end

  defp find_usage_tokens(candidates, keys) do
    Enum.find_value(candidates, &find_map_token(&1, keys))
  end

  defp find_map_token(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, val} when is_integer(val) -> val
        _ -> nil
      end
    end)
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

  defp extract_raw_answers(body, %Prepared{ordered_keys: [single_key]} = prepared) do
    wire_key = to_string(single_key)
    defn = Map.fetch!(prepared.definitions, wire_key)

    if has_flat_decision_fields?(body, defn.type) do
      {:ok, %{wire_key => body}}
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

  defp has_flat_decision_fields?(body, "noul") do
    not Map.has_key?(body, "choice") and
      not Map.has_key?(body, "score") and
      body["type"] in [nil, "noul", "predicate"] and
      Enum.any?(
        [
          "noul",
          "probability",
          "confidence",
          "decision",
          "answer",
          "value",
          "result",
          "predicate"
        ],
        &Map.has_key?(body, &1)
      )
  end

  defp has_flat_decision_fields?(body, "choice") do
    Map.has_key?(body, "choice") and
      not Map.has_key?(body, "noul") and
      not Map.has_key?(body, "score") and
      body["type"] in [nil, "choice"]
  end

  defp has_flat_decision_fields?(body, "score") do
    Map.has_key?(body, "score") and
      not Map.has_key?(body, "noul") and
      not Map.has_key?(body, "choice") and
      body["type"] in [nil, "score"]
  end

  defp has_flat_decision_fields?(_body, _type), do: false

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
    if invalid_noul_shape?(raw_ans) do
      invalid_answer_error("Invalid noul answer shape for #{inspect(caller_key)}", raw_ans)
    else
      case resolve_noul_probability(raw_ans) do
        {:ok, prob} ->
          {:ok, %NoulAnswer{noul: prob, id: caller_key, raw: raw_ans}}

        :error ->
          invalid_answer_error("Invalid noul probability for #{inspect(caller_key)}", raw_ans)
      end
    end
  end

  defp normalize_question_answer(caller_key, %{type: "choice"} = defn, raw_ans) do
    option_order = Map.get(defn, :option_order, [])
    valid_options = choice_valid_options(defn, option_order)
    choice_raw = raw_ans["choice"]
    raw_conf = raw_ans["confidence"]

    with true <- valid_choice_shape?(raw_ans),
         true <- valid_choice_value?(choice_raw),
         choice_str = to_string(choice_raw),
         true <- MapSet.size(valid_options) == 0 or MapSet.member?(valid_options, choice_str),
         {:ok, parsed_probs} <- normalize_probabilities(raw_ans["probabilities"]),
         conf = if(is_nil(raw_conf), do: Map.get(parsed_probs, choice_str, 1.0), else: raw_conf),
         true <- is_number(conf) do
      probs =
        if is_nil(raw_ans["probabilities"]),
          do: backfill_choice_probabilities(choice_str, conf, valid_options),
          else: parsed_probs

      {:ok,
       %ChoiceAnswer{
         choice: choice_str,
         confidence: conf,
         probabilities: probs,
         id: caller_key,
         raw: raw_ans,
         option_order: option_order
       }}
    else
      _ ->
        invalid_answer_error("Invalid choice for #{inspect(caller_key)}", raw_ans)
    end
  end

  defp normalize_question_answer(caller_key, %{type: "score"} = defn, raw_ans) do
    levels = Map.get(defn, :levels, [])
    legend = Map.new(levels, fn lvl -> {lvl.index, lvl.label} end)
    raw_score = raw_ans["score"]
    raw_conf = raw_ans["confidence"]
    conf = if is_nil(raw_conf), do: 1.0, else: raw_conf
    max_index = max(length(levels) - 1, 1)

    with true <- valid_score_shape?(raw_ans),
         {:ok, probs} <- normalize_score_probabilities(raw_ans["probabilities"], levels),
         true <- is_number(raw_score),
         true <- is_number(conf),
         {:ok, score} <- normalize_score_value(raw_score, probs, max_index) do
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
      _ ->
        invalid_answer_error("Invalid score for #{inspect(caller_key)}", raw_ans)
    end
  end

  defp invalid_answer_error(message, raw_ans) do
    {:error, %Error{type: :invalid_response, message: message, details: %{answer: raw_ans}}}
  end

  defp invalid_noul_shape?(raw_ans) do
    Map.has_key?(raw_ans, "choice") or
      Map.has_key?(raw_ans, "score") or
      raw_ans["type"] not in [nil, "noul", "predicate"]
  end

  defp valid_choice_shape?(raw_ans) do
    not Map.has_key?(raw_ans, "noul") and
      not Map.has_key?(raw_ans, "score") and
      raw_ans["type"] in [nil, "choice"]
  end

  defp valid_score_shape?(raw_ans) do
    not Map.has_key?(raw_ans, "noul") and
      not Map.has_key?(raw_ans, "choice") and
      raw_ans["type"] in [nil, "score"]
  end

  defp resolve_noul_probability(raw_ans) do
    case find_boolean_field(raw_ans, @noul_boolean_keys) do
      {:ok, bool_val} ->
        conf =
          case raw_ans["confidence"] do
            nil -> numeric_prob(raw_ans["probability"]) || numeric_prob(raw_ans["noul"])
            val -> val
          end

        resolve_boolean_confidence(bool_val, conf)

      :none ->
        resolve_first_numeric_noul(raw_ans)
    end
  end

  defp find_boolean_field(raw_ans, keys) do
    Enum.find_value(keys, :none, fn key ->
      case Map.fetch(raw_ans, key) do
        {:ok, val} when is_boolean(val) -> {:ok, val}
        _ -> nil
      end
    end)
  end

  defp resolve_first_numeric_noul(raw_ans) do
    case Enum.find(@noul_numeric_keys, &present_value?(raw_ans, &1)) do
      nil -> :error
      key -> resolve_numeric_prob(raw_ans[key])
    end
  end

  defp present_value?(map, key), do: Map.has_key?(map, key) and not is_nil(map[key])

  defp numeric_prob(val) when is_number(val), do: val
  defp numeric_prob(_), do: nil

  defp resolve_numeric_prob(val) when is_number(val) and val >= 0.0 and val <= 1.0,
    do: {:ok, val}

  defp resolve_numeric_prob(_), do: :error

  defp resolve_boolean_confidence(bool, nil), do: {:ok, if(bool, do: 1.0, else: 0.0)}

  defp resolve_boolean_confidence(bool, conf)
       when is_number(conf) and conf >= 0.0 and conf <= 1.0 do
    {:ok, if(bool, do: conf, else: 1.0 - conf)}
  end

  defp resolve_boolean_confidence(_, _), do: :error

  defp backfill_choice_probabilities(choice_str, conf, valid_options)
       when is_number(conf) and conf >= 0.0 and conf <= 1.0 do
    other_options =
      valid_options
      |> MapSet.delete(choice_str)
      |> MapSet.to_list()

    case other_options do
      [] ->
        %{choice_str => conf}

      others ->
        remainder = max(1.0 - conf, 0.0) / length(others)

        others
        |> Map.new(&{&1, remainder})
        |> Map.put(choice_str, conf)
    end
  end

  defp backfill_choice_probabilities(choice_str, conf, _valid_options) do
    %{choice_str => conf}
  end

  defp choice_valid_options(defn, option_order) do
    cond do
      is_list(option_order) and option_order != [] ->
        MapSet.new(option_order, &to_string/1)

      is_map(defn[:option_keys]) and map_size(defn[:option_keys]) > 0 ->
        MapSet.new(Map.keys(defn[:option_keys]), &to_string/1)

      is_list(defn[:criteria]) or (is_map(defn[:criteria]) and map_size(defn[:criteria]) > 0) ->
        MapSet.new(defn[:criteria], fn {k, _v} -> to_string(k) end)

      true ->
        MapSet.new()
    end
  end

  defp valid_choice_value?(val) when is_binary(val), do: val != ""
  defp valid_choice_value?(val) when is_atom(val), do: not is_nil(val) and not is_boolean(val)
  defp valid_choice_value?(_), do: false

  defp normalize_score_value(raw_score, probs, max_index) do
    score =
      if max_index > 1 and map_size(probs) > 0 and raw_score >= 0.0 and raw_score <= 1.0 do
        expected = Enum.reduce(probs, 0.0, fn {idx, p}, acc -> acc + idx * p end)

        if abs(raw_score * max_index - expected) + 1.0e-6 < abs(raw_score - expected) do
          raw_score * max_index
        else
          raw_score
        end
      else
        raw_score
      end

    if score >= 0.0 and score <= max_index do
      {:ok, score}
    else
      :error
    end
  end

  defp normalize_probabilities(nil), do: {:ok, %{}}

  defp normalize_probabilities(probs)
       when (is_map(probs) and not is_struct(probs)) or is_list(probs) do
    with {:ok, pairs} <- extract_probability_pairs(probs) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn
        {k, v}, {:ok, acc}
        when (is_binary(k) or (is_atom(k) and not is_nil(k)) or is_integer(k)) and is_number(v) ->
          {:cont, {:ok, Map.put(acc, to_string(k), v)}}

        _, _ ->
          {:halt, :error}
      end)
    end
  end

  defp normalize_probabilities(_), do: :error

  defp normalize_score_probabilities(nil, _levels), do: {:ok, %{}}

  defp normalize_score_probabilities(raw_probs, levels)
       when (is_map(raw_probs) and not is_struct(raw_probs)) or is_list(raw_probs) do
    label_to_idx = Map.new(levels, fn lvl -> {lvl.label, lvl.index} end)
    idx_set = MapSet.new(levels, & &1.index)

    with {:ok, pairs} <- extract_probability_pairs(raw_probs) do
      reduce_score_probabilities(pairs, label_to_idx, idx_set)
    end
  end

  defp normalize_score_probabilities(_, _levels), do: :error

  defp reduce_score_probabilities(pairs, label_to_idx, idx_set) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case resolve_score_index(k, label_to_idx, idx_set) do
        {:ok, idx} when is_number(v) -> {:cont, {:ok, Map.put(acc, idx, v)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp extract_probability_pairs(probs) when is_map(probs), do: {:ok, Map.to_list(probs)}

  defp extract_probability_pairs(probs) when is_list(probs) do
    probs
    |> Enum.reduce_while({:ok, []}, fn
      %{"value" => k, "probability" => v}, {:ok, acc} when not is_nil(k) ->
        {:cont, {:ok, [{k, v} | acc]}}

      %{"label" => k, "probability" => v}, {:ok, acc} when not is_nil(k) ->
        {:cont, {:ok, [{k, v} | acc]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  defp resolve_score_index(k, _label_to_idx, idx_set) when is_integer(k) do
    if MapSet.member?(idx_set, k), do: {:ok, k}, else: :error
  end

  defp resolve_score_index(k, label_to_idx, idx_set) when is_binary(k) or is_atom(k) do
    str = to_string(k)

    with :error <- Map.fetch(label_to_idx, str),
         {int, ""} <- Integer.parse(str),
         true <- MapSet.member?(idx_set, int) do
      {:ok, int}
    else
      {:ok, idx} -> {:ok, idx}
      _ -> :error
    end
  end

  defp resolve_score_index(_, _, _), do: :error
end
