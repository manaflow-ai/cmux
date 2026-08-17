---
name: cmux-settings
description: "View and edit cmux settings in ~/.config/cmux/cmux.json. Use when the user wants to change cmux preferences (appearance, sidebar, notifications, automation, browser, shortcuts), set a value by JSON path, validate the file, open it in an editor, or look up which keys cmux recognizes. Triggers on '/cmux-settings', 'change cmux setting', 'set <something> in cmux', 'cmux config', 'cmux.json', or 'rebind a cmux shortcut'."
---

# cmux-settings

cmux reads user settings from `~/.config/cmux/cmux.json` (JSONC). A file watcher applies changes on save, no restart. Legacy `~/.config/cmux/settings.json` is read only as a fallback for keys absent from `cmux.json`.

Schema: `https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json`. The authoritative path list is `Sources/CmuxSettingsJSONPathSupport.swift`; the installed skill carries a generated copy in `references/all-keys.md`. Settings sections are `app`, `terminal`, `notifications`, `sidebar`, `sidebarAppearance`, `workspaceColors`, `automation`, `browser`, `shortcuts`. Non-settings sections (`actions`, `ui`, `commands`, `vault`, `rightSidebar`) share the same file.

## Helper script

Use the bundled helper for every read/write. It strips JSONC comments, writes atomically, and validates keys against the schema.

```bash
skills/cmux-settings/scripts/cmux-settings <subcommand>            # from a cmux checkout
~/.codex/skills/cmux-settings/scripts/cmux-settings <subcommand>   # installed Codex skill
```

The rest of this doc assumes it is on `$PATH` as `cmux-settings`; from a checkout, `export PATH="$PWD/skills/cmux-settings/scripts:$PATH"`.

| Command | What it does |
|---|---|
| `cmux-settings path` | Print the config path. |
| `cmux-settings dump` | Print the raw file (preserves comments). |
| `cmux-settings dump --no-comments` | Print the parsed JSON. |
| `cmux-settings get <a.b.c>` | Print value at dotted JSON path. |
| `cmux-settings set <a.b.c> <value>` | Set value. `<value>` is parsed as JSON (`true`, `42`, `"text"`, `[…]`, `{…}`); unquoted plain words are stored as strings. |
| `cmux-settings unset <a.b.c>` | Delete key, reverting to the in-app default. |
| `cmux-settings list-supported` | List every settings JSON path the app recognizes. |
| `cmux-settings validate` | Parse the file and flag unknown settings keys. |
| `cmux-settings open` | Open `cmux.json` in `$EDITOR`, VS Code, Cursor, or TextEdit. |

`--file <path>` overrides the target file, useful for `--file ~/.config/cmux/settings.json`.

## Workflow

1. Look up the key when the user named a setting in plain English:
   ```bash
   cmux-settings list-supported | rg -i 'sidebar.*terminal|terminal.*sidebar'
   ```
2. Set it. JSON literals must be valid JSON.
   ```bash
   cmux-settings set sidebarAppearance.matchTerminalBackground true
   cmux-settings set app.appearance dark
   cmux-settings set shortcuts.bindings.newTab '["ctrl+b","c"]'
   cmux-settings set browser.hostsToOpenInEmbeddedBrowser '["localhost","*.internal.example"]'
   ```
3. Read back and `cmux-settings validate`.
4. Tell the user it auto-reloaded, and that `cmux-settings unset <key>` reverts it.

## Quick reference

- Appearance: `app.appearance` (`"system" | "light" | "dark"`), `app.appIcon`, `app.menuBarOnly`, `app.minimalMode`.
- Sidebar tint: `sidebarAppearance.matchTerminalBackground`, `.tintColor`, `.tintOpacity` (0..1).
- Sidebar details: `sidebar.hideAllDetails`, `.showBranchDirectory`, `.showPullRequests`, `.showPorts`, `.showLog`.
- Notifications: `notifications.dockBadge`, `.sound` (enum including `"none"`, `"custom_file"`), `.customSoundFilePath`, `.hooks` (array).
- Browser: `browser.defaultSearchEngine`, `.theme`, `.defaultZoomLevel`, `.openTerminalLinksInCmuxBrowser`, `.hostsToOpenInEmbeddedBrowser`.
- Automation: `automation.socketControlMode` (`off | cmuxOnly | automation | password | allowAll`), `.portBase`, `.portRange`.
- Shortcuts: `shortcuts.bindings.<actionId>` = `"cmd+b"`, `["ctrl+b","c"]`, `null`, or `""` to unbind. Action ids in [references/shortcut-actions.md](references/shortcut-actions.md).

Full list of settings, defaults, and descriptions: `cmux-settings list-supported` or [references/all-keys.md](references/all-keys.md).

## Rules

- Only edit `cmux.json`. Never `settings.json` unless the user explicitly asks; it is legacy and read only when a key is absent from `cmux.json`.
- Never tell the user to restart cmux. The file watcher reloads on save.
- Always `cmux-settings validate` after a bulk edit. Unknown keys mean the user pasted a key the app does not consume.
- Do not blindly overwrite `actions`, `ui`, `commands`, `vault`, or `rightSidebar`; they share the file and hold hand-tuned non-settings config.
- Shortcut action ids must match the schema enum. Look them up before binding.
- Colors are `#RRGGBB`; opacities are `0..1`.
- Translate app-level phrasing ("Settings > Notifications > Dock badge") to the JSON path first; `web/app/[locale]/(landing)/docs/configuration/page.tsx` mirrors the schema 1:1.
