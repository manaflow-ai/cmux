---
name: cmux
description: End-user control of cmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane cmux layout.
---

# cmux Core Control

Non-browser cmux topology and routing.

- **Window**: top-level macOS cmux window.
- **Workspace**: tab-like group within a window.
- **Pane**: split container in a workspace.
- **Surface**: a tab within a pane (terminal or browser panel).

## Fast start

```bash
cmux identify --json                              # current caller context
cmux list-windows / list-workspaces / list-panes
cmux list-pane-surfaces --pane pane:1
cmux new-workspace
cmux new-split right --panel pane:1
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux split-off --surface surface:7 right
cmux reorder-surface --surface surface:7 --before surface:3

# workspace context-menu actions (color, description, rename, pin, ...)
cmux workspace-action --action set-color --color Blue
cmux workspace-action --action set-description --description "Ship checklist"

# attention cue
cmux trigger-flash --surface surface:7
```

## Handle model

Output defaults to short refs (`window:N`, `workspace:N`, `pane:N`, `surface:N`). UUIDs are accepted as input; request UUID output only when needed with `--id-format uuids|both`.

## Settings

cmux-owned settings live in `~/.config/cmux/cmux.json`. `cmux docs settings` prints the docs URL, schema URL, raw GitHub resources, cmux.json paths, and reload command. `cmux settings`, `cmux settings cmux-json`, and `cmux settings shortcuts` open the UI.

`cmux reload-config` reloads both `cmux.json` and `~/.config/ghostty/config`, refreshing terminals in place with no app restart.

Terminal rendering (font, cursor style, theme, scrollback, `background-opacity`, `background-blur`) belongs in Ghostty config, not cmux settings. Everything else (app behavior, sidebar, notifications, browser behavior, automation, workspace colors, cmux-owned shortcuts) is cmux settings. Before editing, copy any existing `cmux.json` to a timestamped `.bak` next to it. Legacy `~/.config/cmux/settings.json` and `~/Library/Application Support/com.cmuxterm.app/settings.json` are read only as fallback for missing keys.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle, reorder/move, and context-menu actions (color, description, rename) |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe cmux.json settings edits and validation |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../cmux-markdown/SKILL.md](../cmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
