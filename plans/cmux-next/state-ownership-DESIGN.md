# Sidebar state ownership: who owns what, and why a group toggle lagged

Status: landed for group folds (Oct 20, 2026). Builds on OWNERSHIP-PRINCIPLES.md (binding) and
state-ownership.md; this file is the map for the sidebar and the rule for view state.

User (Oct 20): "opening and closing sidebar workspace groups still lags too much ... where does
state live? ... does a toggle send state to the daemon and wait for the whole thing to come back?
The algorithm must not scale linearly with the number of workspaces: users will have thousands."

## 1. Short answer

**Before this change: yes.** On the sidebar-document path (sidebar-v2, the default), a click on a
group header changed nothing on screen. The app sent `group.update {collapsed}` to cmux-tui and
waited for the echo. The echo then rebuilt the sidebar from scratch. Each step below ran once per
click:

1. The click reloaded the whole list (`SidebarListView.reload`, every row).
2. `sidebar.apply` bumped the store version. The app asked the Rust mirror for every row
   (`view`: O(sections + items + live)), built the projection again, and compared it with the
   old one: O(N) three times, for nothing (the mirror ignores collapse).
3. The daemon wrote the fold, then mirrored it into `personal_groups`, which emits
   `personal-changed`. The app mapped that to `tree-changed`, so **every fold refetched the whole
   tree snapshot** (`list-workspaces` + `list-personal`: every workspace, screen, pane and tab).
4. The echo applied: version bump, then the same O(N) rebuild, then a new section list for the
   window, compared row by row with the old one (`sections` setter), then a full list layout
   (`SidebarLayout.make`, every row) and a full apply (six passes over every row, each hashing
   every key).

So a fold cost one round trip, one full tree snapshot and about ten O(N) passes on the main
thread. At 10,000 workspaces that is tens of milliseconds per click, and fast clicks queued
behind each other.

**Now: no.** The window shows the fold at once, on that group's rows only. It tells the owner
the new value in one small op and never waits. The echo carries one row and rebuilds nothing.

## 2. State map

```
                 ┌──────────────────────── cmux-tui daemon (home session) ────────────────────────┐
                 │  sidebar document (SQLite: sidebar_items, sidebar_sections, revision)          │
  owner of  ───► │    order, sections, groups, membership, pins, links; group.collapsed (record)  │
  record         │  personal store (SQLite: personal_groups, …)  legacy mirror for TUI / iOS     │
                 │  session/workspace tree (SQLite + memory)     workspaces, screens, panes, tabs  │
                 └──────▲───────────────────────────┬─────────────────────────────────────────────┘
          small ops     │ sidebar.apply {ops, key}   │ session.events: one row per change
          (idempotent)  │ (no echo of the list)      │ (state_upsert sidebar_item, revision)
                 ┌──────┴───────────────────────────▼─────────────────────────────────────────────┐
                 │ Swift app (one process)                                                        │
  caches ──────► │  SidebarDocStore: records (confirmed doc) + SidebarMirror (Rust: confirmed +   │
                 │    pending intents) → projection (order/membership)   groupFolds (confirmed)   │
                 │  DaemonStore: tree mirror, PersonalStore (list-personal)                       │
                 │  SidebarBridge / SidebarRows (per window): live sections + held edits/folds    │
  view  ───────► │  SidebarModel (per window): sections as drawn; collapsed groups, selection,    │
  state          │    filter, hover, collapsed layout sections (UserDefaults)                     │
                 │  SidebarListView: SidebarLayout (rows + frames), realized row views only       │
                 └────────────────────────────────────────────────────────────────────────────────┘
```

| State | Source of truth | Caches | Flow | Persists |
| --- | --- | --- | --- | --- |
| Workspaces, screens, panes, tabs | daemon tree | `DaemonStore` records | daemon → app (deltas; snapshot on gaps) | daemon SQLite |
| Sidebar order, sections, group membership, pins, links | sidebar document | `records`, Rust mirror, projection, window sections, `SidebarLayout` | app op → daemon → echo (one row) → app | daemon SQLite |
| **Group fold (collapsed)** | **the window shows it; the document records it** | `groupFolds`, window sections, layout | window applies at once → op to daemon → other clients follow; echo rebuilds nothing | daemon SQLite (document), mirrored to `personal_groups` |
| Layout-section fold (Chats, app sections) | window | `collapsedLayoutSections` | app only | UserDefaults |
| Machine-section fold | window | `collapsedSections` | app only | window's sidebar snapshot |
| Selection, hover, drag, filter text, scroll | window | — | app only | no (selection: window record) |
| Row content (title, status, unread, progress) | daemon (terminal facts, agent state) | row feed, model rows | daemon → app, one row patched in place (`patchRows`) | daemon |

Five lines:

1. The daemon owns what other clients must agree on: the tree, and the sidebar document (order, membership, pins).
2. The Swift app holds caches of those (`DaemonStore`, `SidebarDocStore` with its Rust mirror). It never writes them back; it sends ops.
3. Each window owns its view state (fold, selection, hover, filter, scroll). It applies a change at once and never waits for the daemon.
4. A group fold is per-user view state with a durable record: the window shows it first, then the document stores it so the TUI, iOS and other windows follow.
5. Updates move one row: ops carry one value, echoes carry the changed rows, and the list splices them. No step lists every workspace.

## 3. The model (what the code does now)

**Rule: the UI owns view state and applies it locally, at once. The owner gets a small delta and
never echoes the whole list. Updates cost O(changed rows); lists are virtualized; revisions
reconcile.**

A fold, end to end:

1. Click or key on a header (`SidebarListView+Mouse`, `SidebarGroupKeys`), the palette, the CLI or MCP.
   They all go through one path: `SidebarBridge.handle(.toggleCollapse(.group))`.
2. `SidebarRows.foldShown` holds the fold for the window and calls `SidebarModel.setGroupCollapsed`.
   That writes the one group in place: no structural set, no row-by-row compare, no observation of
   `sections`. `structureRevision` stays, so the sidebar does not lay the list out.
3. `SidebarListView.foldGroup` builds a new layout with `SidebarLayout.folding`. That splices only
   the group's member rows (the same rows `make` would build; `SidebarLayoutFoldTests` checks this
   row by row). The rows after the group move by the height change.
   `SidebarLayoutKeyIndex` takes the splice without hashing every key again. The rows below move
   by one strided vector add over their `y` field (microseconds at 10,000 rows); that is the one
   step left that touches every later row, and it copies none.
   Only realized views (the viewport plus overscan) move, open or close. Group lines below the
   group move by the same height.
4. `SidebarDocStore.setGroupCollapsed` sends `group.update {collapsed: value}`: the value, not a
   toggle, so each fast click sends what it shows. The store does not rebuild after it.
5. The echo batch holds one `sidebar_item` row. `SidebarDocRecords.apply(batch:)` finds that the
   batch only folds groups. The store updates `records` and `groupFolds` and moves
   `foldRevision`; `version` does not move, so no projection is rebuilt. Other windows (and folds
   from the TUI or iOS) apply `lastFolds` to their own rows with the same fast path.
6. The daemon's mirror write into `personal_groups` still emits `personal-changed`. The app now
   refetches `list-personal` alone (`DaemonStore.refetchPersonal`), never the tree. The applied
   sequence waits below that event until the fetch lands, so read-your-writes waiters stay
   correct (`PersonalRefetch`).
7. Refused or never answered: the hold drops and the live rows show the document's fold again
   (one redraw).

Nested groups (a283, remote groups slice 1) live only in the sidebar document (`Item.parent`, up
to 3 levels); the list draws a nested tree as its top group, so a fold is still one header and
its member rows. A nested group's fold is the same `group.update` on its own item. Only the
user's own fold moves on the spring; another client's fold shows in one step
(sidebar-calm-movement.md).

Reconciliation is by revision. The document revision chain is judged by the Rust mirror (a skipped
revision refetches the document). The tree uses event sequences and snapshot barriers. A window's
hold of a fold ends when its own echo (or the live rows) shows the same value. An earlier click's
echo with the old value does not undo a newer click.

## 4. Measurements

Mac-mini fleet, `SidebarGroupToggleScalingTests` (a real chevron click on a 10-member group near
the top; workspaces in 100 groups, all open; median and p90 of 16 toggles; main thread):

| Workspaces | Before median / p90 (ms) | After median / p90 (ms) | List reloads per toggle (before → after) |
| --- | --- | --- | --- |
| 10 | 0.79 / 0.80 | 0.36 / 0.39 | 2 → 0 |
| 100 | 7.5 / 7.6 | 1.08 / 1.25 | 2 → 0 |
| 1,000 | 39.1 / 39.9 | 0.97 / 0.99 | 2 → 0 |
| 10,000 | 365.7 / 377.2 | 1.11 / 1.19 | 2 → 0 |

Same host (aws-m4pro-6), Debug test build. Before: test commit `df23b124756` alone (guard ratio
46.8x, fails). After: the fix (guard ratio 1.29x, passes). Of the 1.1 ms after, about 1.0 ms is
the list moving and configuring its ~44 realized row views; the model write is under 0.001 ms and
the render check about 0.01 ms. These numbers cover the click on the main thread only: the daemon
round trip is no longer on the click path, and before the fix it added a full tree snapshot on top.

Guard: the median at 10,000 workspaces may cost at most 1.5x the one at 100, the p90 must fit in
one 8 ms frame, and a toggle may lay the list out at most once.

## 5. What still costs O(N) (not on the click)

- The personal path (`usesPersonalOrganization` without the sidebar document) still maps the
  window's sections again after `list-personal` lands. It runs after the click frame, not in it.
- A later structural change (a new workspace, a move) still rebuilds the projection and the
  window's sections once. That is a structural change, not a fold. Its cost is a168's area
  (`patchRows`, tab switching).
- The daemon still writes the fold into `personal_groups` for old clients and scans to the next
  loose workspace (`write_back`). That is SQL in the daemon, off the app's main thread. Drop it
  when the TUI and iOS read the document.
- Rust `view` still builds folded groups' child rows and throws them away. Swift never asks it to
  fold (`collapsed: []`). That is harmless now, because a fold no longer calls `view`.

## 6. Other UI state that must follow the same rule

Apply locally at once, send a small op or keep it local, never wait for a full echo:

- Machine-section and layout-section folds (already local; keep them so).
- Workspace inline-tab disclosure (`collapsedWorkspaces`): today it goes through the full
  layout. Give it the same splice.
- Selection and focus (already patched in place: `patchSelection`).
- Pin and unpin, and Move to Top: they move rows, so they stay structural. But the echo should
  splice the moved rows instead of rebuilding the projection.
- Tab-strip group folds (`tabGroup.toggleCollapsed`) and Home chat (a293's
  home-chat-pipeline-DESIGN.md uses the same rule: one ordered log, optimistic ids, deltas only).
- Density and appearance changes (a289) are view state: they lay the list out once, locally.

## 7. Open questions

- Should a fold be per window instead of per user? Today it is per user (the document holds it),
  so a second window folds too. Reply "fold per window" to change it.
