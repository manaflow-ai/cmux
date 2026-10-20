---
name: cmux-settings
description: "View and edit cmux settings in ~/.config/cmux/cmux-next.json, including appearance, terminal, browser, diff, files, sidebar, notifications and Computer Use behavior. Use when the user wants to change cmux preferences, set a value by JSON path, open the settings file in an editor, or look up which keys cmux recognizes. Triggers on '/cmux-settings', 'change cmux setting', 'customize viewer', 'set <something> in cmux', 'cmux config', 'cmux.json', or 'rebind a cmux shortcut'."
---

# cmux-settings

cmux-next reads user settings from `~/.config/cmux/cmux-next.json` (JSONC;
`CMUX_NEXT_CONFIG_FILE` overrides the path). On first launch the app copies
classic cmux's `~/.config/cmux/cmux.json` into it once; after that, edits to
`cmux.json` do not reach cmux-next. The app applies changes on save, with no
restart.

The schema is `schemas/settings/settings-schema.json`: its `rows` list every
path, kind, accepted values, default and whether an agent may set it
(`agent_settable`). Classic keys such as `app.appearance`, `sidebarAppearance.*`,
`markdown.*`, `fileEditor.*` and `diffViewer.*` are not cmux-next keys; several
were renamed (`diffViewer.defaultLayout` is `diff.layout`). `settings set`
validates values for schema keys and refuses retired keys with `removed`. It
writes any other path without validation. That raw write is how custom actions
and `shortcuts.bindings.*` are set; any other unknown path succeeds and changes
nothing, so look the key up first. Every write prints the `file` it
wrote.

## Read and change a setting

With the app running, use its settings verbs. They read and write the file the
app uses:

```bash
cmux settings get diff.layout
cmux settings set diff.layout split          # VALUE is parsed as JSON, else stored as a string
cmux settings reset diff.layout              # remove the key, so the default applies (unset is the same)
cmux settings reload-configuration
```

A key with `agent_settable: false` (privacy- or security-sensitive, such as
`browser.hostsToOpenInEmbeddedBrowser`) is refused with `setting_user_only`.
Add `--confirm` only when the user asked for the change: the app then shows the
person a confirmation sheet and the CLI waits for their answer. A declined sheet
also returns `setting_user_only`.

## Workflow

1. Look up the key when the user named a setting in plain English. Search the
   schema's row keys, titles and keywords:
   ```bash
   jq -r '.rows[] | [.key, .title.text, (.keywords | join(","))] | @tsv' \
     schemas/settings/settings-schema.json | rg -i 'dock|badge'
   ```
   Outside a checkout, `cmux settings get` with no path prints the current
   values; `cmux settings list [--section S]` lists every key with its value,
   and `cmux settings list --keys` needs no app.
2. Set it with `cmux settings set <key> <value>`. JSON literals must be valid
   JSON (`true`, `16`, `'"split"'`, `'["localhost"]'`).
3. Read it back with `cmux settings get <key>`. `cmux settings validate [FILE]`
   reports schema problems in the file without the app.
4. Tell the user it applied live, and that `cmux settings reset <key>` reverts it.

For a viewer-specific question, read [the viewer matrix](../cmux-customization/references/viewer-types.md)
first; do not invent keys the schema does not list.

## Quick reference

- Appearance: `appearance.theme`, `appearance.appTheme`, `appearance.accent`, `appearance.backgroundOpacity`, `appearance.backgroundBlur`.
- Terminal: `terminal.fontFamily`, `terminal.fontSize` (default from Ghostty config).
- Sidebar: `sidebar.density`, `sidebar.groupBy`, `sidebar.minimalMode` (`off | bottom | top | both`).
- Notifications: `notifications.dockBadge`, `notifications.desktop`, `notifications.attention.*`.
- Browser: `browser.defaultEngine`, `browser.hostsToOpenInEmbeddedBrowser` (user-only), `browser.links.*`, `browser.hibernation`.
- Diff and files: `diff.layout` (`split | unified`), `diff.wordWrap`, `files.textEditor` (user-only).
- Computer Use: `computerUse.enabled` (off by default), `computerUse.driver`; both user-only.
- Shortcuts: `shortcuts.bindings.<actionId>` = `"cmd+b"`, `["ctrl+b","c"]`, `null`, or `""` to unbind. Action ids in [references/shortcut-actions.md](references/shortcut-actions.md).

## The bundled helper is classic-only

`skills/cmux-settings/scripts/cmux-settings` and
[references/all-keys.md](references/all-keys.md) target classic cmux: the helper
defaults to `~/.config/cmux/cmux.json`, its key list comes from
`web/data/cmux.schema.json`, and its `set`, `unset`, `undo`, `--preview` and
`validate` need a CLI whose `config validate` checks classic `cmux.json`, named
by `CMUX_CLI_BIN`; the Rust `cmux config validate` checks `cmux-next.json`
against the cmux-next schema instead. Use it only for classic cmux, and pass
`--file ~/.config/cmux/cmux-next.json` if you read the cmux-next file with it.

## Rules

- Edit cmux-next settings through `cmux settings`; edit the file by hand only when the app is not running, and copy it to a timestamped `.bak` first.
- Never tell the user to restart cmux. The app reloads on save.
- Never pass `--confirm` on your own initiative; it asks the person to approve a user-only change.
- Shortcut action ids must match the schema enum. Look them up before binding.
- Colors are `#RRGGBB`; opacities are `0..1`.
