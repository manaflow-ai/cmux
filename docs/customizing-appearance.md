# Customizing cmux's look

cmux's terminals run on libghostty, so most of the terminal's look comes from
Ghostty config: theme, fonts, cursor, transparency, background images, padding,
and shaders. The app chrome around the terminals (sidebar, workspace colors,
pane borders, notification rings, icon) lives in `~/.config/cmux/cmux.json`.

## Where settings live

| File | What it controls | How changes apply |
| --- | --- | --- |
| `~/.config/ghostty/config` or `~/.config/ghostty/config.ghostty` | Terminal rendering, shared with standalone Ghostty | **Reload Configuration** (Cmd+Shift+,) or `cmux reload-config` |
| `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` | Same, Ghostty's macOS location | Same |
| `~/Library/Application Support/com.cmuxterm.app/config.ghostty` | cmux-only Ghostty overrides. `cmux themes` and the Settings font-size controls write here | Same |
| `~/.config/cmux/cmux.json` | App chrome and behavior ([schema](https://github.com/manaflow-ai/cmux/blob/main/web/data/cmux.schema.json)) | Reloads automatically when you save |

cmux loads its own `config.ghostty` after Ghostty's files, so a key set there
wins. Nightly and RC builds use their own folder (for example
`com.cmuxterm.app.nightly`) and fall back to the release one when theirs is
empty. `config-file = ...` includes work as they do in Ghostty.
The full `cmux.json` reference is at <https://cmux.com/docs/configuration>.

Some keys are read only by cmux: `sidebar-background`, `sidebar-tint-opacity`,
`sidebar-font-size`, and `surface-tab-bar-font-size`. Standalone Ghostty
doesn't recognize them, so if you share `~/.config/ghostty/config` with Ghostty,
put them in cmux's own `config.ghostty` instead.

### What cmux overrides

cmux owns the window, the shell bootstrap, and its shortcuts, so a few Ghostty
settings are replaced or don't apply:

- `term` is always `xterm-256color`.
- `shell-integration` is forced to `none` because cmux's own bootstrap loads
  Ghostty's zsh and bash integration. Set `shell-integration = none` yourself
  to skip that too. Your `shell-integration-features` are kept, except
  `cursor` is always off (see [Cursor](#cursor)).
- `macos-background-from-layer = true` and `macos-titlebar-proxy-icon = hidden`
  are always set.
- `terminal.copyOnSelect: true` in `cmux.json` sets
  `copy-on-select = clipboard`. When it's false, your Ghostty value applies.
- `font-size` is multiplied by `app.globalFontMagnification` when that isn't 100.
- These Ghostty keybinds are unbound so cmux's remappable shortcuts can use
  them: Cmd+D, Cmd+Shift+D, Cmd+W, Cmd+Option+W, Cmd+Shift+W, Cmd+Ctrl+=, and
  Cmd+1 through Cmd+9. Rebind them in Settings > Keyboard Shortcuts or
  `shortcuts.bindings` in `cmux.json`.
- Settings implemented by Ghostty.app's own windowing code, rather than
  libghostty, have no effect: for example `macos-titlebar-style`,
  `macos-icon`, `window-decoration`, and `window-width`/`window-height`.

## Themes

Pick a theme interactively, with a live preview across the running app:

```bash
cmux themes
```

Or script it:

```bash
cmux themes list
cmux themes set "Catppuccin Mocha"
cmux themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
cmux themes clear
```

`set` writes `theme = light:...,dark:...` into cmux's `config.ghostty` and asks
the app to reload. `clear` removes that line so your Ghostty config's `theme`
applies again. You can also write the pair yourself in any Ghostty config file:

```ini
theme = light:Catppuccin Latte,dark:Catppuccin Mocha
```

The light or dark half follows `app.appearance` (`system`, `light`, or `dark`)
in `cmux.json`.

Custom themes are ordinary Ghostty config files. Put one in
`~/.config/ghostty/themes/<Name>` and it shows up in `cmux themes list`. Colors
set directly in your config (`background`, `foreground`, `palette`, and so on)
override the theme's.

With no theme and no terminal colors configured, cmux supplies its own
light/dark palette. Set `"terminal": { "adaptiveDefaultTheme": false }` in
`cmux.json` to get Ghostty's fixed built-in palette instead.

## Transparency, blur, and background images

```ini
background-opacity = 0.85
background-blur = 20
```

- `background-opacity` below 1 makes the whole cmux window translucent.
  `background-opacity-cells = true` also applies it to cells with an explicit
  background color.
- `background-blur` takes an intensity, `true` (20), or `false`. cmux passes it
  to the same macOS compositor call standalone Ghostty uses. On macOS 26,
  `macos-glass-regular` and `macos-glass-clear` switch the window to native
  glass.
- Known gaps: [#1674](https://github.com/manaflow-ai/cmux/issues/1674) tracks
  blur and opacity looking different from standalone Ghostty, and
  [#2581](https://github.com/manaflow-ai/cmux/issues/2581) tracks transparency
  being lost in fullscreen.
- `sidebarAppearance.tintOpacity` in `cmux.json` only tints the sidebar; it
  doesn't make the terminal transparent.

Background images come from libghostty's renderer and work in cmux:

```ini
background-image = ~/Pictures/wallpaper.png
background-image-opacity = 0.3
background-image-fit = cover
background-image-position = center
```

PNG and JPEG only. Each terminal draws its own copy, so the image repeats across
split panes and each copy uses its own GPU memory.

`window-padding-x`, `window-padding-y`, `window-padding-balance`, and
`window-padding-color` pad each terminal pane.

## Fonts

```ini
font-family = JetBrains Mono
font-size = 14
font-feature = -calt, -liga, -dlig
font-thicken = true
adjust-cell-height = 10%
```

`font-feature = -calt` turns off programming ligatures; `-calt, -liga, -dlig`
turns off most ligatures.

- `app.globalFontMagnification` in `cmux.json` (50 to 200, in steps of 10)
  scales terminals, tab titles, sidebars, settings, and other app chrome
  together.
- Cmd+Ctrl+= and Cmd+Ctrl+- change every terminal in the current workspace by
  one point; Cmd+Ctrl+0 resets them.
- `sidebar-font-size` (10 to 20, default 12.5) and `surface-tab-bar-font-size`
  (8 to 14, default 11) size the sidebar and pane tab bars. Settings writes both
  to cmux's `config.ghostty`.

## Cursor

```ini
cursor-style = bar
cursor-style-blink = false
cursor-color = #f5c2e7
cursor-text = #1e1e2e
cursor-opacity = 0.9
```

cmux turns off Ghostty's shell-integration `cursor` feature, which would switch
the cursor to a bar at the prompt. Your `cursor-style` is what you see at the
prompt; programs can still change it with escape sequences.

## Custom shaders

cmux's Ghostty fork supports `custom-shader`, including the cursor uniforms
(`iCurrentCursor`, `iPreviousCursor`, `iTimeCursorChange`) that cursor-trail
shaders use:

```ini
custom-shader = ~/.config/ghostty/shaders/cursor_smear.glsl
custom-shader-animation = true
```

Repeat `custom-shader` to chain shaders. A shader that fails to compile is
skipped, and the error goes to the log rather than showing as a config error.

## Panes

| Setting | Where | Effect |
| --- | --- | --- |
| `unfocused-split-opacity`, `unfocused-split-fill` | Ghostty config | Dim unfocused cmux panes |
| `split-divider-color` | Ghostty config | Pane divider color when `paneBorderColor` is unset |
| `paneBorderColor` | `cmux.json` | Divider color between cmux panes |
| `activePaneBorderColor` | `cmux.json` | Border around the focused pane |

## Sidebar

In `cmux.json`:

- `sidebarAppearance.tintColor`, `lightModeTintColor`, `darkModeTintColor`, and
  `tintOpacity` (0 to 1, default 0.18) tint the sidebar.
- `sidebarAppearance.matchTerminalBackground: true` uses the terminal
  background instead of a tint.
- `sidebar.*` keys pick which rows appear (branch, PRs, ports, logs, progress,
  notification text, and so on), and `sidebar.workspaceDescriptionColor`
  recolors workspace descriptions. See the
  [schema](https://github.com/manaflow-ai/cmux/blob/main/web/data/cmux.schema.json)
  for the full list.

The Ghostty keys `sidebar-background` (a hex color, or
`light:#hex,dark:#hex`) and `sidebar-tint-opacity` set the same tint. Use one
place or the other.

To replace the sidebar entirely, write a [custom sidebar](custom-sidebars.md)
in `~/.config/cmux/sidebars/`. [`Examples/CustomSidebars`](../Examples/CustomSidebars)
has ready-to-copy ones.

## Workspace and notification colors

- `workspaceColors.indicatorStyle`: `leftRail` (default) or `solidFill` for the
  selected workspace.
- `workspaceColors.selectionColor` and `workspaceColors.notificationBadgeColor`
  override those colors.
- `workspaceColors.colors` is the named palette shown in the workspace color
  picker. It replaces the built-in palette, so copy the default entries from the
  schema that you want to keep.
- Color a workspace from the CLI: `cmux workspace-action set-color Amber` or
  `cmux workspace-action --action set-color --color "#C0392B"`.
- `notifications.paneFlashColor` recolors the unread pane ring and pane flash.
  `notifications.unreadPaneRing` and `notifications.paneFlash` turn them off.

## App chrome

- `app.minimalMode: true` hides the workspace title bar and moves its controls
  into the sidebar.
- `app.appIcon`: `automatic`, `light`, or `dark` for the Dock and app switcher
  icon.
- `app.appearance`: `system`, `light`, or `dark`.

## Prompts and images

- Prompt themes such as Starship and oh-my-posh work in cmux terminals. Set them
  up in your shell rc files as usual.
- With Ghostty's shell integration loaded (zsh and bash, unless you set
  `shell-integration = none`), prompts are marked with OSC 133. Cmd+Shift+Up and
  Cmd+Shift+Down jump between prompts, and `{`/`}` do the same in keyboard copy
  mode.
- The kitty graphics protocol works, so image viewers that use it display
  inline. `image-storage-limit` caps the memory used.

## Example configs

`~/Library/Application Support/com.cmuxterm.app/config.ghostty`:

```ini
theme = light:Catppuccin Latte,dark:Catppuccin Mocha

font-family = JetBrains Mono
font-size = 14
font-feature = -calt

background-opacity = 0.9
background-blur = 20
window-padding-x = 8
window-padding-y = 6
window-padding-balance = true

cursor-style = bar
cursor-style-blink = false

unfocused-split-opacity = 0.85

sidebar-font-size = 13
surface-tab-bar-font-size = 12
```

`~/.config/cmux/cmux.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
  "schemaVersion": 1,
  "app": {
    "appearance": "system",
    "appIcon": "automatic",
    "minimalMode": true,
    "globalFontMagnification": 110
  },
  "paneBorderColor": "#313244",
  "activePaneBorderColor": "#CBA6F7",
  "sidebarAppearance": {
    "lightModeTintColor": "#EFF1F5",
    "darkModeTintColor": "#1E1E2E",
    "tintOpacity": 0.35
  },
  "workspaceColors": {
    "indicatorStyle": "solidFill",
    "selectionColor": "#45475A"
  },
  "notifications": {
    "paneFlashColor": "#F5C2E7"
  }
}
```

Save `cmux.json` and it applies. After editing the Ghostty file, press
Cmd+Shift+, or run `cmux reload-config`.
