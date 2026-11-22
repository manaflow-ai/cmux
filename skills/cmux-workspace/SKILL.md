---
name: cmux-workspace
description: "Work inside the current cmux workspace and terminal. Use for cmux workspace, current workspace, caller terminal, panes, tabs, socket targeting, and non-interfering cmux automation."
---

# cmux Workspace

Scope work to the cmux workspace that invoked the agent.

- **Window**: a macOS cmux window. Only the app has windows (`cmux window list`).
- **Workspace** (`ws_…`): a sidebar entry.
- **Screen** (`screen_…`): a layout inside a workspace.
- **Pane** (`pane_…`): a split region inside a screen.
- **Tab** (`tab_…`): a tab inside a pane, showing a terminal or a browser.
- **Terminal** (`term_…`): the terminal a tab shows. It has its own id and survives moves.

## Find the caller

A cmux terminal exports `CMUX_TUI_TERMINAL_ID` (the caller terminal), `CMUX_TUI_SOCKET` (the daemon session) and `CMUX_SOCKET_PATH` (the app). The CLI reads them, so plain `cmux` commands reach the right session.

```bash
printf 'terminal=%s\nsession=%s\napp=%s\n' \
  "${CMUX_TUI_TERMINAL_ID:-}" "${CMUX_TUI_SOCKET:-}" "${CMUX_SOCKET_PATH:-}"
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json
cmux tab list --json
```

The terminal record lists the tabs that show it, and a tab record names its pane. Use those ids for every mutating command.

`current` means the session's active workspace, screen and pane, which is what the user is looking at. It is not the caller: an agent can run in one workspace while the user looks at another. Use `current` only when the user asked about the focused context, and say so.

## Non-disruptive automation

Treat layout and focus as separate concerns. `workspace <sel> focus`, `pane <sel> focus`, `tab <sel> focus` and `pane <sel> focus direction …` are user-affecting actions, like clicks. Never call them speculatively.

Build layout additively, addressing panes by id:

```bash
cmux pane pane_… split --right --cwd "$PWD"
cmux tab create browser --pane pane_… --url http://127.0.0.1:8765
cmux pane pane_… run --name dev -- npm run dev
```

`pane <sel> run -- <argv…>` opens a new tab in that pane running the exact argv; `run shell '<script>'` runs a shell script instead. Prefer it over creating a tab and then writing input. If a command rejects a valid id, report it and stop rather than working around it by focusing.

## Right-side helper pane

For auxiliary output (preview apps, TUIs, logs, one-off shells, browser checks), reuse one helper pane to the right of the caller. Inspect first with `cmux pane list --json` and `cmux tab list --json`, then:

- Helper pane exists: add a tab to it.
  ```bash
  cmux tab create terminal --pane pane_<helper> --cwd "$PWD"
  ```
- No helper pane: split the caller's pane once.
  ```bash
  cmux pane pane_<caller> split --right
  ```
- Several stale helper panes from this same automation, and the user asked to tidy: keep one and close the rest with `cmux pane pane_… close`. Never close a pane you cannot confidently identify as stale helper output.

Repeated "open it" requests add tabs to the existing helper pane, not more splits.

## Caller terminal

Text is written literally. Add `\n` yourself, or send `enter` as a key.

```bash
cmux terminal "$CMUX_TUI_TERMINAL_ID" write --text $'git status\n'
cmux terminal term_… keys ctrl+c
cmux terminal term_… screen read
cmux terminal term_… screen wait --pattern 'passed|failed' --timeout-ms 60000
```

Do not send input, close terminals, or change focus in another workspace unless the user named that target.

## Moving tabs

```bash
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux terminal term_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
```

Moves need the full destination and an index. They do not change focus.

## Workspace status, progress and log

Without a selector these target your own workspace (the one that holds `$CMUX_TUI_TERMINAL_ID`), even when another workspace is focused.

```bash
cmux workspace status set build "tests running" --icon hammer --color blue
cmux workspace status clear build
cmux workspace progress set 0.4 --label "tests"
cmux workspace progress set --indeterminate
cmux workspace progress clear
cmux workspace log append "deploy finished" --level success --source ci
cmux workspace log append -- "-3 files changed"
cmux workspace log list --limit 20 --json
cmux workspace status list --json          # entries, progress, last log line
cmux workspace ws_… status list            # another workspace
```

Status entries are keyed (at most 64 per workspace); `set` replaces the entry with that key. Log levels: info, progress, success, warning, error; the workspace keeps its newest 200 lines. The workspace's workflow status is a different thing, an app action: `cmux workspace set-status --target ws_… --status inProgress`. For attention, use `cmux notify --title "Build" --body "done"`.

## Contributor reloads

For cmux app/runtime changes in a cmux source checkout, use a tagged reload from the active worktree. Never build or launch untagged `cmux DEV`.

```bash
./scripts/reload.sh --tag <short-tag>
CMUX_TAG=<short-tag> scripts/cmux-debug-cli.sh app identify
```

## Socket access

The CLI finds the daemon from `--socket`/`--session`, then `CMUX_TUI_SOCKET`, then the app's session; it finds the app from `CMUX_SOCKET_PATH`. If a command cannot connect, check `cmux session list` for the daemon and `cmux app ping` for the app. Exit code 3 means transport failure.

Lists act on that one session. `--all-sessions` runs a list on every local session (records gain `session`), and a session-qualified id (`build-box:ws_…`) routes one command to that local session. Sessions the app reaches over SSH or Cloud are not reachable from the CLI yet.

## Rules

- Work in the caller workspace by default; pass explicit ids for mutating actions so automation is auditable.
- Never call a focus verb unless the user explicitly asked.
- Build layout additively with `pane … split`, `tab create …` and `pane … run`.
- If a command rejects a valid id, report it. Do not work around by focusing.
- Do not close, focus, move, or send input to another workspace unless the user names that target.
- Old `workspace:N`, `pane:N` and `surface:N` refs are gone. Selectors are a public id, `current`, or an exact name (`name:<value>` forces a name).

## References

- [references/commands.md](references/commands.md): workspace, pane, tab, terminal, notification and app command list.
- [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md): browser tabs under the same current-workspace rule.
