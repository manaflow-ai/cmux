---
name: cmux-settings
description: "View and edit cmux settings in ~/.config/cmux/cmux.json. Use when the user wants to change cmux preferences (appearance, sidebar, notifications, automation, browser, shortcuts), set a value by JSON path, validate the file, open it in an editor, or look up which keys cmux recognizes. Triggers on '/cmux-settings', 'change cmux setting', 'set <something> in cmux', 'cmux config', 'cmux.json', or 'rebind a cmux shortcut'."
---

# cmux-settings

cmux reads user settings from `~/.config/cmux/cmux.json` (JSONC). A file watcher applies most changes on save. `browser.disableTrackingPrevention` requires a restart because it configures browser storage policy. Legacy `~/.config/cmux/settings.json` is read only as a fallback for keys absent from `cmux.json`.

Schema: `https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json`. The helper uses the schema-generated path list in `references/all-keys.md` in both checkouts and installed skills. If that reference is unavailable, it falls back to paths discoverable in `Sources/CmuxSettingsJSONPathSupport.swift`. Settings sections are `app`, `terminal`, `notifications`, `sidebar`, `sidebarAppearance`, `workspaceColors`, `automation`, `browser`, `shortcuts`. Non-settings sections (`actions`, `ui`, `commands`, `vault`, `rightSidebar`) share the same file.

## Helper script

Use the bundled helper for every read/write. It strips JSONC comments, validates the complete proposed document with `cmux config validate` before writing, and writes atomically unless the change adds a validation issue. Issues the file already had, such as a key from a newer cmux, don't block an unrelated change; run `validate` to see them.

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
| `cmux-settings undo <receipt>` | Restore one path changed by `set`/`unset --receipt`, only if it still holds the value that change installed. |
| `cmux-settings list-supported` | List every settings JSON path the app recognizes. |
| `cmux-settings validate` | Run the same semantic validation as `cmux config validate` (unknown paths, types, enums, bounds, nested constraints, and config scope). |
| `cmux-settings open` | Open `cmux.json` in `$EDITOR`, VS Code, Cursor, or TextEdit. |

`--file <path>` overrides the target file. Scope is inferred from the real global paths and the project config discovered from the current directory; use `--scope global|project` to override that inference for an arbitrary file.

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
4. Tell the user whether the setting reloads on save or requires the restart documented in its schema description, and that `cmux-settings unset <key>` reverts it.

`set` and `unset` print a JSON result such as `{"status": "persisted", "key": "app.appearance", "runtime": "unobserved"}`. It records what reached disk; the running app's reload is not observed. A refusal prints `{"status": "conflict", "code": ...}` on stderr and exits 1 without writing. An `invalid_config` refusal adds `issues`, the path and message of each problem the change would add.

## Reversible changes

Use these when a change may need to be taken back later, for example a preset the user can uninstall:

```bash
cmux-settings set computerUse.showInMenuBar false --preview        # prints the change and a revision; writes nothing
cmux-settings set computerUse.showInMenuBar false \
  --expect-revision <revision> --receipt ~/private/menu-bar-undo.json
cmux-settings undo ~/private/menu-bar-undo.json
```

- `--expect-revision` refuses the write if the file changed since the preview.
- `--receipt` creates a new mode-0600 file and never overwrites one; an existing file returns `receipt_exists`, and a path that can't be created returns `receipt_unwritable`, before anything is written. It holds config values, so keep it private.
- `undo` restores the prior value, or the prior absence, only while the path on the same resolved file still holds the value the receipt installed. If the user or another tool changed it since, `undo` returns `undo_conflict` and leaves the newer choice alone.
- Plain `unset` is an unconditional reset, not an undo.

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
- Only request a restart when the setting's schema description requires it, such as `browser.disableTrackingPrevention`. Other settings reload on save.
- Always `cmux-settings validate` after a bulk edit. Validation errors include the exact config path and violated constraint.
- Do not blindly overwrite `actions`, `ui`, `commands`, `vault`, or `rightSidebar`; they share the file and hold hand-tuned non-settings config.
- Shortcut action ids must match the schema enum. Look them up before binding.
- Colors are `#RRGGBB`; opacities are `0..1`.
- Translate app-level phrasing ("Settings > Notifications > Dock badge") to the JSON path first; `web/app/[locale]/(landing)/docs/configuration/page.tsx` mirrors the schema 1:1.
