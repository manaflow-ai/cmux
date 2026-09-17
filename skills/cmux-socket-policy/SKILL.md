---
name: cmux-socket-policy
description: "Socket command threading and focus policy for cmux CLI/socket work. Use when adding or changing socket commands, CLI commands, telemetry commands, focus/select/open/close/send-key behavior, or automation that could steal app focus."
---

# cmux Socket Policy

## Threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands such as `report_*`, `ports_kick`, status/progress updates, or log metadata updates.
- For telemetry hot paths, parse and validate arguments off-main.
- Dedupe and coalesce off-main first.
- Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state are allowed to run on the main actor.
- If adding a new socket command, default to off-main handling and require an explicit reason in code comments when main-thread execution is necessary.

## Focus policy

- Socket/CLI commands must not steal macOS app focus.
- Do not activate the app or raise windows unless the command has explicit focus intent.
- Only explicit focus-intent commands may mutate in-app focus/selection.
- Explicit focus-intent commands include `window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents.
- All non-focus commands should preserve the current user focus context while still applying data/model changes.

## Detailed reference

- Read [references/threading-and-focus.md](references/threading-and-focus.md) when adding a command, changing command execution context, or deciding whether focus changes are allowed.
