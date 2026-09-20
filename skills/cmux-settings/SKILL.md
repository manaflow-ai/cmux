---
name: cmux-settings
description: "View and edit cmux settings in ~/.config/cmux/cmux.json. Use when the user wants to change cmux preferences (appearance, sidebar, notifications, automation, browser, shortcuts), set a value by JSON path, validate the file, open it in an editor, or look up which keys cmux recognizes. Triggers on '/cmux-settings', 'change cmux setting', 'set <something> in cmux', 'cmux config', 'cmux.json', or 'rebind a cmux shortcut'."
---

# cmux-settings

Use the bundled helper for config reads and writes:
`skills/cmux-settings/scripts/cmux-settings` from a checkout, or
`~/.codex/skills/cmux-settings/scripts/cmux-settings` when installed.
The examples below assume its directory is on `PATH`.

The global file is `~/.config/cmux/cmux.json` (JSONC). Legacy `settings.json`
is a fallback for absent keys; never edit it without an explicit request.
The watcher reloads asynchronously. Disk persistence does not prove runtime
application or determine restart requirements.

## Discover and edit

1. Resolve the user's intent with `cmux-settings list-supported` and
   [all keys](references/all-keys.md). The source owner is
   `Sources/CmuxSettingsJSONPathSupport.swift`; constraints come from
   `web/data/cmux.schema.json`, not a separate handwritten registry.
2. Read the current path, then use the helper:

   ```sh
   cmux-settings get app.appearance
   cmux-settings set app.appearance dark
   cmux-settings set notifications.dockBadge false
   cmux-settings set shortcuts.bindings.newTab '["ctrl+b","c"]'
   ```

3. Read back and run `cmux-settings validate`, especially after bulk edits.
   The helper validates the complete candidate before atomic publication and
   preserves JSONC comments and unrelated formatting.
4. Report persisted state separately from unobserved runtime application.

`--file <path>` chooses another config. `--scope global|project` overrides
scope inferred from global locations and project discovery.

## Commands

| Command | Result |
|---|---|
| `path` | Config location |
| `dump [--no-comments]` | Original text or parsed JSON |
| `get <path>` | JSON value |
| `set <path> <value>` | JSON literal, or unquoted string |
| `unset <path>` | Remove the explicit value; restore inheritance |
| `list-supported` | Recognized paths |
| `validate` | Canonical semantic diagnostics |
| `open` | Open in `$EDITOR`, VS Code, or TextEdit |

## Reversible changes

Use `set` or `unset` with `--preview` for a single-path preview. Commit with
`--expect-revision <revision>` when approval depends on that exact source.
`--receipt <new-private-file>` creates a local, mode-0600 undo receipt.
`undo <receipt-file>` restores the owned path only while its current value
and target still match the installed result. Otherwise it returns a conflict
and preserves the newer choice. Unconditional `unset` is not preset undo.

Keep previews and receipts private: they contain config values. Participating
writers coordinate through a stable sidecar lock; busy means retry from fresh
state. Arbitrary editors can still race the final source check and rename.
Do not delete a lock file while writers are active.

## Preserve existing contracts

- Other sections share this file: never blindly replace `actions`, `ui`,
  `commands`, `vault`, or `rightSidebar`.
- Look up [shortcut action IDs](references/shortcut-actions.md) before binding;
  IDs must match the schema. JSON null or an empty string unbinds a shortcut.
- Colors use `#RRGGBB`; opacities are in `0..1`.
- Translate Settings labels to canonical paths before editing; do not invent
  keys from display text. Validation reports the offending path and constraint.
