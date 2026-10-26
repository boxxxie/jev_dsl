defmodule JevDSL do
  @moduledoc """
  Compile-time Elixir macro DSL, two-tier caching layer, and execution runner for
  TypeSafe Jev (`SystemOneSDK`) semantic contracts.

  `JevDSL` compiles `%SystemOneSDK.Prepared{}` contracts at build time (`defnoul`,
  `defchoice`, `defscore`, `defjev`, `defalias`), caches rehydrated `Jason.Fragment`
  wire payloads in `:persistent_term` in O(1), provides deterministic SHA-256
  content-addressed L1/L2 caching (`JevDSL.Cache`), and generates `evaluate/3`,
  `evaluate_many/3`, `available?/2`, `cache_key/2`, and `__export_cue__/0` directly
  on your contract module.

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

      # Deterministic unit tests via 1-arity `:eval_fn` (or `:cache_only` for offline fixtures)
      {:ok, mocked} =
        MyApp.TriageContracts.evaluate(:is_spam, %{body: "a"},
          eval_fn: fn _state -> {:ok, %{answers: %{is_spam: %{noul: 0.05}}}} end
        )
  """

  alias JevDSL.{Cache, Contract, CUE, Question, Runner}

  defmacro __using__(opts \\ []) do
    quote do
      import JevDSL
      alias JevDSL
      @jev_dsl_opts unquote(opts)
      Module.register_attribute(__MODULE__, :jev_contracts, accumulate: true)
      Module.register_attribute(__MODULE__, :jev_aliases, accumulate: true)
      @before_compile JevDSL
    end
  end

  @doc """
  Defines a single-question Noul (boolean probability) contract (`SystemOneSDK.Noul`).
  """
  defmacro defnoul(name, opts \\ [], do: prompt_block) when is_atom(name) do
    q_name = Keyword.get(opts, :as, name)
    prompt = extract_text(prompt_block)

    quote do
      prepared =
        SystemOneSDK.prepare!([
          {unquote(q_name), SystemOneSDK.Noul.new(instructions: unquote(prompt))}
        ])

      @jev_contracts {
        unquote(name),
        %Contract{
          name: unquote(name),
          questions: [
            %Question{
              name: unquote(q_name),
              type: :noul,
              instructions: unquote(prompt),
              criteria: %{}
            }
          ],
          prepared: %{prepared | encoded: nil}
        }
      }
    end
  end

  @doc """
  Defines a single-question Choice contract (`SystemOneSDK.Choice`) using `key -> "description"` stab clauses.
  """
  defmacro defchoice(name, opts \\ [], do: block) when is_atom(name) do
    q_name = Keyword.get(opts, :as, name)
    instructions = Keyword.get(opts, :ask)
    {parsed_inst, criteria_pairs} = parse_clause_block(block, instructions, __CALLER__)

    quote do
      criteria_map =
        Map.new(unquote(criteria_pairs), fn {k, v} -> {Atom.to_string(k), v} end)

      prepared =
        SystemOneSDK.prepare!([
          {unquote(q_name),
           SystemOneSDK.Choice.new(criteria_map, instructions: unquote(parsed_inst))}
        ])

      @jev_contracts {
        unquote(name),
        %Contract{
          name: unquote(name),
          questions: [
            %Question{
              name: unquote(q_name),
              type: :choice,
              instructions: unquote(parsed_inst),
              criteria: Map.new(unquote(criteria_pairs))
            }
          ],
          prepared: %{prepared | encoded: nil}
        }
      }
    end
  end

  @doc """
  Defines a single-question ordered Score contract (`SystemOneSDK.Score`, 2..10 rubric levels)
  using `label -> "description"` stab clauses.
  """
  defmacro defscore(name, opts \\ [], do: block) when is_atom(name) do
    q_name = Keyword.get(opts, :as, name)
    instructions = Keyword.get(opts, :ask)
    {parsed_inst, level_pairs} = parse_clause_block(block, instructions, __CALLER__)

    quote do
      levels =
        Enum.map(unquote(level_pairs), fn {k, v} -> {Atom.to_string(k), v} end)

      prepared =
        SystemOneSDK.prepare!([
          {unquote(q_name), SystemOneSDK.Score.new(levels, instructions: unquote(parsed_inst))}
        ])

      @jev_contracts {
        unquote(name),
        %Contract{
          name: unquote(name),
          questions: [
            %Question{
              name: unquote(q_name),
              type: :score,
              instructions: unquote(parsed_inst),
              criteria: unquote(level_pairs)
            }
          ],
          prepared: %{prepared | encoded: nil}
        }
      }
    end
  end

  @doc """
  Defines a multi-question contract combining `choice`, `noul`, and/or `score` sub-questions.
  """
  defmacro defjev(name, do: block) when is_atom(name) do
    exprs =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    questions_ast = Enum.map(exprs, &compile_subquestion_ast(&1, __CALLER__))

    quote do
      questions = unquote(questions_ast)

      prepared_kw = Enum.map(questions, &JevDSL.__build_sdk_question__/1)
      prepared = SystemOneSDK.prepare!(prepared_kw)

      @jev_contracts {
        unquote(name),
        %Contract{
          name: unquote(name),
          questions: questions,
          prepared: %{prepared | encoded: nil}
        }
      }
    end
  end

  @doc """
  Aliases a secondary or legacy contract name to a canonical contract atom.
  """
  defmacro defalias(alias_name, target_name) when is_atom(alias_name) and is_atom(target_name) do
    quote do
      @jev_aliases {unquote(alias_name), unquote(target_name)}
    end
  end

  defp compile_subquestion_ast({:choice, _, [q_name, opts, [do: q_block]]}, caller) do
    {parsed_inst, criteria_pairs} = parse_clause_block(q_block, opts[:ask], caller)

    quote do
      %Question{
        name: unquote(q_name),
        type: :choice,
        instructions: unquote(parsed_inst),
        criteria: Map.new(unquote(criteria_pairs))
      }
    end
  end

  defp compile_subquestion_ast({:score, _, [q_name, opts, [do: q_block]]}, caller) do
    {parsed_inst, level_pairs} = parse_clause_block(q_block, opts[:ask], caller)

    quote do
      %Question{
        name: unquote(q_name),
        type: :score,
        instructions: unquote(parsed_inst),
        criteria: unquote(level_pairs)
      }
    end
  end

  defp compile_subquestion_ast({:noul, _, [q_name, [do: noul_block]]}, _caller) do
    prompt = extract_text(noul_block)

    quote do
      %Question{
        name: unquote(q_name),
        type: :noul,
        instructions: unquote(prompt),
        criteria: %{}
      }
    end
  end

  defp compile_subquestion_ast({:noul, _, [q_name, opts]}, _caller) when is_list(opts) do
    prompt = String.trim(opts[:ask] || "")

    quote do
      %Question{
        name: unquote(q_name),
        type: :noul,
        instructions: unquote(prompt),
        criteria: %{}
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

  @doc false
  def __build_sdk_question__(%Question{type: :choice} = q) do
    criteria_str_map = Map.new(q.criteria, fn {k, v} -> {Atom.to_string(k), v} end)
    {q.name, SystemOneSDK.Choice.new(criteria_str_map, instructions: q.instructions)}
  end

  def __build_sdk_question__(%Question{type: :score} = q) do
    levels = Enum.map(q.criteria, fn {k, v} -> {Atom.to_string(k), v} end)
    {q.name, SystemOneSDK.Score.new(levels, instructions: q.instructions)}
  end

  def __build_sdk_question__(%Question{type: :noul} = q) do
    {q.name, SystemOneSDK.Noul.new(instructions: q.instructions)}
  end

  defp extract_text(text) when is_binary(text), do: String.trim(text)
  defp extract_text({:__block__, _, [text]}) when is_binary(text), do: String.trim(text)

  defp parse_clause_block(block, explicit_inst, caller) when is_list(block) do
    pairs =
      Enum.map(block, fn
        {:->, _, [[{key_atom, _, _}], desc]} when is_atom(key_atom) and is_binary(desc) ->
          {key_atom, String.trim(desc)}

        other ->
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description:
              "Expected `option_name -> \"description\"` clause, got: #{Macro.to_string(other)}"
      end)

    {String.trim(explicit_inst || ""), pairs}
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
  @spec export_cue(%{optional(atom()) => Contract.t() | map()}) :: String.t()
  defdelegate export_cue(contracts_map), to: CUE, as: :export

  @doc false
  def hydrate_contracts_map(compiled_by_atom) do
    Map.new(compiled_by_atom, fn {k, v} ->
      {k, %{v | prepared: hydrate_prepared(v.prepared)}}
    end)
  end

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
      def __jev_dsl_opts__, do: @jev_dsl_opts

      @doc "Returns a map of all compiled `%JevDSL.Contract{}` definitions keyed by contract atom."
      def __contracts__ do
        unquote(__MODULE__).hydrate_contracts_map(@compiled_by_atom)
      end

      @doc "Exports all compiled contracts in this module to a deterministic CUE schema string."
      def __export_cue__, do: CUE.export(@compiled_by_atom)

      @doc "Returns the hydrated `%SystemOneSDK.Prepared{}` struct for `key` (atom or string)."
      def prepared(key) do
        unquote(__MODULE__).fetch_prepared(@compiled_by_atom, @compiled_by_string, key)
      end

      @doc "Returns `true` if `key` (atom or string) is a defined or aliased contract."
      def has_contract?(key) do
        unquote(__MODULE__).contract_exists?(@compiled_by_atom, @compiled_by_string, key)
      end

      @doc "Returns `{:ok, fingerprint}` for `key`, or `:error` if the contract does not exist."
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
      maybe_quote_evaluate_many(mod)
    ]
  end

  defp maybe_quote_cache_key(mod) do
    unless Module.defines?(mod, {:cache_key, 2}) do
      quote do
        @doc "Computes the deterministic SHA-256 cache key (`\"jev_<sha256>\"`) for `key` and `state`."
        def cache_key(key, state), do: Cache.key(state, prepared(key))
      end
    end
  end

  defp maybe_quote_available(mod) do
    unless Module.defines?(mod, {:available?, 2}) do
      quote do
        @doc "Returns `true` if this contract module can evaluate contracts (via mock, API key, or Tier-2 cache)."
        def available?(opts \\ [], eval_fn_key \\ :eval_fn) do
          Runner.available?(__MODULE__, opts, eval_fn_key)
        end
      end
    end
  end

  defp maybe_quote_evaluate(mod) do
    unless Module.defines?(mod, {:evaluate, 3}) do
      quote do
        @doc "Evaluates `state` against `key` with automatic L1/L2 caching and mock support."
        def evaluate(key, state, opts \\ []), do: Runner.evaluate(__MODULE__, key, state, opts)
      end
    end
  end

  defp maybe_quote_evaluate_many(mod) do
    unless Module.defines?(mod, {:evaluate_many, 3}) do
      quote do
        @doc "Evaluates `states` concurrently against `key` with L1/L2 caching and batching."
        def evaluate_many(key, states, opts \\ []),
          do: Runner.evaluate_many(__MODULE__, key, states, opts)
      end
    end
  end

  defp merge_compiled_contracts!(env) do
    contracts = Module.get_attribute(env.module, :jev_contracts) |> Map.new()
    aliases = Module.get_attribute(env.module, :jev_aliases) |> Map.new()

    Enum.reduce(aliases, contracts, fn {alias_k, target_k}, acc ->
      case Map.fetch(contracts, target_k) do
        {:ok, target_contract} ->
          Map.put(acc, alias_k, target_contract)

        :error ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "defalias #{inspect(alias_k)} references unknown contract #{inspect(target_k)}"
      end
    end)
  end
end
