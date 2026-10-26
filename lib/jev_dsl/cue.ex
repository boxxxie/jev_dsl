defmodule JevDSL.CUE do
  @moduledoc """
  Deterministic CUE schema exporter for compiled `JevDSL.Contract` catalogs.
  """

  alias JevDSL.{Contract, Question}

  @doc """
  Serializes a map of compiled `JevDSL.Contract` structs into a deterministic CUE schema string.
  """
  @spec export(%{optional(atom()) => Contract.t() | map()}) :: String.t()
  def export(contracts_map) when is_map(contracts_map) do
    contracts_map
    |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
    |> Enum.map_join("\n\n", fn {contract_key, %{questions: questions}} ->
      q_blocks = Enum.map_join(questions, "\n", &format_question/1)
      "#{contract_key}: {\n#{q_blocks}\n}"
    end)
  end

  defp format_question(%Question{} = q), do: do_format_question(q)
  defp format_question(%{} = q), do: do_format_question(q)

  defp do_format_question(q) do
    criteria_section = format_criteria(q.criteria)

    [
      "  #{q.name}: {",
      "    type: #{Jason.encode!(Atom.to_string(q.type))}",
      "    instructions: #{Jason.encode!(q.instructions)}",
      criteria_section,
      "  }"
    ]
    |> Enum.join("\n")
  end

  defp format_criteria(criteria) when is_map(criteria) and map_size(criteria) == 0,
    do: "    criteria: {}"

  defp format_criteria(criteria) when is_map(criteria) do
    criteria_lines =
      criteria
      |> Enum.sort_by(fn {ck, _} -> Atom.to_string(ck) end)
      |> Enum.map_join("\n", fn {ck, desc} ->
        "      #{ck}: #{Jason.encode!(desc)}"
      end)

    "    criteria: {\n#{criteria_lines}\n    }"
  end

  defp format_criteria(levels) when is_list(levels) do
    level_lines =
      Enum.map_join(levels, "\n", fn {ck, desc} ->
        "      {label: #{Jason.encode!(Atom.to_string(ck))}, description: #{Jason.encode!(desc)}}"
      end)

    "    criteria: [\n#{level_lines}\n    ]"
  end
end
