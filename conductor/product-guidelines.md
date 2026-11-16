# Product Guidelines: SystemOneDSL

## API & DSL Design Principles
- **Compile-Time Feedback:** Fail fast during compilation (`CompileError` with accurate file/line metadata) for invalid contract schemas, duplicate names, or unsupported options.
- **Explicit & Idiomatic Elixir:** Return `{:ok, result}` / `{:error, reason}` tuples for fallible operations, with `!` variants (`evaluate!/3`) raising `SystemOneDSL.Error` or structured exceptions.
- **Predictable Atom Keys:** Compile declared choice/score keys to atoms in declaration order so callers can pattern match directly; accept both atoms and strings in lookup helpers.
- **Zero-Surprise Defaults:** Keep runtime dependencies minimal and optional integrations (e.g., Igniter) cleanly isolated.

## Documentation & Messaging Style
- **Concise & Example-Driven:** Document every public module and function with `@moduledoc` / `@doc`, `@spec` typespecs, and runnable-style examples.
- **Usage Rules:** Keep `usage-rules.md` aligned with DSL and backend conventions for both human developers and AI agents.
- **Clear Error Diagnostics:** Actionable error messages that name the contract, field, and expected shape.

## Quality & Reliability Standards
- **4-Layer ATDD & Property-Based Testing:** Separate domain intent from wire/transport mechanics using 4-layer ATDD executable specifications for behavioral workflows, and use direct unit tests + `stream_data` (`ExUnitProperties`) invariants for codecs, schemas, and adapters.
- **Deterministic Testing:** Support offline/stubbed testing without live network calls by default (`async: true`); isolate live integration tests behind ExUnit tags (e.g., `@moduletag :live`).
- **Strict Static Checks:** Maintain clean `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and Dialyzer compliance (`mix precommit`).
