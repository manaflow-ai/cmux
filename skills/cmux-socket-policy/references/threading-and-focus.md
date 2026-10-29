# Socket Threading and Focus

Socket commands are a control plane. They usually run because an agent, script, or background tool is reporting state, not because a user asked the app to become active. The rules are in [../SKILL.md](../SKILL.md); this is the reasoning.

## Why telemetry stays off-main

`DispatchQueue.main.sync` blocks the socket handling path behind UI work and can deadlock when the command path is already main-adjacent. High-frequency commands (`report_*`, `ports_kick`, status, progress, log metadata) parse and validate off-main, dedupe and coalesce before crossing to UI state, then schedule only the smallest required mutation.

## When main actor is justified

Commands that directly manipulate AppKit or Ghostty UI state may need it: focus, select, open/close UI surfaces, send key/input, and list/current queries that require an exact synchronous UI snapshot. Document why in the command. Do not cargo-cult main actor isolation onto telemetry commands.

## Focus preservation

A background agent may be working in one workspace while the user is in another app or workspace. A non-focus command applies model and data changes without activating the app, raising a window, selecting another workspace, or focusing a pane or surface.

Decide whether a new command is focus-intent as part of its API contract, not as an implementation accident.
