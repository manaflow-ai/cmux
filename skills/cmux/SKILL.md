---
name: cmux
description: End-user control of cmux topology and routing (windows, workspaces, panes, tabs, terminals, focus, moves, identify, flash). Use when automation needs deterministic placement and navigation in a multi-pane cmux layout.
---

# cmux Core Control

Non-browser cmux topology and routing. The `cmux` CLI is noun-first: `cmux <scope> [<selector>] <verb>`.

- **Window**: top-level macOS cmux window, owned by the app.
- **Workspace** (`ws_…`): a sidebar entry.
- **Screen** (`screen_…`): a layout inside a workspace.
- **Pane** (`pane_…`): a split region in a screen.
- **Tab** (`tab_…`): a tab in a pane, showing a terminal or browser.
- **Terminal** (`term_…`): terminal content, addressable with or without a tab.
- **Room**: a personal view that shows the workspaces pinned to it and those of the sessions it follows. Rooms, workspace groups and tab or screen groups take their id or exact name (`cmux room --help`).
- **Closed history**: recently closed tabs, screens and workspaces (`cmux closed list`, `cmux closed <id> reopen`).

## Fast start

```bash
cmux app identify                                  # which app and socket
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json  # the caller terminal
cmux window list
cmux workspace list
cmux pane list
cmux tab list
cmux workspace create --name api
cmux pane pane_… split --right
cmux pane pane_… run -- npm run dev                # new tab running the argv
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux pane flash-focused                            # attention cue (app action)
```

## Selectors

Every instance selector is a public id (`ws_…`, `pane_…`, `tab_…`, `term_…`), `current`, or an exact name. `name:<value>` forces a name; it is required for names equal to `current`, shaped like an id, or containing `_`. An ambiguous name fails with every candidate id. `current` is the focused object in the session, not the caller; use `$CMUX_TUI_TERMINAL_ID` for the caller. Ids are stable across app and daemon restarts. The old `window:N`, `workspace:N`, `pane:N` and `surface:N` refs are gone.

## Running a command in a new terminal

`cmux pane <sel> run -- <argv…>` opens a tab in that pane running the exact argv; `run shell '<script>'` passes a script to the shell. `--on-exit close|keep` controls the tab after the process exits, and `--cwd`/`--name` set its directory and title. `cmux workspace <sel> run` does the same in a workspace. The app action `cmux workspace new --command "…"` types the command into a new workspace's shell.

## App actions

Every action in the app's registry is also a verb: `cmux action list --noun workspace` lists them and `cmux action describe "<noun> <verb>"` shows arguments. Run one with `cmux <noun> <verb> [--target ID] [--<arg> VALUE]`, for example `cmux workspace set-color --target ws_… --color blue`. The daemon grammar is tried first; words it rejects run as an app action.

## Settings

cmux-owned settings live in `~/.config/cmux/cmux.json`. With the app running, `cmux settings get [PATH]`, `cmux settings set PATH VALUE` and `cmux settings unset PATH` read and write it. `cmux settings reload-configuration` reloads it, and `cmux settings open-json` opens it.

Terminal rendering (font, cursor style, theme, scrollback, `background-opacity`, `background-blur`) belongs in Ghostty config, not cmux settings. Everything else (app behavior, sidebar, notifications, browser behavior, automation, workspace colors, cmux-owned shortcuts) is cmux settings. Before editing, copy any existing `cmux.json` to a timestamped `.bak` next to it.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Selectors, ids, and finding the caller |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window and workspace lifecycle, order, and context-menu actions |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, tabs, moves, focus |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue; surface health was removed |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe cmux.json settings edits |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser tabs |
