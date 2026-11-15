# Tech Stack: JevDSL

- **Language & Runtime:** Elixir (`~> 1.18`) on Erlang/OTP (`:logger`, `:crypto`, `:persistent_term`, ETS)
- **Architecture:** Single-package Mix library (`jev_dsl`)
- **Core Dependencies:**
  - `system_one_sdk` (`~> 0.6.0`) — TypeSafe Jev client, contract preparation, and transport stubs
  - `jason` (`~> 1.4`) — JSON encoding/decoding and `Jason.Fragment` pre-encoded payloads
  - `nimble_options` (`~> 1.1`) — Compile-time and runtime option validation
  - `telemetry` (`~> 1.3`) — Observability events for evaluation and cache hits/misses
  - `igniter` (`~> 0.8`, optional) — `mix jev_dsl.install` generator task
- **Caching:** Built-in ETS L1 cache (`JevDSL.Cache.ETS`) + pluggable `JevDSL.Cache` L2 behaviour
- **Testing & Quality:** ExUnit, `stream_data` (`~> 1.1`), `credo` (`~> 1.7`), `dialyxir` (`~> 1.4`), `ex_doc` (`~> 0.40`)
- **CI / Precommit Alias:** `mix precommit` (`format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `test`)
