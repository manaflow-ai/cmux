# Settings: daemon-owned state, one web page, every surface

Status: plan, 2026-10-03 (updated 2026-10-04 for the pane protocol and the shared page host). Owner: settings lead. Lawrence: "move settings into react, the tanstack
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
`schemas/settings/settings-schema.json` (landed 306bb4e0858, `SettingsSchemaExportTests.exportIsFresh`,
`CMUX_UPDATE_ACTION_SURFACES=1` rewrites it). The Rust crate embeds it at build time
(`include_str!`), so a bundled daemon and its app always agree. Per row: every text with its
xcstrings key (descriptors carry keys through `SettingText` / `SettingsText.keyed`), kind, choices,
range, default, `accepts`/`refuses` samples (the conformance corpus the Rust validator must match),
`validation` (`portable` or `domain:<name>`), `agent_settable` + `agent_refusal`,
`kept_on_reset_all`, and the document's `schema_hash`. The catalog lane's surface parity reads the
same file.

End state (step 2, after parity): the schema is authored once in
`config/settings/schema.json`; Swift descriptors and TypeScript types are generated from it. Kinds
and validation then live in exactly one place, in Rust.

Validation per kind: `toggle`, `choice`, `choice_or_number`, `number` (range, finite), `color`
(`#RRGGBB[AA]`), `url` (the `BrowserNewTabPage.url` rules, ported with a shared fixture table),
`host_list`, `time_range` are portable and checked in Rust. `theme`, `font_family`, `sound` check
against the value domain the app published (`settings.domains.publish`); with no published domain
(headless host) they accept any non-empty string and the app reports a diagnostic on apply.

Agent policy is explicit per key with no default (`SettingsSchema+AgentPolicy.swift`; the export
test fails on a key in neither table). Refused today: `history.terminalCommands` and
`feed.mirrorNotifications.*` (privacy), `browser.remoteLocalhost` (network), `app.quitBehavior`
(destructive). `appearance.backgroundOpacity` and `appearance.backgroundBlur` are settable.

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

Refusal codes are the ones the Swift socket stopgap (c9cb3b51eea, 1f08a54bc4c) already returns, so
clients change once: `managed` (with source and reason) and `invalid_params` (with the kind and the
accepted values or range); new: `agent_refused`, `revision_conflict`, `idempotency_conflict`.
`SocketSettingsWriteTests` moves to the Rust actor with the same cases when slice b deletes the
Swift writer. The daemon honors `CMUX_NEXT_CONFIG_FILE` exactly as the
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
- Drill-in rows (title, count, chevron) for sub-pages; Back/Forward (dispatcher commands) walks the page
  history; deep links `#/settings/<section>?focus=<key>` from the palette, CLI
  (`cmux settings open <key>`) and notices.
- Keyboard: the app's key dispatcher owns every Cmd and Ctrl chord and sends page commands (find,
  back, forward, reset of the focused row). The page handles plain keys: Up/Down moves through
  rows, Tab moves into a control, Space toggles, Return opens a menu. Every row is reachable without
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
Ghostty value) and Material (Frosted, Glass, Clear Glass, None; a material choice, never a radius
slider). Keys
`appearance.backgroundOpacity` and `appearance.backgroundBlur` already exist in the schema; the page
gives them first-class controls and a preview of the window behind.

One background (lane 20 render rule): html and body `background: transparent`, no full-page
container background and no background fill at any level (groups are separated by spacing and
hairlines that follow `appearance.borders`); the WKWebView draws no background
(`drawsBackground = false`, `underPageBackgroundColor = .clear`); the page tab paints nothing when
opacity < 1 (the window's one backdrop is the only translucent layer) and
`ThemeTokens.surfaceBackground` at opacity 1. Interactive feedback (hover, selection, focus) uses
the shared web theme variables (`AgentPaneTheme.values` until lane 20 defines them in windows.md).
A test checks the computed html/body background.

Strings: page chrome and descriptor strings are xcstrings keys (21 languages). The build generates
`webviews/src/settings/generated/strings.<locale>.json` from the xcstrings files the descriptors and
the page use; the page picks the app's language. No string lives only in TypeScript.

## 5. Hosting and wires (updated 2026-10-04: pane protocol, shared page host)

- Host: the shared `CmuxNextPages` module (React UIs lead; react-pages.md Q7) serves every page at
  `cmux-page://<page id>/` from one generic `PageWebView`, `PageSchemeHandler` and `PageBridge`
  (`cmuxPage` message handler, one namespace allowlist per page). Settings adds only its allowlist
  (`cmux.settings.*`) and its provider. The earlier Settings-only host (`cmux-settings://page`,
  branch `feat-cmux-next-settings-react` 7b1cad2e028) is not landed; its parts went to that module.
- Manifest (pane-protocol.md "Pages"): `{"id":"cmux.settings","route":"/settings",
  "entry":"pages/settings/index.html","namespace":"cmux.settings","provider":{"kind":"daemon-module"},
  "consumes":["cmux.settings/1"],"scopes":["settings:read","settings:write"],
  "engines":["webkit","cef","browser"]}`. Presentation fields come from the app manifest's
  `presentation` block when it exists; Settings adds none of its own.
- Ops on the page side are `cmux.settings.*` (the CLI keeps `cmux settings ...`, MCP keeps the
  generated v2 tools). Until the pane-protocol router reaches the daemon, the page bridge relays
  each data op to the daemon's v2 op of the same verb (`cmux.settings.set` -> `settings.set`):
  it moves `idempotency_key` into the v2 envelope, stamps origin `user` (a page-sent origin is
  refused), maps error codes `settings.X` to `cmux.settings.X`, and forwards the daemon's
  `settings-changed` event as `cmux.settings.changed {revision, keys, origin}`.
  `settings.domains.publish` and `settings.team_policy.set` are never reachable from a page.
  When the router lands, the daemon module declares the same ops with the `cmux-pane-protocol`
  schemars macro and the relay goes away; no page file changes.
- Native ops (served by Swift): `cmux.settings.preview {key, value}`, `cmux.settings.preview.end
  {key}`, `cmux.settings.sound.play {name}`; Open cmux.json and the native Settings card are catalog
  actions through `cmux.app.action.run`.
- Every page also uses two bridge streams: `cmux.page.connection {connected}` (daemon link) and
  `cmux.page.command {command}` (find, back, forward, reset from the app's key dispatcher; pages
  handle no Cmd or Ctrl chords). Locale: the document language; theme: the one web theme
  (`--cmux-*`); route: the URL fragment (`#/settings/<section>?focus=<key>`).
- Value domains (themes, fonts, sounds) come from `cmux.settings.snapshot.domains` (the app
  publishes them to the daemon), so the page needs no native op for them.
- A direct page-to-daemon WebSocket is not used before the router: the daemon's WebSocket listener
  has no Origin allowlist yet and an authenticated client can type into terminals.

## Page pattern (copy this for History and App Store)

One directory per page, `webviews/src/pages/<page>/`:

| File | Role |
| --- | --- |
| `ops.ts` | the page's contract: op name -> [params, result], stream name -> event, the `Client` interface (`call`, `subscribe`; structurally the shared pageClient), error-code helpers. Hand-written until the schemars IR generates it. |
| `store.ts` | one immutable state object read with `useSyncExternalStore`; `start()` subscribes (changed, `cmux.page.connection`, `cmux.page.command`) then reads; every write is one op with a fresh `idempotency_key`; a newer read always wins; offline writes are refused, never queued. No `useEffect`. |
| `mockProvider.ts` | the namespace served on a pane-protocol `Session` over `createMockPair()`: same error codes, idempotency rules and events as the real owner. Used by the dev server (`main.tsx`) and every test, so tests cross the real envelope. |
| `mount.tsx` | `mount<Page>(root, client)`: the only entry the shared shell calls. |
| `keyboard.ts` | plain keys only (Up/Down/Space/Return/Escape/typing); `runPageCommand` for dispatcher commands. |
| `generated/strings.json` | from the xcstrings catalogs (`scripts/pages/<page>/generate-strings.mjs --check`); every page string is an xcstrings key in all languages. |

Tests (bun): the mock provider honors the owner's accept/refuse samples; the page renders an editor
for every row kind; writes send one op with a key; another client's write shows up live; offline
mode refuses writes; chords do nothing and dispatcher commands work; html/body and containers paint
no background.

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
| c | Web page in `webviews/src/pages/settings` on the shared page host (`CmuxNextPages`), Settings provider behind Debug Settings `settings.surface = web` (default native until d passes) | webviews tests; tagged build + `debug.window_snapshot` of the page tab |
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

## 9. Decisions

Answered 2026-10-03: Q1 remove `appearance.tabBarBackground = darker` (every background matches);
Q2 the catalog lane keeps the palette page and parity test and skips the Swift writer routing;
Q3 delete the native window after one dogfood round of the web page.
