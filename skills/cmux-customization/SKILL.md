---
name: cmux-customization
description: "Customize cmux for its user: cmux-next.json (or classic cmux.json) actions, commands, layouts, buttons, Command Palette, Dock, sidebar and app settings, shortcuts, notifications, browser routing, terminal preferences, the examples library, and views of their own (a sidebar or Session Info section built as the customize app)."
---

# cmux Customization

Keep the user's config intact, prefer schema-backed edits, and validate before reporting completion.

For content viewers, start with [the viewer customization matrix](references/viewer-types.md).
It maps each viewer to the settings, command, or external file that owns its
knobs, including explicit fallbacks for viewer types whose template settings
have not shipped yet.

## Choose the right surface

cmux-next reads one settings file, `~/.config/cmux/cmux-next.json`; classic
`~/.config/cmux/cmux.json` is copied into it once on first launch and not read
after that.

| Want to change | Edit |
|---|---|
| App preferences (appearance, sidebar, notifications, browser routing, diff, files, Computer Use) | `cmux settings set <key> <value>`; keys come from `schemas/settings/settings-schema.json` (see [cmux-settings](../cmux-settings/SKILL.md)). `files.textEditor` and `computerUse.*` are user-only: the person changes them |
| Custom actions and Command Palette entries | `actions` in `cmux-next.json` (types `command` and `agent` only) |
| Terminal rendering (fonts, themes, cursor style, copy-on-select, shell integration) | Ghostty config, usually `~/.config/ghostty/config`; `terminal.fontFamily`, `terminal.fontSize` and `appearance.theme` override it in cmux settings |
| Bring fonts, colors and terminal behavior over from another terminal | Not supported: `cmux import` was removed with the Swift CLI. Copy the values into Ghostty config by hand. |
| Workspace names, descriptions, colors, read state | cmux CLI app actions (`cmux workspace set-color --target ws_… --color blue`), see [../cmux/references/windows-workspaces.md](../cmux/references/windows-workspaces.md) |
| Agent hooks (agent state in the sidebar) | `cmux agent hook install [provider…]`; `cmux agent hook status` to check |

Not yet supported in cmux-next, even though classic cmux read them:
`text`, `workspaceCommand` and `workspace` action types (reported and skipped by
the action parser, so `submit` is never read), `commands` workspace layouts,
`ui.newWorkspace.*` plus-button wiring (`action`, `contextMenu`, `rightClick`),
`ui.surfaceTabBar.buttons` (the tab bar buttons were removed), Dock files (`.cmux/dock.json`, `~/.config/cmux/dock.json`) and
project-local `.cmux/cmux.json`. Say so instead of writing them. The recipes in
[references/examples.md](references/examples.md) that use them are classic-only.

If a request can be handled by Ghostty config, say so and use Ghostty config instead of inventing cmux UI settings.

Key surface: `actions`, named entries with `type: "command"` (`command`) or `type: "agent"` (`agent`, optional `args`), plus optional `title`, `tooltip`, `icon` and `target` (`newTabInCurrentPane` or `currentTerminal`). Each registers as `cmuxConfig.<name>` for the Command Palette, shortcuts and `cmux action run`.

## Workflow

1. Inspect the existing file.

   ```bash
   test -f ~/.config/cmux/cmux-next.json && sed -n '1,220p' ~/.config/cmux/cmux-next.json
   ```

2. Open a draft instead of making a backup copy. cmux keeps every applied setup as a numbered generation, so what was there is one step away.

   ```bash
   cmux customize brief 'what the person asked for, in their words'
   ```

   It prints where each part lives (settings, shortcuts, themes, their own views, the chat stylesheet, automations) and which files the person edited by hand since your last turn: read those again before writing. From an MCP client the same thing is the `customize_ask` tool. Every save you make shows in their cmux window at once; that is the preview.

3. For app settings, use `cmux settings set <key> <value>` and read it back with `cmux settings get <key>`. Never hand-write a settings key: the app ignores a value its build refuses and keeps the default.
4. For actions, edit the JSONC by hand and preserve unrelated sections.
5. Run `cmux settings validate`; it must report no problems. It checks schema values only: an unknown action id, an unsupported chord or a removed key shows only in the app's toast and on the Settings row. Then `cmux settings reload-configuration` (the app also reloads on save). A refused value also shows a toast in the app that names the key, the value and why ([cmux-settings](../cmux-settings/SKILL.md#when-the-app-ignores-a-value)).
6. Verify the configured entrypoint exists: confirm the action ID and where it should appear.
7. Run `cmux customize check` (or `customize_check`) and fix every problem it lists, each with a file and a line, until there are none. Then stop: do not run `cmux customize apply` or `discard` unless the person says so. Tell them what changed on screen and that it is a preview they can apply, refine by asking again, or discard. After an apply, `cmux customize rollback` goes back one generation and `cmux customize save NAME` keeps the setup as one file they can share.

For viewer changes, verify the exact path or command state from the matrix. If
the requested viewer or knob is absent from the schema, explain that it is not
supported yet instead of writing an unknown key. The `templates.<viewer>`
surface proposed for future notes/Markdown/diff customization is not available
until the schema and runtime implement it.

## Example: Command Palette action

Appears in Cmd+Shift+P as `cmuxConfig.codex-new-tab`.

```json
{
  "actions": {
    "codex-new-tab": {
      "type": "agent",
      "agent": "codex",
      "title": "Codex",
      "tooltip": "Start Codex in this workspace",
      "target": "newTabInCurrentPane"
    }
  }
}
```

Before choosing a preset, template, starter config, or known workflow pattern, read [references/examples.md](references/examples.md). `cmux docs workflows` was removed with the Swift CLI, so that file is the catalog.

## Validation

- App settings: read each key back with `cmux settings get <key>`.
- Keep valid JSONC, no duplicate keys.
- `cmux settings reload-configuration` when the app is running.
- Confirm the exact user-facing result: action title, shortcut, or palette entry.

## Rules

- Do not overwrite a whole top-level config section unless you own the full section.
- Do not store secrets in actions, commands, or prompts. Use environment variables or the user's secret manager.
- Do not use sleeps or timing workarounds in generated commands.
- Do not add a cmux setting for behavior Ghostty already owns.
- Keep labels short enough for menus, buttons, and the Command Palette.

## Rice cmux

A whole look (terminal theme, App Theme, accent, background and its opacity,
borders, glass, motion, even the terminal's own colors) lives in one dotfile:
`~/.config/cmux/themes/<name>.json`. No build, no restart: pick it once with
`cmux settings set appearance.themeFile <name>` (or the palette's Theme File row,
which previews each file on the whole app as you move over it), and from then on
every save of that file re-applies it live to the window, every page, the agent
pane and the terminals. `cmux settings reset appearance.themeFile` goes back.

The file is JSONC in cmux-next.json's own shape, nested or with dotted keys at the
top, so a block copies between the two:

```jsonc
// ~/.config/cmux/themes/tokyo.json
{
  "appearance.theme": "TokyoNight",       // the terminal theme
  "appearance.appTheme": "TokyoNight",    // the window, sidebar, tabs and pages
  "appearance.accent": "magenta",
  "appearance.background": "none",
  "appearance.backgroundOpacity": 0.85,
  "appearance.borders": "none",
  "appearance.glassTransparency": 0.6,
  "ui.animationSpeed": "fast",
  // The terminal theme's own colors, as appearance.themeEdits of the theme above.
  "colors": { "background": "#16161e", "foreground": "#c0caf5", "accent": "#bb9af7" },
  // Or a Ghostty theme block:
  // "ghostty": ["background = #16161e", "foreground = #c0caf5", "palette = 4=#7aa2f7"]
}
```

- cmux ships examples (`Resources/theme-files/` in the app), each in the Theme File
  list by name: `harbor` (the sidebar's own glass, the terminal font, a painting
  behind the window and the pane background), `classic-desktop` (gray chrome, hard
  edges, no motion), `phosphor` (green on black), `claude-desktop` (cream and clay),
  `charcoal` (a dark chat app), and three nature looks on the Blocks chrome: `moss`
  (deep forest green), `meadow` (sage and cream) and `lily-pond` (teal glass blocks
  over Monet's water lilies). To ask for a look, start from the closest one:
  copy it to `~/.config/cmux/themes/<name>.json` to edit it (your file of the same
  name wins over the shipped one). Steps and the undo path for people:
  [theme-recipes.md](../../docs/cmux-next/theme-recipes.md).
- A background picture may sit beside the theme: `"appearance.background":
  "file:harbor.jpg"` (or `folder:walls`, or `file:~/Pictures/x.png`) resolves against
  `~/.config/cmux/themes`, so a theme and its pictures move as one folder.
- A look is more than colors: shape the tabs, the sidebar and the buttons too.
  `"density"` is the theme's own density, the blockiness of every horizontal tab and
  sidebar row, the sidebar's width, the tab strip's height and the toolbar's buttons:
  a built-in (`basedOn`) with the Density Playground's tokens over it (Cmd-Shift-P,
  Density Playground, lists every token with its range). While the file applies it is
  the density in use, over `appearance.density`. Edit it by hand (`cmux theme set`
  takes settings only):

  ```jsonc
  "density": {
    "basedOn": "compact",
    "tokens": {
      "tabCornerRadius": 2, "sidebarCornerRadius": 2, "verticalTabCornerRadius": 2, // square tabs
      "browserRowHeight": 26, "tabGap": 2,                                          // the tab strip
      "sidebarWidth": 250, "sidebarRowHeight": 26, "sidebarRowGap": 1,             // the sidebar
      "toolbarGlyphSize": 13, "omnibarButtonSpacing": 2, "itemCornerRadius": 3     // the buttons
    }
  }
  ```
- Only look settings apply (`appearance.*`, `ui.animation*`, `ui.calm`,
  `browser.omnibar.glass*`, `app.uiScale`, `terminal.fontFamily`,
  `terminal.fontSize`; the sidebar's shape, text and buttons: `sidebar.style`, `sidebar.border`,
  `sidebar.borderWidth`, `sidebar.sectionLook`, `sidebar.density`, `sidebar.textSize`,
  `sidebar.groupHeader.background`, `sidebar.groupPalette`, `sidebar.groupGradient`,
  `sidebar.showSearchButton`, `sidebar.showProfileControl`, `sidebar.showNewWorkspaceChooser`,
  `sidebar.controlsOnHover`, `sidebar.detailedStatusIcons`, `sidebar.showColors`,
  `sidebar.spacesVisibility`; the top right buttons and tabs: `tabs.toolbarButtons`,
  `tabs.plusButton`, `window.titlebarButtons`, `focus.inactiveTabStyle`; pane corners:
  `layout.paneCornerRadius`, `layout.cornerPadding`, `layout.paneBorderWidth`; the agent
  chat's text sizes and Session Info: `agentPane.display.font.*`, `agentPane.display.code.scale`,
  `agentPane.display.senderIcon.*`, `agentPane.display.sessionInfo.placement`,
  `agentPane.display.trayHandle`), each checked like `cmux settings set`.
  A refused value or key is dropped with the toast settings use, naming the
  theme file and the key (`themes/tokyo.json: appearance.accent = "purple" was
  ignored: ...`); the rest still applies. Look keys up as in
  [cmux-settings](../cmux-settings/SKILL.md).
- The theme file wins over the same keys in cmux-next.json (their Settings rows say
  so), and a managed (MDM or team) value wins over it. To change one of those keys,
  edit the theme file, or unset `appearance.themeFile`.
- Contrast is guarded: a `foreground` under 4.5:1 on its `background` shows as the
  app theme's text color instead, and Settings says so at the Theme File row.

### Restyle cmux from an agent: `cmux theme`

When someone asks you to change how cmux looks, use these commands rather than
hand-editing JSON. They check every value the same way the app does, keep the
file's comments, and work even when cmux is not running. The app picks up each
save at once, on the Mac and on a paired iPhone.

1. If no theme file is active yet, `cmux theme export --save <name> --use`. It
   writes the current look as a theme file and makes it the active one. Nothing on
   screen changes: each live entry holds today's value, and every other look key is
   a comment showing its default.
2. Change one thing at a time with `cmux theme set KEY VALUE`, for example
   `cmux theme set appearance.accent magenta` or
   `cmux theme set appearance.backgroundOpacity 0.85`. A value cmux refuses is
   rejected before anything is written, and the error says what is accepted.
3. Run `cmux theme check`. Each problem prints as `themes/NAME.json:LINE: key:
   message`. Exit 0 means there are none.
4. To undo, `cmux theme reset KEY` takes one key out. `cmux theme reset` with no
   key goes back to the stock look.

The other verbs:
- `cmux theme get [KEY]` shows what the file sets.
- `cmux theme list` lists the files and marks the active one.
- `cmux theme use NAME` picks a different file.
- `cmux theme import FILE.json [--use]` copies someone else's theme file in; without `--use`
  the look does not change.
- A shared theme in a git repository (`cmux-theme.json` at its root): `cmux theme install
  github.com/OWNER/REPO` installs it and puts it on in one step, wallpapers included. Never tell
  the person to run commands after it: run it yourself (`--yes` once they said yes), then say
  what changed. `cmux apps install` and `cmux theme import` of that repository do the same;
  `cmux theme remove OWNER/REPO` puts back the earlier look. A snippet repository
  (`cmux-snippet.json`: look settings and stylesheets, such as fonts) is `cmux snippet install`.
- To make a repository show up for others, give it the GitHub topics `cmux-extension` (what
  cmux.com's candidate list searches), `cmux-theme` (or `cmux-snippet`) and `cmux`, and list it
  in manaflow-ai/cmux-extensions: [theme-recipes.md](../../docs/cmux-next/theme-recipes.md#share-a-theme-so-people-find-it).
- `cmux theme schema --install` writes `themes/.schema.json` for editor completion.
  The exported file's `$schema` already points at it.
- A base16, iTerm2, Windows Terminal or Ghostty color scheme is a terminal theme, not
  a look. Install it with `cmux theme import scheme.yaml`, then
  `cmux theme set appearance.theme "<its name>"`.
- Add `--json` to any of these for output a script can read.

### Wallpaper that switches by itself

The picture behind the window can change on its own, the way macOS does it. When
someone asks for that ("switch my wallpaper at sunset", "use the Catalina dynamic
one"), run one `cmux wallpaper` command. It checks the values, expands `~`, writes
every key of the mode in one atomic settings write, and the app picks it up at once.
It prints what is now set in one line. `cmux wallpaper show` prints the mode, its
keys and the picture shown now.

| Ask | Command |
| --- | --- |
| One picture for light mode, one for dark | `cmux wallpaper follow-appearance --light ~/Pictures/day.jpg --dark ~/Pictures/night.jpg` |
| Switch at sunset (and back at 7) | `cmux wallpaper schedule 07:00=~/Pictures/day.jpg sunset=~/Pictures/night.jpg` |
| macOS Catalina, following the sun | `cmux wallpaper use-macos-dynamic catalina` |
| The dynamic wallpapers this Mac has | `cmux wallpaper use-macos-dynamic` |
| A folder, a new picture every 30 minutes | `cmux wallpaper rotate ~/Pictures/Walls --every 30m` |
| Sun times for another place | `cmux wallpaper location 37.77,-122.42` (`auto`: from the time zone) |
| One fixed picture, or none | `cmux wallpaper set ~/Pictures/x.jpg`, `cmux wallpaper off` |

- WHEN is `HH:MM` (24 h, local time) or `sunrise`, `sunset`, `dawn`, `dusk`, `noon`,
  with an optional offset: `sunset-30m`, `sunrise+1h`. The picture of the latest
  time today that has passed shows; before the first, yesterday's last.
- A picture is a path (image or movie), `desktop` (the desktop picture), a painting
  id, or a macOS wallpaper name (`sonoma`). A folder only goes to `set` or `rotate`.
- `use-macos-dynamic NAME --follow appearance` shows the wallpaper's light or dark
  picture instead of following the sun.
- `--every` takes `15m`, `30m`, `1h`, `daily`, or a number of minutes (1 to 1440).
- `schedule --clear` stops a schedule. Add `--json` for one object a script can read.

The same settings by hand, in `~/.config/cmux/cmux-next.json` (or a theme file):

```jsonc
// Follow light/dark
{ "appearance.background": "appearance",
  "appearance.backgroundLight": "file:/Users/me/Pictures/day.jpg",
  "appearance.backgroundDark": "file:/Users/me/Pictures/night.jpg" }

// Switch at sunset, back at 7:00
{ "appearance.background": "schedule",
  "appearance.backgroundSchedule": {
    "07:00": "file:/Users/me/Pictures/day.jpg",
    "sunset": "file:/Users/me/Pictures/night.jpg" } }

// macOS Catalina, following the sun (location: optional, default from the time zone)
{ "appearance.background": "system:/System/Library/Desktop Pictures/Catalina.madesktop",
  "appearance.backgroundDynamic": "time",
  "appearance.backgroundLocation": "37.77,-122.42" }

// A folder, every 30 minutes
{ "appearance.background": "folder:/Users/me/Pictures/Walls",
  "appearance.backgroundRotation": 30 }
```

## Make a view

When someone asks for a view of their own (a sidebar section, a Session Info
section, "a view of the PRs from the last 24h"), write the customize app in
`~/.config/cmux/customize`: `cmux-app.json` (id `local/customize`, manifest v2)
and `main.js`, a classic script that uses the scene globals (`VStack`, `Row`,
`ForEach`, `EmptyState`, ...) and ends with
`globalThis.__cmuxAppExports = { ... }`. cmux watches the folder: every save
reloads the view, and the app installs itself the first time. No restart, no
install click.

- A new view of its own (a sidebar section or a Session Info section): run `cmux ext new NAME --kind sidebar|session-info --json` in a folder, read its `DESIGN.md` (the look each kind should keep: rows with symbols, tones not colors, every state drawn, and a lead line where its DESIGN.md asks for one; a Session Info section has none, since its header leads), edit its `src/main.ts` keeping that shape, then `cmux ext dev --once --json` until ok.
  To share it from GitHub: `cmux ext new NAME --repo OWNER/REPO`, then `cmux ext publish --json` says what is left (push, `cmux ext pack` and a release, the registry PR) ([extensions.md](references/extensions.md)).
  Before any widget, section or pane is done, `cmux ext shot --json` must report `design: []`: build it from the type roles, `SPACE` and components in [extension-design.md](references/extension-design.md), which also has the loop and every check's fix.
- `implements["cmux.section/1"]` is its one sidebar section; `options.defaultRegion`
  `top`, `middle` or `bottom` (the band under the workspace list). cmux places it
  there the first time it sees it, and the person's later move or removal wins.
  Put it back on purpose with `cmux apps place 'local/customize#cmux.section/1' --region bottom`.
- `implements["cmux.session.info.section/1"]` is its one Session Info section; its
  render function gets `{ session_id, cwd, branch?, harness? }` as its argument.
- Show or hide it in one step: Toggle Custom Sidebar (Cmd+Shift+P, Ctrl+Opt+Cmd+B, the
  sidebar's right-click Options menu, or `cmux sidebar toggle-custom`). It flips the app's
  hidden flag, which cmux keeps across relaunches; with no customize folder it writes the
  starter template and the view appears.
- Scopes: read scopes (`integration:github:read`) are granted at install. Others
  (`actions:run`, `net:<host>`) need the person to turn them on in Settings > Apps.
- Script errors: `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'`.
- A section whose script failed shows the error with its `main.js:line` and a Reload button. A save
  mounts it again by itself; `cmux apps reload` (palette: Reload Custom Views) runs every local view
  again from its saved files without a restart.
- Adding a view: keep every existing implementation and render function. A taken
  slot gets the new view inside its existing render; add each new name to the one
  `__cmuxAppExports` object.

### Matching the app

Build a pane only from the kit so it looks like cmux in every theme: `Panel`
(the app's card surface), `Row`, `Button`, `Menu`, `Toggle`, `Slider`,
`TextField`, `Badge`, `EmptyState`, plus `cmux.toast({ title, message?, tone? })`
for a notice and `cmux.theme` for the tone names. Never a literal color
(`#RRGGBB`) or size (point fonts, hand-set padding or radii): pass tones
(`tint: cmux.theme.success`) and font names. The kit, its rules and a
copy-paste focus timer template are in
[references/local-app-views.md](references/local-app-views.md#matching-the-app).

The worked example, as copy-paste files, and the recipe for adding a view:
[references/local-app-views.md](references/local-app-views.md).

### Change what cmux does

To make a button run the person's own command, read the current workspace,
follow changes or open a pane of their own, start from a folder in
[templates/](templates/) (`starter`, `sidebar-section`, `command-button`,
`pane`, `threads`: the agent chats as a thread list, from `agent_chat.list`;
`clock-weather`, `my-prs` and `design-links`: a time and weather widget, your PRs
in the order you keep, Figma and other links opened in a cmux tab; `media-player`: a
radio player with the song on now; `start-page`: a start page of your own as a pane;
`newtab-cards`, `newtab-calm`, `newtab-threads` and `newtab-console`: whole New Tab pages,
the Cards, Default, Threads and Console layouts cmux no longer ships, picked with
`cmux settings set tabs.newTabApp local/customize`). For "what could I
make?", start from [references/ideas.md](references/ideas.md). A button runs a `cmux-next.json` action with
`cmux.actions.run("cmuxConfig.<name>")` from a click, once the person turns on
`actions:run`. What an extension can call, what is missing, and how to install
a template: [references/extensions.md](references/extensions.md).
