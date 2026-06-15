---
name: cmux-settings
description: "Read and write any cmux setting and remap any keyboard shortcut from the command line via `cmux settings`. Use when the user wants to change a cmux preference (appearance, sidebar, notifications, automation, browser, terminal, shortcuts), set/get a value, list or describe what's settable, export/import a config, or rebind a shortcut. Triggers on '/cmux-settings', 'change cmux setting', 'set <something> in cmux', 'cmux config', 'cmux.json', 'remap/rebind a cmux shortcut', or 'cmux settings'."
---

# cmux-settings

`cmux settings` reads and writes **every** cmux setting and **every** keyboard shortcut from the command line, while the app is running. It is **catalog-driven**: the CLI derives the full set of keys, their types, allowed values, and defaults from the app's single source of truth (`SettingCatalog`). So you never hardcode a key list — you **discover** it at runtime, and the CLI automatically covers new settings as they are added.

Changes apply **live** (no restart): a CLI write lands in exactly the same place the Settings window reads from (`UserDefaults`, `~/.config/cmux/cmux.json`, or a secret file) and the running app picks it up immediately.

## The loop: discover → set → verify

Always discover before guessing a key name.

```bash
# 1. Discover. List every key (flat, sorted, scriptable):
cmux settings list --keys
# Find the one you want (plain English -> key):
cmux settings list --keys | rg -i 'sidebar|terminal|appearance'
# Inspect one key fully — type, allowed values, default, current value, backend:
cmux settings describe app.appearance

# 2. Set. Values are validated against the catalog (type / enum / range):
cmux settings set app.appearance dark

# 3. Verify:
cmux settings get app.appearance        # -> dark
```

`cmux settings list --json` and `--json` on any read command give machine-readable output (stable, sorted). Use it to enumerate programmatically:

```bash
cmux settings list --json | jq -r '.settings[] | select(.type=="enum") | .id'
```

## Subcommands

| Command | What it does |
|---|---|
| `cmux settings list [--json] [--keys]` | Every setting with value, default, backend. `--keys` = flat key list. |
| `cmux settings get <key> [--json]` | Print one setting's value. |
| `cmux settings set <key> <value>` | Set a value (validated). Quote values with spaces. |
| `cmux settings unset <key>` | Clear an override, reverting to the default. |
| `cmux settings reset <key>` | Same as unset. |
| `cmux settings reset --all --yes` | Clear every override. |
| `cmux settings describe <key> [--json]` | Type, allowed enum values, default, current value, backend, section. |
| `cmux settings export [--json] [--out file]` | Dump current settings (secrets omitted). |
| `cmux settings import <file>` | Apply a settings file; validated atomically (all-or-nothing). |
| `cmux settings shortcuts <subcommand>` | Manage keyboard shortcuts (below). |

Validation never silently no-ops: an unknown key, wrong type, unknown enum case, or out-of-range value exits non-zero with a clear stderr message.

## Examples

```bash
# Toggle a boolean
cmux settings set app.menuBarOnly true

# Set an enum (run `describe` first to see the cases)
cmux settings describe browser.defaultSearchEngine
cmux settings set browser.defaultSearchEngine duckduckgo

# Number
cmux settings set automation.portBase 9200

# JSON value (quote it)
cmux settings set browser.hostsToOpenInEmbeddedBrowser '["localhost","*.internal.example"]'

# Revert one setting, or everything
cmux settings unset app.menuBarOnly
cmux settings reset --all --yes

# Version-control a profile across machines
cmux settings export --out ~/dotfiles/cmux-settings.json
cmux settings import ~/dotfiles/cmux-settings.json
```

## Keyboard shortcuts

Shortcuts live under `cmux settings shortcuts` and key off action ids (e.g. `newTab`, `openSettings`). Bindings are config strings: a single stroke `cmd+t`, a tmux-style chord `ctrl+b c` (or `["ctrl+b","c"]`), or `none` to unbind.

```bash
cmux settings shortcuts list                 # every action: current binding + default
cmux settings shortcuts get newTab
cmux settings shortcuts set newTab "cmd+t"
cmux settings shortcuts set newTab "ctrl+b c"
cmux settings shortcuts unset newTab         # revert to default
cmux settings shortcuts reset                # clear every override
```

Assigning a binding already used by another action fails with a clear conflict error; pass `--force` to reassign it:

```bash
cmux settings shortcuts set newTab "cmd+k" --force
```

(Bare `cmux settings shortcuts`, with no subcommand, opens the GUI Settings window to Keyboard Shortcuts.)

## Secrets

Secret-backed settings (e.g. `automation.socketPassword`) are **redacted** on read — `get` / `list` / `export` print `<redacted>`, never the value, and `export` omits them entirely. They are still settable:

```bash
cmux settings set automation.socketPassword 'hunter2'   # writes the secret file
cmux settings get automation.socketPassword             # -> <redacted>
```

## Rules

- Discover with `list --keys` / `describe` instead of guessing or hardcoding a key list — the CLI is the source of truth and stays current as settings change.
- Don't tell the user to restart cmux; writes apply live.
- `import` is all-or-nothing: if any entry is invalid, nothing is applied and the offending entries are reported.
- To revert, `cmux settings unset <key>` (one) or `cmux settings reset --all --yes` (everything).

## Fallback: editing `cmux.json` directly

When the app is **not running** (the CLI needs it for live-apply) or you want to hand-edit the JSON, cmux still reads `~/.config/cmux/cmux.json` (JSONC) and auto-reloads on save. The bundled helper edits it safely (strips comments, writes atomically, validates keys):

```bash
# From a cmux checkout
skills/cmux-settings/scripts/cmux-settings <subcommand>
# From an installed Codex skill
~/.codex/skills/cmux-settings/scripts/cmux-settings <subcommand>
```

| Command | What it does |
|---|---|
| `cmux-settings get <a.b.c>` | Print value at a dotted JSON path. |
| `cmux-settings set <a.b.c> <value>` | Set value (JSON literal, or bare string). |
| `cmux-settings unset <a.b.c>` | Delete a key, reverting to the in-app default. |
| `cmux-settings list-supported` | List every JSON path the app recognizes. |
| `cmux-settings validate` | Flag unknown keys in the file. |

This helper writes only `cmux.json` (the ~15 JSON-backed settings, shortcut bindings, and non-settings config sections); the ~170 `UserDefaults`-backed settings are reachable only through the running app via `cmux settings`. Prefer `cmux settings` whenever the app is up. See [references/all-keys.md](references/all-keys.md) for a static (possibly stale) key reference; `cmux settings list --keys` is authoritative.
