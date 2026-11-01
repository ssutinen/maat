# ARCHITECTURE.md — current state

This document describes the Maat system as it exists now. Update it when the code changes. It does not describe plans.

## What exists now

The repository holds the design contract and the working setup. No engine code exists yet.

```
maat/
├── SPECIFICATION.md   # design contract (sections 1-14)
├── AGENTS.md          # entry point for agents
├── ARCHITECTURE.md    # this file
├── STATUS.md          # current todos
├── DECISIONS.md       # durable decision record
├── justfile           # command runner for build/test/lint/run
└── .gitignore         # build artifacts
```

## Version control

This is a git repository. The user controls git. Agents run no git operations unless the user explicitly asks; see the Git rules in `AGENTS.md`.

## Command runner

All build, test, lint, and run commands go through `just` (the `justfile`). Humans and agents run `just <command>`; nothing calls `mix` directly.

## Design contract

`SPECIFICATION.md` holds the design contract: the intended architecture, the five primitives, the executor contract, and the execution semantics. This file does not repeat that design. It records what is implemented, and it changes when the implementation changes.
