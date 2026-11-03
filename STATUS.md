# STATUS.md — current todos

Last updated: 2026-11-01.

| ID | Todo | Status |
|---|---|---|
| T-01 | Set up the Elixir toolchain on Fedora Atomic (OTP 27+, Elixir >= 1.20), per-user without system layering | done |
| T-02 | Scaffold the `mix` project per SPECIFICATION.md section 12 (`mix.exs`, `lib/maat/` tree, `schemas/`) | done |
| T-03 | Milestone M0: schemas, memory driver, interpreter, admission lint, property tests green on crash-injected runs | done |
| T-04 | Milestone M1: SQLite driver, durable event trail, leases + fencing over SQLite, sweeper, restart recovery (kill -9 at random points, instances resume, no state divergence) | pending |

## Done

- Pre-M0 design gaps resolved and folded into SPECIFICATION.md v0.3 (DECISIONS.md D-009–D-016).
- T-01: toolchain verified present (Homebrew per-user: Elixir 1.20.5 on OTP 29, just 1.59.0). The user manages toolchain installs.
- T-02 + T-03: M0 implemented and green via `just lint` / `just test` / `just test-property` — 25 tests, 5 property suites (canonicalization round-trip, determinism, crash-injection convergence, fencing, timer durability).
