# cmux home

`cmux home` is a shared prototype for an Agent View style home screen inside cmux. It tracks local agent sessions, groups them by attention state, and gives each implementation the same JSON contract to render.

This directory is intentionally outside the Swift runtime. Rust, Go, and TypeScript prototypes should consume the same state shape, adapter matrix, and smoke fixtures here.

## Goals

- Show sessions that are awaiting input, actively working, or completed.
- Resume a native agent session without inventing a cmux-only session model.
- Jump back to the workspace and surface where the agent is running.
- Keep the view customizable without binding customization to one implementation.
- Use local cmux primitives first: hook session files, Feed workstream JSONL, the `cmux events` stream, workspace and surface IDs, and Dock.

## Files

- `SPEC.md`: shared state and adapter contract.
- `examples/home-state.schema.json`: JSON Schema for the shared state.
- `examples/state.sample.json`: fixture with Claude Code, Codex, OpenCode, and Pi sessions.
- `scripts/dogfood-cmux.sh`: opens a live cmux workspace with all three prototypes.
- `scripts/smoke.sh`: validates the fixture and runs available implementations in summary mode.
- `scripts/smoke.py`: dependency-free smoke runner used by the shell wrapper.

## Dogfood in cmux

Run:

```sh
tools/cmux-home/scripts/dogfood-cmux.sh
```

This uses the running cmux Unix socket through the `cmux` CLI and creates a focused workspace named `cmux home`. The workspace has three panes:

- Rust/Ratatui: `cargo run -- --data ...`
- Go/Charm: `go run ./cmd/cmux-home --data ...`
- TypeScript/OpenTUI: `bun src/cli.ts --data ...`

By default it uses `examples/state.sample.json`. To point the panes at another state file:

```sh
CMUX_HOME_STATE=/path/to/state.json tools/cmux-home/scripts/dogfood-cmux.sh
```

The launcher does not start Claude Code, Codex, OpenCode, or Pi sessions. It only opens renderers over a state snapshot so the UI can be compared quickly inside real cmux panes.

## How it integrates with cmux

`cmux home` should not own agent execution. A state producer composes existing cmux primitives:

- Hook session files under `~/.cmuxterm/<agent>-hook-sessions.json` provide agent session IDs, workspace IDs, surface IDs, cwd, pid, and resume commands.
- `cmux events --category feed --category agent --category workspace --category surface --reconnect` provides live attention changes.
- `cmux list-workspaces --json` and `cmux tree --json` fill current labels, refs, pane layout, and stale-target checks.
- `cmux rpc` or equivalent CLI helpers can jump back to the workspace and surface for a session.

## Expected implementation flags

Every prototype should support this non-interactive summary command:

```sh
cmux-home --data tools/cmux-home/examples/state.sample.json --once
```

The command should print a compact summary and exit 0. It must not open a TUI, focus cmux, start agents, or mutate user state.

## Smoke test

Run:

```sh
tools/cmux-home/scripts/smoke.sh
```

The smoke helper validates `examples/state.sample.json`, then tries discovered Rust, Go, and TypeScript implementations if their manifests or built binaries exist. It runs `--data <state> --once` first, then falls back to `--state <state> --summary --non-interactive` for implementations that use that spelling. It exits 0 when only the shared fixture exists. Use `--require-implementation` when running in an implementation PR.

You can force one command with:

```sh
CMUX_HOME_IMPL="path/to/cmux-home" tools/cmux-home/scripts/smoke.sh --require-implementation
```

## Dock usage

Dock can host a terminal UI for `cmux home`. A future project Dock control can run the chosen implementation:

```json
{
  "controls": [
    {
      "id": "cmux-home",
      "title": "cmux home",
      "command": "cmux-home",
      "cwd": ".",
      "height": 360
    }
  ]
}
```

Dock is optional. The same state contract should also work for a standalone CLI summary, a full terminal TUI, or a native cmux surface.
