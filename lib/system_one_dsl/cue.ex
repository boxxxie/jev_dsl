defmodule SystemOneDSL.CUE do
  @moduledoc """
  Deterministic CUE schema exporter for compiled `SystemOneDSL.Contract` catalogs.
  """

  alias SystemOneDSL.{Contract, Question}

  @doc """
  Serializes a map of compiled `SystemOneDSL.Contract` structs into a deterministic CUE schema string.

  ## Examples

      iex> q = %SystemOneDSL.Question{name: :is_spam, type: :noul, instructions: "Spam?", criteria: %{}}
      iex> prep = SystemOneSDK.prepare!([is_spam: SystemOneSDK.noul("Spam?")])
      iex> contract = %SystemOneDSL.Contract{name: :is_spam, questions: [q], prepared: prep}
      iex> SystemOneDSL.CUE.export(%{is_spam: contract})
      "is_spam: {\\n  is_spam: {\\n    type: \\"noul\\"\\n    instructions: \\"Spam?\\"\\n    criteria: {}\\n  }\\n}"
  """
  @spec export(%{optional(atom() | String.t()) => Contract.t() | map()}) :: String.t()
  def export(contracts_map) when is_map(contracts_map) do
    contracts_map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n\n", fn {contract_key, %{questions: questions}} ->
      q_blocks = Enum.map_join(questions, "\n", &format_question/1)
      "#{format_label(contract_key)}: {\n#{q_blocks}\n}"
    end)
  end

  defp format_question(%Question{} = q), do: do_format_question(q)
  defp format_question(%{} = q), do: do_format_question(q)

  defp do_format_question(q) do
    criteria_section = format_criteria(q.type, q.criteria)

    [
      "  #{format_label(q.name)}: {",
      "    type: #{Jason.encode!(to_string(q.type))}",
      "    instructions: #{Jason.encode!(q.instructions)}",
      criteria_section,
      "  }"
    ]
    |> Enum.join("\n")
  end

  defp format_criteria(_type, criteria) when criteria in [%{}, [], nil],
    do: "    criteria: {}"

  defp format_criteria(_type, criteria) when is_map(criteria) do
    criteria_lines =
      criteria
      |> Enum.sort_by(fn {ck, _} -> to_string(ck) end)
      |> Enum.map_join("\n", fn {ck, desc} ->
        "      #{format_label(ck)}: #{Jason.encode!(desc)}"
      end)

    "    criteria: {\n#{criteria_lines}\n    }"
  end

  defp format_criteria(:score, levels) when is_list(levels) do
    level_lines =
      Enum.map_join(levels, "\n", fn {ck, desc} ->
        "      {label: #{Jason.encode!(to_string(ck))}, description: #{Jason.encode!(desc)}}"
      end)

    "    criteria: [\n#{level_lines}\n    ]"
  end

  defp format_criteria(_type, pairs) when is_list(pairs) do
    criteria_lines =
      Enum.map_join(pairs, "\n", fn {ck, desc} ->
        "      #{format_label(ck)}: #{Jason.encode!(desc)}"
      end)

    "    criteria: {\n#{criteria_lines}\n    }"
  end

  defp format_label(key) do
    str = to_string(key)

    if Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, str) do
      str
    else
      Jason.encode!(str)
    end
  end
end
