---
name: cmux-customization
description: "Customize cmux for an end user, including terminal, browser, Markdown, diff, file preview, notes, HTML, and right-sidebar viewers. Use when changing cmux-next.json (or classic cmux.json) actions, custom commands, workspace layouts, plus-button behavior, surface tab bar buttons, Command Palette entries, Dock controls, sidebar and app settings, shortcuts, notifications, browser routing, examples-library presets, or Ghostty-backed terminal preferences."
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
