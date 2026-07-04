---
name: cmux-settings
description: "View and edit cmux settings in ~/.config/cmux/cmux.json. Use when the user wants to change cmux preferences (appearance, sidebar, notifications, automation, browser, shortcuts), set a value by JSON path, validate the file, open it in an editor, or look up which keys cmux recognizes. Triggers on '/cmux-settings', 'change cmux setting', 'set <something> in cmux', 'cmux config', 'cmux.json', or 'rebind a cmux shortcut'."
---

# cmux-settings

cmux reads user settings from `~/.config/cmux/cmux.json` (JSONC). The app installs a file watcher; saving the file applies changes immediately, no restart needed. Legacy `~/.config/cmux/settings.json` is read only as a fallback for keys not present in `cmux.json`.

Schema: `https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json`. The authoritative path list lives in `Sources/CmuxSettingsJSONPathSupport.swift` in the cmux checkout, and the installed skill includes a generated copy in `references/all-keys.md`. Top-level sections are `app`, `terminal`, `notifications`, `sidebar`, `sidebarAppearance`, `workspaceColors`, `automation`, `browser`, and `shortcuts`. Non-settings sections (`actions`, `ui`, `commands`, `vault`, `rightSidebar`) coexist in the same file.

## Helper script

Use the bundled helper for every read/write. It strips JSONC comments, writes atomically, and validates keys against the schema.

```bash
# From a cmux checkout
skills/cmux-settings/scripts/cmux-settings <subcommand>

# From an installed Codex skill
~/.codex/skills/cmux-settings/scripts/cmux-settings <subcommand>
```

For brevity in the rest of this doc, assume the script is on `$PATH` as `cmux-settings`. To make it so for a session from a checkout: `export PATH="$PWD/skills/cmux-settings/scripts:$PATH"`.

Subcommands:

| Command | What it does |
|---|---|
| `cmux-settings path` | Print the config path. |
| `cmux-settings dump` | Print the raw file (preserves comments). |
| `cmux-settings dump --no-comments` | Print the parsed JSON. |
| `cmux-settings get <a.b.c>` | Print value at dotted JSON path. |
| `cmux-settings set <a.b.c> <value>` | Set value. `<value>` is parsed as JSON (`true`, `42`, `"text"`, `[…]`, `{…}`); plain strings without quotes are stored as strings. |
| `cmux-settings unset <a.b.c>` | Delete key, reverting to the in-app default. |
| `cmux-settings list-supported` | List every settings JSON path the app recognizes. |
| `cmux-settings validate` | Parse the file and flag any unknown settings keys. |
| `cmux-settings open` | Open `cmux.json` in `$EDITOR`, VS Code, Cursor, or TextEdit. |

`--file <path>` overrides the target file (useful for `--file ~/.config/cmux/settings.json` when the user keeps things in the legacy file).

## Workflow

1. Confirm the change. If the user named a setting in plain English (e.g. "make the sidebar tint match the terminal background"), look it up first.
   ```bash
   cmux-settings list-supported | rg -i 'sidebar.*terminal|terminal.*sidebar'
   ```
2. Set the value. JSON literals (`true`, `false`, numbers, arrays, objects) must be valid JSON. Plain words are stored as strings.
   ```bash
   cmux-settings set sidebarAppearance.matchTerminalBackground true
   cmux-settings set app.appearance dark
   cmux-settings set shortcuts.bindings.toggleSidebar cmd+b
   cmux-settings set shortcuts.bindings.newTab '["ctrl+b","c"]'
   cmux-settings set browser.hostsToOpenInEmbeddedBrowser '["localhost","*.internal.example"]'
   ```
3. Verify by reading back and validating.
   ```bash
   cmux-settings get sidebarAppearance.matchTerminalBackground
   cmux-settings validate
   ```
4. Tell the user it auto-reloaded. No app restart. If they want to revert, run `cmux-settings unset <key>`.

## Quick reference

- Appearance: `app.appearance` = `"system" | "light" | "dark"`, `app.appIcon`, `app.menuBarOnly`, `app.minimalMode`.
- Sidebar tint: `sidebarAppearance.matchTerminalBackground`, `sidebarAppearance.tintColor`, `sidebarAppearance.tintOpacity` (0..1).
- Sidebar details: `sidebar.hideAllDetails`, `sidebar.showBranchDirectory`, `sidebar.showPullRequests`, `sidebar.showPullRequestCIStatus`, `sidebar.showPorts`, `sidebar.showLog`.
- Notifications: `notifications.dockBadge`, `notifications.sound` (enum incl. `"none"`, `"custom_file"`), `notifications.customSoundFilePath`, `notifications.hooks` (array).
- Browser: `browser.defaultSearchEngine`, `browser.theme`, `browser.openTerminalLinksInCmuxBrowser`, `browser.hostsToOpenInEmbeddedBrowser`.
- Automation: `automation.socketControlMode` (`off | cmuxOnly | automation | password | allowAll`), `automation.portBase`, `automation.portRange`.
- Shortcuts: `shortcuts.bindings.<actionId>` = `"cmd+b"`, `["ctrl+b","c"]`, `null`, or `""` to unbind. See `references/shortcut-actions.md`.

For the full list of settings, defaults, and descriptions, run `cmux-settings list-supported` or read [references/all-keys.md](references/all-keys.md).

## Rules

- Only edit `cmux.json`. Never edit `settings.json` unless the user explicitly asks; it is legacy and only read when the key is absent from `cmux.json`.
- Never tell the user to restart cmux to apply a change. The file watcher reloads on save.
- Always validate after a bulk edit: `cmux-settings validate`. Unknown keys mean the user pasted a key the app does not consume.
- Do not blindly overwrite top-level sections (`actions`, `ui`, `commands`, `vault`, `rightSidebar`). They live in the same file and contain non-settings config the user has hand-tuned.
- Shortcut action ids must match the schema enum. Look them up in [references/shortcut-actions.md](references/shortcut-actions.md) before binding.
- Color values must be `#RRGGBB`. Opacities are `0..1`.
- For settings the user expressed in app-level language (e.g. "Settings > Notifications > Dock badge"), translate to the matching JSON path first; the docs page at `web/app/[locale]/docs/configuration/page.tsx` mirrors the schema 1:1.
