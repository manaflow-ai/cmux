---
name: cmux-cli
description: "Comprehensive cmux CLI usage guide. Use when the user asks about cmux CLI, cmux --help, socket commands, command discovery, workspaces, panes, surfaces, browser CLI, hooks, feed, settings, or automation through the cmux command."
---

# cmux CLI

Use this skill when a task is best handled through the `cmux` command line, or when the user asks how to use, inspect, script, or document the cmux CLI. Prefer the live CLI help for exact syntax, then apply the safety rules here.

## Prerequisites

Use the `cmux` binary on `PATH` for normal user workflows:

```bash
cmux --help
cmux version
cmux ping
```

When dogfooding a tagged Debug build from a cmux source checkout, use the tag-bound helper instead of `/tmp/cmux-cli`:

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh --help
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh identify --json
```

`scripts/cmux-debug-cli.sh` targets `/tmp/cmux-debug-<tag>.sock`, uses the matching CLI from the tagged app bundle, and scrubs ambient cmux terminal context before running.

## Discovery

Always discover current syntax from the CLI before giving exact command help:

```bash
cmux --help
cmux help
cmux <command> --help
cmux docs settings
cmux docs shortcuts
cmux docs api
cmux docs browser
cmux docs agents
cmux docs dock
```

Some subcommands print the top-level help instead of detailed subcommand help. If that happens, search the source locally:

```bash
rg -n "Usage: cmux <command>|case \"<command>\"|run.*<Command>" CLI
```

Do not fetch source files with `gh api`. Read the local checkout or active worktree.

## Mental Model

cmux exposes app state over a Unix socket.

- Window: top-level macOS cmux window.
- Workspace: sidebar tab-like container inside a window.
- Pane: split region inside a workspace.
- Surface: tab inside a pane. A surface can host a terminal, browser, markdown viewer, diff viewer, or other panel.
- Panel: lower-level content implementation. Prefer surface commands unless a command explicitly requires `--panel`.

Handle inputs usually accept UUIDs, refs such as `window:1`, `workspace:2`, `pane:3`, `surface:4`, or numeric indexes. Output defaults to refs:

```bash
cmux --id-format refs identify
cmux --id-format both list-pane-surfaces --workspace workspace:1
cmux --json --id-format both tree --all
```

## Socket Targeting

Prefer the caller environment when running inside cmux:

```bash
printf 'workspace=%s\nsurface=%s\nsocket=%s\n' \
  "${CMUX_WORKSPACE_ID:-}" \
  "${CMUX_SURFACE_ID:-}" \
  "${CMUX_SOCKET_PATH:-}"
cmux identify --json
```

Use explicit socket targeting for tagged or non-default apps:

```bash
cmux --socket /tmp/cmux-debug-<tag>.sock identify --json
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock cmux ping
```

Socket auth resolves in this order: `--password`, then `CMUX_SOCKET_PASSWORD`, then the password saved in Settings. Do not ask the user for a password until `cmux capabilities --json` or the command error shows auth is actually required.

## Global Options

Common global options:

```bash
cmux --json <command>
cmux --id-format refs <command>
cmux --id-format uuids <command>
cmux --id-format both <command>
cmux --socket <path> <command>
cmux --password <password> <command>
```

Use `--json` for automation and scripts. Use plain output when writing quick human-facing status.

## Safe First Commands

Start every automation session by inspecting context and capabilities:

```bash
cmux ping
cmux capabilities --json
cmux identify --json
cmux list-windows --json
cmux list-workspaces --json
cmux tree --all --json
```

Inside cmux, scope mutating commands to the caller workspace and surface by default:

```bash
cmux list-panes --workspace "${CMUX_WORKSPACE_ID:-}" --json
cmux list-pane-surfaces --workspace "${CMUX_WORKSPACE_ID:-}" --json
cmux read-screen --workspace "${CMUX_WORKSPACE_ID:-}" --surface "${CMUX_SURFACE_ID:-}" --lines 80
```

## Common Workflows

Use [references/commands.md](references/commands.md) for a broader command catalog. High-frequency patterns:

```bash
# Open without stealing focus when supported.
cmux open . --focus false
cmux open https://example.com --workspace "${CMUX_WORKSPACE_ID:-}" --focus false

# Create helper output in the caller workspace.
cmux new-pane --workspace "${CMUX_WORKSPACE_ID:-}" --type terminal --direction right --focus false
cmux new-surface --workspace "${CMUX_WORKSPACE_ID:-}" --pane pane:2 --type terminal --focus false

# Read and write the caller terminal.
cmux read-screen --surface "${CMUX_SURFACE_ID:-}" --scrollback --lines 200
cmux send --surface "${CMUX_SURFACE_ID:-}" "echo ok\n"
cmux send-key --surface "${CMUX_SURFACE_ID:-}" enter

# Browser surface automation.
cmux browser open https://example.com --focus false
cmux browser snapshot --surface surface:5 --compact
cmux browser click "button[type=submit]" --snapshot-after

# Settings and docs.
cmux docs settings
cmux settings path
cmux config validate
cmux reload-config

# Sidebar status for task progress.
cmux set-status build running --workspace "${CMUX_WORKSPACE_ID:-}" --color "#ff9500"
cmux set-progress 0.4 --label "Building" --workspace "${CMUX_WORKSPACE_ID:-}"
cmux clear-status build --workspace "${CMUX_WORKSPACE_ID:-}"
cmux clear-progress --workspace "${CMUX_WORKSPACE_ID:-}"
```

## Command Families

The CLI includes these broad families:

- App/docs/settings: `welcome`, `docs`, `settings`, `config`, `shortcuts`, `reload-config`, `themes`.
- Openers and viewers: `open`, `markdown`, `diff`, browser commands.
- Context and topology: `identify`, `list-windows`, `list-workspaces`, `tree`, workspace/window/pane/surface lifecycle commands.
- Terminal IO: `read-screen`, `send`, `send-key`, `capture-pane`, `pipe-pane`, `clear-history`, `respawn-pane`.
- Browser automation: `browser open`, `goto`, `snapshot`, `click`, `fill`, `screenshot`, `get`, `find`, `tab`, cookies, storage.
- Notifications and sidebar state: `notify`, notification list/read/clear commands, `right-sidebar`, `set-status`, `set-progress`, `log`.
- Agent workflows: `hooks`, `feed`, `claude-teams`, `codex-teams`, `omo`, `omx`, `omc`.
- Auth and cloud: `auth`, `login`, `logout`, `vm` or `cloud`.
- Advanced socket/debug: `capabilities`, `events`, `rpc`, `surface-health`, `debug-terminals`, `trigger-flash`.
- tmux compatibility: `capture-pane`, `resize-pane`, `wait-for`, `swap-pane`, `break-pane`, `join-pane`, `find-window`, buffers, hooks, messages.

## Non-Disruptive Automation

The user may be looking at a different workspace, window, or app. Treat focus changes like UI clicks.

Do not call these unless the user explicitly asks:

- `focus-window`
- `focus-pane`
- `focus-panel`
- `select-workspace`
- `tab-action` actions that focus or select
- `right-sidebar focus`

Prefer additive, scoped commands:

```bash
cmux new-pane --workspace "${CMUX_WORKSPACE_ID:-}" --type terminal --direction right --focus false
cmux new-surface --workspace "${CMUX_WORKSPACE_ID:-}" --pane pane:2 --type terminal --focus false
cmux send --workspace "${CMUX_WORKSPACE_ID:-}" --surface surface:7 "npm test\n"
```

When creating helper output for a task, reuse one right-side helper pane in the caller workspace. Use `list-panes` and `list-pane-surfaces` first, then create a new pane only when no suitable helper pane exists.

## Settings Boundary

cmux-owned settings live in `~/.config/cmux/cmux.json`. Ghostty terminal behavior lives in `~/.config/ghostty/config`. Prefer Ghostty config for terminal behavior Ghostty already supports, such as font, cursor style, scrollback, theme, background opacity, and blur.

Before editing `cmux.json`, run:

```bash
cmux docs settings
cmux settings path
```

Back up the existing file to a timestamped `.bak` copy before editing, then run:

```bash
cmux reload-config
```

## Debug and Tagged Builds

For cmux app/runtime development, build a tagged app before using CLI commands against it:

```bash
./scripts/reload.sh --tag <tag>
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh identify --json
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces --json
```

Do not use bare `xcodebuild` without a tagged `-derivedDataPath`. Do not use `/tmp/cmux-cli` for tagged dogfood because it points at the most recently reloaded build and can target the wrong socket.

Useful debug files:

```bash
cat /tmp/cmux-last-cli-path
cat /tmp/cmux-last-debug-log-path
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

## Rules

- Run `cmux --help` or `cmux <command> --help` before giving exact syntax.
- Use `--json` for scripts and agent automation.
- Scope mutating commands with `--workspace`, `--surface`, `--pane`, and `--window` where available.
- Prefer `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, and `CMUX_SOCKET_PATH` over focused-window fallbacks.
- Pass `--focus false` or `--no-focus` whenever the command supports it unless the user asked to focus something.
- Never change settings without first running `cmux docs settings` or `cmux settings path`; back up `cmux.json` before editing.
- Prefer Ghostty config for terminal behavior Ghostty already supports.
- For tagged Debug builds, use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`.
- Do not run commands against the default socket when the task is about a tagged app.
- Do not ask the user to paste commands into cmux when the CLI can perform the setup directly.

## Related Skills

- `skills/cmux/SKILL.md` covers core topology and routing.
- `skills/cmux-workspace/SKILL.md` covers current-workspace targeting and helper panes.
- `skills/cmux-browser/SKILL.md` covers browser surface automation.
- `skills/cmux-settings/SKILL.md` covers safe settings edits.
- `skills/cmux-markdown/SKILL.md` covers markdown viewer panels.
