---
name: cmux-customization
description: "Customize cmux for an end user, including terminal, browser, Markdown, diff, file preview, notes, HTML, and right-sidebar viewers. Use when changing cmux-next.json (or classic cmux.json) actions, custom commands, workspace layouts, plus-button behavior, surface tab bar buttons, Command Palette entries, Dock controls, sidebar and app settings, shortcuts, notifications, browser routing, examples-library presets, Ghostty-backed terminal preferences, or a view of their own (a sidebar or Session Info section built as the customize app, such as the PRs from the last 24h)."
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

2. Back up the file when it exists.

   ```bash
   stamp="$(date +%Y%m%d-%H%M%S)"
   test -f ~/.config/cmux/cmux-next.json && cp -p ~/.config/cmux/cmux-next.json ~/.config/cmux/cmux-next.json."$stamp".bak
   ```

3. For app settings, use `cmux settings set <key> <value>` and read it back with `cmux settings get <key>`. Never hand-write a settings key: the app ignores a value its build refuses and keeps the default.
4. For actions, edit the JSONC by hand and preserve unrelated sections.
5. Run `cmux settings validate`; it must report no problems. It checks schema values only: an unknown action id, an unsupported chord or a removed key shows only in the app's toast and on the Settings row. Then `cmux settings reload-configuration` (the app also reloads on save). A refused value also shows a toast in the app that names the key, the value and why ([cmux-settings](../cmux-settings/SKILL.md#when-the-app-ignores-a-value)).
6. Verify the configured entrypoint exists: confirm the action ID and where it should appear.

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

- Only look settings apply (`appearance.*`, `ui.animation*`, `ui.calm`,
  `browser.omnibar.glass*`, `app.uiScale`), each checked like `cmux settings set`.
  A refused value or key is dropped with the toast settings use, naming the
  theme file and the key (`themes/tokyo.json: appearance.accent = "purple" was
  ignored: ...`); the rest still applies. Look keys up as in
  [cmux-settings](../cmux-settings/SKILL.md).
- The theme file wins over the same keys in cmux-next.json (their Settings rows say
  so), and a managed (MDM or team) value wins over it. To change one of those keys,
  edit the theme file, or unset `appearance.themeFile`.
- Contrast is guarded: a `foreground` under 4.5:1 on its `background` shows as the
  app theme's text color instead, and Settings says so at the Theme File row.

## Make a view

When someone asks for a view of their own (a sidebar section, a Session Info
section, "a view of the PRs from the last 24h"), write the customize app in
`~/.config/cmux/customize`: `cmux-app.json` (id `local/customize`, manifest v2)
and `main.js`, a classic script that uses the scene globals (`VStack`, `Row`,
`ForEach`, `EmptyState`, ...) and ends with
`globalThis.__cmuxAppExports = { ... }`. cmux watches the folder: every save
reloads the view, and the app installs itself the first time. No restart, no
install click.

- `implements["cmux.section/1"]` is its one sidebar section; `options.defaultRegion`
  `top`, `middle` or `bottom` (the band under the workspace list). cmux places it
  there the first time it sees it, and the person's later move or removal wins.
  Put it back on purpose with `cmux apps place 'local/customize#cmux.section/1' --region bottom`.
- `implements["cmux.session.info.section/1"]` is its one Session Info section; its
  render function gets `{ session_id, cwd, branch?, harness? }` as its argument.
- Scopes: read scopes (`integration:github:read`) are granted at install. Others
  (`actions:run`, `net:<host>`) need the person to turn them on in Settings > Apps.
- Script errors: `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'`.
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
`pane`). A button runs a `cmux-next.json` action with
`cmux.actions.run("cmuxConfig.<name>")` from a click, once the person turns on
`actions:run`. What an extension can call, what is missing, and how to install
a template: [references/extensions.md](references/extensions.md).
