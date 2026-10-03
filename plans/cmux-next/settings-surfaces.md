# Settings on every surface

Status: plan, 2026-10-03. Owner: catalog lane. Lane 20 owns the Settings pane UI and the transparency keys; this plan does not change the pane.

Goal (Lawrence): every setting is settable from every surface: the palette, the `cmux` CLI, MCP and the control socket. A test fails when a setting lacks a surface.

## Schema source

`SettingsSchema.all` (CmuxNextSettings) is the only list. Each `SettingDescriptor` has the dotted key, section, title, help, `SettingKind`, default and keywords. Nothing below keeps its own list of keys. A new descriptor appears on every surface with no other edit.

Not in scope: keys outside the schema (custom actions, tab bar buttons, shortcut bindings). They keep their current editors. Ghostty settings stay in the Ghostty config (cmux points at them and does not copy them).

## One writer

Every write goes through `SettingsController.setSetting(_:to:)`, which checks the managed-preferences guard and `descriptor.accepts(value)`. A nil value removes the key, so the default applies.

Gap today: the socket's `settings.set` and `settings.unset` write cmux.json through the raw `ControlSettingsStore`. They skip schema validation and the managed guard. Fix: the control router gets a `ControlSettingsWriter` (implemented by `SettingsController`). Schema keys go through `setSetting`. Non-schema paths keep the raw write, but a managed key is refused on every path.

## Op shapes (socket, generated rows)

- `settings.list` (new) returns `{"settings": [row]}`. Each row has: `key` (dotted), `section`, `title`, `help`, `kind` (`toggle`, `choice`, `choice_or_number`, `number`, `color`, `sound`, `url`, `host_list`, `time_range`, `theme`, `font_family`), `choices` (`[{value, title}]`), `range` (`{min, max, step}`), `default` (or null with `default_label`), `value` (the current value or null), `managed` (the managed source or null).
- `settings.get {path}` stays as it is (any path, raw JSON).
- `settings.set {path, value}` validates schema keys through the writer. A refusal returns `invalid_params` with the accepted kinds and values.
- `settings.reset {path}` (new name) removes the key through the writer. `settings.unset` stays as an alias.

## Value pickers (palette)

"Set Setting…" (`palette.setSetting`, Cmd-Shift-P) opens one page with a row per descriptor. The row shows the title and the current value. The keywords are the descriptor keywords plus the section. Choosing a row opens an editor that fits its kind:

- toggle: flips in place (the Toggle Setting behavior).
- choice: a nested list of the choices; the current choice is checked.
- choice or number: the choices plus "Custom…", which opens a number input.
- number: a text input, checked against the range; the refusal names the range.
- color: a text input for `#RRGGBB` or `#RRGGBBAA`, plus "Use Theme Color" (reset).
- theme, font, sound: a text input with the known names as suggestions.
- url, host list, time range: a text input (host list: comma-separated; time range: `HH:MM-HH:MM`).

Every page also has "Reset to Default". Writes go through the palette settings source and then `setSetting`. Toggle Setting… stays as an alias that filters the page to toggles.

## CLI grammar (Rust `cmux`, cmux-tui window, the CLI owner)

`cmux settings list [--json] [--section <s>]`, `cmux settings get <key>`, `cmux settings set <key> <value>` (the value is parsed as JSON, then as a bare string), `cmux settings reset <key>`. `unset` stays as an alias. The verbs map one-to-one to the socket ops. Request file: `.cmux-scratch/nx-worker/cli-requests/settings-surfaces.md`.

## MCP

The tools are `settings_list`, `settings_get`, `settings_set` and `settings_reset`, restricted to schema keys. Today MCP excludes all settings methods because cmux.json can hold credentials and holds `mcp.enabled`. Schema keys hold no credentials, and `mcp.*` is not a schema key, so restricting MCP to schema keys keeps both safeguards.

## Generated artifacts

- `plans/cmux-next/settings-surfaces.json`: every schema row (the `settings.list` shape without `value` and `managed`), plus `surfaces: {palette, cli, mcp, socket}`. The Rust CLI and MCP parity tests read it. `SettingsSurfaceParityTests.exportIsFresh` keeps it current. `CMUX_UPDATE_ACTION_SURFACES=1` rewrites it with the action exports.
- `SettingsSurfaceParityTests` (Swift) checks each descriptor: (1) it has a palette row and an editor for its kind; (2) `settings.list` has a row for it; (3) `settings.set` with its default (or a sample value of its kind) goes through the writer, and a value of the wrong kind is refused; (4) the export lists it with every surface offered. A descriptor that fails any check names itself.
- Rust (later, in the window): a parity test reads the export and checks that every key round-trips through `cmux settings set/get/reset` against a fake socket and is offered as an MCP tool argument.

## Order

1. This plan.
2. Swift: writer routing for socket writes, `settings.list` and `settings.reset`, the export with its freshness test, the palette Set Setting page, and the parity test. All in one push with the regenerated files.
3. Rust CLI verbs and MCP tools, through the CLI owner in a cmux-tui window.

DECISION: MCP gets settings set and reset for schema keys only (`mcp.*` and non-schema paths stay out). RECOMMEND: yes. An agent that changes the look or behavior on request is the point of the change, and the credential risk is only in non-schema keys.
