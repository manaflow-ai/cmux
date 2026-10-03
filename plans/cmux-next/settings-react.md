# Settings: daemon-owned state, one web page, every surface

Status: plan, 2026-10-03. Owner: settings lead. Lawrence: "move settings into react, the tanstack
app thing"; "improve settings page from first principles"; "make sure settings will talk to rust,
that will then talk to swift, so we can consolidate all stuff in rust"; "ensure every single
setting is settable from everywhere, including cmd shift p, cli, mcp"; "controls for
transparency"; "all bg across entire app must match the same".

Builds on: settings-surfaces.md (catalog lane: op shapes, palette pickers, export, parity test),
ownership-v2.md (config actor, slice 8), windows.md (lane 20: page tabs, one background token,
transparency), OWNERSHIP-PRINCIPLES.md ("Preferences are owned by the config layer on that
machine"). Where this file and settings-surfaces.md differ, this file moves the writer from Swift to
Rust; the op shapes, the palette pickers and the parity checks of settings-surfaces.md stay.

## 1. Ownership

| State | Owner (one writer) | Clients |
| --- | --- | --- |
| cmux.json (user layer), its JSONC text | config actor in the daemon (`cmux-config` crate) | everyone, through `settings.*` ops |
| Managed layer (MDM profile, team device policy) | inputs read or received by the config actor; never written by clients | |
| Effective settings (file + managed merge), diagnostics, revision | config actor | Swift app, web page, TUI, CLI, MCP |
| Value domains (theme names, font families, sound names) | the Mac app publishes them to the config actor (host facts only the app knows) | config actor validates against them |
| Live preview during a gesture (slider drag) | the client that runs the gesture (view state, never persisted) | |
| Applying settings to windows, themes, keymaps | Swift app (projection of the effective settings) | |

Rules:

- Every write is a typed op to the daemon with an idempotency key (`op_id`). The config actor checks
  the managed guard and the descriptor, edits the JSONC text in place (comments and unknown keys
  survive), publishes atomically (temp file + rename), bumps `revision` and emits one
  `settings.changed` event. It also watches the file, so a hand edit becomes the same event.
- Swift never writes cmux.json. `SettingsController` becomes a projection: it subscribes, keeps the
  last effective snapshot, parses it with `CmuxConfigSnapshot.parse` and applies it with
  `SettingsApplier`. Its setters send ops.
- The web page, the palette, the CLI and MCP send the same ops. None of them writes a file.
- While the daemon is unreachable, every settings control shows the disconnected state and refuses
  writes; nothing queues (U5). Reads use the daemon's last snapshot cache (section 6).

### What moves from Swift into Rust

| Swift today | Rust after |
| --- | --- |
| `CmuxConfigFile` (read, JSONC in-place set/remove, atomic publish) | `cmux-config::file` |
| `JSONC.swift` (parse + edit) | `cmux-config::jsonc` (comment-preserving editor) |
| `ConfigFileWatcher` for cmux.json and the managed files | `cmux-config::watch` (kqueue/inotify through the daemon's runtime) |
| `ManagedPreferences`, `ManagedPreferenceReaders`, `ManagedPolicyKey` | `cmux-config::managed` (macOS: the managed preferences plist of the app's domain; Linux: `/etc/cmux/managed.json`) |
| `EffectiveSettings.merge`, `ManagedKeyGuard`, `TeamPolicyLayer` storage | `cmux-config::effective` (team layer arrives by op from the app until the sync actor exists) |
| `ManagedStatusReport` file writer | `cmux-config::status` |
| `SettingDescriptor.accepts`, `setSetting`, `removePruning`, `resetAllSettings` | `cmux-config::schema` + reducer |
| raw `ControlSettingsStore` socket writes (`settings.set/unset` in `ControlRouter+Builtins`) | deleted; the daemon serves `settings.*` |
| `ShortcutBindingFormat` parse/validate for `shortcuts.bindings.*` | `cmux-config::shortcuts` (validated against the action catalog export) |

Stays in Swift: `CmuxConfigSnapshot.parse` and `SettingsApplier` (typed projection into
`DesignSettings`, the action registry and keymaps), `AppThemeSetting`/font/sound discovery (they
publish value domains), the native Settings window until parity (section 8).

## 2. Schema

Source of truth, step 1: `SettingsSchema.all` in Swift, exported to
`plans/cmux-next/settings-surfaces.json` by the catalog lane (settings-surfaces.md), kept fresh by
`SettingsSurfaceParityTests.exportIsFresh`. The Rust crate embeds it at build time
(`include_str!`), so a bundled daemon and its app always agree. The export adds, per row:
`title_key`, `help_key`, `choices[].title_key` (xcstrings keys beside the English text),
`agent_settable` (default true), `validation` (`portable` or `domain:<name>`) and a `schema_hash`.

End state (step 2, after parity): the schema is authored once in
`config/settings/schema.json`; Swift descriptors and TypeScript types are generated from it. Kinds
and validation then live in exactly one place, in Rust.

Validation per kind: `toggle`, `choice`, `choice_or_number`, `number` (range, finite), `color`
(`#RRGGBB[AA]`), `url` (the `BrowserNewTabPage.url` rules, ported with a shared fixture table),
`host_list`, `time_range` are portable and checked in Rust. `theme`, `font_family`, `sound` check
against the value domain the app published (`settings.domains.publish`); with no published domain
(headless host) they accept any non-empty string and the app reports a diagnostic on apply.

`agent_settable: false` marks keys an agent must not change through MCP (none in the schema today;
`mcp.*` and every non-schema path are already outside MCP). The flag exists so a future key with a
trust effect is one line, not a policy change.

## 3. Ops (daemon, capability `settings-v1`)

Reads and writes are `cmux.protocol/2` operations in `cmux-tui/spec/resource-operations-v2.json`
(owner `config` in `resource_router::operation_owner`), so params are catalog-validated and every
mutation carries an `idempotency_key`. Shapes follow settings-surfaces.md:

- `settings.schema {}` (read) -> `{schema_hash, rows}` (descriptor rows without values).
- `settings.list {section?}` (read) -> rows with `value`, `default`, `customized`,
  `managed {source, reason}`.
- `settings.get {key | path}` (read); `settings.snapshot {}` (read) -> `{revision, effective, file,
  managed, diagnostics, schema_hash}`.
- `settings.set {key | path, value, if_revision?}`, `settings.reset {key | path}`,
  `settings.reset_all {}` (mutations).
- `settings.domains.publish {themes, font_families, sounds}` and `settings.team_policy.set {layer}`
  (mutations the daemon accepts only from the hosting app's connection, `set-client-info` kind app).

Change notification, slice a: a raw `settings-changed {revision, keys, origin}` event on the
existing `subscribe` stream, emitted through `MuxEvent` like `bookmarks-changed`, decoded by Swift
`DaemonEvent`. Settings are per machine, not per session, so `session.events` does not fit; a v2
stream replaces the raw event when the catalogs merge (D7).

Non-schema paths (custom actions, tab bar buttons, `shortcuts.bindings.*`) go through the same
actor with the managed guard. A request with origin `mcp` is refused for non-schema paths and for
rows with `agent_settable: false`; the owner enforces it, not the MCP server. The MCP tools are the
generated v2 tools for these operations (`v2_tools.rs`); the old app-method exclusion for settings
stays for the app socket until slice b deletes those methods.

A refusal is `validation.invalid` with the kind, the accepted values or range, and for a managed key
the source and reason (`settings.managed`). The daemon honors `CMUX_NEXT_CONFIG_FILE` exactly as the
Swift `CmuxConfigFile.defaultURL` does, so tagged builds never touch the user's file.

## 4. The page (web, in a page tab)

Principles taken from the reference captures (layout and flow, not pixels):

- Two columns. Left: a search field on top, then the section list (icon + name + a status badge:
  a warning when a section has diagnostics, a lock when it has managed keys). Right: the section.
- Search first. Opening Settings focuses the search field. Typing filters across every section by
  title, help, keywords, key and current value; results are rows you can edit in place, grouped by
  section, with the match highlighted. Return on a result reveals the row in its section and focuses
  its control. Esc clears the query, a second Esc returns focus to the list.
- Rows: title and one-line help on the left, the control on the right, one row per setting, grouped
  into cards with the group title above the card. No Save buttons.
- A customized row shows a reset button beside its control; Reset to Default sends `settings.reset`.
- Managed rows show the value, a disabled control and the reason ("Set by your organization's
  profile", "Set by team policy <team>"). The same text comes from the daemon for CLI and MCP refusals.
- Notices sit inline above the row they concern (a diagnostic for a bad value in cmux.json, with
  "Open cmux.json" and "Reset").
- Collections (shortcuts, custom actions, browser profiles, machines) are tables with their own
  search and a category filter, one row per item, editable cells (Record Shortcut).
- Drill-in rows (title, count, chevron) for sub-pages; Back/Forward (Cmd-[ / Cmd-]) walks the page
  history; deep links `#/settings/<section>?focus=<key>` from the palette, CLI
  (`cmux settings open <key>`) and notices.
- Keyboard: Cmd-F focuses search, Up/Down moves through rows, Tab moves into a control, Space
  toggles, Return opens a menu, Cmd-Backspace resets the focused row. Every row is reachable without
  the mouse.

Editors per kind: toggle = switch; choice with up to 3 values = segmented control, more = menu;
choice_or_number = menu with "Custom…" opening a number field; number = slider + field with unit
(fractions shown as percent), committed on release or Return; color = swatch + hex field + "Use
Theme Color"; theme = a grid of previews (light and dark); font_family = searchable list with a live
sample; sound = menu with a play button (native bridge); url = text field checked on commit;
host_list = token field; time_range = two time fields.

Live apply: every commit is one `settings.set`. During a slider drag the page sends a local preview
to the app through the native bridge (`preview {key, value}`, `preview.end`); Swift shows it as an
overlay that is never written. The commit at the end is the only op (OWNERSHIP-PRINCIPLES: gestures
are local continuous state).

Transparency: Appearance > Window Background: Opacity (slider 0-100 %, live preview, reset = the
Ghostty value) and Material (Frosted, Glass, Clear Glass, None). Keys
`appearance.backgroundOpacity` and `appearance.backgroundBlur` already exist in the schema; the page
gives them first-class controls and a preview of the window behind.

One background: the web view is transparent (`drawsBackground = false`, page `background:
transparent`); the page tab container paints `ThemeTokens.surfaceBackground` (lane 20), so the page
shows the same background, opacity and material as every other surface. Cards use one fill derived
from the theme foreground at low alpha, delivered as CSS variables through the theme bridge
(`AgentPaneTheme.values` moves to a shared web page theme in CmuxNextDesign so both pages get the
same tokens). The page never picks its own background color.

Strings: page chrome and descriptor strings are xcstrings keys (21 languages). The build generates
`webviews/src/settings/generated/strings.<locale>.json` from the xcstrings files the descriptors and
the page use; the page picks the app's language. No string lives only in TypeScript.

## 5. Hosting and wires

- A new `InternalPageProvider` (page `settings`) returns a WKWebView that loads
  `cmux-settings://page/index.html#/settings`, served by a scheme handler from the bundled webviews
  output (the agent pane's scheme-handler pattern). The handler serves only that origin; navigation
  to any other origin opens in a browser tab; message handlers accept only frames whose origin is
  `cmux-settings://page`.
- The page reaches the daemon through the native bridge: `window.webkit.messageHandlers.cmuxSettings`
  carries `{op, params}`; Swift forwards each request unchanged to the daemon's `settings.*` ops
  and streams `settings.changed` back. Swift does not interpret or cache the ops on this path.
  The relay forwards only operations whose name starts with `settings.` (plus the stream cancel of
  its own stream); anything else is refused at the bridge. A direct page-to-daemon WebSocket is not
  used: the daemon's WebSocket listener is opt-in, has no Origin allowlist yet
  (cmux-tui/spec/transports.md), and an authenticated WebSocket client can type into terminals, so it
  would grant the page far more than settings.
- Swift subscribes once per app (not per tab) and fans events out to the controller, the palette and
  every Settings tab.

## 6. Cold start and daemon loss

The config actor writes `<state>/settings/effective.json` (effective root, managed map, revision,
schema hash) after every change. At launch, before the daemon answers, the app applies that cache
(no merge logic in Swift). When the daemon connects, its snapshot replaces the cache view. With no
cache (first launch), the app applies defaults until the daemon answers. While the daemon is
unreachable, Settings shows "Settings are read only until cmux reconnects" and refuses writes.

## 7. Slices

| # | Slice | Gate |
| --- | --- | --- |
| a | `cmux-config` crate in the daemon (first cmux.json writer outside Swift; a comment-preserving JSONC editor ported from `JSONC.swift`, since the workspace has only a read-only stripper): schema from the export, portable validation, managed reader, merge, JSONC editor, atomic publish, watcher, events, cache file; `settings.*` ops; capability `settings-v1`; Rust CLI `cmux settings list/get/set/reset/open` and MCP `settings_list/get/set/reset` against the daemon (cmux-tui landing window) | cargo tests on a Testbox: reducer property tests (idempotent replay, managed keys never change, every row's default and a wrong-kind sample), JSONC round-trip fixtures shared with the Swift tests; the 191-op count tests and `check-resource-api-boundary.py` updated |
| b | Swift projection: `DaemonSettingsSource` (snapshot + subscribe), `SettingsController` setters send ops when the daemon serves `settings-v1`, domains publish, team policy forwarded; raw socket writes removed; native window kept | Swift tests on the fleet: a write from the CLI path updates `DesignSettings` with no file access from Swift |
| c | Web page in `webviews/src/settings`, scheme handler, page provider behind Debug Settings `settings.surface = web` (default native until d passes) | webviews tests; tagged build + `debug.window_snapshot` of the page tab |
| d | Parity test over every descriptor: palette row + editor, `settings.list` row, CLI round trip, MCP tool, page row with an editor for its kind | one test fails per missing surface |
| e | Default `settings.surface = web`; delete the native Settings views and `SettingsWindowModel` after one dogfood round | dogfood |
| f | Schema authored in `config/settings/schema.json`; Swift descriptors, `web/data/cmux.schema.json` and TS types generated; `cmux-tui.json` overlapping keys fold into cmux.json | generator `--check` in CI |

Collections without a daemon owner yet (accounts: app Keychain; spaces and machines: their owners'
catalog ops) render in the page through the catalog actions that already exist; where none exists,
the page links to the native card until its owner serves ops. That is the only reason the native
window stays after slice d.

## 8. Strongest objection

"This makes the app's look and every settings change depend on a second process. Today Settings
works with the app alone; after this, a dead or slow daemon means stale settings and refused edits,
and cold start gets a process hop."

Answer: the daemon already owns every terminal; with the daemon down the app has no terminals to
show either, so settings availability does not get worse in any state the app is useful in. Cold
start reads the daemon's cache file, so first paint needs no round trip. A local socket round trip
is far below one frame, and slider drags never round trip (local preview, one commit). In return:
the CLI, MCP and TUI change settings with no app running (headless hosts, VMs, remote Mac minis),
the two writers of today (`setSetting` and the raw socket store) become one, and `cmux-tui.json`
stops duplicating theme keys.

Second objection: three schema sources until slice f (Swift descriptors, the Rust export,
and `web/data/cmux.schema.json` for editors and docs) (Swift authors descriptors, Rust validates from an
export). Answer: the export freshness test fails CI on drift, the daemon is bundled from the same
commit, and `schema_hash` in identify makes a mismatch visible; slice f generates all three from
one file.

## 9. Questions for the coordinator

- Q1 (lane 20): `appearance.tabBarBackground = darker` draws a second background under the tab strip,
  which contradicts "all bg across entire app must match the same". Rec: remove the `darker` choice
  (or keep it as a Debug Settings prototype only) when the one-token work lands.
- Q2 (catalog lane): this plan takes the writer of settings-surfaces.md "One writer" into Rust. Rec:
  the catalog lane still lands the Swift export, the palette Set Setting page and the parity test;
  it skips the Swift `ControlSettingsWriter` routing, which slice b deletes.
- Q3: Native window deletion (slice e) waits for one dogfood round of the web page. Rec: yes.
