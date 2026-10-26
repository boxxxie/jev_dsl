defmodule JevDSL do
  @moduledoc """
  Compile-time Elixir macro DSL, two-tier caching layer, and execution runner for
  TypeSafe Jev (`SystemOneSDK`) semantic contracts.

  `JevDSL` compiles `%SystemOneSDK.Prepared{}` contracts at build time (`defnoul`,
  `defchoice`, `defscore`, `defjev`, `defalias`), caches rehydrated `Jason.Fragment`
  wire payloads in `:persistent_term` in O(1), provides deterministic SHA-256
  content-addressed L1/L2 caching (`JevDSL.Cache`), and generates `evaluate/3`,
  `evaluate!/3`, `evaluate_many/3`, `available?/2`, `cache_key/2`, `contract/1`,
  `prepared/1`, and `__export_cue__/0` directly on your contract module.

  Both atoms and strings are supported interchangeably for contract keys, question
  keys, stab-clause option keys, and answer lookups (`fetch_answer/2`, `choice?/2`,
  `probability/2`).

  ## Quick Start

      defmodule MyApp.TriageContracts do
        use JevDSL,
          otp_app: :my_app,
          cache: JevDSL.Cache.ETS

        defnoul :is_spam do
          "Does this message contain unsolicited promotional spam?"
        end

        defchoice :sentiment,
          ask: "Classify the overall tone of the message." do
          positive -> "Constructive, appreciative, or favorable tone."
          neutral -> "Factual or informational without strong emotion."
          negative -> "Critical, frustrated, or dissatisfied tone."
        end

        defscore :completeness,
          ask: "Rate how complete the submission is." do
          incomplete -> "Missing required identity or contact fields."
          partial -> "Core fields are present but optional context is missing."
          complete -> "All identity, contact, and biographical fields are populated."
        end

        defjev :ticket_triage do
          noul :requires_escalation do
            "Does this issue require immediate engineering escalation?"
          end

          choice :priority,
            ask: "Select the appropriate response priority." do
            urgent -> "Production outage or security incident."
            normal -> "Standard bug report or feature question."
          end

          score :clarity,
            ask: "Rate the clarity of the reproduction steps." do
            vague -> "No steps or environment details provided."
            clear -> "Includes clear steps and expected vs actual behavior."
          end
        end
      end

  ## Evaluating Contracts

      # Single evaluation (automatically cached by state + contract fingerprint)
      {:ok, response} = MyApp.TriageContracts.evaluate(:sentiment, %{text: "Great work!"})

      # Concurrent batch evaluation (resolves L1/L2 cache hits first, batches only misses)
      results = MyApp.TriageContracts.evaluate_many(:is_spam, [%{body: "a"}, %{body: "b"}])

      # Deterministic unit tests via 1-arity `:eval_fn` (or `:cache_only` / `SystemOneSDK.Test`)
      {:ok, mocked} =
        MyApp.TriageContracts.evaluate(:is_spam, %{body: "a"},
          eval_fn: fn _state -> {:ok, %{answers: %{is_spam: %{noul: 0.05}}}} end
        )
  """

  alias JevDSL.{Cache, Contract, CUE, Question, Runner}
  alias SystemOneSDK.Question, as: SDKQuestion

  @use_schema NimbleOptions.new!(
                otp_app: [
                  type: :atom,
                  doc: "OTP application atom used for reading runtime configuration."
                ],
                cache: [
                  type: :atom,
                  default: JevDSL.Cache.ETS,
                  doc: "L1 cache module implementing `JevDSL.Cache`."
                ],
                tier2_cache: [
                  type: :atom,
                  doc: "Optional persistent L2 cache module implementing `JevDSL.Cache`."
                ],
                use_tier2_cache: [
                  type: :boolean,
                  default: true,
                  doc: "Whether to read from `:tier2_cache` on L1 misses."
                ],
                persist_tier2: [
                  type: :boolean,
                  default: true,
                  doc: "Whether to write and backfill evaluations into `:tier2_cache`."
                ],
                min_confidence: [
                  type: :float,
                  default: 0.65,
                  doc: "Minimum confidence threshold (`0.0..1.0`) for full-TTL caching."
                ],
                cache_ttl: [
                  type: :pos_integer,
                  doc: "Default L1 cache TTL in seconds."
                ],
                ttl: [
                  type: :pos_integer,
                  doc: "Alias for `:cache_ttl` in seconds."
                ],
                keys: [
                  type: {:in, [:atoms, :strings]},
                  default: :atoms,
                  doc: "Default key representation (`:atoms` or `:strings`) for choice options."
                ],
                eval_fn_key: [
                  type: :atom,
                  default: :eval_fn,
                  doc: "Option key inspected for 1-arity test mock functions."
                ],
                api_key: [
                  type: :any,
                  doc: "Optional default API key."
                ],
                typesafe_api_key: [
                  type: :any,
                  doc: "Optional default TypeSafe API key."
                ],
                base_url: [
                  type: :any,
                  doc: "Optional default TypeSafe base URL."
                ],
                model: [
                  type: :any,
                  doc: "Optional default System One model identifier."
                ],
                max_concurrency: [
                  type: :pos_integer,
                  doc: "Default max concurrency for `evaluate_many/3`."
                ]
              )

  defmacro __using__(opts \\ []) do
    quote do
      import JevDSL
      alias JevDSL
      @jev_dsl_opts JevDSL.__validate_use_opts__!(unquote(opts))
      Module.register_attribute(__MODULE__, :jev_contracts, accumulate: true)
      Module.register_attribute(__MODULE__, :jev_aliases, accumulate: true)
      @before_compile JevDSL
    end
  end

  @doc false
  def __validate_use_opts__!(opts) do
    NimbleOptions.validate!(opts, @use_schema)
  end

  @doc """
  Defines a single-question Noul (boolean probability) contract (`SystemOneSDK.Question.Noul`).

  Supports a string block, `ask: "..."` option, or `true -> "..."` / `false -> "..."` stab clauses.
  """
  defmacro defnoul(name, opts_or_block \\ [], maybe_block \\ nil) do
    {opts, do_block} = normalize_macro_args(opts_or_block, maybe_block, __CALLER__)
    contract_atom = normalize_key_atom!(name, __CALLER__)
    q_name = normalize_key_atom!(Keyword.get(opts, :as, contract_atom), __CALLER__)
    {prompt, criteria} = parse_noul_definition(opts, do_block, __CALLER__)
    keys_mode = Keyword.get(opts, :keys)

    question_ast =
      quote do
        %Question{
          name: unquote(q_name),
          type: :noul,
          instructions: unquote(prompt),
          criteria: unquote(Macro.escape(criteria))
        }
      end

    quote do
      JevDSL.__register_contract__(
        __MODULE__,
        unquote(contract_atom),
        [unquote(question_ast)],
        unquote(keys_mode),
        unquote(__CALLER__.file),
        unquote(__CALLER__.line)
      )
    end
  end

  @doc """
  Defines a single-question Choice contract (`SystemOneSDK.Question.Choice`) using `key -> "description"` stab clauses.
  Preserves the exact declaration order of options.
  """
  defmacro defchoice(name, opts_or_block, maybe_block \\ nil) do
    {opts, do_block} = normalize_macro_args(opts_or_block, maybe_block, __CALLER__)
    contract_atom = normalize_key_atom!(name, __CALLER__)
    q_name = normalize_key_atom!(Keyword.get(opts, :as, contract_atom), __CALLER__)
    {parsed_inst, criteria_pairs} = parse_clause_block(do_block, opts[:ask], __CALLER__)
    keys_mode = Keyword.get(opts, :keys)

    question_ast =
      quote do
        %Question{
          name: unquote(q_name),
          type: :choice,
          keys: unquote(keys_mode),
          instructions: unquote(parsed_inst),
          criteria: unquote(Macro.escape(criteria_pairs))
        }
      end

    quote do
      JevDSL.__register_contract__(
        __MODULE__,
        unquote(contract_atom),
        [unquote(question_ast)],
        unquote(keys_mode),
        unquote(__CALLER__.file),
        unquote(__CALLER__.line)
      )
    end
  end

  @doc """
  Defines a single-question ordered Score contract (`SystemOneSDK.Question.Score`, 2..10 rubric levels)
  using `label -> "description"` stab clauses.
  """
  defmacro defscore(name, opts_or_block, maybe_block \\ nil) do
    {opts, do_block} = normalize_macro_args(opts_or_block, maybe_block, __CALLER__)
    contract_atom = normalize_key_atom!(name, __CALLER__)
    q_name = normalize_key_atom!(Keyword.get(opts, :as, contract_atom), __CALLER__)
    {parsed_inst, level_pairs} = parse_clause_block(do_block, opts[:ask], __CALLER__)
    keys_mode = Keyword.get(opts, :keys)

    question_ast =
      quote do
        %Question{
          name: unquote(q_name),
          type: :score,
          keys: unquote(keys_mode),
          instructions: unquote(parsed_inst),
          criteria: unquote(Macro.escape(level_pairs))
        }
      end

    quote do
      JevDSL.__register_contract__(
        __MODULE__,
        unquote(contract_atom),
        [unquote(question_ast)],
        unquote(keys_mode),
        unquote(__CALLER__.file),
        unquote(__CALLER__.line)
      )
    end
  end

  @doc """
  Defines a multi-question contract combining `choice`, `noul`, and/or `score` sub-questions.
  """
  defmacro defjev(name, opts_or_block, maybe_block \\ nil) do
    {opts, block} = normalize_macro_args(opts_or_block, maybe_block, __CALLER__)
    contract_atom = normalize_key_atom!(name, __CALLER__)
    keys_mode = Keyword.get(opts, :keys)

    exprs =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    questions_ast = Enum.map(exprs, &compile_subquestion_ast(&1, __CALLER__))

    quote do
      JevDSL.__register_contract__(
        __MODULE__,
        unquote(contract_atom),
        unquote(questions_ast),
        unquote(keys_mode),
        unquote(__CALLER__.file),
        unquote(__CALLER__.line)
      )
    end
  end

  @doc """
  Aliases a secondary or legacy contract name (atom or string) to a canonical contract name.
  """
  defmacro defalias(alias_name, target_name) do
    alias_atom = normalize_key_atom!(alias_name, __CALLER__)
    target_atom = normalize_key_atom!(target_name, __CALLER__)

    quote do
      @jev_aliases {unquote(alias_atom), unquote(target_atom), unquote(__CALLER__.line)}
    end
  end

  defp normalize_macro_args([do: block], nil, _caller), do: {[], block}

  defp normalize_macro_args(opts, [do: block], _caller) when is_list(opts), do: {opts, block}

  defp normalize_macro_args(opts, nil, _caller) when is_list(opts) do
    {Keyword.delete(opts, :do), Keyword.get(opts, :do)}
  end

  defp normalize_macro_args(other, maybe_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "Invalid contract definition arguments: #{inspect({other, maybe_block})}"
  end

  defp normalize_key_atom!(name, _caller) when is_atom(name) and not is_nil(name), do: name

  defp normalize_key_atom!(name, caller) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "Contract and question names cannot be blank strings"
    else
      String.to_atom(trimmed)
    end
  end

  defp normalize_key_atom!(other, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Expected an atom or string for contract/question name, got: #{Macro.to_string(other)}"
  end

  defp compile_subquestion_ast({:choice, meta, [q_name, [do: q_block]]}, caller) do
    compile_subquestion_ast({:choice, meta, [q_name, [], [do: q_block]]}, caller)
  end

  defp compile_subquestion_ast({:choice, _, [q_name, opts, [do: q_block]]}, caller)
       when is_list(opts) do
    q_atom = normalize_key_atom!(Keyword.get(opts, :as, q_name), caller)
    {parsed_inst, criteria_pairs} = parse_clause_block(q_block, opts[:ask], caller)
    q_keys = Keyword.get(opts, :keys)

    quote do
      %Question{
        name: unquote(q_atom),
        type: :choice,
        instructions: unquote(parsed_inst),
        criteria: unquote(Macro.escape(criteria_pairs)),
        keys: unquote(q_keys)
      }
    end
  end

  defp compile_subquestion_ast({:score, meta, [q_name, [do: q_block]]}, caller) do
    compile_subquestion_ast({:score, meta, [q_name, [], [do: q_block]]}, caller)
  end

  defp compile_subquestion_ast({:score, _, [q_name, opts, [do: q_block]]}, caller)
       when is_list(opts) do
    q_atom = normalize_key_atom!(Keyword.get(opts, :as, q_name), caller)
    {parsed_inst, level_pairs} = parse_clause_block(q_block, opts[:ask], caller)
    q_keys = Keyword.get(opts, :keys)

    quote do
      %Question{
        name: unquote(q_atom),
        type: :score,
        instructions: unquote(parsed_inst),
        criteria: unquote(Macro.escape(level_pairs)),
        keys: unquote(q_keys)
      }
    end
  end

  defp compile_subquestion_ast({:noul, _, [q_name, [do: noul_block]]}, caller) do
    q_atom = normalize_key_atom!(q_name, caller)
    {prompt, criteria} = parse_noul_definition([], noul_block, caller)

    quote do
      %Question{
        name: unquote(q_atom),
        type: :noul,
        instructions: unquote(prompt),
        criteria: unquote(Macro.escape(criteria))
      }
    end
  end

  defp compile_subquestion_ast({:noul, _, [q_name, opts, [do: noul_block]]}, caller)
       when is_list(opts) do
    q_atom = normalize_key_atom!(Keyword.get(opts, :as, q_name), caller)
    {prompt, criteria} = parse_noul_definition(opts, noul_block, caller)

    quote do
      %Question{
        name: unquote(q_atom),
        type: :noul,
        instructions: unquote(prompt),
        criteria: unquote(Macro.escape(criteria))
      }
    end
  end

  defp compile_subquestion_ast({:noul, _, [q_name, opts]}, caller) when is_list(opts) do
    q_atom = normalize_key_atom!(Keyword.get(opts, :as, q_name), caller)
    {prompt, criteria} = parse_noul_definition(opts, nil, caller)

    quote do
      %Question{
        name: unquote(q_atom),
        type: :noul,
        instructions: unquote(prompt),
        criteria: unquote(Macro.escape(criteria))
      }
    end
  end

  defp compile_subquestion_ast(other_ast, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Unsupported expression inside defjev block. Expected `choice`, `noul`, or `score`, got: #{Macro.to_string(other_ast)}"
  end

  defp parse_noul_definition(opts, do_block, caller) do
    ask = Keyword.get(opts, :ask)

    cond do
      is_list(do_block) ->
        {parsed_inst, pairs} = parse_clause_block(do_block, ask, caller)
        {parsed_inst, pairs}

      not is_nil(do_block) ->
        {extract_text(do_block, caller), %{}}

      is_binary(ask) ->
        {String.trim(ask), %{}}

      true ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "defnoul/noul requires either a prompt `do` block or `ask: \"...\"` option"
    end
  end

  @doc false
  def __register_contract__(mod, name, questions, override_keys_mode, file, line) do
    existing = Module.get_attribute(mod, :jev_contracts) || []

    if List.keymember?(existing, name, 0) do
      raise CompileError,
        file: file,
        line: line,
        description: "Duplicate JevDSL contract #{inspect(name)} defined in #{inspect(mod)}"
    end

    dsl_opts = Module.get_attribute(mod, :jev_dsl_opts) || []
    default_keys_mode = override_keys_mode || Keyword.get(dsl_opts, :keys, :atoms)

    prepared_kw =
      try do
        Enum.map(questions, fn q ->
          __build_sdk_question__(q, q.keys || default_keys_mode)
        end)
      rescue
        err in [SystemOneSDK.Error] ->
          reraise CompileError.exception(
                    file: file,
                    line: line,
                    description: Exception.message(err)
                  ),
                  __STACKTRACE__
      end

    prepared =
      case SystemOneSDK.prepare(prepared_kw) do
        {:ok, prep} ->
          prep

        {:error, %SystemOneSDK.Error{message: msg}} ->
          raise CompileError, file: file, line: line, description: msg
      end

    contract = %Contract{
      name: name,
      questions: questions,
      prepared: %{prepared | encoded: nil}
    }

    Module.put_attribute(mod, :jev_contracts, {name, contract})
  end

  @doc false
  def __build_sdk_question__(question, keys_mode \\ :atoms)

  def __build_sdk_question__(%Question{type: :choice} = q, keys_mode) do
    pairs =
      Enum.map(q.criteria, fn {k, v} ->
        key =
          case keys_mode do
            :strings -> to_string(k)
            _ when is_atom(k) -> k
            _ when is_binary(k) -> String.to_atom(k)
          end

        {key, v}
      end)

    inst = normalize_optional_instructions(q.instructions)
    {q.name, SDKQuestion.Choice.new!(inst, pairs)}
  end

  def __build_sdk_question__(%Question{type: :score} = q, _keys_mode) do
    levels = Enum.map(q.criteria, fn {k, v} -> {to_string(k), v} end)
    inst = normalize_optional_instructions(q.instructions)
    {q.name, SDKQuestion.Score.new!(inst, levels)}
  end

  def __build_sdk_question__(%Question{type: :noul} = q, _keys_mode) do
    inst = normalize_optional_instructions(q.instructions)

    case q.criteria do
      criteria when criteria in [%{}, [], nil] ->
        {q.name, SDKQuestion.Noul.new!(inst)}

      pairs when is_list(pairs) ->
        {q.name, SDKQuestion.Noul.new!(inst, criteria: pairs)}

      map when is_map(map) ->
        {q.name, SDKQuestion.Noul.new!(inst, criteria: Map.to_list(map))}
    end
  end

  defp normalize_optional_instructions(""), do: nil
  defp normalize_optional_instructions(inst), do: inst

  defp extract_text(text, _caller) when is_binary(text), do: String.trim(text)
  defp extract_text({:__block__, _, [text]}, _caller) when is_binary(text), do: String.trim(text)

  defp extract_text(other, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Expected a string literal prompt in noul block, got: #{Macro.to_string(other)}"
  end

  defp parse_clause_block(block, explicit_inst, caller) when is_list(block) do
    pairs =
      Enum.map(block, fn
        {:->, _, [[{:__aliases__, _, parts}], desc]}
        when is_list(parts) and is_binary(desc) ->
          key_str = Enum.map_join(parts, ".", &Atom.to_string/1)
          {normalize_key_atom!(key_str, caller), String.trim(desc)}

        {:->, _, [[{key_atom, _, ctx}], desc]}
        when is_atom(key_atom) and is_atom(ctx) and is_binary(desc) ->
          {key_atom, String.trim(desc)}

        {:->, _, [[key_atom], desc]}
        when is_atom(key_atom) and is_binary(desc) ->
          {key_atom, String.trim(desc)}

        {:->, _, [[key_str], desc]}
        when is_binary(key_str) and is_binary(desc) ->
          {normalize_key_atom!(key_str, caller), String.trim(desc)}

        other ->
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description:
              "Expected `option_name -> \"description\"` clause, got: #{Macro.to_string(other)}"
      end)

    inst =
      case explicit_inst do
        nil -> nil
        str when is_binary(str) -> String.trim(str)
        other -> other
      end

    {inst, pairs}
  end

  defp parse_clause_block(other, _explicit_inst, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Expected `option_name -> \"description\"` stab clauses in `do` block, got: #{Macro.to_string(other)}"
  end

  @doc """
  Fetches an answer from a `%SystemOneSDK.SystemOneResponse{}` (or map with `:answers`),
  matching `key` whether passed as an atom or a string.

  ## Examples

      iex> resp = %{answers: %{tone: %{choice: "positive"}}}
      iex> JevDSL.fetch_answer(resp, :tone)
      {:ok, %{choice: "positive"}}
      iex> JevDSL.fetch_answer(resp, "tone")
      {:ok, %{choice: "positive"}}
      iex> JevDSL.fetch_answer(resp, :missing)
      :error
  """
  @spec fetch_answer(SystemOneSDK.SystemOneResponse.t() | map(), atom() | String.t()) ::
          {:ok, term()} | :error
  def fetch_answer(%{answers: answers}, key)
      when is_map(answers) and (is_atom(key) or is_binary(key)) do
    fetch_dual_key(answers, key)
  end

  def fetch_answer(_, _), do: :error

  @doc """
  Fetches an answer by atom or string `key`, raising `KeyError` if not present.
  """
  @spec fetch_answer!(SystemOneSDK.SystemOneResponse.t() | map(), atom() | String.t()) :: term()
  def fetch_answer!(%{answers: answers} = response, key) do
    case fetch_answer(response, key) do
      {:ok, answer} ->
        answer

      :error ->
        raise KeyError,
          key: key,
          term: answers,
          message:
            "no JevDSL answer for #{inspect(key)}; available keys: #{inspect(Map.keys(answers))}"
    end
  end

  @doc """
  Returns `true` if a `ChoiceAnswer` (or choice value) selected `expected_option`,
  comparing atoms and strings equivalently.

  ## Examples

      iex> ans = %SystemOneSDK.ChoiceAnswer{choice: "positive", confidence: 0.9, probabilities: %{"positive" => 0.9}}
      iex> JevDSL.choice?(ans, :positive)
      true
      iex> JevDSL.choice?(ans, "positive")
      true
      iex> JevDSL.choice?(ans, :negative)
      false
  """
  @spec choice?(SystemOneSDK.ChoiceAnswer.t() | map() | atom() | String.t(), atom() | String.t()) ::
          boolean()
  def choice?(%{choice: choice}, expected)
      when (is_atom(choice) or is_binary(choice)) and (is_atom(expected) or is_binary(expected)) do
    to_string(choice) == to_string(expected)
  end

  def choice?(choice, expected)
      when (is_atom(choice) or is_binary(choice)) and (is_atom(expected) or is_binary(expected)) do
    to_string(choice) == to_string(expected)
  end

  def choice?(_, _), do: false

  @doc """
  Fetches the probability for `option_key` (atom or string) from a `ChoiceAnswer` or probability map.

  ## Examples

      iex> ans = %SystemOneSDK.ChoiceAnswer{choice: "positive", confidence: 0.9, probabilities: %{"positive" => 0.9, "neutral" => 0.1}}
      iex> JevDSL.probability(ans, :positive)
      {:ok, 0.9}
      iex> JevDSL.probability(ans, "neutral")
      {:ok, 0.1}
  """
  @spec probability(SystemOneSDK.ChoiceAnswer.t() | map(), atom() | String.t()) ::
          {:ok, number()} | :error
  def probability(%{probabilities: probs}, option_key)
      when is_map(probs) and (is_atom(option_key) or is_binary(option_key)) do
    fetch_dual_key(probs, option_key)
  end

  def probability(%{} = probs, option_key)
      when is_atom(option_key) or is_binary(option_key) do
    fetch_dual_key(probs, option_key)
  end

  def probability(_, _), do: :error

  defp fetch_dual_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> {:ok, val}
      :error -> find_by_string_key(map, to_string(key))
    end
  end

  defp find_by_string_key(map, target_str) do
    case Enum.find(map, fn {k, _v} -> to_string(k) == target_str end) do
      {_k, v} -> {:ok, v}
      nil -> :error
    end
  end

  @doc """
  Rehydrates and caches the `Jason.Fragment` wire encoder on a compile-time `%SystemOneSDK.Prepared{}` struct.
  """
  @spec hydrate_prepared(SystemOneSDK.Prepared.t()) :: SystemOneSDK.Prepared.t()
  def hydrate_prepared(%SystemOneSDK.Prepared{json: json, fingerprint: fp} = prep) do
    pt_key = {__MODULE__, :hydrated_prepared, fp}

    case :persistent_term.get(pt_key, nil) do
      %SystemOneSDK.Prepared{} = cached ->
        cached

      nil ->
        hydrated = %{prep | encoded: Jason.Fragment.new(json)}
        :persistent_term.put(pt_key, hydrated)
        hydrated
    end
  end

  @doc """
  Exports compiled Jev contracts into a CUE schema document.
  """
  @spec export_cue(%{optional(atom() | String.t()) => Contract.t() | map()}) :: String.t()
  defdelegate export_cue(contracts_map), to: CUE, as: :export

  @doc false
  def hydrate_contracts_map(compiled_by_atom) do
    Map.new(compiled_by_atom, fn {k, v} ->
      {k, %{v | prepared: hydrate_prepared(v.prepared)}}
    end)
  end

  @doc false
  def fetch_contract(compiled_by_atom, _compiled_by_string, key) when is_atom(key) do
    case Map.fetch(compiled_by_atom, key) do
      {:ok, contract} -> {:ok, %{contract | prepared: hydrate_prepared(contract.prepared)}}
      :error -> :error
    end
  end

  def fetch_contract(_compiled_by_atom, compiled_by_string, key) when is_binary(key) do
    case Map.fetch(compiled_by_string, key) do
      {:ok, contract} -> {:ok, %{contract | prepared: hydrate_prepared(contract.prepared)}}
      :error -> :error
    end
  end

  def fetch_contract(_compiled_by_atom, _compiled_by_string, _key), do: :error

  @doc false
  def fetch_prepared(compiled_by_atom, _compiled_by_string, key) when is_atom(key) do
    compiled_by_atom
    |> Map.fetch!(key)
    |> Map.fetch!(:prepared)
    |> hydrate_prepared()
  end

  def fetch_prepared(_compiled_by_atom, compiled_by_string, key) when is_binary(key) do
    compiled_by_string
    |> Map.fetch!(key)
    |> Map.fetch!(:prepared)
    |> hydrate_prepared()
  end

  @doc false
  def contract_exists?(compiled_by_atom, _compiled_by_string, key) when is_atom(key),
    do: Map.has_key?(compiled_by_atom, key)

  def contract_exists?(_compiled_by_atom, compiled_by_string, key) when is_binary(key),
    do: Map.has_key?(compiled_by_string, key)

  def contract_exists?(_compiled_by_atom, _compiled_by_string, _key), do: false

  @doc false
  def lookup_contract_fingerprint(compiled_by_atom, _compiled_by_string, key) when is_atom(key) do
    extract_fingerprint(Map.get(compiled_by_atom, key))
  end

  def lookup_contract_fingerprint(_compiled_by_atom, compiled_by_string, key)
      when is_binary(key) do
    extract_fingerprint(Map.get(compiled_by_string, key))
  end

  def lookup_contract_fingerprint(_compiled_by_atom, _compiled_by_string, _key), do: :error

  defp extract_fingerprint(%{prepared: %SystemOneSDK.Prepared{fingerprint: fp}})
       when is_binary(fp),
       do: {:ok, fp}

  defp extract_fingerprint(_), do: :error

  defmacro __before_compile__(env) do
    merged = merge_compiled_contracts!(env)
    by_string = Map.new(merged, fn {k, v} -> {Atom.to_string(k), v} end)

    quote do
      unquote(quote_introspection_api(merged, by_string))
      unquote(quote_runner_api(env.module))
    end
  end

  defp quote_introspection_api(merged, by_string) do
    quote do
      @compiled_by_atom unquote(Macro.escape(merged))
      @compiled_by_string unquote(Macro.escape(by_string))

      @doc false
      @spec __jev_dsl_opts__() :: keyword()
      def __jev_dsl_opts__, do: @jev_dsl_opts

      @doc "Returns a map of all compiled `%JevDSL.Contract{}` definitions keyed by contract atom."
      @spec __contracts__() :: %{optional(atom()) => JevDSL.Contract.t()}
      def __contracts__ do
        unquote(__MODULE__).hydrate_contracts_map(@compiled_by_atom)
      end

      @doc "Fetches the compiled `%JevDSL.Contract{}` for `key` (atom or string)."
      @spec contract(atom() | String.t()) :: {:ok, JevDSL.Contract.t()} | :error
      def contract(key) do
        unquote(__MODULE__).fetch_contract(@compiled_by_atom, @compiled_by_string, key)
      end

      @doc "Exports all compiled contracts in this module to a deterministic CUE schema string."
      @spec __export_cue__() :: String.t()
      def __export_cue__, do: CUE.export(@compiled_by_atom)

      @doc "Returns the hydrated `%SystemOneSDK.Prepared{}` struct for `key` (atom or string)."
      @spec prepared(atom() | String.t()) :: SystemOneSDK.Prepared.t()
      def prepared(key) do
        unquote(__MODULE__).fetch_prepared(@compiled_by_atom, @compiled_by_string, key)
      end

      @doc "Returns `true` if `key` (atom or string) is a defined or aliased contract."
      @spec has_contract?(term()) :: boolean()
      def has_contract?(key) do
        unquote(__MODULE__).contract_exists?(@compiled_by_atom, @compiled_by_string, key)
      end

      @doc "Returns `{:ok, fingerprint}` for `key` (atom or string), or `:error` if the contract does not exist."
      @spec contract_fingerprint(term()) :: {:ok, String.t()} | :error
      def contract_fingerprint(key) do
        unquote(__MODULE__).lookup_contract_fingerprint(
          @compiled_by_atom,
          @compiled_by_string,
          key
        )
      end
    end
  end

  defp quote_runner_api(mod) do
    [
      maybe_quote_cache_key(mod),
      maybe_quote_available(mod),
      maybe_quote_evaluate(mod),
      maybe_quote_evaluate_bang(mod),
      maybe_quote_evaluate_many(mod)
    ]
  end

  defp maybe_quote_cache_key(mod) do
    unless Module.defines?(mod, {:cache_key, 2}) do
      quote do
        @doc "Computes the deterministic SHA-256 cache key (`\"jev_<sha256>\"`) for `key` (atom or string) and `state`."
        @spec cache_key(atom() | String.t(), term()) :: String.t()
        def cache_key(key, state), do: Cache.key(state, prepared(key))

        defoverridable cache_key: 2
      end
    end
  end

  defp maybe_quote_available(mod) do
    unless Module.defines?(mod, {:available?, 2}) do
      quote do
        @doc "Returns `true` if this contract module can evaluate contracts (via mock, client, API key, or Tier-2 cache)."
        @spec available?(keyword(), atom()) :: boolean()
        def available?(opts \\ [], eval_fn_key \\ :eval_fn) do
          Runner.available?(__MODULE__, opts, eval_fn_key)
        end

        defoverridable available?: 0, available?: 1, available?: 2
      end
    end
  end

  defp maybe_quote_evaluate(mod) do
    unless Module.defines?(mod, {:evaluate, 3}) do
      quote do
        @doc "Evaluates `state` against `key` (atom or string) with automatic L1/L2 caching and mock support."
        @spec evaluate(atom() | String.t(), map(), keyword()) ::
                {:ok, SystemOneSDK.SystemOneResponse.t() | map()} | {:error, term()}
        def evaluate(key, state, opts \\ []), do: Runner.evaluate(__MODULE__, key, state, opts)

        defoverridable evaluate: 2, evaluate: 3
      end
    end
  end

  defp maybe_quote_evaluate_bang(mod) do
    unless Module.defines?(mod, {:evaluate!, 3}) do
      quote do
        @doc "Evaluates `state` against `key` (atom or string) or raises `JevDSL.Error` / `SystemOneSDK.Error`."
        @spec evaluate!(atom() | String.t(), map(), keyword()) ::
                SystemOneSDK.SystemOneResponse.t() | map()
        def evaluate!(key, state, opts \\ []),
          do: Runner.evaluate!(__MODULE__, key, state, opts)

        defoverridable evaluate!: 2, evaluate!: 3
      end
    end
  end

  defp maybe_quote_evaluate_many(mod) do
    unless Module.defines?(mod, {:evaluate_many, 3}) do
      quote do
        @doc "Evaluates `states` concurrently against `key` (atom or string) with L1/L2 caching and batching."
        @spec evaluate_many(atom() | String.t(), [map()], keyword()) ::
                [{:ok, SystemOneSDK.SystemOneResponse.t() | map()} | {:error, term()}]
        def evaluate_many(key, states, opts \\ []),
          do: Runner.evaluate_many(__MODULE__, key, states, opts)

        defoverridable evaluate_many: 2, evaluate_many: 3
      end
    end
  end

  defp merge_compiled_contracts!(env) do
    contracts =
      env.module
      |> Module.get_attribute(:jev_contracts)
      |> Enum.reverse()
      |> Map.new()

    aliases =
      env.module
      |> Module.get_attribute(:jev_aliases)
      |> Enum.reverse()

    Enum.reduce(aliases, contracts, fn {alias_k, target_k, line}, acc ->
      cond do
        Map.has_key?(acc, alias_k) ->
          raise CompileError,
            file: env.file,
            line: line,
            description:
              "defalias #{inspect(alias_k)} conflicts with an existing contract or alias in #{inspect(env.module)}"

        not Map.has_key?(contracts, target_k) ->
          raise CompileError,
            file: env.file,
            line: line,
            description:
              "defalias #{inspect(alias_k)} references unknown contract #{inspect(target_k)}"

        true ->
          Map.put(acc, alias_k, Map.fetch!(contracts, target_k))
      end
    end)
  end
end
