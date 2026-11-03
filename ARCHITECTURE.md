# ARCHITECTURE.md — current state

This document describes the Maat system as it exists now. Update it when the code changes. It does not describe plans.

## What exists now

The engine core (milestone M0) is implemented and green. No HTTP API, no SQLite driver, no executor bridge yet.

```
maat/
├── SPECIFICATION.md        # design contract (v0.3)
├── AGENTS.md               # entry point for agents
├── ARCHITECTURE.md         # this file
├── STATUS.md               # current todos
├── DECISIONS.md            # durable decision record
├── justfile                # command runner for build/test/lint/run
├── mix.exs                 # app :maat, deps per SPECIFICATION.md section 12
├── config/config.exs       # runtime config; test overrides under `if Mix.env() == :test`
├── schemas/                # graph.schema.json, manifest.schema.json, codes.json (draft-07)
├── lib/maat.ex             # public API: start_instance, get_instance, signal, result, events
├── lib/maat/
│   ├── application.ex      # supervision tree
│   ├── canonical.ex        # canonical JSON: sorted keys, integers or decimal strings, no floats
│   ├── clock.ex            # clock behaviour + System impl (fake clock in test/support)
│   ├── codes.ex            # diagnostic codes from schemas/codes.json
│   ├── schemas.ex          # loads schema files
│   ├── storage.ex          # the storage behaviour (Maat.Storage)
│   ├── storage/memory.ex   # memory driver: fencing-token leases, CAS on version, kill switch
│   ├── graph/
│   │   ├── admission.ex    # JSON Schema validation + lint, 3xxx codes
│   │   └── registry.ex     # content-addressed graph registry ("b" <> sha256)
│   └── engine/
│       ├── interpreter.ex  # pure decision function: (graph, state, event) -> {state', actions}
│       ├── instance.ex     # GenServer per instance key; decide -> CAS persist -> execute actions
│       ├── supervisor.ex   # DynamicSupervisor for instance processes
│       ├── sweeper.ex      # scans the event trail for due timers, wakes instances
│       └── lease.ex        # fencing lease wrapper
└── test/                   # unit tests + property suites (StreamData)
```

## Command runner

All build, test, lint, and run commands go through `just` (the `justfile`). Humans and agents run `just <command>`; nothing calls `mix` directly.

## Data flow

`event -> Instance -> Interpreter.decide (pure) -> storage.put (compare-and-swap on version) -> append to event trail -> execute actions (dispatched / timer / emit / enqueue / terminal)`.

Crash recovery: the supervisor restarts the instance process, which re-reads state from storage and re-derives pending actions with a `{:resume, now}` event. A writer that lost its lease is fenced by the version check (4001) on its next write.

## Design contract

`SPECIFICATION.md` holds the design contract: the intended architecture, the five primitives, the executor contract, and the execution semantics. This file does not repeat that design. It records what is implemented, and it changes when the implementation changes.

## Version control

This is a git repository. The user controls git. Agents run no git operations unless the user explicitly asks; see the Git rules in `AGENTS.md`.
