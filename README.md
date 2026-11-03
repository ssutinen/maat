# Maat

Maat is a durable execution engine for agent-authored workflows. It runs
declarative workflow graphs (JSON) reliably: it survives crashes, retries
failures, waits for signals or absolute deadlines, and resumes without loss.

The engine is an interpreter over persisted state, not code with replay. Node
code runs in external executors (WASM, containers, processes) that honor one
invocation contract. The engine never executes agent code itself.

The full design contract is [SPECIFICATION.md](SPECIFICATION.md).

## Status

Milestone M0 (core semantics) is implemented and green: canonical JSON, the
storage behaviour with an in-memory driver, the pure interpreter, admission
lint, and property-based test suites. The HTTP API, the SQLite driver, and the
executor bridge come next.

## Requirements

- Elixir >= 1.20 on Erlang/OTP 27+
- [just](https://just.systems) — every build, test, lint, and run command goes through it

## Quick start

```sh
just setup          # install Hex/Rebar and fetch dependencies
just test           # run the test suite
just test-property  # run only the property-based suites
just lint           # check formatting and compiler warnings
just check          # lint, then test
just                # list all commands
```

## Repository map

| Path | What it is |
|---|---|
| `SPECIFICATION.md` | The design contract: architecture, primitives, executor contract, semantics, milestones. |
| `justfile` | The command runner. |
| `schemas/` | JSON Schema contract files (graph, node manifest, diagnostic codes). |
| `lib/` | The engine code. |
| `test/` | Unit tests and property suites. |
| `ARCHITECTURE.md` | The implemented system, as it is now. |
| `STATUS.md` | Current todo items. |
| `DECISIONS.md` | Append-only record of durable decisions. |
