---
name: cmux-keyboard-shortcuts
description: "Guide and apply cmux keyboard shortcut customization. Use when the user asks to customize, rebind, unbind, reset, audit, or create shortcut templates for cmux, including tmux-style, Vim-style, terminal-first, browser-heavy, iTerm/Terminal-like, or agent-triage layouts."
---

# cmux-keyboard-shortcuts

Turn a user's workflow preferences into cmux shortcut bindings in `~/.config/cmux/cmux.json`: guide, propose compact templates, apply the selected changes, and confirm the config parses with recognized keys.

## Contributor rule: adding a new shortcut

Every new cmux-owned keyboard shortcut must be added to `Sources/KeyboardShortcutSettings.swift`, visible and editable in Settings > Keyboard Shortcuts, supported as `shortcuts.bindings.<actionId>` in `~/.config/cmux/cmux.json`, and documented in `web/app/[locale]/(landing)/docs/keyboard-shortcuts/page.tsx` and the configuration docs. All four, not a subset.

## Prerequisites

- Work from a cmux checkout or worktree root when possible.
- Use `skills/cmux-settings/scripts/cmux-settings` for every read/write. It reads JSONC, writes atomically, and validates JSON plus recognized settings keys.
- Action IDs: `skills/cmux-settings/references/shortcut-actions.md`. Current defaults: `web/data/cmux-shortcuts.ts` or `Sources/KeyboardShortcutSettings.swift`.

```bash
if [[ -z "${CMUX_SETTINGS:-}" ]]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for candidate in \
    "$root/skills/cmux-settings/scripts/cmux-settings" \
    "${CODEX_HOME:-$HOME/.codex}/skills/cmux-settings/scripts/cmux-settings" \
    "$HOME/.agents/skills/cmux-settings/scripts/cmux-settings"; do
    [[ -x "$candidate" ]] && CMUX_SETTINGS="$candidate" && break
  done
  [[ -n "${CMUX_SETTINGS:-}" ]] || {
    echo "cmux-settings helper not found; run from a cmux checkout or install cmux-settings" >&2
    exit 1
  }
fi
```

## Shortcut model

- Setting path: `shortcuts.bindings.<actionId>`.
- Single stroke: `"cmd+b"`.
- Chord: `["ctrl+b","c"]`. The first stroke needs a modifier unless the key is Space. The second stroke can be bare.
- Unbind: prefer `null` for explicit unbinds. `""`, `"none"`, `"clear"`, `"unbound"`, and `"disabled"` are accepted aliases, but `null` is the clearest JSON value and matches the templates below.
- `selectSurfaceByNumber` and `selectWorkspaceByNumber` must use a digit from 1 to 9. `cmd+1` means the full `cmd+1` through `cmd+9` family.
- `showHideAllWindows` is the only system-wide shortcut. It cannot be a chord, requires modifiers, and may be rejected by macOS if reserved.
- `globalSearch` is application-scoped and only fires while cmux is active.
- `showHideAllWindows` also requires Settings > Global Hotkey > Enable System-Wide Hotkey. The binding can validate in `cmux.json` while the feature is disabled, so warn the user to enable that setting before reporting the shortcut as usable.
- `unset` deletes a `cmux.json` override. It does not clear shortcut changes saved through the Settings UI/UserDefaults. If the user asks for true built-in defaults, tell them to use Settings > Keyboard Shortcuts > Reset Default Shortcuts after clearing file-managed overrides, then verify in the app. For `showHideAllWindows`, use Settings > Global Hotkey to restore the shortcut to `ctrl+opt+cmd+.` because Keyboard Shortcuts > Reset Default Shortcuts intentionally skips the global hotkey.
- Saving `cmux.json` live reloads. Never tell the user to restart cmux.

## Workflow

1. Classify the request:
   - **One-off rebind/unbind:** map the phrase to an action ID, apply, validate, report previous and new binding.
   - **Audit:** inspect bindings, validate, summarize overrides and unbound shortcuts without writing.
   - **Reset:** clarify file-managed overrides vs true built-in defaults (see the `unset` rule above).
   - **Broad customization:** propose 3-5 templates below and ask the user to choose.
   - **Named style** (tmux, Vim, iTerm, browser, agent triage): pick the closest template, show the changed actions and likely collisions, and ask before a bulk apply unless the user already named that template.
2. Inspect existing config:

   ```bash
   "$CMUX_SETTINGS" path
   "$CMUX_SETTINGS" get shortcuts.bindings 2>/dev/null || printf '{}\n'
   "$CMUX_SETTINGS" validate
   ```

3. Snapshot prior values for every action you will change. A path that was absent reverts with `unset`; a path with an existing custom value reverts with `set <same-json-value>`.

   ```bash
   "$CMUX_SETTINGS" get shortcuts.bindings.focusLeft 2>/dev/null || printf '<absent>\n'
   ```

4. Apply only the chosen action paths, then `"$CMUX_SETTINGS" validate`.

   ```bash
   "$CMUX_SETTINGS" set shortcuts.bindings.newSurface '["ctrl+b","c"]'
   "$CMUX_SETTINGS" set shortcuts.bindings.focusLeft cmd+opt+h
   "$CMUX_SETTINGS" set shortcuts.bindings.sendFeedback null
   ```

5. Read back each changed action: `"$CMUX_SETTINGS" get shortcuts.bindings.newSurface`.
6. Finish with the template name, changed actions, and exact revert commands from the snapshot.

## Preset templates

Apply action by action, never by overwriting the whole `shortcuts.bindings` object.

### Tmux Prefix

One terminal-style namespace; `ctrl+b` starts a cmux chord instead of reaching the shell.

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

These actions already match cmux built-in defaults, so clear file overrides rather than writing default values.

```bash
for a in newSurface closeTab nextSurface prevSurface selectSurfaceByNumber \
         splitRight splitDown toggleSplitZoom toggleTerminalCopyMode renameTab; do
  "$CMUX_SETTINGS" unset "shortcuts.bindings.$a"
done
```

### Vim Pane Navigation

Prefix-free pane movement with no arrow keys.

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

Unread handling on one key family. `toggleUnread` stays on `cmd+opt+u` so this composes with Vim Pane Navigation without colliding with `cmd+opt+j`.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.showNotifications cmd+u
"$CMUX_SETTINGS" set shortcuts.bindings.jumpToUnread cmd+j
"$CMUX_SETTINGS" set shortcuts.bindings.markOldestUnreadAndJumpNext cmd+shift+j
"$CMUX_SETTINGS" set shortcuts.bindings.toggleUnread cmd+opt+u
"$CMUX_SETTINGS" set shortcuts.bindings.triggerFlash cmd+shift+h
"$CMUX_SETTINGS" set shortcuts.bindings.focusRightSidebar cmd+shift+e
```

### Workspace And Surface Lanes

Workspaces and surfaces on distinct number and bracket lanes.

```bash
"$CMUX_SETTINGS" set shortcuts.bindings.selectWorkspaceByNumber cmd+1
"$CMUX_SETTINGS" set shortcuts.bindings.selectSurfaceByNumber cmd+opt+1
"$CMUX_SETTINGS" set shortcuts.bindings.nextSidebarTab 'cmd+opt+]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSidebarTab 'cmd+opt+['
"$CMUX_SETTINGS" set shortcuts.bindings.nextSurface 'cmd+shift+]'
"$CMUX_SETTINGS" set shortcuts.bindings.prevSurface 'cmd+shift+['
```

### Browser Defaults Restore

Return embedded-browser behavior to common macOS browser shortcuts. `unset` keeps future cmux defaults applying.

```bash
for a in openBrowser focusBrowserAddressBar browserBack browserForward browserReload \
         browserZoomIn browserZoomOut browserZoomReset toggleBrowserDeveloperTools \
         showBrowserJavaScriptConsole find findNext findPrevious; do
  "$CMUX_SETTINGS" unset "shortcuts.bindings.$a"
done
```

### Terminal-First Cleanup

Fewer app-level shortcuts. Prefer unbinding only the actions the user names; this is a starting proposal.

```bash
for a in renameTab renameWorkspace editWorkspaceDescription triggerFlash sendFeedback; do
  "$CMUX_SETTINGS" set "shortcuts.bindings.$a" null
done
```

## Rules

- Do not edit `~/.config/cmux/settings.json` unless the user explicitly asks; it is legacy fallback config.
- Do not overwrite all of `shortcuts.bindings` unless the user wants a full replacement.
- Do not invent action IDs. Validate against the schema or `shortcut-actions.md`.
- Do not apply a broad template without showing the changed actions first, unless the user named that template.
- Do not promise conflict detection from `cmux-settings validate`. It validates JSON and supported keys, not shortcut syntax, macOS reservation, or focus-context conflicts.
- Before assigning `cmd+[` or `cmd+]` to application-scoped actions, warn that they collide with browser Back/Forward unless the browser actions are also changed or unbound.
- `unset` clears file-managed overrides for one action. Do not call that a built-in default reset unless Settings UI/UserDefaults values were also reset.
