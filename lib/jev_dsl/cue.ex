defmodule JevDSL.CUE do
  @moduledoc """
  Deterministic CUE schema exporter for compiled `JevDSL.Contract` catalogs.
  """

  alias JevDSL.{Contract, Question}

  @doc """
  Serializes a map of compiled `JevDSL.Contract` structs into a deterministic CUE schema string.

  ## Examples

      iex> q = %JevDSL.Question{name: :is_spam, type: :noul, instructions: "Spam?", criteria: %{}}
      iex> prep = SystemOneSDK.prepare!([is_spam: SystemOneSDK.noul("Spam?")])
      iex> contract = %JevDSL.Contract{name: :is_spam, questions: [q], prepared: prep}
      iex> JevDSL.CUE.export(%{is_spam: contract})
      "is_spam: {\\n  is_spam: {\\n    type: \\"noul\\"\\n    instructions: \\"Spam?\\"\\n    criteria: {}\\n  }\\n}"
  """
  @spec export(%{optional(atom() | String.t()) => Contract.t() | map()}) :: String.t()
  def export(contracts_map) when is_map(contracts_map) do
    contracts_map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n\n", fn {contract_key, %{questions: questions}} ->
      q_blocks = Enum.map_join(questions, "\n", &format_question/1)
      "#{contract_key}: {\n#{q_blocks}\n}"
    end)
  end

  defp format_question(%Question{} = q), do: do_format_question(q)
  defp format_question(%{} = q), do: do_format_question(q)

  defp do_format_question(q) do
    criteria_section = format_criteria(q.type, q.criteria)

    [
      "  #{q.name}: {",
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
        "      #{ck}: #{Jason.encode!(desc)}"
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
        "      #{ck}: #{Jason.encode!(desc)}"
      end)

    "    criteria: {\n#{criteria_lines}\n    }"
  end
end
