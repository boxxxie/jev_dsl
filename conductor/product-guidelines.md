# Product Guidelines: JevDSL

## API & DSL Design Principles
- **Compile-Time Feedback:** Fail fast during compilation (`CompileError` with accurate file/line metadata) for invalid contract schemas, duplicate names, or unsupported options.
- **Explicit & Idiomatic Elixir:** Return `{:ok, result}` / `{:error, reason}` tuples for fallible operations, with `!` variants (`evaluate!/3`) raising `JevDSL.Error` or structured exceptions.
- **Predictable Atom Keys:** Compile declared choice/score keys to atoms in declaration order so callers can pattern match directly; accept both atoms and strings in lookup helpers.
- **Zero-Surprise Defaults:** Keep runtime dependencies minimal and optional integrations (e.g., Igniter) cleanly isolated.

## Documentation & Messaging Style
- **Concise & Example-Driven:** Document every public module and function with `@moduledoc` / `@doc`, `@spec` typespecs, and runnable-style examples.
- **Usage Rules:** Keep `usage-rules.md` aligned with DSL and backend conventions for both human developers and AI agents.
- **Clear Error Diagnostics:** Actionable error messages that name the contract, field, and expected shape.

## Quality & Reliability Standards
- **Deterministic Testing:** Support offline/stubbed testing without live network calls by default; isolate live integration tests behind ExUnit tags.
- **Strict Static Checks:** Maintain clean `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and Dialyzer compliance (`mix precommit`).
