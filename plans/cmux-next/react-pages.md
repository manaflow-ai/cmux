# React pages: History and App Store (Rust backend, React UI)

Status: plan, 2026-10-04. Owner: React UIs lead. Request R62 (Lawrence): "ensure history, app store,
and settings are all in react instead of swift. only home/chief UI should be in swift. most all
other UIs should be in react with rust backend." Coordinator decision UI-STACK: Home/Chief stay
native; Settings, History, App Store and new pages are React in `webviews/` with a Rust backend
(the cmux-tui daemon owns data and ops), talking over the pane protocol (pane-protocol.md, R60).
Swift keeps window chrome, sidebar, tab strip, terminals, the key dispatcher and native glue. A
Swift page is deleted when its React page reaches parity; never two implementations.

Settings is the settings lead's (settings-react.md). This file copies its pattern: one daemon
owner, one page tab, the same ops for palette, CLI and MCP. Binding: OWNERSHIP-PRINCIPLES.md,
history.md (entry kinds, owners, retention), app-platform.md (catalog semantics, install states).

## 1. Shared page shell (both pages)

| Part | Path | Notes |
| --- | --- | --- |
| Page entry | `webviews/src/pages/<page>/main.tsx`, routed by `data-cmux-webview-kind="<page>"` in `webviews/src/main.tsx` | own chunk, like `surfaces/` |
| Page client adapter | `webviews/src/pages/shared/pageClient.ts` | the only file that knows the transport (section 1.1) |
| Strings | `webviews/src/pages/<page>/generated/strings.<locale>.json` from the page's xcstrings | generator with `--check`; no string only in TS |
| Theme | `WebTheme.bootstrapScript` + `--cmux-*` variables (windows.md "Web theme") | html/body transparent, separators `--cmux-separator`, hover/selection `--cmux-hover`/`--cmux-selection`, no blue, `appearance.borders = none` gives no lines |
| Swift host | one generic `PageWebView` (WKWebView, `drawsBackground = false`) + scheme handler `cmux-page://<page id>/` serving the bundled webviews output | one origin per page id (pane-protocol.md Pages); proposed to the settings lead as the shared host instead of a per-page scheme |

### 1.0a First-party page roots (coordinator decision 2026-10-04)

`PageID.registerBundledRoot(root, for: id)` (H10) stays as the one way to give a first-party page a root
in the app bundle outside CmuxNextPages (for example cmux.diff on the one webviews-app build, with
`PageDescriptor.entry`). It accepts only ids in `PageID.firstParty`, is called once at launch, and the
first registration wins. P5 of the agent pane move deletes only the agent pane's own special path, not
H10. App pages never use it.

### 1.1 Transport

The pane protocol router is not in the daemon yet. The page code calls one interface:

```ts
interface PageClient {
  call<R>(op: string, params: unknown, opts?: { signal?: AbortSignal }): Promise<R>;
  subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void>;
}
```

- Now: `pageClient.ts` speaks the pane-protocol envelope (`call`/`ok`/`err`/`sub`/`ev`) over the
  WebKit message handler `cmuxPage` (reply-capable). Swift relays each call unchanged to its owner
  and refuses any op outside the page's namespace (`cmux.history.*` for History, `cmux.apps.*` for
  App Store) plus the page's declared native UI ops. Swift does not interpret or cache.
- Later: the same file builds a `Session` from `webviews/src/protocol/` over the handshake
  transport, resolves the namespace with `cmux.router.resolve`, and talks to the daemon module
  directly. No page file changes.
- Tests use the protocol's in-memory mock pair (or a local mock until `webviews/src/protocol/` is on
  feat-cmux-next).

Manifest entries (pane-protocol.md Pages):

```json
{"id":"cmux.history","route":"/history","entry":"pages/history/index.html","namespace":"cmux.history",
 "provider":{"kind":"daemon-module"},"consumes":["cmux.history/1"],"scopes":["history:read","history:write"],
 "engines":["webkit","cef","browser"]}
{"id":"cmux.apps","route":"/apps","entry":"pages/apps/index.html","namespace":"cmux.apps",
 "provider":{"kind":"daemon-module"},"consumes":["cmux.apps/1"],"scopes":["apps:read","apps:write"],
 "engines":["webkit","cef","browser"]}
```

### 1.2 Keys and focus

No shortcut handling in pages. Cmd chords go to the app's key dispatcher (keybindings lead); the
dispatcher sends page commands (`find`, `focusSearch`) to the page through the bridge. Plain content
input inside a focused page control (typing in the search field, Up/Down/Return in the focused list,
Space on a switch) stays in the page, like text input in a terminal. Open question Q3.

### 1.3 Native UI ops

Ops that change one client's view (open a URL in this tab, go to a location, open a terminal tab
with typed text, reveal) are served by Swift as catalog actions with origin `user` (the page is a
user surface). The page calls them as `cmux.app.action.run {action, args}`; Swift runs
`ActionRegistry.perform`, the same handler the palette and CLI use.

## 2. History

### 2.1 Today (Swift)

Page UI: `CmuxNextHistory/HistoryPageView.swift`, `HistoryPageRow.swift`, `HistoryPageHostView.swift`,
`HistoryPageModel.swift` (keep `HistoryPageAddress`), `HistoryStrings.swift`;
`CmuxNextApp/History/HistoryPageTab.swift` (a `BrowserTab` with a native view, URL `cmux://history`,
survives relaunch), `HistoryPageService.swift` (open/select logic; `TabContentCache.appPage` is shared
with bookmarks, agent activity, remote view).

Features: search (all tokens, case and diacritic insensitive, over title, detail, machine, payload);
chips All/Pages/Locations/Commands/Agents/Closed; Group By Day/Workspace/Machine; Clear History…
Last Hour/Today/Last 7 Days/Last 4 Weeks/All Time; rows with icon, title, "detail · machine", time,
badges Offline/Current/Running; context menu per kind (page: Open, Open in New Tab, Copy URL, Remove
All from This Site; location: Go To; closed: Reopen, Copy URL; agent: Resume Agent Session, Copy
Session ID; command: Run Again, Copy Command; all: Remove from History); search focused on open,
Up/Down select, Return or double-click opens; empty states "No history" / "No matches"; at most
1000 entries; hidden: non-web pages, `cmux:`/`about:blank`/`~` locations.

Entry points (all stay; they open the new page): `history.show`, `browserShowHistory` (Cmd-Y),
`history.search`, `recentlyFocused`, `recentlyClosed`, `history.commands`,
`history.resumeAgentSession`, `history.reopen`, `history.clear`, `focusHistoryBack/Forward/Last`,
`layout.undo`; Rust CLI `cmux history list|search` (today the app control method `history.list`,
`AppControl.swift:42`); typed `cmux://history`. Palette pages stay native (palette is Swift) and move
to the same ops in H3.

Data owners today:

| Kind | Owner | Store |
| --- | --- | --- |
| page | Swift app | `BrowserProfiles/<profile>/History.sqlite` (`BrowserVisitLog`, `HistorySQLite`), 90 days, 100k visits |
| location | Swift app (`LocationTrailService`, client view state) | daemon personal projection `history.trail` |
| closed | daemon (`closed.list`, `closed.reopen`, `state-resources-v1`) | daemon; Swift in-memory fallback trackers for old daemons |
| command | daemon journal `shell.command.finished` (`terminal-command-journal-v1`) | Swift folds in memory (`TerminalCommandFold`) |
| agent | daemon journal `agent.session.*`, `agent.turn.*` (`session-journal-v1`) | Swift folds in memory (`AgentSessionFold`) |
| hidden | Swift writes projection `history.hidden` | daemon projection |

The merge, search, grouping and clear logic all run in Swift (`HistoryService`).

### 2.2 Target owners

A daemon module `cmux-history` (new crate, pure query core + SQLite store; module in
`cmux-tui-core` wires ops) owns the merged read model and every history write that is not client
view state:

| Kind | Writer after | Notes |
| --- | --- | --- |
| page | daemon module (per-profile SQLite under the daemon state dir); the app reports each finished main-frame navigation with `cmux.history.visit.record` (accepted only from the hosting app connection) | the omnibox seeds from `cmux.history.visit.summaries`; CLI/MCP/TUI get page history with no app |
| location | Swift app (trail reducer and cursor are per-client view state); persistence unchanged (`history.trail` projection, only that client writes) | the module reads the projection; Remove of a location is a native UI op |
| closed | daemon (exists) | drop the Swift fallback trackers (the bundled daemon serves `state-resources-v1`) |
| command, agent | daemon journal (exists); the folds move into `cmux-history` | |
| hidden | daemon module (owns `history.hidden`) | one writer |

Decided (Q1, 2026-10-04): page visits move from the app into the daemon module; history.md
section 2 is updated. The CLI then reads history with no app running. The 1 MiB projection limit
does not apply (the module keeps its own SQLite file, not a projection).

### 2.3 Ops (`cmux.history/1`, declared with the `cmux-pane-protocol` schemars macro once the crate lands)

| Op | Kind | Params -> result | Status |
| --- | --- | --- | --- |
| `cmux.history.entries.list` | read | `{kinds?, text?, range?, limit? (default 200, max 5000), cursor?}` -> `{entries[HistoryEntry], next_cursor?, revision}` | new (replaces app `history.list`) |
| `cmux.history.entries.remove` | mutation | `{ids[], idempotency_key}` -> `{removed}` | new |
| `cmux.history.site.remove` | mutation | `{host, profile?, idempotency_key}` | new |
| `cmux.history.clear` | mutation | `{kinds?, range, profile?, idempotency_key}` | new |
| `cmux.history.visit.record` | mutation (app connection only: today a connection that declares set-client-info kind `frontend`, accepted by the coordinator 2026-10-04 because a forged visit only adds a row; switch to `verified_app` when the peer verification lands) | `{profile, url, title?, tab, at_ms, idempotency_key}` | new |
| `cmux.history.visit.summaries` | read | `{profile, limit?}` -> `[{url, title, visit_count, last_visit_ms}]` | new (omnibox seed) |
| `cmux.history.changed` | event | `{revision, kinds[]}` | new (no polling; the page re-reads its window) |
| `closed.list`, `closed.reopen`, `session.journal.subscribe` | existing v2 | used by the module, not by the page | exist |

`HistoryEntry`: `{id: "<session>:<kind>:<id>", kind, title, detail?, machine?, workspace?, at_ms,
available, current?, running?, url?, profile?, closed_kind?, cwd?, command?, exit_code?,
session_id?, provider?}`. The provider filters (kinds, tokens, range, displayable); the page groups
and derives the row menu from the kind and fields (presentation, pure, tested in `model.ts`).

Restore actions stay Swift catalog actions (native UI ops, section 1.3): new `history.open {id,
new_tab?}` (one entry point for row activation: page open, location go to, closed reopen, agent
resume, command run again; `HistoryRestorer` already implements each), existing `history.reopen`,
`history.resumeAgentSession`. CLI and MCP keep the same verbs.

Surfaces: CLI `cmux history list|search|remove|clear` and MCP tools generated from the ops; palette
pages read the same op. Every op declares its surfaces in the catalog (check-action-surfaces).

### 2.4 Page (`webviews/src/pages/history/`)

- `model.ts` (pure): query state, kind filter, grouping (day labels from the locale, workspace,
  machine), selection, keyboard-free reducers; bun tests.
- `HistoryPage.tsx`: header with search field (focused on open) and Group By / Clear menus; chips
  row; grouped list (virtualized above 500 rows); row component with icon, title, detail, time,
  badges; context menu from `entry.actions` (web menu, not native).
- `useHistory.ts`: `entries.list` on open and on each query change (a newer request supersedes the
  older reply), subscribe `cmux.history.changed` and re-read; no polling.
- Copy actions: `navigator.clipboard.writeText` on the click; fallback native op
  `cmux.app.clipboard.write` if the custom scheme is not a secure context (checked in H1).

### 2.5 Slices

Decided (Q2, 2026-10-04): no temporary Swift provider. H1 develops against a mock provider in the
browser dev loop; H2 and H3 run in parallel; the page becomes the default when H3 lands.

| # | Slice | Window | Gate |
| --- | --- | --- | --- |
| H1 | React page, `pageClient` adapter, strings generator, mock `cmux.history` provider and a browser dev entry (dev-slot pattern) | none (webviews) | bun tests, tsc, webviews bundle `--check` |
| H1b | Swift `PageWebView` + `cmux-page://<id>/` scheme handler + `cmuxPage` bridge that relays namespaced ops to the daemon; `HistoryPageTab` hosts it when the daemon serves `cmux.history/1` | none (Swift) | Swift tests on cmux-mini-6, tagged fleet build + `debug.window_snapshot` |
| H2 | `cmux-history` crate: entry model, folds (agent, command, ported from Swift with shared fixtures), query (tokens, diacritics, displayable), hidden ranges, visit SQLite store; property tests | crate-only slot | cargo on a Testbox |
| H3 | daemon module + ops + events + CLI/MCP; Swift: the browser records visits by op, omnibox seeds from `visit.summaries`, palette pages read the op; delete `HistoryService` merge, `BrowserVisitLog`, `HistorySQLite`, folds, `HiddenHistoryStore`, `HistoryControl`, fallback closed trackers | cmux-tui landing window | cargo tests, Swift tests, CLI round trip on a tagged build |
| H4 | parity test (every feature of 2.1 has a page test); delete the Swift page files of 2.1 after one dogfood round | none | dogfood |

## 3. App Store

### 3.1 Today (Swift)

Page UI (delete at parity): `CmuxNextApps/Store/AppStoreWindowController.swift`, `Views/AppStoreRootView`,
`AppDiscoverView`, `AppListingViews`, `AppListingDetailView`, `AppInstalledView`, `AppGrantsView`,
`AppLivePreview`, `AppIconView`; models `AppStoreModel`, `AppStorePages`, `AppStoreCatalog`,
`AppStoreListing`, `AppPreviewSink`. Shared, stays native: `AppSectionFrame`, `Render/*`, `Scene/*`
(sidebar sections). The registry, grants and JSC engine go with the app platform lead's supervisor
(app-platform.md section 13), not with this page.

Features: Discover and Installed tabs; listing detail (description, previews, permissions,
versions, repository link, tier and installed badges); layouts grid (default) / list / split (Debug
Settings `apps.store.layout`); search over id, name, description, publisher, categories, keywords;
category chips; live preview of sidebar-section and status-item contributions (real JS, native
`AppSceneView`, sample data for apps not installed); grants per scope with reason, Run sandboxed;
logs (last 200 lines); Installed rows with enable switch, Reload, Permissions, Logs, Remove, Local
badge; "Prototype engine" note. Install and Remove come only from buttons (user gesture).

Entry points: `appStore.show [app]` (palette, CLI `app store`, sidebar background menu, sidebar App
Store item), `appStore.showInstalled`, `app.hide/unhide`, `app.open`, `app.command.run`. The store is
an internal page tab `app-store` (one per window; standalone window only with no main window).

Data owners today: all in Swift (bundled scan as catalog, `registry.json` installs, grants, logs in
memory). No Rust supervisor and no cloud store ops exist yet.

### 3.2 Ops (`cmux.apps/1`, app-platform.md section 15, owned by the app platform lead)

The page uses the 17 ops of app-platform.md section 15 through the generated client: catalog
(`catalog.list`, `catalog.get`, `asset.get`), installs (`installed.list`, `install`, `uninstall`,
`set {enabled, hidden, sandboxed}`), grants (`grants.get`, `grant.set`), updates (`updates.list`,
`update`), dev apps (`local.add`, `local.remove`, `validate`), `logs` (stream), `watch` (typed
stream, no polling) and `open {app, command?, focus?}`. `cmux.apps.set` replaces `app.hide/unhide`
and `cmux.apps.open` replaces `app.open`. Install, uninstall, grant, update, local and non-hidden
`set` changes need origin user with a gesture. This page changes no catalog semantics.

### 3.3 Page (`webviews/src/pages/apps/`)

- `model.ts` (pure): tab, query, category, selection, layout variant; search matching ported from
  `AppStoreListing.matches` with shared fixtures.
- Views: Discover (grid, list, split as DEV variants, grid default), listing detail, Installed
  (rows, enable switch, actions), Permissions panel (scope switches, sandbox), Logs panel (stream).
- Icons and screenshots through `cmux.apps.asset.get` (HTTP from the provider later, pane-protocol
  "Bulk static data"). A manifest SF Symbol icon: the Mac host renders it to PNG for `asset.get`;
  other clients show a generic glyph; the manifest validator warns on symbol icons (Q5). No SF
  Symbols as web SVGs (Apple license).
- Install, uninstall, update and grant changes: the page sends the op; the Mac host shows a native
  Swift confirmation (app name, scopes with risk class) and that sheet stamps origin user (Q4). Page
  JS never proves a gesture.

### 3.4 Slices

| # | Slice | Window | Gate |
| --- | --- | --- | --- |
| A1 | React page against a mock `cmux.apps` provider (fixtures from the bundled apps) behind Debug Settings `apps.store.surface = web`; Swift host reuses `PageWebView` in the `app-store` internal page | none | bun tests, tagged build snapshot |
| A2 | wire to the supervisor's `cmux.apps.*` when it lands (the app platform lead's window); install gesture path | theirs | tagged build: install, grant revoke, logs |
| A3 | parity with screenshots in place of the live preview (Q6; web scene renderer later), parity test, default web, delete the Swift store files of 3.1 after one dogfood round | none | dogfood |

## 4. Parity checklists

History: every item of 2.1 "Features" and "Entry points" has a page test or an entrypoint test;
CLI `history list|search` works with the app quit (after H3); incognito entries never shown;
offline machine entries greyed; clear per kind and range; Cmd-Y and `cmux://history` select an
existing tab.

App Store: every item of 3.1 "Features"; install refused without a user gesture; revoke takes effect
on the next call; hidden apps listed in Installed with Unhide; layouts as DEV variants.

Both: strings in English and Japanese; one background (computed html/body background test);
`appearance.borders = none`; Reduce Motion; no blue; works in WebKit and a plain browser with the
mock provider (CEF when the CEF host lands).

## 5. Decisions (coordinator, 2026-10-04)

- Q1 yes: page visits move into the daemon module.
- Q2 no temporary Swift provider: H1 on a mock provider; H2 and H3 in parallel.
- Q3 yes: the page handles plain Up/Down/Return/Space/Escape/typing that the dispatcher delivers to
  a focused list or field; never Cmd or Ctrl chords.
- Q4: page JS cannot prove a gesture; install, uninstall, update and grant.set always show a native
  Swift confirmation that stamps origin user.
- Q5: no SF Symbols as web SVGs; the Mac host renders symbol names to PNG through `asset.get`;
  generic glyph elsewhere; validator warning for symbol icons.
- Q6 yes: screenshots-only parity first.
- Q7 yes: one `cmux-page://<id>/` scheme and one `PageWebView` for every page.
