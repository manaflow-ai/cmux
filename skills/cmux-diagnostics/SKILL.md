---
name: cmux-diagnostics
description: "Run end-user cmux diagnostics. Use when cmux hooks, notifications, session restore, settings, browser automation, socket access, CLI control, or agent resume behavior is not working, or when the user asks for a cmux health check, doctor report, or support-safe debug summary."
---

# cmux Diagnostics

Use this skill to collect and interpret support-safe cmux diagnostics for end users. Default to read-only checks. Do not dump hook config files, session stores, prompt logs, tokens, or environment secrets.

## Quick Report

Run the bundled read-only diagnostic script first:

```bash
# From a cmux checkout
skills/cmux-diagnostics/scripts/cmux-diagnostics

# From an installed skill
~/.agents/skills/cmux-diagnostics/scripts/cmux-diagnostics

# From a Codex-only skills.sh install
~/.codex/skills/cmux-diagnostics/scripts/cmux-diagnostics
```

Use `--include-context` only when workspace names, cwd paths, and current cmux identifiers are relevant to the user-reported issue:

```bash
skills/cmux-diagnostics/scripts/cmux-diagnostics --include-context
```

## What to Check

1. CLI and socket health:

   ```bash
   command -v cmux
   cmux ping
   cmux capabilities --json
   ```

   If socket commands fail, check whether the agent is running inside a cmux terminal and whether socket automation is enabled.

2. Settings health:

   ```bash
   ~/.agents/skills/cmux-settings/scripts/cmux-settings validate
   ~/.agents/skills/cmux-settings/scripts/cmux-settings get terminal.autoResumeAgentSessions
   ```

   If the user installed with `skills.sh`, use `~/.codex/skills/cmux-settings/scripts/cmux-settings` instead.
   If `terminal.autoResumeAgentSessions` is false, cmux restores panes but will not automatically resume saved agent sessions.

3. Hook installation:

   ```bash
   cmux hooks setup --agent codex
   cmux hooks setup --agent opencode
   cmux hooks setup
   ```

   Only run install or uninstall commands after the user agrees. `cmux hooks setup` installs supported agents found on PATH and skips missing agents.

4. Session restore evidence:

   ```bash
   ls -lh ~/.cmuxterm/*-hook-sessions.json 2>/dev/null
   ```

   Missing session stores usually means the agent has not run inside cmux since hooks were installed, hooks are disabled, or the agent integration does not support resume capture.

5. Notification path:

   ```bash
   cmux notify "cmux diagnostic test"
   ```

   Use this only when the user is ready for a visible test notification.

## Interpretation

- `cmux` not found: the CLI is not installed or not on PATH for this shell.
- `cmux ping` fails: app is not reachable through the current socket path, the app is closed, or automation access is disabled.
- No `CMUX_WORKSPACE_ID` or `CMUX_SURFACE_ID`: the command is probably running outside a cmux terminal. Some hooks intentionally no-op outside cmux.
- Hook config exists but no session store: run one supported agent inside cmux after installing hooks, then re-check.
- Session store exists but restore does not launch agents: check `terminal.autoResumeAgentSessions` and whether the saved executable still exists on PATH.
- Settings validation fails: fix the config first. Invalid config can make later symptoms misleading.

## Rules

- Stay read-only until the user asks to fix something.
- Never print raw hook files, session JSON, prompt logs, shell history, tokens, or API keys.
- Summarize file presence, size, modified time, and marker presence instead of contents.
- Prefer narrow fixes such as `cmux hooks setup --agent codex` over reinstalling every integration.
- After a fix, rerun the diagnostic script and report the changed lines.
