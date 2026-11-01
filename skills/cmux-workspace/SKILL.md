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

`caller` names your own workspace, screen, pane, tab or terminal (`cmux pane caller split --right`, `cmux workspace caller rename …`), and fails rather than guess when there is no caller. Inside cmux, `current` means the caller's object too; it is the focused object (what the user is looking at) only without a caller, such as a shell outside cmux, or with `--socket`/`--session`. Prefer `caller` in agent scripts.

In the cmux MCP server (`cmux_exec`), `current` is the caller's own workspace, screen, pane or tab: the server asks the app where the chat is on every call, so the person can look at another workspace while the script runs. `focused` is the one the person looks at. A chat the app cannot place fails with `caller.unresolved` instead of acting on the focused workspace.

An agent's new terminal or link that names no place opens beside its own chat, in its own workspace: `tab_create_terminal` (and `cmux tab create terminal`) with no workspace, screen or pane goes to the column right of the chat, or makes that column; `workspace_open_url` with no workspace opens through the app's beside-the-chat rule, never in Home. Name a pane only to put it somewhere else.

## Non-disruptive automation

Treat layout and focus as separate concerns. `workspace <sel> focus`, `pane <sel> focus`, `tab <sel> focus` and `pane <sel> focus direction …` are user-affecting actions, like clicks. Never call them speculatively.

Build layout additively, addressing panes by id:

```bash
cmux pane pane_… split --right -- npm run dev       # new pane runs the command, focus stays
cmux tab create browser --pane pane_… --url http://127.0.0.1:8765
cmux pane pane_… run --name tests -- npm test        # another tab in an existing pane
```

`workspace create`, `pane split`, `tab create` and `pane run` never move the user's focus; `workspace create --focus` and `pane split --focus` are the only ways they take it, and only when the user asked. Give `pane split` the command its new pane should run (`-- <argv…>` or `--shell '<script>'`): a split without one starts a shell, and running the command afterwards with `pane run` leaves that shell behind as an empty tab. `pane <sel> run -- <argv…>` opens a new tab in an existing pane running the exact argv; `run shell '<script>'` runs a shell script instead. Prefer these over creating a tab and then writing input. If a command rejects a valid id, report it and stop rather than working around it by focusing.

## Right-side helper pane

For auxiliary output (preview apps, TUIs, logs, one-off shells, browser checks), reuse one helper pane to the right of the caller. Find the caller's pane (the tab record of `$CMUX_TUI_TERMINAL_ID` names it), then ask for its right neighbor:

```bash
cmux pane pane_<caller> neighbor right --json     # the pane to its right, if any
cmux pane list --json                             # or inspect every pane
```

- A pane is already to the right: add a tab to it. Never split again.
  ```bash
  cmux tab create terminal --pane pane_<helper> --cwd "$PWD" --name logs
  cmux pane pane_<helper> run --name dev -- npm run dev
  cmux tab create browser --pane pane_<helper> --url http://localhost:3000
  ```
- No pane to the right: split the caller's pane once, with the command it should run.
  ```bash
  cmux pane pane_<caller> split --right -- npm run dev
  ```
- Several stale helper panes from this same automation, and the user asked to tidy: keep one and close the rest with `cmux pane pane_… close`. Never close a pane you cannot confidently identify as stale helper output.

Repeated "open it" requests add tabs to the existing helper pane, not more splits.

An agent in a chat tab of the cmux app: the same rule holds. Find the column right of the chat with `cmux pane <chat pane> neighbor right` and add tabs to it; `cmux open URL` opens a page there and makes the column when needed. With no column yet, make it once with `cmux pane <chat pane> split --right --viewport-width 0.5` (a chat dock takes no plain split). `cmux app identify` and `cmux --json identify` answer only when the app is reachable (`cmux app ping`); never depend on them for layout.

## Larger layouts beside a chat

When the chat is the only agent chat in its workspace, make it a docked left column first, then build to its right. In a `cmux_exec` script, one `workspace_layout_apply` does it; its viewport `base_width` must equal the first column's width:

```js
await cmux.workspace_layout_apply({workspace: "current", layout: {
  screen_id, version: 1, active_pane_id: chatPane, zoomed_pane_id: null,
  root: {kind: "viewport", base_width: 0.32, columns: [
    {column_id: chatColumn, width: 0.32, dock: {edge: "left", mode: "docked", role: "agent_chat"}, root: chatLeaf},
    {column_id: workColumn, width: 0.62, root: workTree},
  ]},
}});
```

Every `column_id` and `split_id` must already exist (read them with `screen_layout_export`); the daemon refuses an id it does not know. Make new ones with `pane_split`: `viewport_width` makes a new column, `ratio` makes a split. Then move them with one apply.

Columns or splits:

- **A column** for each separate task the person switches between: a browser, a dev server, a second repo. Columns scroll sideways, so there is no limit to their count.
- **A split inside a column** for views read together: a server above its log, a page above its console, a test run beside the diff it tests.
- Never more than three panes in one column; make a new column.

Widths, as fractions of the viewport:

- Chat dock: about a third (0.3 to 0.35). Chat text needs about 80 characters.
- Main work column: half to two thirds (0.5 to 0.66).
- Side columns (logs, monitors, a second terminal): a third (0.33 to 0.4).
- Never under a quarter: a terminal narrower than about 80 columns wraps its output.
- The chat dock and the first work column together should fill the viewport, so the main work shows without a scroll.

Name every tab you make (`tab_rename`), so the person can find it by title.

## Classic commands are gone

cmux-next has no `identify` (outside the app), `new-split`, `new-pane`, `new-surface`, `list-panels`, `list-pane-surfaces`, `focus-panel` or `workspace:N`/`pane:N`/`surface:N` refs. Use the noun-first commands above: `pane … split`, `tab create …`, `pane … run`, `pane list`, `tab list`, `pane … neighbor`. If a command fails, read `cmux <noun> --help`; never look for another cmux socket than the one in your environment.

## Sidebar groups

Sidebar groups are the user's. Never create a group or move a workspace into one unless the user asks, and never group workspaces by topic on your own. A Chief subagent's workspace stays ungrouped unless its spawn task has a `Group: Chief agents` line and the user already has that group; the Chief host never makes one. When the user asks:

```bash
cmux --json workspace group list
cmux workspace group <group> add --workspace ws_…
```

Grouping never closes or renames the user's workspaces. Groups are personal: they live in this Mac's home session.

## Caller terminal

Text is written literally. Add `\n` yourself, or send `enter` as a key.

```bash
cmux terminal "$CMUX_TUI_TERMINAL_ID" write --text $'git status\n'
cmux terminal term_… keys ctrl+c
cmux terminal term_… screen read
cmux terminal term_… screen wait --pattern 'passed|failed' --timeout-ms 60000
cmux agents wait --until idle --target term_… --timeout 60   # another agent finished
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

Status entries are keyed (at most 64 per workspace); `set` replaces the entry with that key. Log levels: info, progress, success, warning, error; the workspace keeps its newest 200 lines. The workspace's workflow status is a different thing, an app action: `cmux workspace set-status --target ws_… --status working`. For attention, use `cmux notify --title "Build" --body "done"`. When the user must act in one tab (confirm, log in, approve), mark it with `cmux attention request --tab tab_… --reason "<one line>"` and clear it with `cmux attention clear --tab tab_…`; neither moves focus.

## Contributor reloads

For cmux app/runtime changes in a cmux source checkout, use a tagged reload from the active worktree. Never build or launch untagged `cmux DEV`.

```bash
./scripts/reload.sh --tag <short-tag>
CMUX_TAG=<short-tag> scripts/cmux-debug-cli.sh app identify
```

## Socket access

The CLI finds the daemon from `--socket`/`--session`, then `CMUX_TUI_SOCKET`, then the app's session; it finds the app from `CMUX_SOCKET_PATH`. If a command cannot connect, check `cmux workspace list` for the daemon and `cmux app ping` for the app. Exit code 3 means transport failure.

Lists act on that one session. `--all-sessions` runs a list on every local session (records gain `session`; a person only, an agent caller such as a Chief turn gets `origin.forbidden`), and a session-qualified id (`build-box:ws_…`) routes one command to that local session. Sessions the app reaches over SSH or Cloud are not reachable from the CLI yet.

## Rules

- Work in the caller workspace by default; pass explicit ids for mutating actions so automation is auditable.
- Never call a focus verb unless the user explicitly asked.
- Never tell the user a raw `ws_…`, `tab_…` or `pane_…` id: name the workspace and tab by their titles. When the user must act in a tab, mark it with `cmux attention request`; when they ask to go there, focus it (`cmux tab tab_… focus`, MCP `tab_focus`).
- Build layout additively with `pane … split`, `tab create …` and `pane … run`. Add tabs to an existing right pane instead of splitting again, and give a split its command so no empty shell is left.
- `pane split` and `workspace create` keep focus; pass `--focus` (MCP `focus: true`) only when the user asked to look at the new pane or workspace.
- If a command rejects a valid id, report it. Do not work around by focusing.
- Do not close, focus, move, or send input to another workspace unless the user names that target.
- Old `workspace:N`, `pane:N` and `surface:N` refs are gone. Selectors are a public id, `caller`, `current`, or an exact name (`name:<value>` forces a name).

## References

- [references/commands.md](references/commands.md): workspace, pane, tab, terminal, notification and app command list.
- [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md): browser tabs under the same current-workspace rule.
