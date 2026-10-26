<!-- jev_dsl-start -->
## jev_dsl usage
_Compile-time contract DSL, two-tier content-addressed cache, and runner for TypeSafe Jev (`SystemOneSDK`)._

- Define all TypeSafe Jev (`SystemOneSDK`) contracts at compile time using `use JevDSL` rather than building runtime maps or loading `.json` prompt files.
- Add `:jev_dsl` to `import_deps` in `.formatter.exs` so `defnoul`, `defchoice`, `defscore`, `defjev`, and `defalias` format cleanly without parentheses.
- Use the four contract macros according to judgment shape:
  - `defnoul :key do "Prompt" end` — single boolean probability (`0.0..1.0`).
  - `defchoice :key, ask: "Prompt" do opt_a -> "Criteria A"; opt_b -> "Criteria B" end` — mutually exclusive classification (`>= 2` options).
  - `defscore :key, ask: "Prompt" do low -> "Criteria"; high -> "Criteria" end` — ordered rubric grading scale (`>= 2` levels).
  - `defjev :key do ... end` — multi-question bundle combining `noul`, `choice`, and `score` in a single request.
- Call `MyContracts.evaluate(contract_key, state, opts)` for single evaluations and `MyContracts.evaluate_many(contract_key, states, opts)` for concurrent batches.
- Never manually hash state maps without including the contract fingerprint; always use `MyContracts.cache_key(contract_key, state)` or `JevDSL.Cache.key(state, prepared)` so prompt/rubric changes automatically invalidate cached judgments.
- In unit tests, pass `eval_fn: fn state -> {:ok, ...} end` or `cache_only: true` in `opts` for deterministic, zero-network execution.
<!-- jev_dsl-end -->
