# Lane: settings

## Active streams
- Settings in Rust + web page (settings lead): config actor in the daemon owns cmux.json (validate, MDM guard, JSONC persist, `settings-changed`); Swift applies daemon snapshots; web Settings page in a page tab via `cmux-settings://page`; palette, CLI and MCP use the same `settings.*` v2 ops. Design: plans/cmux-next/settings-react.md. Touches: catalog lane (settings-surfaces export), lane 20 (background token, transparency), app platform (page tabs).

## Landed
- 2026-10-03 (this commit) plans: settings-react.md (ownership, ops, page design, slices a-f, objections) (settings lead)
- 2026-10-03 1f08a54bc4c control (catalog lane): stopgap, the app socket settings.set/reset/unset refuse managed keys (`managed`) and schema-invalid values (`invalid_params`), and write schema keys through SettingsController.setSetting (SocketSettingsWriteTests). Slice b of settings-react.md deletes these writers. settings-surfaces.md now points at the daemon config actor.
