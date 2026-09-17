---
name: cmux-workspace
description: "Work inside the current cmux workspace and terminal. Use for cmux workspace, current workspace, caller surface, panes, surfaces, socket targeting, and non-interfering cmux automation."
---

# cmux Workspace

Scope work to the cmux workspace that invoked the agent.

- **Window**: a macOS cmux window.
- **Workspace**: a sidebar entry. The UI calls it a tab; CLI/socket APIs call it a workspace.
- **Pane**: a split region inside a workspace.
- **Surface**: a tab inside a pane, terminal or browser.
- **Panel**: internal content type inside a surface. Prefer CLI surface commands over panel internals.

## Default rule

Scope actions to the current caller workspace unless the user explicitly asks for another workspace, another window, or global state. Do not assume the visually focused workspace is the right target: an agent can run in one workspace while the user looks at another.

```bash
printf 'workspace=%s\nsurface=%s\nsocket=%s\n' \
  "${CMUX_WORKSPACE_ID:-}" "${CMUX_SURFACE_ID:-}" "${CMUX_SOCKET_PATH:-}"
cmux identify --json
```

`CMUX_WORKSPACE_ID` is the default workspace anchor and `CMUX_SURFACE_ID` the default caller terminal anchor. If they are missing, fall back to `cmux identify --json` and say explicitly that you are using the currently focused context.

## Non-disruptive automation

Treat layout and focus as separate concerns. `select-workspace`, `focus-pane`, `focus-panel`, and focus-changing `tab-action` verbs are user-affecting actions, like clicks. Never call them speculatively, even inside the caller's own workspace, since the user may be looking elsewhere.

Build layout additively in one shot, using commands that create a pane already populated with the right surface:

```bash
cmux new-pane --workspace "${CMUX_WORKSPACE_ID}" --type browser --direction right --url "http://127.0.0.1:8765"
cmux new-pane --workspace "${CMUX_WORKSPACE_ID}" --type terminal --direction down
```

Avoid create-then-move-then-focus chains. Pass `--focus false` wherever the verb supports it (`move-surface --focus false` preserves the user's attention; more commands may grow the flag, see https://github.com/manaflow-ai/cmux/issues/1418 and https://github.com/manaflow-ai/cmux/issues/2820). If a layout command rejects a valid `surface:` or `pane:` ref, report the bug and stop rather than working around it by focusing.

## Right-side helper pane

For auxiliary output (preview apps, TUIs, logs, one-off shells, browser checks), reuse one helper pane to the right of the caller terminal. Inspect first with `cmux identify --json`, `cmux list-panes`, and `cmux list-pane-surfaces`, then:

- Helper pane exists: add a surface to it.
  ```bash
  cmux new-surface --workspace "${CMUX_WORKSPACE_ID:-}" --pane pane:<helper> --type terminal --focus false
  ```
- No helper pane: create exactly one.
  ```bash
  cmux new-pane --workspace "${CMUX_WORKSPACE_ID:-}" --type terminal --direction right --focus false
  ```
- Multiple obvious stale helper panes from this same automation, and the user asked to tidy: keep one and clean up duplicates. Never close a pane you cannot confidently identify as stale helper output.

Send commands to the new or reused surface by explicit surface ref. Repeated "open it" requests create tabs inside the existing right helper pane, not more splits.

## Caller terminal

The surface that invoked the agent is the safest anchor for relative operations.

```bash
cmux send "npm test\n"                                    # focused terminal in caller workspace
cmux send --surface "${CMUX_SURFACE_ID:-}" "git status\n"  # exact caller surface
cmux send-key --surface "${CMUX_SURFACE_ID:-}" enter
```

Do not send keystrokes, close surfaces, or change focus in another workspace unless the user named that target.

## Moving surfaces

```bash
cmux move-surface --surface "${CMUX_SURFACE_ID}" --before surface:3   # also --after, --index
cmux move-surface --surface surface:240 --pane pane:172 --focus false
cmux drag-surface-to-split --surface surface:240 down
```

Known papercut: `drag-surface-to-split` routes through V1 and resolves the workspace via UI focus, so it fails with `ERROR: Surface not found` when the caller's workspace is not the visually focused one (https://github.com/manaflow-ai/cmux/issues/1901, related https://github.com/manaflow-ai/cmux/issues/3189). Until that lands, build layout additively. Never call `focus-pane` or `focus-panel` to recover from a failed move; report the failure and stop.

## Sidebar state

Attach status, progress, and logs to the current workspace so the sidebar reflects this task.

```bash
cmux set-status build "running" --workspace "${CMUX_WORKSPACE_ID:-}" --color "#ff9500"
cmux set-progress 0.4 --label "Building" --workspace "${CMUX_WORKSPACE_ID:-}"
cmux log --workspace "${CMUX_WORKSPACE_ID:-}" --level info -- "Started build"
cmux sidebar-state --workspace "${CMUX_WORKSPACE_ID:-}" --json
```

## Contributor reloads

For cmux app/runtime changes in a cmux source checkout, use a tagged reload from the active worktree. It creates an isolated app name, bundle ID, debug socket, and DerivedData path. Never build or launch untagged `cmux DEV`.

```bash
./scripts/reload.sh --tag <short-tag>
CMUX_SOCKET_PATH=/tmp/cmux-debug-<short-tag>.sock cmux identify --json
```

## Socket access

Use the socket path cmux provided before any default: `SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"`. Socket access can be off, restricted to cmux-spawned processes, or open to all local processes. If a command cannot connect, inspect `cmux capabilities --json` and `cmux ping` before changing settings.

## Rules

- Work in the caller workspace by default; prefer explicit `--workspace` and `--surface` flags for mutating actions even when env vars are set, so automation is auditable.
- Never call `focus-pane`, `focus-panel`, `select-workspace`, or focus-changing `tab-action` verbs unless the user explicitly asked.
- Pass `--focus false` on `move-surface` and any creation verb that supports it.
- Build layout additively with `new-pane --type ... --url ...`, not create-then-move-then-focus.
- If a CLI command rejects a valid surface or pane ref, report it. Do not work around by focusing.
- Do not close, focus, move, or send input to another workspace unless the user names that target.
- Use short refs in chat and examples; UUIDs only for logs, persistence, or debugging.

## References

- [references/commands.md](references/commands.md): full workspace, pane, surface, notification, and utility command list.
- [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md): browser surfaces under the same current-workspace rule.
