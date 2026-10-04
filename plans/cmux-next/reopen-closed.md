# cmux next: Reopen Closed (Cmd-Shift-T) and bulk container actions (R102, design proposal)

Status: APPROVED by the coordinator (2026-10-04), D1-D5 as recommended, with one change: app-local
tab kinds MIGRATE into daemon tab kinds (section 3.0). The coordinator owns the spec;
this file is the lane plan. Base: feat-cmux-next 86fd13ce03c.

Lawrence's request: "we need cmd shift t to work (ensure history is done very efficiently, ownership
in rust, and works for every surface type, in a generalizable way, accounting for cmux apps that
people might bring in the future too)". Scope extension: a complete, first-principles bulk-action
catalog for every container level, and Cmd-Shift-T semantics for each bulk action.

## 0. What exists today (measured on 86fd13ce03c)

- Daemon `closed-history-v1` (cmux-tui-core `state/closed_history_store.rs`, `state/closed_history.rs`):
  table `closed_history` in the registry SQLite, ops `closed.list` and `closed.reopen` (idempotent,
  changes go into the same journal batch as the tombstone patch). Records exist for tab, screen and
  workspace. Tab content is only `terminal` (cwd, terminal id) or `browser` (url, engine, profile).
  Bound: 50 items per session, count only, no age. Ephemeral workspaces are not recorded.
  `insert_record` takes `MAX(sequence)` on a column with no index (full scan on each append).
- The daemon does not know app-local tabs: agent tabs (`local-agent:`), internal pages
  (`local-page:`: Settings, App Store, React pages), `local-browser:` tabs, and viewers. Their close is
  recorded nowhere, so Cmd-Shift-T cannot bring them back. This is the main reason why "Cmd-Shift-T
  does not work" for Lawrence (repro on cmux-lawrence-2 is step S4.0 below).
- The app keeps three more histories: `ClosedTabTracker` (tree diff, 25 tabs), `ClosedScreenHistory`,
  `ClosedWorkspaceTracker`, plus `WindowManager.reopenClosedWindow`. These are second owners of the
  same facts (violates single owner).
- Cmd-Shift-T = action `reopenClosedBrowserPanel` ("Reopen Last Closed Tab", CLI `tab reopen-last-closed`,
  defaultShortcut in the catalog, so KeyboardShortcutSettings and cmux.json already list it). It
  reopens only tabs, never a screen, workspace, space or window; a bulk close (7 tabs) needs 7 presses
  and the tabs come back one by one.
- No record keeps a window, a column, a title icon, browser back/forward history, scroll, a
  scrollback snapshot, an agent session id, a page route or an app payload.

## 1. Principles

1. One owner: the daemon owns the closed log (Rust). The app, the TUI, the phone, the CLI and MCP
   read it and request restores. The Swift trackers are deleted.
2. The closed log IS the restore-record store of spec/archive-and-hibernation.md (ARCHIVE-1). "Close"
   becomes "archive": the same record, the same op. Cmd-Shift-T is "restore the newest archive
   group in this window". The Archive view (History page, H3 lead) is the long list of the same rows.
   There is one log, not a "recently closed" log beside an "archive" log.
3. One close gesture = one close group = one restore. A bulk action ("Close Tabs to the Right" on 7
   tabs) writes ONE group with 7 members. Cmd-Shift-T restores the whole group in its original order
   and positions. Repeated presses walk back group by group.
4. One restore interface for every surface kind, first-party and third-party (section 3).
5. One shared action path per action: catalog action -> one daemon op -> one atomic patch. Shortcut,
   palette, menu, context menu, CLI and MCP all call it.

## 2. Data model (daemon, `closed-history-v2`)

Two tables in the registry SQLite (store of record, journal-backed through the existing batch):

```
closed_groups(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- O(1) append, natural newest-first order
  group_id TEXT UNIQUE NOT NULL,           -- closed_<uuid>
  op TEXT NOT NULL,                        -- the action that closed it: tab.close, tab.closeToRight, space.close...
  level TEXT NOT NULL,                     -- tab|pane|column|screen|workspace|space|window|mixed
  window_id TEXT NULL,                     -- window record id that showed it (client context of the close)
  space_id TEXT NULL, workspace_id TEXT NULL, screen_id TEXT NULL,   -- the container it left
  title TEXT NOT NULL, icon TEXT NULL,     -- summary for lists ("7 tabs from api-server")
  member_count INTEGER NOT NULL,
  closed_at_ms INTEGER NOT NULL,
  state TEXT NOT NULL,                     -- closed|restored|partially_restored|purged
  bytes INTEGER NOT NULL                   -- payload + cold bytes, for the budget
)
closed_members(
  group_id TEXT NOT NULL, ordinal INTEGER NOT NULL,   -- original order inside the group
  parent_ordinal INTEGER NULL,             -- tree: window > space > workspace > screen > column/pane > tab
  object TEXT NOT NULL,                    -- tab|pane|column|screen|workspace|space|window
  place_json TEXT NOT NULL,                -- {window, space, workspace, screen, column, pane, index, group(tab group), pinned, split geometry}
  surface_kind TEXT NULL,                  -- terminal|browser|conversation|page|viewer|app (tabs only)
  provider TEXT NULL,                      -- cmux.terminal|cmux.browser|cmux.agent|cmux.page|cmux.viewer|app:<app id>
  provider_version INTEGER NULL,
  title TEXT NULL, icon TEXT NULL,
  payload BLOB NULL,                       -- provider restore payload, inline, <= 16 KiB, validated
  cold_ref TEXT NULL,                      -- pointer to a cold blob (scrollback snapshot), with sha256 and size
  restored_at_ms INTEGER NULL,             -- partial restore marks members
  PRIMARY KEY(group_id, ordinal)
)
INDEX closed_groups_window ON closed_groups(window_id, seq) WHERE state != 'restored'
```

- RAM: the daemon keeps an index of the newest 1,000 open groups (seq, group id, window, level,
  title, count, time; about 200 B each, about 200 KB). Payloads and members stay on disk and are read
  only on restore or on a list that expands a group. `history.closed.list` is answered from RAM.
- Cold blobs: files under the daemon state dir `closed/<group>/<ordinal>.zst` (mode 0600), written
  after the commit (the record says `cold: pending|ready|failed`). A crash before the blob is written
  degrades that member to "respawn without scrollback"; the record is never lost.
- Migration: v1 rows become one group with one member each (same ids, so open History pages and
  `closed.reopen` callers keep working). `closed.list` and `closed.reopen` stay as v1 aliases for older
  apps and Cloud guests (docs/cloud-guest-upgrades.md: open every older schema).
- Retention (ARCHIVE-1 says "forever, with a disk budget for blobs"):
  - Group rows: forever by default; settings `history.closed.maxGroups` (default 0 = unlimited) and
    `history.closed.maxAgeDays` (default 0 = forever). A deletion by these limits is a hard delete.
  - Cold blobs: budget `history.closed.blobBudgetMB` (default 2048, part of the archive 20 GB budget),
    least recently closed first. A member whose blob is evicted degrades to respawn (cwd, env) and its
    list row says "scrollback not kept".
  - Restored groups are deleted at once (restore moves the objects back; the archive keeps no copy).
  - "Clear Recently Closed" (and per-item "Delete Permanently") deletes rows and blobs (hard delete).
- Efficiency: append is one INSERT per group plus one per member (no MAX scan, no eviction scan in
  the hot path; retention runs on a low-priority idle pass, triggered by the append count, no timer
  polling). Capture reads only the closing rows. Cmd-Shift-T is one RAM lookup plus one indexed read.

## 3. The restore interface (one for every surface kind)

Each surface kind has one restore provider with two functions:

```
capture(tab) -> {provider, provider_version, title, icon, payload (<= 16 KiB JSON), cold?}
restore(pane, index, member) -> new tab
```

### 3.0 Ownership rule (coordinator change, 2026-10-04)

App-local tab kinds MIGRATE into daemon tab kinds; they do not stay app-local with pushed state.
The agent tab and the new-tab page become a daemon `app` tab (R91, through the app screens lead's
`app` tab kind). Internal React pages and viewers become daemon tabs of the same `app` kind (a
first-party app id plus a route or path). Then `capture()` reads only daemon rows for every kind.
Pushed state (below) is ONLY for state that the daemon cannot own, documented per kind:

| Kind | Daemon owns (captured at close) | Pushed (daemon cannot own it) |
|---|---|---|
| terminal | cwd, launch spec, env set through cmux, hook-reported agent session, scrollback grid | nothing |
| browser (CEF, via cmux-browser-host) | url, engine, profile, back/forward list (the Rust host sees every navigation) | scroll position |
| browser (WebKit) | url, engine, profile | back/forward list (WKBackForwardList lives in the app process), scroll |
| app tab: agent (R91) | app id, conversation id, acpmux session id, cwd | draft prompt text |
| app tab: new-tab page, React pages | app id, page id, route | scroll |
| app tab: viewer | app id, path or document id, revision | scroll anchor |
| app tab: third-party | app id, app version | the app's restore payload (section 3.1, through the app host, which is a daemon module) |

The daemon cannot ask the app at close time (the app may be gone; the close may come from the CLI,
an agent or another Mac). So state that the daemon does not own is PUSHED ahead of time by its
single owner:

- `surface.restore_state.put {tab, provider, version, payload}`: the owner (the app for a page or a
  browser, the app host for a third-party app) puts the newest payload when it changes in a way that
  matters (navigation committed, route changed, file opened), coalesced, at most one row per tab
  (upsert, no history). Scroll positions ride on the close request instead (below).
- Every close op takes an optional `restore_state` map {tab -> payload}: when the closer is the
  owning client (Cmd-W in the app), it sends the freshest payload (scroll included) in the close
  request itself. The daemon uses the inline payload, else the pushed row, else only what it owns.

| Surface kind | Provider | Payload (what restores) | Cold | Not stored |
|---|---|---|---|---|
| Terminal | cmux.terminal (daemon) | cwd, launch command, env set through cmux (launch spec), shell kind, hook-reported agent session (harness + session id) | scrollback snapshot (text grid, <= 10k lines, zstd) | inherited process env; any env name that matches the secret deny-list (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY`, `AWS_*`, ...); output of a terminal marked private |
| Browser | cmux.browser (daemon owns url/engine/profile; app pushes the rest) | url, engine, profile, back/forward list (url + title per entry, max 50), current index, scroll | none (no screenshots, ARCHIVE-1) | private/incognito profiles (nothing recorded), form data, cookies, POST bodies |
| Agent conversation | cmux.agent | conversation id, acpmux session id, harness, cwd, draft prompt | none (transcript stays in acpmux) | nothing extra |
| React page (Settings, History, App Store, ...) | cmux.page | page id + route + query | none | |
| Viewer (diff, markdown, file, image) | cmux.viewer | viewer id, path or document id, revision, scroll anchor | none | file bytes |
| Third-party app pane | app:<id> | the app's own opaque JSON, validated (section 3.1) | none | anything over the limit |

Restore rules per kind:

- Terminal: when the terminal still runs (within the existing 30 s reap grace, or a "keep running"
  close), a new view attaches to the live terminal. Otherwise: a new shell in the saved cwd and env;
  the saved scrollback shows above a separator line "Restored from <date>; the process <cmd> was
  stopped" (ARCHIVE-1 decision 1); when a hook reported an agent session, the tab offers "Resume
  <harness> session" (one key), and does not run it without the user (an agent turn costs money).
  No process scanning, ever.
- Browser: the app gets the payload, rebuilds back/forward and scroll. The browser power-user lead
  (item 8) owns the engine side (WebKit/CEF history restore). This lane owns only the payload slot,
  its schema and the transport. Agreement needed on the schema (section 8).
- Agent: reopens the conversation tab on the same session.
- Page and viewer: reopen the page on the route, the viewer on the path. A missing file opens the
  viewer in a "file not found" state with "Locate…".

### 3.1 Third-party apps (manifest-declared)

- The manifest declares the capability on the interface it implements:
  `implements: [{"interface": "cmux.pane/1", "options": {"restore": {"version": 1, "maxBytes": 8192,
  "schema": "restore.schema.json"}}}]` (also `cmux.viewer/1`). The validator (`cmux-app-manifest`)
  checks: maxBytes <= 16384, the schema file exists in the package and compiles, version >= 1.
- The app host exposes two methods on the interface: `restoreState()` (called by the host when the
  pane changes, coalesced; the host puts it with actor `app:<id>`) and `restore(payload, version)`.
- The daemon validates every put: size, JSON, the app's schema, actor = the owning app. It never
  interprets the payload. The payload is visible only to that app and to the user (not to other apps,
  not to agents/MCP list results, which see title, kind and app id only).
- Restore when the app is disabled, uninstalled or too old for the payload version: a placeholder
  tab "<App name> is not installed" with "Install" / "Enable" / "Discard" buttons. The member stays
  in the log until the app restores it or the user discards it. An app that declares no restore
  capability gets a plain reopen (a new pane of the same app, no state).
- A newer app version gets `restore(payload, oldVersion)` and migrates; a refusal falls back to a
  fresh pane.

## 4. Cmd-Shift-T and the Reopen Closed list

- One action, `history.reopenClosed`, title "Reopen Closed" (en) / Japanese string, default
  Cmd-Shift-T, in KeyboardShortcutSettings (visible and editable in Settings, `cmux.json`
  `shortcuts`), documented in the keyboard shortcut and configuration docs. The old id
  `reopenClosedBrowserPanel` becomes an alias in `ActionCatalog` renames, so user bindings keep
  working. `tab reopen-last-closed`, `screen.reopenClosed`, `reopenClosedWorkspace` become presets of
  the same op with a level filter (they stay in the palette; their bindings keep working).
- Scope: the newest open group whose `window_id` is the key window. When the window has none: the
  newest group whose window is closed (a closed window, or a workspace from a closed window).
  It never takes a group from another LIVE window. (DECISION 1.)
- Repeated presses walk back: each restore removes the group, so the next press finds the next one.
  Cmd-Shift-T after a restore of a group never re-restores the same group (idempotency key per press).
- Restore is atomic: one daemon patch recreates every member of the group, then the app selects the
  first restored object (a tab: selected in its pane; a screen: selected; a workspace or space:
  shown in the window; a window: opened and made key).
- "Reopen Closed…" (palette page, existing `recentlyClosed` id): groups newest first, each row
  expandable to members. Enter restores the whole group; Right arrow expands; Enter on a member
  restores only that member (partial restore: the group stays with the rest, state
  `partially_restored`); Cmd-Backspace deletes permanently (confirmation). Filter by window
  (default) / all windows (Tab key). The History page (H3 lead) shows the same rows through
  `history.list --kind closed`; this lane does not build that page.
- Ops (catalog, so CLI and MCP are generated): `history.closed.list {scope: window|all, window?,
  level?, limit, cursor, expand?}`, `history.closed.restore {group? , members?, scope, window?,
  destination?: original|current-workspace|new-window}`, `history.closed.delete {group|members|all|since}`.
  CLI: `cmux history closed list|restore|delete`, plus the existing `tab reopen-last-closed`.

## 5. Bulk container actions (complete catalog)

### 5.1 One generic op

Every bulk action is `layout.bulk {verb, level, selector, anchor, destination?, include_pinned?}`:

- level: tab | pane | column | screen | workspace | space | window (and tab group, workspace group
  as containers of tabs/workspaces).
- selector: this | others | to_right | to_left | above | below | all | duplicates | idle | empty |
  unpinned | selection (multi-select) | matching (a query, CLI/MCP only).
- verb: close (archive) | move_to_new{split, column, screen, workspace, space, window} |
  move_to{existing target} | merge_into | duplicate | pin | unpin | sort{name, last_used,
  directory, kind} | hibernate | wake | group | ungroup.
- One op call = one atomic patch = one close group (for close/merge). The catalog lists curated
  presets of this op (below), each one an ActionDescriptor with its own id, title, when-clause and
  optional shortcut. The CLI also takes the generic form: `cmux tab close --to-right`,
  `cmux workspace close --others --in-space`.

Shared rules for every preset:

- Pinned objects are skipped by every bulk selector except `this` and `selection` (and `all` with
  `include_pinned: true`, CLI `--include-pinned`). The palette shows "(keeps 2 pinned)" in the row.
- Anchors: `to_right`/`to_left` are relative to the anchor object in its container's order;
  `others` keeps the anchor; the anchor is the context-menu target, else the focused object.
- A container is never left empty by a close: closing every tab of a pane closes the pane, every
  pane of a screen closes the screen, and so on up to the workspace; the last workspace of a window
  leaves the window with an empty workspace (it does not close the window unless the action is a
  window close). The closed containers join the same group, so the restore brings the layout back.
- `duplicates`: tabs with the same canonical URL (browser), the same page route, the same viewer
  path, or the same cwd with an idle shell (terminal). The newest-focused copy stays.
- `idle`: finished terminals, idle shells (no foreground child, reported by hooks), hibernated
  pages, agent sessions with no running turn, no background job and no monitor.
- `empty`: containers with no tabs (or only a new-tab page).

### 5.2 Confirmation rules

- Archive is reversible, so archive actions do NOT confirm. After any bulk close, a toast says
  "Closed 7 tabs. Reopen (Cmd-Shift-T)" with a Reopen button (non-modal, auto-dismiss through the
  injected Clock).
- Confirm (a sheet, keyboard default "Close") when the group would STOP live work that cannot come
  back: a running foreground command, a running agent turn, an unsaved document. The sheet lists the
  programs (from hook facts, never process scanning; the existing `runningPrograms` path of
  `closeWorkspace` is generalized). Setting `closing.confirmRunningWork`: always | bulkOnly | never
  (default always). Scripted runs (CLI/MCP/agents) must pass `--confirm` when running work would stop,
  else the op refuses and names the programs.
- Permanent deletes always confirm (`isDestructive: true`): Delete Permanently, Clear Recently Closed,
  `space.delete` (already), workspace group delete (already).
- Moves, sorts, merges, pins and duplicates never confirm; they are undone by the inverse action
  (and merges write a group so Cmd-Shift-T can split the merged objects back out, section 6).

### 5.3 The catalog (E = exists today, N = new; ids keep the existing naming)

Tab (in a pane strip; when `focus != textField` for keys):

| Action | Id | E/N | when-clause / availability |
|---|---|---|---|
| Close Tab | closeTab | E | a tab is targeted |
| Close Other Tabs | closeOtherTabsInPane | E | pane has > 1 unpinned tab |
| Close Tabs to the Right / Left | closeTabsToRight / closeTabsToLeft | E | an unpinned tab exists on that side |
| Close All Tabs in Pane | tab.closeAllInPane | N | pane has a tab |
| Close Duplicate Tabs | tab.closeDuplicates | N | pane (palette: workspace) has a duplicate |
| Close Idle Tabs | tab.closeIdle | N | an idle tab exists in the workspace |
| Close Other Tabs in Workspace | tab.closeOthersInWorkspace | N | workspace has > 1 tab |
| Move Tab to New Split / Column / Workspace / Window | tab.moveToNewSplit, tab.moveToNewColumn, palette.moveTabToNewWorkspace, tab.moveToNewWindow | E | |
| Move Tab to Workspace… / Space… | tab.moveToWorkspace (E), tab.moveToSpace (N) | E/N | |
| Move Tabs to the Right to New Window / Workspace | tab.moveToRightToNewWindow, tab.moveToRightToNewWorkspace | N | tabs exist to the right |
| Duplicate Tab | duplicateTab | E | |
| Pin / Unpin Tab | palette.toggleTabPin | E | |
| Sort Tabs (Name, Kind, Last Used) | tab.sortByName, tab.sortByKind, tab.sortByLastUsed | N | pane has > 1 tab |
| Hibernate / Wake Tab | hibernateTab / wakeTab | E | |
| Hibernate Other Tabs | tab.hibernateOthers | N | |
| Group / Ungroup / Close Group | tabGroup.create, tabGroup.ungroup, tabGroup.close | E | |

Pane and column (split / scrolling columns):

| Action | Id | E/N | when |
|---|---|---|---|
| Close Pane | closePane | E | |
| Close Other Panes | pane.closeOthers | N | screen has > 1 pane |
| Close Column / Other Columns / Columns to the Right / Left | column.close, column.closeOthers, column.closeToRight, column.closeToLeft | N | scrolling-column layout (`columnLayout`), condition on that side |
| Move Pane to New Workspace | pane.moveToNewWorkspace | E | |
| Move Pane to New Screen / Window | pane.moveToNewScreen, pane.moveToNewWindow | N | |
| Merge Pane into Left / Right Pane (tabs join the neighbor) | pane.mergeLeft, pane.mergeRight | N | a neighbor exists |
| Equalize, swap, resize, dock | (existing layout actions) | E | |

Screen (tabs of the screen bar in a workspace):

| Action | Id | E/N | when |
|---|---|---|---|
| Close Screen / Others / to Right / to Left | screen.close, screen.closeOthers, screen.closeToRight, screen.closeToLeft | E | |
| Close Empty / Idle Screens | screen.closeEmpty, screen.closeIdle | N | |
| Merge Screen into… | screen.mergeInto | N | > 1 screen |
| Merge All Screens | screen.mergeAll | N | > 1 screen |
| Duplicate, pin, move, move to new workspace/window | screen.duplicate, screen.togglePin, screen.move*, screen.moveToNewWorkspace, screen.moveToNewWindow | E | |
| Move Screen to Space… | screen.moveToSpace | N | |
| Reopen Closed Screen | screen.reopenClosed | E (becomes a level preset of history.reopenClosed) | |

Workspace (sidebar rows):

| Action | Id | E/N | when |
|---|---|---|---|
| Close Workspace | closeWorkspace | E | |
| Close Other Workspaces (in space) | palette.closeOtherWorkspaces | E (scope becomes the current space; today: all) | DECISION 3 |
| Close Workspaces Above / Below | palette.closeWorkspacesAbove / palette.closeWorkspacesBelow | E | |
| Close Other Workspaces in Group | workspace.closeOthersInGroup | E | |
| Close All Workspaces in Space | workspace.closeAllInSpace | N | |
| Close Idle / Empty / Duplicate Workspaces | workspace.closeIdle, workspace.closeEmpty, workspace.closeDuplicates | N | |
| Merge Into…, Duplicate, Duplicate Terminals Only, Duplicate to Space | workspace.mergeInto, workspace.duplicate, workspace.duplicateTerminalsOnly, workspace.duplicateToSpace | E | |
| Merge All Workspaces in Space into This One | workspace.mergeAllIntoThis | N | |
| Move to Space / New Window / Window / Group / Top / Bottom | workspace.moveToSpace, moveWorkspaceToNewWindow, moveWorkspaceToWindow, moveWorkspaceToGroup, palette.moveWorkspaceToTop, workspace.moveToBottom | E | |
| Move Workspaces Below to New Space / Window | workspace.moveBelowToNewSpace, workspace.moveBelowToNewWindow | N | |
| Sort by Name / Last Used / Directory | workspace.sortBy* | E | |
| Pin / Unpin | palette.toggleWorkspacePin | E | |
| Hibernate Other Workspaces | workspace.hibernateOthers | N | |
| Reopen Closed Workspace | reopenClosedWorkspace | E (level preset) | |

Space (Lawrence's examples "delete spaces to the right", "delete all other spaces"):

A space has two removal verbs, and the design keeps both distinct:
- Close Space (archive): the space and all its workspaces go into one group; Cmd-Shift-T brings the
  space back with every workspace in order.
- Delete Space (existing `space.delete`, destructive): removes the space container only; its
  workspaces move to another space (`moveTo`, default space by default). No workspace is closed.

| Action | Id | E/N | when |
|---|---|---|---|
| Close Space / Others / to the Right / to the Left | space.close, space.closeOthers, space.closeToRight, space.closeToLeft | N | non-default space for `this`; the default space is never closed (its workspaces are) |
| Close Empty Spaces | space.closeEmpty | N | an empty non-default space exists |
| Delete Space… (keep workspaces) | space.delete | E | |
| Delete Other Spaces / to the Right / to the Left (keep workspaces, move them to this space) | space.deleteOthers, space.deleteToRight, space.deleteToLeft | N, destructive (confirms; no workspace is lost) | |
| Merge Space into… / Merge All Spaces into This One | space.mergeInto, space.mergeAllIntoThis | N | > 1 space |
| Move Space to New Window | space.moveToNewWindow | N | |
| Duplicate Space | space.duplicate | N | |
| Sort Spaces by Name | space.sortByName | N | |
| Move left/right/to index, new, rename, color, icon, theme | space.move* etc. | E | |

Window:

| Action | Id | E/N | when |
|---|---|---|---|
| Close Window | closeWindow | E (becomes archive: one group with every workspace of the window) | |
| Close Other Windows | window.closeOthers | N | > 1 main window |
| Merge All Windows | window.mergeAll | N | > 1 main window |
| Move Window's Workspaces to Space… | window.moveToSpace | N | |
| Reopen Closed Window | window.reopenClosed | N (level preset; replaces app-only `reopenClosedWindow`) | |

Recently closed:

| Action | Id | E/N |
|---|---|---|
| Reopen Closed (Cmd-Shift-T) | history.reopenClosed (alias reopenClosedBrowserPanel) | N id, E shortcut |
| Reopen Closed… (list) | recentlyClosed | E (rebuilt on the daemon list) |
| Reopen Closed Tab / Screen / Workspace / Window (level filters) | reopenClosedBrowserPanel, screen.reopenClosed, reopenClosedWorkspace, window.reopenClosed | E/E/E/N |
| Clear Recently Closed… | history.closed.clear | N, destructive |

New when-clause context keys (KeyContext): `pane.tabCount`, `pane.unpinnedRight`, `pane.unpinnedLeft`,
`screen.count`, `space.count`, `space.isDefault`, `window.count`, `closed.inWindow` (bool: a group
exists for Cmd-Shift-T), `layout.kind` (`split|columns|canvas`). They are computed from the store
mirror (no polling), so menus disable items correctly and the palette hides unavailable rows.

### 5.4 Shortcuts (against the current KeyboardShortcutSettings, 86fd13ce03c)

This design adds NO new default shortcut. It keeps two existing ones:

| Shortcut | Action | Status |
|---|---|---|
| Cmd-Shift-T | history.reopenClosed (alias of reopenClosedBrowserPanel, TabActionCatalog) | exists; same key, wider behavior |
| Opt-Cmd-T | closeOtherTabsInPane | exists, unchanged |

Every new action in 5.3 has no default key. Each one is bindable in Settings and in `cmux.json`
like every catalog action. This design does not use Ctrl-1..9 (Lawrence 2026-10-04: Select Tab N
by default) or Ctrl-Opt-1..9 (Spaces). Note for R59: on this base, Ctrl-1..6 are still right-sidebar
switches (SidebarActionCatalog), Ctrl-Opt-1 is a tab select (TabActionCatalog:184), and a space
switch in ProfileActionCatalog:166 uses a Cmd/Ctrl digit. R59 owns that remap; this lane does not
touch it.

## 6. Cmd-Shift-T for each bulk action

| Closing action | One group with | Cmd-Shift-T restores |
|---|---|---|
| Close Tab | 1 tab | the tab at its index in its pane |
| Close tabs to right/left/others/all/duplicates/idle | n tabs (+ the pane/screen when it emptied) | every tab at its old index, original order; the emptied pane/screen comes back with its geometry |
| Close pane / column variants | panes or columns with their tabs | the panes/columns in the split/column positions |
| Close screen variants | screens with panes and tabs | screens at their positions in the screen bar |
| Close workspace variants | workspaces with screens | workspaces at their sidebar positions, in their group and space |
| Close space variants | space(s) + workspaces | the spaces at their positions, then their workspaces |
| Close window / other windows | window(s) + spaces/workspaces shown | new window(s) with the same frame (clamped to the visible screen), the same workspaces |
| Merge (pane, screen, workspace, space, window) | a "merge" group: the source container and the member list it brought in | the source container recreated, the moved members moved back out (they are not copies) |
| Move, sort, pin, duplicate | no group | not part of Cmd-Shift-T (they have inverse actions) |

## 7. Edge cases

1. Target container gone: restore to the nearest live ancestor in the record's path (pane -> its
   screen -> its workspace -> its space -> its window); when the whole path is gone, recreate the
   containers from the record (a workspace record recreates the workspace). A tab whose pane is gone
   but whose screen lives opens in that screen's focused pane at the recorded index.
2. Index out of range or the container changed (a newer layout exists): insert at min(index, count);
   relative order inside the group is kept. Restore never moves or closes objects that exist now.
   A split geometry that no longer fits is recomputed from the recorded ratios.
3. App not installed / disabled / older than the payload: placeholder tab (section 3.1).
4. Running processes: closing stops them after the scrollback, cwd and env are saved (ARCHIVE-1);
   the confirmation rules of 5.2 protect running work. Within the reap grace (30 s) a restore
   reattaches the still-live terminal.
5. Incognito / ephemeral workspaces and private browser profiles: never logged (no group, no member,
   no payload, no blob). A close that mixes private and normal objects logs only the normal ones.
6. Machine offline: a group from a machine that is offline lists as "on <machine>, offline" and
   restores when it reconnects; Cmd-Shift-T skips it and says so in the toast.
7. Multiple daemons in one window: Cmd-Shift-T takes the newest group across the window's daemons
   (by closed_at), as `DaemonClosedHistory` does today.
8. Two clients press at once (two windows, the phone): the restore op is idempotent per group and
   per press key; the second request gets "already restored" and the client does nothing.
9. Restore of an object whose id now exists (a moved tab came back by other means): skip that member,
   restore the rest, report it.
10. Remote (SSH/Cloud) terminals: restore uses the same machine; the terminal provider records the
    machine; an unreachable machine gives a placeholder with Retry.
11. Huge group (close 300 tabs): one group; the restore creates tabs without loading pages (pages
    restore hibernated, terminals as snapshots + lazy respawn on focus), so one press stays fast.
12. Daemon restart, app relaunch, crash: the log is in SQLite, written in the close commit;
    a cold blob that was not written degrades to respawn.
13. Retention evicted a blob: the member restores without scrollback and says so.
14. Cmd-Shift-T in a text field: the key goes to the action only when the when-clause allows
    (`!textInputFocus` except the address bar, where browsers also reopen tabs; follows R59 dispatcher).
15. Closed by an agent or CLI: same group; the toast shows only in the window that showed the object.
16. Window frame on a disconnected display: clamp to the current visible frame.
17. Secrets in a page route or URL (tokens in a query string): the provider strips query keys on the
    deny-list before it stores the payload.

## 8. Coordination

- R59 keybinding lead: this lane adds one action id and an alias; it does not touch KeyRouter,
  ChordTracker or menu key equivalents. New context keys (5.3) go through R59.
- React UIs lead (H3, History page): the page reads `history.list --kind closed` and the new
  `history.closed.*` ops; this lane gives the data and the ops only.
- Browser power-user lead (item 8): owns the engine-side back/forward restore. This lane proposes
  the `cmux.browser` payload v1: `{url, engine, profile, nav: [{url, title}], index, scroll: {x, y}}`.
- Archive/hibernation (R56): this design is the restore-record half of R56. Archive-on-close and
  hibernation eviction write the same groups (archive = close group with `state = closed`).
- Session host / terminal snapshot lane: reuse its snapshot format for the scrollback blob.
- App platform lead: the `restore` option on `cmux.pane/1` and `cmux.viewer/1` and the two host methods.

## 9. Build order (red test first in every slice)

- Deletion rule (coordinator): the slice that moves a kind into the daemon also DELETES the Swift
  history of that kind: ClosedTabTracker, ClosedScreenHistory, ClosedWorkspaceTracker and the
  app-only `reopenClosedWindow`, with a test that no Swift closed history remains.
- S1 (daemon, cmux-tui window, no Cargo.lock change), AS BUILT: `closed_groups` (INTEGER PRIMARY KEY
  append, index on window), one group per closing patch, members in restore order, window derived
  from the window record that lists the workspace, `closed.list {window, limit}` (default 100, max
  1000), `closed.reopen {closed?, window?, members?}` (newest of the window, else of a closed
  window; partial reopen; tab back at its index), retention forever, v1 migration, CLI flags.
  Deviations from section 2, on purpose: (a) members are a JSON array in the group row, not a
  `closed_members` table: a group is read and rewritten whole, and partial reopen rewrites one row;
  (b) no separate RAM index: the list is an indexed `ORDER BY seq DESC LIMIT n` read, and SQLite's
  page cache is the RAM index (a second copy would need rollback-safe sync with every commit);
  (c) op names stay `closed.list` / `closed.reopen` with new optional fields (no new ops, so no
  catalog count churn); the `history.closed.*` names are aliases for S1b only if the coordinator
  wants them.
- S1 v1 compatibility (landed fix): v1 `closed_history` is COPIED, never moved, and stays read-only
  for one release (drop it later in its own commit). A ledger keeps each copied row's v1 sequence.
  At each open, a copied row the older daemon removed counts as reopened only when a copied row
  with a LOWER sequence is still present (v1 evicts the lowest first); its group then goes. Every
  other removed row keeps its group. A v2 reopen or delete of a copied group also removes its v1
  row. Residual: when the older daemon reopens its lowest-sequence row, v1 data cannot tell that
  from an eviction, so the group stays and the item can be reopened once more.
- S1b (daemon): `closed.delete {closed | members | all | since}`, retention settings
  (`history.closed.maxGroups`, `maxAgeDays`), `surface.restore_state.put` and inline restore state
  on close ops (only for state the daemon cannot own, 3.0), privacy deny-list for env and URL query
  keys, private browser profiles never recorded, window close as a `window` group.
- S2 (daemon): `layout.bulk` op with every selector and verb, one group per call.
- S3 (daemon): terminal provider (scrollback blob, env deny-list, agent session resume offer).
- S4 (Swift): S4.0 repro of today's Cmd-Shift-T failure on cmux-lawrence-2; `history.reopenClosed`
  with the alias; Reopen Closed… page; catalog presets of 5.3 on one shared path; app-local kinds
  (agent, page, viewer, local browser) push restore state and restore through the provider registry;
  delete ClosedTabTracker, ClosedScreenHistory, ClosedWorkspaceTracker, app-only window reopen; toast.
- S5 (app platform): manifest `restore` option, validator rules, host methods, placeholder tab.
- S6 (browser payload) with the browser lead.

## 10. Decisions (all APPROVED as recommended, coordinator 2026-10-04)

1. DECISION: Cmd-Shift-T scope. RECOMMEND: the newest group of the key window, else the newest group
   from a closed window; never a group from another live window. Reason: it matches browsers and
   never steals objects from a window the user is not in.
2. DECISION: confirmation for running work. RECOMMEND: confirm when a close (single or bulk) would
   stop a running command, agent turn or unsaved document; never for idle shells or finished work.
   Reason: archive restores the layout but cannot restore a killed build or server.
3. DECISION: "Close Other Workspaces" scope. RECOMMEND: the current space (today it is every
   workspace). Reason: a space is the user's unit of context; closing other spaces' workspaces is
   `space.closeOthers`.
4. DECISION: retention defaults. RECOMMEND: groups forever (ARCHIVE-1), blob budget 2 GB, the
   Cmd-Shift-T walk unlimited. Reason: rows are small; blobs are the only real cost.
5. DECISION: restoring an agent session. RECOMMEND: show "Resume session" in the restored tab, do not
   start the agent automatically. Reason: a resumed turn can cost money and act on files.
