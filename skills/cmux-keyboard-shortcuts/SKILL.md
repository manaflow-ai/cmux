---
name: cmux-keyboard-shortcuts
description: "Guide and apply cmux keyboard shortcut customization. Use when the user asks to customize, rebind, unbind, reset, audit, or create shortcut templates for cmux, including tmux-style, Vim-style, terminal-first, browser-heavy, iTerm/Terminal-like, or agent-triage layouts."
---

# cmux-keyboard-shortcuts

Use this skill to turn a user's workflow preferences into cmux shortcut bindings in `~/.config/cmux/cmux.json`. It should guide the user, propose compact templates, apply selected changes, and validate the result.

## Prerequisites

- Work from a cmux checkout or worktree root when possible.
- Use `skills/cmux-settings/scripts/cmux-settings` for every read/write. It preserves JSONC, writes atomically, and validates the schema.
- For action IDs, read `skills/cmux-settings/references/shortcut-actions.md`.
- For current defaults, read `web/data/cmux-shortcuts.ts` or `Sources/KeyboardShortcutSettings.swift`.

```bash
ROOT="${ROOT:-$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)}"
CMUX_SETTINGS="${CMUX_SETTINGS:-$ROOT/skills/cmux-settings/scripts/cmux-settings}"
```

## Shortcut Model

- Setting path: `shortcuts.bindings.<actionId>`.
- Single stroke: `"cmd+b"`.
- Chord: `["ctrl+b","c"]`. The first stroke needs a modifier unless the key is Space. The second stroke can be bare.
- Unbind: `null`, `""`, `"none"`, `"clear"`, `"unbound"`, or `"disabled"`.
- `selectSurfaceByNumber` and `selectWorkspaceByNumber` must use a digit from 1 to 9. `cmd+1` means the full `cmd+1` through `cmd+9` family.
- `showHideAllWindows` and `globalSearch` are system-wide shortcuts. They cannot be chords, require modifiers, and may be rejected by macOS if reserved.
- Saving `cmux.json` live reloads. Do not tell the user to restart cmux.

## Workflow

1. Classify the request:
   - One-off rebind or unbind: map the phrase to an action ID, apply it, validate, and report the previous and new binding.
   - Broad customization request: propose 3 to 5 templates from "Preset Templates" and ask the user to choose.
   - Named style such as tmux, Vim, iTerm, browser, or agent triage: select the closest template, show the changed actions, and ask before a bulk apply unless the user explicitly said to apply it.
2. Inspect existing config:
   ```bash
   "$CMUX_SETTINGS" get shortcuts.bindings
   "$CMUX_SETTINGS" validate
   ```
3. Apply only the chosen action paths:
   ```bash
   "$CMUX_SETTINGS" set shortcuts.bindings.newSurface '["ctrl+b","c"]'
   "$CMUX_SETTINGS" set shortcuts.bindings.focusLeft cmd+opt+h
   "$CMUX_SETTINGS" set shortcuts.bindings.sendFeedback null
   "$CMUX_SETTINGS" validate
   ```
4. Verify readback for changed actions:
   ```bash
   "$CMUX_SETTINGS" get shortcuts.bindings.newSurface
   ```
5. Finish with the template name, changed actions, and exact revert commands using `unset`.

## Preset Templates

Use these as proposal templates. Apply them action by action, not by overwriting the whole `shortcuts.bindings` object.

### Tmux Prefix

For users who want one terminal-style shortcut namespace and accept that `ctrl+b` starts a cmux chord instead of going directly to the shell.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.newSurface '["ctrl+b","c"]'
"$CMUX_SETTINGS" set shortcuts.bindings.closeTab '["ctrl+b","x"]'
"$CMUX_SETTINGS" set shortcuts.bindings.nextSurface '["ctrl+b","n"]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSurface '["ctrl+b","p"]'
"$CMUX_SETTINGS" set shortcuts.bindings.selectSurfaceByNumber '["ctrl+b","1"]'
"$CMUX_SETTINGS" set shortcuts.bindings.splitRight '["ctrl+b","v"]'
"$CMUX_SETTINGS" set shortcuts.bindings.splitDown '["ctrl+b","s"]'
"$CMUX_SETTINGS" set shortcuts.bindings.focusLeft '["ctrl+b","h"]'
"$CMUX_SETTINGS" set shortcuts.bindings.focusDown '["ctrl+b","j"]'
"$CMUX_SETTINGS" set shortcuts.bindings.focusUp '["ctrl+b","k"]'
"$CMUX_SETTINGS" set shortcuts.bindings.focusRight '["ctrl+b","l"]'
"$CMUX_SETTINGS" set shortcuts.bindings.toggleSplitZoom '["ctrl+b","z"]'
"$CMUX_SETTINGS" set shortcuts.bindings.toggleTerminalCopyMode '["ctrl+b","["]'
"$CMUX_SETTINGS" set shortcuts.bindings.equalizeSplits '["ctrl+b","="]'
```

### Vim Pane Navigation

For users who want fast pane movement without a prefix and do not want to depend on arrow keys.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.focusLeft cmd+opt+h
"$CMUX_SETTINGS" set shortcuts.bindings.focusDown cmd+opt+j
"$CMUX_SETTINGS" set shortcuts.bindings.focusUp cmd+opt+k
"$CMUX_SETTINGS" set shortcuts.bindings.focusRight cmd+opt+l
"$CMUX_SETTINGS" set shortcuts.bindings.splitRight cmd+opt+v
"$CMUX_SETTINGS" set shortcuts.bindings.splitDown cmd+opt+s
"$CMUX_SETTINGS" set shortcuts.bindings.toggleSplitZoom cmd+opt+z
"$CMUX_SETTINGS" set shortcuts.bindings.equalizeSplits cmd+opt+=
```

### Agent Triage

For users who live in notifications and want unread handling on one key family.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.showNotifications cmd+u
"$CMUX_SETTINGS" set shortcuts.bindings.jumpToUnread cmd+j
"$CMUX_SETTINGS" set shortcuts.bindings.markOldestUnreadAndJumpNext cmd+shift+j
"$CMUX_SETTINGS" set shortcuts.bindings.toggleUnread cmd+opt+j
"$CMUX_SETTINGS" set shortcuts.bindings.triggerFlash cmd+shift+h
"$CMUX_SETTINGS" set shortcuts.bindings.focusRightSidebar cmd+shift+e
```

### Workspace And Surface Lanes

For users who want workspaces and surfaces on distinct number and bracket lanes.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.selectWorkspaceByNumber cmd+1
"$CMUX_SETTINGS" set shortcuts.bindings.selectSurfaceByNumber cmd+opt+1
"$CMUX_SETTINGS" set shortcuts.bindings.nextSidebarTab 'cmd+opt+]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSidebarTab 'cmd+opt+['
"$CMUX_SETTINGS" set shortcuts.bindings.nextSurface 'cmd+]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSurface 'cmd+['
```

### Browser Defaults Restore

For users who changed too much and want embedded-browser behavior to match common macOS browser shortcuts again.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.openBrowser cmd+shift+l
"$CMUX_SETTINGS" set shortcuts.bindings.focusBrowserAddressBar cmd+l
"$CMUX_SETTINGS" set shortcuts.bindings.browserBack 'cmd+['
"$CMUX_SETTINGS" set shortcuts.bindings.browserForward 'cmd+]'
"$CMUX_SETTINGS" set shortcuts.bindings.browserReload cmd+r
"$CMUX_SETTINGS" set shortcuts.bindings.browserZoomIn cmd+=
"$CMUX_SETTINGS" set shortcuts.bindings.browserZoomOut cmd+-
"$CMUX_SETTINGS" set shortcuts.bindings.browserZoomReset cmd+0
"$CMUX_SETTINGS" set shortcuts.bindings.toggleBrowserDeveloperTools cmd+opt+i
"$CMUX_SETTINGS" set shortcuts.bindings.showBrowserJavaScriptConsole cmd+opt+c
"$CMUX_SETTINGS" set shortcuts.bindings.find cmd+f
"$CMUX_SETTINGS" set shortcuts.bindings.findNext cmd+g
"$CMUX_SETTINGS" set shortcuts.bindings.findPrevious cmd+opt+g
```

### Terminal-First Cleanup

For users who want fewer app-level shortcuts. Prefer unbinding only the actions they name, but this is a reasonable starting proposal.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.renameTab null
"$CMUX_SETTINGS" set shortcuts.bindings.renameWorkspace null
"$CMUX_SETTINGS" set shortcuts.bindings.editWorkspaceDescription null
"$CMUX_SETTINGS" set shortcuts.bindings.triggerFlash null
"$CMUX_SETTINGS" set shortcuts.bindings.sendFeedback null
```

## Rules

- Do not edit `~/.config/cmux/settings.json` unless the user explicitly asks. It is legacy fallback config.
- Do not overwrite all of `shortcuts.bindings` unless the user explicitly wants a full replacement.
- Do not invent action IDs. Validate against the schema or `shortcut-actions.md`.
- Do not apply a broad template without showing the changed actions first unless the user explicitly said to apply that named template.
- Do not promise conflict detection from `cmux-settings validate`; it validates syntax and supported keys, not every focus-context conflict.
- Prefer `unset` to "restore defaults" for individual actions:
  ```bash
  "$CMUX_SETTINGS" unset shortcuts.bindings.focusLeft
  "$CMUX_SETTINGS" validate
  ```
