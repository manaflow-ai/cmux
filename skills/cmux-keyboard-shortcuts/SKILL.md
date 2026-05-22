---
name: cmux-keyboard-shortcuts
description: "Guide and apply cmux keyboard shortcut customization. Use when the user asks to customize, rebind, unbind, reset, audit, or create shortcut templates for cmux, including tmux-style, Vim-style, terminal-first, browser-heavy, iTerm/Terminal-like, or agent-triage layouts."
---

# cmux-keyboard-shortcuts

Use this skill to turn a user's workflow preferences into cmux shortcut bindings in `~/.config/cmux/cmux.json`. It should guide the user, propose compact templates, apply selected changes, and confirm the config parses with recognized keys.

## Prerequisites

- Work from a cmux checkout or worktree root when possible.
- Use `skills/cmux-settings/scripts/cmux-settings` for every read/write. It reads JSONC, writes atomically, and validates JSON plus recognized settings keys.
- For action IDs, read `skills/cmux-settings/references/shortcut-actions.md`.
- For current defaults, read `web/data/cmux-shortcuts.ts` or `Sources/KeyboardShortcutSettings.swift`.

```bash
find_cmux_settings() {
  local root
  root="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
  for candidate in \
    "$root/skills/cmux-settings/scripts/cmux-settings" \
    "${CODEX_HOME:-$HOME/.codex}/skills/cmux-settings/scripts/cmux-settings" \
    "$HOME/.agents/skills/cmux-settings/scripts/cmux-settings"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if [[ -z "${CMUX_SETTINGS:-}" ]]; then
  CMUX_SETTINGS="$(find_cmux_settings)" || {
    echo "cmux-settings helper not found; run from a cmux checkout or install cmux-settings" >&2
    exit 1
  }
fi
```

## Shortcut Model

- Setting path: `shortcuts.bindings.<actionId>`.
- Single stroke: `"cmd+b"`.
- Chord: `["ctrl+b","c"]`. The first stroke needs a modifier unless the key is Space. The second stroke can be bare.
- Unbind: prefer `null` for explicit unbinds. `""`, `"none"`, `"clear"`, `"unbound"`, and `"disabled"` are accepted aliases, but `null` is the clearest JSON value and matches the templates below.
- `selectSurfaceByNumber` and `selectWorkspaceByNumber` must use a digit from 1 to 9. `cmd+1` means the full `cmd+1` through `cmd+9` family.
- `showHideAllWindows` and `globalSearch` are system-wide shortcuts. They cannot be chords, require modifiers, and may be rejected by macOS if reserved.
- `showHideAllWindows` also requires Settings > Global Hotkey > Enable System-Wide Hotkey. The binding can validate in `cmux.json` while the feature is disabled, so warn the user to enable that setting before reporting the shortcut as usable.
- `unset` deletes a `cmux.json` override. It does not clear shortcut changes saved through the Settings UI/UserDefaults. If the user asks for true built-in defaults, tell them to use Settings > Keyboard Shortcuts > Reset Default Shortcuts after clearing file-managed overrides, then verify in the app. For `showHideAllWindows`, use Settings > Global Hotkey to restore the shortcut to `ctrl+opt+cmd+.` because Keyboard Shortcuts > Reset Default Shortcuts intentionally skips the global hotkey.
- Saving `cmux.json` live reloads. Do not tell the user to restart cmux.

## Workflow

1. Classify the request:
   - One-off rebind or unbind: map the phrase to an action ID, apply it, validate, and report the previous and new binding.
   - Audit-only request: inspect current bindings, validate, and summarize overrides/unbound shortcuts without writing.
   - Reset request: clarify whether the user means file-managed overrides or true built-in defaults. For file-managed resets, use `unset` for named actions. For true built-in defaults, remove file overrides and direct the user to Settings > Keyboard Shortcuts > Reset Default Shortcuts; do not report built-in defaults restored from `cmux-settings` alone. If `showHideAllWindows` is included, also direct them to Settings > Global Hotkey to restore `ctrl+opt+cmd+.` and the enable toggle.
   - Broad customization request: propose 3 to 5 templates from "Preset Templates" and ask the user to choose.
   - Named style such as tmux, Vim, iTerm, browser, or agent triage: select the closest template, show the changed actions and likely collisions, and ask before a bulk apply unless the user explicitly said to apply it.
2. Inspect existing config:

   ```bash
   "$CMUX_SETTINGS" path
   "$CMUX_SETTINGS" get shortcuts.bindings 2>/dev/null || printf '{}\n'
   "$CMUX_SETTINGS" validate
   ```

3. Before applying a template, snapshot prior values for every action you will change. A path that is absent must revert with `unset`; a path with an existing custom value must revert with `set <same-json-value>`.

   ```bash
   "$CMUX_SETTINGS" get shortcuts.bindings.focusLeft 2>/dev/null || printf '<absent>\n'
   ```

4. Apply only the chosen action paths:

   ```bash
   "$CMUX_SETTINGS" set shortcuts.bindings.newSurface '["ctrl+b","c"]'
   "$CMUX_SETTINGS" set shortcuts.bindings.focusLeft cmd+opt+h
   "$CMUX_SETTINGS" set shortcuts.bindings.sendFeedback null
   "$CMUX_SETTINGS" validate
   ```

5. Verify readback for changed actions:

   ```bash
   "$CMUX_SETTINGS" get shortcuts.bindings.newSurface
   ```

6. Finish with the template name, changed actions, and exact revert commands from the snapshot. Use `unset` only for actions that were absent before the template; use `set` to restore previous custom bindings.

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

### macOS Terminal/iTerm Restore

For users who want surface, split, and tab behavior to feel like common macOS terminals again. These actions already match cmux built-in defaults when no Settings UI override exists, so unset file overrides instead of writing default values.

```bash
"$CMUX_SETTINGS" unset shortcuts.bindings.newSurface
"$CMUX_SETTINGS" unset shortcuts.bindings.closeTab
"$CMUX_SETTINGS" unset shortcuts.bindings.nextSurface
"$CMUX_SETTINGS" unset shortcuts.bindings.prevSurface
"$CMUX_SETTINGS" unset shortcuts.bindings.selectSurfaceByNumber
"$CMUX_SETTINGS" unset shortcuts.bindings.splitRight
"$CMUX_SETTINGS" unset shortcuts.bindings.splitDown
"$CMUX_SETTINGS" unset shortcuts.bindings.toggleSplitZoom
"$CMUX_SETTINGS" unset shortcuts.bindings.toggleTerminalCopyMode
"$CMUX_SETTINGS" unset shortcuts.bindings.renameTab
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

For users who live in notifications and want unread handling on one key family. This keeps toggle unread on `cmd+opt+u` so it can be combined with Vim Pane Navigation without colliding with `cmd+opt+j`.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.showNotifications cmd+u
"$CMUX_SETTINGS" set shortcuts.bindings.jumpToUnread cmd+j
"$CMUX_SETTINGS" set shortcuts.bindings.markOldestUnreadAndJumpNext cmd+shift+j
"$CMUX_SETTINGS" set shortcuts.bindings.toggleUnread cmd+opt+u
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
"$CMUX_SETTINGS" set shortcuts.bindings.nextSurface 'cmd+shift+]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSurface 'cmd+shift+['
```

### Browser Defaults Restore

For users who changed too much and want embedded-browser behavior to match common macOS browser shortcuts again. Use `unset` to clear file overrides so future cmux defaults still apply when no Settings UI override exists.

```bash
"$CMUX_SETTINGS" unset shortcuts.bindings.openBrowser
"$CMUX_SETTINGS" unset shortcuts.bindings.focusBrowserAddressBar
"$CMUX_SETTINGS" unset shortcuts.bindings.browserBack
"$CMUX_SETTINGS" unset shortcuts.bindings.browserForward
"$CMUX_SETTINGS" unset shortcuts.bindings.browserReload
"$CMUX_SETTINGS" unset shortcuts.bindings.browserZoomIn
"$CMUX_SETTINGS" unset shortcuts.bindings.browserZoomOut
"$CMUX_SETTINGS" unset shortcuts.bindings.browserZoomReset
"$CMUX_SETTINGS" unset shortcuts.bindings.toggleBrowserDeveloperTools
"$CMUX_SETTINGS" unset shortcuts.bindings.showBrowserJavaScriptConsole
"$CMUX_SETTINGS" unset shortcuts.bindings.find
"$CMUX_SETTINGS" unset shortcuts.bindings.findNext
"$CMUX_SETTINGS" unset shortcuts.bindings.findPrevious
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
- Do not promise conflict detection from `cmux-settings validate`; it validates JSON and supported keys, not shortcut syntax, macOS reservation, or every focus-context conflict.
- Before assigning `cmd+[` or `cmd+]` to application-scoped actions, warn that they collide with common browser Back/Forward behavior unless the browser actions are also changed or unbound.
- Prefer `unset` to clear file-managed overrides for individual actions. Do not call this a built-in default reset unless Settings UI/UserDefaults values have also been reset:

  ```bash
  "$CMUX_SETTINGS" unset shortcuts.bindings.focusLeft
  "$CMUX_SETTINGS" validate
  ```
