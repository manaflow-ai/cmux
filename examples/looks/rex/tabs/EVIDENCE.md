# Validation receipt

Repository: `manaflow-ai/cmux`  
Date: 2026-11-21 UTC  
Scope: `examples/looks/rex/tabs` only for this profile.

- 20 bindings / 11 distinct actions / 3 window + 17 terminal-scoped bindings; zero settings, zero custom executable actions.
- JSON parse, unique key/context pairs, action IDs checked against
  `cmux-tui/crates/cmux-action-catalog/src/catalog/*.rs`: PASS.
- Embedded `profile.json` keybindings exactly equal sibling `keybindings.json`: PASS.
- `cmux customize use <absolute profile.json> --json`, followed by
  `cmux customize check --json`: exit 0, `problems: []`, `skipped: []`,
  `can_apply: true`; installed keybindings read back exactly: PASS.
- Validation used temporary directories with `CMUX_NEXT_CONFIG_FILE`,
  `CMUX_CUSTOMIZE_DIR`, `CMUX_CUSTOMIZE_STATE_DIR` explicitly overridden;
  no personal configuration was changed.
- Both profiles applied together in isolation: 24 example bindings plus
  one pre-existing binding, with unrelated `terminal.fontSize: 15` preserved: PASS.
- Preview then `cmux customize discard --json` restores the original binding: PASS.
- Tab indices are explicitly 1 through 8. Checked against `TabHandlers.swift`
  `bindSelection`: 9 selects last, so a ninth-tab parity claim is excluded.
- Terminal adaptation scopes explicitly require terminal focus and a closed
  palette. Scope expressions and action semantics were inspected in source.

Limits: `customize check` validates file syntax, not every live shortcut
context. No connected app is available (`cmux action describe renameTab --json`
returned `app.not_found`), so focus transitions, key resolution, native picker,
rename UI, and screenshots of this setup running are **not live verified**.
