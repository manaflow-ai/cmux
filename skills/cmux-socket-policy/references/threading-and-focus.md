# Socket Threading and Focus

Socket commands are a control plane. They often run because an agent, script, or background tool is reporting state, not because a user asked the app to become active.

## Telemetry hot paths

High-frequency telemetry commands include:

- `report_*`
- `ports_kick`
- status updates
- progress updates
- log metadata updates

These should avoid synchronous main-thread work. Parse and validate arguments off-main, dedupe/coalesce before crossing to UI state, and schedule only the smallest required mutation.

`DispatchQueue.main.sync` is especially risky because it can block the socket handling path behind UI work and can deadlock if the command path is already main-adjacent.

## Commands allowed on main actor

Commands that directly manipulate AppKit or Ghostty UI state may need main actor execution:

- focus
- select
- open/close UI surfaces
- send key/input
- list/current queries requiring an exact synchronous UI snapshot

The command should document why main-thread execution is necessary. Do not cargo-cult main actor isolation onto telemetry commands.

## Focus preservation

Most socket commands should not change the user's macOS focus. A background agent may be running in one workspace while the user is actively using another app or cmux workspace.

Non-focus commands should apply model/data changes without:

- activating the app
- raising a window
- selecting another workspace
- focusing a pane
- focusing a surface

If a command needs focus behavior, name and document it as focus-intent.

## Explicit focus-intent commands

Only explicit focus-intent commands may mutate in-app focus/selection. Examples:

- `window.focus`
- `workspace.select`
- `workspace.next`
- `workspace.previous`
- `workspace.last`
- `surface.focus`
- `pane.focus`
- `pane.last`
- browser focus commands
- v1 focus equivalents

When adding a new command, decide whether it is focus-intent as part of the API contract, not as an implementation accident.
