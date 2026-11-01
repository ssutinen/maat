# AGENTS.md — Maat

This file is the entry point for agents working in this repository. Keep it small. It points to the documents that hold the details.

## Documentation map

| File | Purpose |
|---|---|
| `ARCHITECTURE.md` | The system as it exists now. Current state only. |
| `STATUS.md` | The work in progress now. Current todos only. |
| `DECISIONS.md` | Durable record of decisions. Append-only. |
| `plans/` | Self-contained plan documents. Write a plan, execute it, then delete the file. |
| `SPECIFICATION.md` | The design contract for the project. Read it before changing the engine. |

## Working rules

1. Run every build, test, lint, and run command through `just` (see `justfile`). Do not call `mix` or other project tools directly.
2. Documentation and code comments describe current state only. Do not write about past architecture or future plans in docs or comments. Plans live in `plans/` and are deleted once executed.
3. All documentation conforms to ISO 24495-1:2023 (plain language). Put the reader first: short sentences, active voice, common words, terms defined on first use, headings and lists for structure.

## Git

- Do not run git operations — no commits, pushes, merges, rebases, resets, cleans, or stash operations — unless the user explicitly asks in this session.
- If the user asks for a push, state the branch. Never force-push to `main`, `master`, or `release/*`; use `--force-with-lease` only after explicit approval.

## Commands

Run `just` with no arguments to list all commands.

| Command | What it does |
|---|---|
| `just setup` | Install Hex/Rebar and fetch dependencies |
| `just compile` | Compile the project |
| `just test` | Run the test suite |
| `just lint` | Check formatting and compiler warnings |
| `just run` | Run the application |
| `just ui` | Start the human UI (when the `maat_ui` package exists) |
| `just check` | Lint, then test |
