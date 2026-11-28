---
name: cmux-diagnostics
description: "Run end-user cmux diagnostics. Use when cmux hooks, notifications, session restore, settings, browser automation, socket access, CLI control, or agent resume behavior is not working, or when the user asks for a cmux health check, doctor report, or support-safe debug summary."
---

# cmux Diagnostics

Collect and interpret support-safe cmux diagnostics for end users. Default to read-only checks. Never dump hook config files, session stores, prompt logs, tokens, or environment secrets.

## Quick report

Run the bundled read-only script first, from whichever install path exists:

```bash
skills/cmux-diagnostics/scripts/cmux-diagnostics            # cmux checkout
~/.agents/skills/cmux-diagnostics/scripts/cmux-diagnostics  # installed skill
~/.codex/skills/cmux-diagnostics/scripts/cmux-diagnostics   # Codex-only skills.sh install
```

Add `--include-context` only when the app identity and the caller terminal record are relevant to the reported issue.

## What to check

1. **CLI and sockets**: `command -v cmux`, `cmux app ping` (the app), `cmux session list` (the cmux-tui daemon), `cmux app capabilities`. Exit code 3 is a transport failure. Inside a cmux terminal, `CMUX_TUI_TERMINAL_ID`, `CMUX_TUI_SOCKET` and `CMUX_SOCKET_PATH` are set.
2. **Settings**: `cmux settings get terminal.autoResumeAgentSessions` with the app running. When it is false, cmux restores panes but does not resume saved agent sessions.
3. **Agent hooks**: `cmux agent hook status` lists each provider as installed, partial or absent. Install with `cmux agent hook install codex` (or another provider; bare `install` covers every provider found on PATH) only after the user agrees. Providers load hooks at start, so restart the agent inside a cmux terminal afterwards.
4. **Notification path**: `cmux notify --title "cmux diagnostic test"`, only when the user is ready for a visible test notification.

The script no longer checks per-provider hook config markers, `~/.cmuxterm/*-hook-sessions.json` session stores, or `cmux-settings validate`. Those belonged to the Swift CLI's hooks; `cmux agent hook status` replaces the first, and the new `cmux` has no config validator yet.

## Interpretation

- `cmux` not found: the CLI is not installed or not on PATH for this shell.
- `cmux app ping` fails: the app is closed, its socket is unreachable from this shell, or socket automation is off.
- `cmux session list` fails: no cmux-tui daemon is reachable through `--socket`, `CMUX_TUI_SOCKET`, or the app's session.
- No `CMUX_TUI_TERMINAL_ID`: the command is running outside a cmux terminal. Hooks and `cmux notify` then have no caller terminal.
- A provider shows `partial`: rerun `cmux agent hook install <provider>` after the user agrees.
- Hooks installed but no agent state: the agent started before the install, or outside a cmux terminal. Restart it inside one.

## Rules

- Stay read-only until the user asks to fix something.
- Never print raw hook files, session JSON, prompt logs, shell history, tokens, or API keys. Summarize file presence, size, modified time, and marker presence instead.
- Prefer a narrow fix such as `cmux agent hook install codex` over reinstalling every integration.
- After a fix, rerun the diagnostic script and report the changed lines.
