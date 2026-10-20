# Pane always has a visible active tab

User report (2026-10-20): "There are still cases where I don't see the active tab
in a pane." Goal: make "a pane with tabs but no selected, shown active tab" an
invalid state the data structures and protocol cannot carry, not a list of
patched cases.

## Invariants

- **I1** A pane holds at least one tab. An empty pane is not a pane: it is removed
  in the same mutation that removes its last tab.
- **I2** A pane's active tab is one of its own tabs (never nil while it has tabs,
  never a tab of another pane, never an out-of-range index).
- **I3** A tab is in exactly one pane, and every index (`tab_pane`) agrees.
- **I4** Every pane is in a screen, and a screen's active pane is one of its panes.
- **I5** The active tab is shown: when any tab of the pane is shown, the active tab
  is not a member of a collapsed group. One exception: the user just picked a
  member of a collapsed group, and the pane expands that group.
- **I6** One rule picks the successor when the active tab leaves or is hidden: the
  next shown tab, else the previous one (opener family first for link tabs,
  `FocusAfterClose.tab`; `TabGroupOrdering.selectionAfterCollapsing` for a collapse).

## Audit: where the active tab lives (feat-cmux-next ec83df89ccf)

Three copies of "which tab is active":

1. **Daemon runtime** `cmux-tui-core::model::Pane { tabs: Vec<SurfaceId>, active_tab: usize }`.
   Both fields are `pub`. About 35 sites write `active_tab` directly and about 40
   write `tabs` directly (tree_edit, tab_drag, resource_content, browser_create,
   browser_tab_create, terminal_create, terminal_move, restore, tab_groups/blocks,
   layout_document, the resource_topology moves). Each site hand-adjusts the index
   (`-= 1`, `+= 1`, `= len - 1`, `position(..).unwrap_or(old)`). An index goes
   stale on any reorder that forgets to adjust it.
2. **Daemon durable** resource topology pane `active_tab: Option<TabPublicId>`. This
   is a second representation with a different type. Restore converts it with
   `position()` and **fails the whole restore** if the id is unknown
   (`restore.rs:152`). It accepts `None` only for an empty pane, so an empty pane
   (I1) can be restored.
3. **App** `TabSelectionMemory` (per window, per pane), "client-local". The daemon
   value is only a default.

Protocol: `LivePane { tabs, active_tab }` (snapshot) sends both together. The v1
delta stream (`tab-added`, `tab-changed`, `tab-closed`) sends membership **without**
the active tab; a separate `TreeSelectionChanged` resync follows
(`resource_tab_deltas.rs`). The app's `PaneModel` holds `tabs` and
`defaultTabIndex` and applies the deltas one at a time.

### Failure modes found

| # | Where | How the pane shows no active tab | Status |
|---|---|---|---|
| F1 | app `TabSelectionMemory.resolve` | A group is collapsed from outside this strip (CLI `cmux tab group <g> update --collapse`, MCP `tab_group_update`, another window, a restore with a collapsed group) while one of its members is selected. `resolve` kept the selection because the tab still existed. The strip hides every member, so no tab is highlighted, and the content still shows the hidden tab. **Repro:** `TabSelectionInvariantTests.groupCollapsedElsewhereMovesSelectionToAShownTab` (red on the base). | fixed |
| F2 | app strip reducer vs daemon | You select a member of a daemon-collapsed group (palette, tab search, Cmd-digit, a reveal, a notification). The strip reducer expands the group **only in its local model**, and the next daemon snapshot (`stripModel.groups = snapshot.groups`) collapses it again, so the selected tab is hidden. Nothing told the daemon to expand. | fixed: the pane asks the daemon to expand, once per tab and group |
| F3 | app `PaneController.structure` | The daemon default went in as `defaultIndex`, an index into the daemon's full tab list. `resolve` applied it to the strip's list, which leaves out dock-bound tabs, appends local tabs and is reordered by `NewTabSuccession`, so the default named the wrong tab or a hidden one. | fixed: the default is passed by tab id |
| F4 | app, 15 writers of `selection.select` | Some write the window's memory without telling the mounted pane (`GlobalSearchHandlers.show`, `CloudMove`, `CloudBringBack`, `AgentTabImport`, `AgentSessionWorkspace`). Others call `services.paneController(for:)`, which returns the **first** window's controller, not the one whose memory they wrote (`SidebarBridge.reveal` with an owner window). The memory names tab X, while the strip and content keep showing Y until the next unrelated apply. | open (slice S3) |
| F5 | app diagnostics | `PaneSurfaceStatus.isBlank` returned false when `selectedTab == nil`, so the invariant monitor and `debug.surfaces` never reported a pane with tabs but no selection. | fixed: `selection_missing` (I2/I5) is logged and counted |
| F6 | daemon close rule | After a close the daemon picks the **previous** tab (`tree_edit.rs:493`), but the app picks the **next** one (`FocusAfterClose`). A second window, a restart, the TUI or any client without memory shows a different tab than the window that closed it. | open (slice S2) |
| F7 | app collapse handlers | The strip's own collapse picked "first tab outside the group" (leftmost), while the group reducer picks the nearest one on the right, else on the left. Two rules can make the selection flicker. | fixed: one rule (`TabGroupOrdering.selectionBeforeCollapsing`) |
| F8 | daemon restore | An unknown durable `active_tab` fails the whole restore instead of healing to the first tab. A pane with no tabs restores (I1). | open (slice S2) |
| F9 | daemon runtime | ~35 hand-adjusted index writes; any missed adjustment leaves `active_tab` out of range, and `Pane::active_surface()` returns `None`. | guarded by the property test; refactor in S2 |

The daemon property test (`pane_active_tab_fuzz.rs`) runs random new, close, move,
split, drag-to-split, move-with-undo, select and tab-group (create, collapse,
expand, close) sequences, plus a persistent restart. After every step it checks I1-I4.

## Chosen structure

**Daemon (the only writer of membership and the shared default):**

```rust
/// Non-empty by construction; `active` is always a valid position.
pub struct PaneTabs { tabs: Vec<SurfaceId>, active: usize } // fields private
impl PaneTabs {
    pub fn new(first: SurfaceId) -> Self;               // I1: no empty constructor
    pub fn active(&self) -> SurfaceId;                  // total, not Option
    pub fn insert(&mut self, at: usize, tab: SurfaceId, activate: bool);
    pub fn remove(&mut self, tab: SurfaceId) -> Removal; // Removal::Emptied => caller drops the pane
    pub fn reorder(&mut self, tab: SurfaceId, to: usize); // active follows its tab id
    pub fn activate(&mut self, tab: SurfaceId) -> bool;
}
```

- An index is stored, but only `PaneTabs` writes it. Every mutation goes through one
  of five methods, and each method re-validates the index (one reducer), so the
  ~35 hand adjustments become calls. `remove` returns `Emptied`, so the caller
  must remove the pane in the same step (I1). An empty pane has no value of this type.
- The successor after `remove` is I6 (next, else previous), the same rule the app uses.
- Durable and wire forms carry the active tab **by id**, together with the list:
  `{ tabs: [TabId], active: TabId }`. A decoder that sees an unknown or missing
  active id heals to the first tab and logs (release). It never fails the restore.
- The protocol sends a pane's membership and its default in one record. The v1 tab
  deltas already make clients resync on anything they cannot express. The next
  step adds the pane's active tab id to `tab-added`/`tab-changed`/`tab-closed`, so
  a delta client never applies membership without the default.

**App:**

- The daemon list is the only tab list. `TabSelectionMemory` is the one place
  that decides a pane's shown tab per window. `resolve` is total (I2, I5, I6).
  The memory is a per-window **choice** among the daemon's tabs, so the app never
  holds its own copy of membership.
- One selection path (S3): `WindowState.select(tab, in: pane)` writes the memory
  of **that** window and applies it to that window's mounted pane, if any.
  The 15 writers call only that. `PaneController` re-resolves on a selection
  change of its own pane (keyed `ObservedMap` read, one pane only), so a bare
  write cannot leave the strip and content behind.
- Invariant check: `PaneSurfaceStatus.isSelectionMissing` (debug log and counter
  after each settle, `debug.surfaces` in any build). The self-heal is `resolve`
  itself: the next apply fixes any state it finds.

Why not "the app has no selection at all, only the daemon's": windows need
independent selection (two windows on one workspace, Chrome's model). The daemon
value stays the shared default for a fresh window, the TUI and the CLI, and a
per-window choice that `resolve` always validates against the daemon's list
cannot name a tab the pane does not have.

## Slices

- **S1 (landed in this task)** Property and repro tests (daemon fuzz, app
  `TabSelectionInvariantTests`). Total `resolve` (F1, F2, F3), one collapse rule
  (F7), the `selection_missing` invariant (F5).
- **S2** `PaneTabs` in cmux-tui-core: private fields, five methods, one successor
  rule (F6, F9). Restore heals unknown or missing active ids (F8). Durable and wire
  active by id; the active tab id on tab deltas.
- **S3** One app selection path (F4) and a `PaneController` that observes its own
  selection key.

Coordination: a168 (tab switch: S3 touches `applySelection`, so measure
`switch.select`), a338 (create/close perf: `PaneTabs.remove` is O(n) like
today), a343 (persistent IDs: durable active by tab id), a315 (Cmd-T self-close),
a295 (Recently Closed: reopen goes through `PaneTabs.insert(activate: true)`),
a281 (new-tab position: `insert(at:)` is the only placement path).
