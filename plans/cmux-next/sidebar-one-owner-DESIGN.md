# Sidebar: one owner, one coordinate space, one pending log

Status: design (Oct 20, 2026). Builds on OWNERSHIP-PRINCIPLES.md (binding) and
state-ownership-DESIGN.md (the map of today). Slice 1 (Cmd-N) landed with this file.

User (Oct 20): "I think there are a lot of bugs in general with our sidebar and cmux-next. I think
a lot of it has to do with state ownership with cmux-next and communication ownership. Can we
think from first principles about how we can rewrite the sidebar and integration with cmux-next
such that there are no bugs at all?" Reported with it: Cmd-N must put the new workspace at the
very top, and a group cannot be dragged to the first position.

## 1. Why the sidebar keeps having bugs

The bugs are not separate mistakes. They come from three structural facts.

1. **The same fact has two to four durable owners.** Workspace order, group membership and pins
   live in the sidebar document (`sidebar-doc-v1`), in the personal tables
   (`personal_workspaces.position`, `personal_groups`), in each daemon's flat tree order
   (`move-workspace`) and, for pins, in `workspace_presentation.pinned`. The app picks one at
   run time (`SidebarDocWiring.isActive`, `usesPersonalOrganization`, `usesMixedOrder`,
   `pinsAreTiles`) at nearly every call site. The daemon copies between them in both directions
   (`sidebar_doc_sync.rs`, whose own header says "approximate where the old model has no place").
   Every copy is a place where two owners can disagree.
2. **About seven optimistic layers, each with its own settle rule.** The `DaemonStore` intent
   log, the `SidebarMirror` intents, `SidebarLayoutService.pending`, `SidebarRows.pending` and
   `folds`, `PendingWorkspaceRows`, `ClosingWorkspaces`, `SidebarOrganizationQueue`, and about ten
   direct `model.apply` calls in `SidebarBridge+Intents.swift` ("the next store change restores
   truth"). They settle on a reply, on `whenApplied`, on "the live rows show it", on the next full
   load or on a timer (`SidebarSelectionHold`, 250 ms). Between two settles the layers disagree,
   and the screen shows the disagreement: a row that jumps, flies back, or lands twice.
3. **More than one coordinate space for order.** A gesture is a view row index; the bridge turns
   it into a section-relative index, `SidebarDaemonReorder` into a daemon-global index, and the
   personal path into a `position`. Each translation has to know the bands (Pinned, then each
   machine section, groups interleaved with loose rows) and the hidden rows (Home, stand-ins,
   collapsed members). A translation that forgets one of them puts the item in the wrong place,
   or refuses a move that is legal (the Move Up bug in sidebar-ordering-AUDIT.md was this kind).

A multi-step write makes it worse: Cmd-N creates the workspace (the daemon appends it), then a
second write moves it (`applyPendingPlacements`). Between the two, three layers show three places.

## 2. Rules for the new sidebar

1. **One durable owner: the sidebar document on the home daemon.** Order, sections, groups,
   membership, pins (workspace and group), group fold and links are fields of the document and
   nowhere else. `personal_*` and `workspace_presentation.pinned` become read-only projections
   written one way (document to legacy) for the TUI and iOS until they read the document; nothing
   writes them back into the document. A daemon without the document is shown read-only for
   organization (order, groups, pins) with its flat order; it is not a second owner.
2. **One coordinate space: ids and anchors.** Every order op names the moved ids and an anchor:
   `{parent: section | group, before: item id | null}`. Indices exist only inside the view. The
   reducer turns an anchor into a position, so band rules (Pinned first, a pinned item stays in
   Pinned, Home first in its section) are checked in one place.
3. **One pending log per client, and the preview uses the reducer.** The client keeps the
   confirmed document (`SidebarDocStore.records`) and one ordered log of pending ops. What the
   sidebar draws is `reduce(confirmed, pending)`, with the same Rust reducer the daemon runs
   (already linked through `SidebarMirror`). So a preview and its commit cannot differ, and a
   reject animates back by removing one log entry. `SidebarRows.pending`, `PendingWorkspaceRows`,
   `ClosingWorkspaces`, `SidebarOrganizationQueue`, `SidebarLayoutService.pending` and every
   direct `model.apply` of an organization change are deleted, not migrated.
4. **One op per user action.** Create-and-place is one op (`workspace.create {id, anchor}`): the
   daemon creates the workspace and writes its document item in one transaction, so no layer
   ever shows the daemon's append. Close, move-to-group, pin and fold are each one op. A gesture
   (drag) stays local until the drop, which becomes one op.
5. **Settle by transaction, never by value.** An op leaves the log on `request-settled
   {transaction}` (applied or rejected), never because a value "looks like" its echo, never on a
   timer, never through NotificationCenter. Offline: the log refuses, nothing queues.
6. **View state is per window and only the window writes it.** Selection, focus, scroll, hover,
   filter and collapsed sections are `WindowState`. The model never picks a selection
   (`dropClosed` goes); after a close, the window picks the next workspace with one function.
   Group fold stays a document field (shared by windows and devices) until Lawrence decides
   otherwise.

## 3. What this removes

| Today | After |
| --- | --- |
| Order in doc, personal, flat tree, presentation | Order in doc only |
| Pins in doc, layout tiles, presentation flag (read from 3 places, written 4 ways) | Pins in doc only |
| Drop resolver translates row index to section index to daemon index | Drop resolver emits `{ids, parent, before}` |
| Cmd-N: create (append) then move | `workspace.create {id, anchor}` |
| 7 optimistic layers, 5 settle rules | 1 log, settled by transaction id |
| Selection written by window, hold, model, `dropClosed` | Selection written by the window |

## 4. Verification

- The Rust reducer already has proptest coverage. Add the band rules as invariants: Pinned is
  first; every item is in exactly one container; an anchor op never moves an item it does not
  name; a legal target position for an item is reachable by one op (this catches "cannot drag a
  group to first").
- A behavior test through the socket: for every row and every drop target in a fixture sidebar,
  the drop's op applied by the daemon gives the order the preview drew.
- Invariant 4 (projection convergence) is checked in debug builds after each settle.

## 5. Slices

Each slice lands alone, with its own review subagent and gates.

1. Cmd-N `top` is the very top of the machine section, out of the current group (landed with
   this file).
2. A group can be dragged to the first position (see section 6).
3. `workspace.create {id, anchor}`: create and place in one op. Delete `PendingWorkspaceRows`
   placement and `applyPendingPlacements` for the document path.
4. Drop resolver emits id anchors; delete `SidebarDaemonReorder` index translation for the
   document path.
5. Route every organization edit through the mirror log; delete `SidebarRows.pending`/`folds`,
   `SidebarOrganizationQueue` and the direct `model.apply` calls.
6. Pins: document only; stop the flag mirror write; keep a one-time read migration.
7. Selection: window only; delete `SidebarSelectionHold` and `dropClosed` selection.
8. Retire the personal and flat-order write paths for organization (needs the TUI and iOS to read
   the document first; until then the daemon writes `personal_*` one way).

## 6. Group drag to first

A dragged group moves by blocks (`SidebarGroupReorder`, u2455): the list without the group is cut
into top-level blocks, its edges pick a gap index, and `probeY(for:)` turns the index back into a
point that the drag geometry resolves to a document target. For every index above 0 the probe was
"just above the end of the block before the gap", so every gap meant "after the previous block".
On the document path the list draws other sections above the machine rows (the top band as a
`.block` row, Pinned, or Pinned's empty drop zone during a drag), and one list draws no machine
header. So the gap above the first machine row probed the end of Pinned or the band: the drop
pinned the group, or was refused and kept the last gap (second place). The first slot was not
reachable. The reducer was right; the bug was a coordinate translation (section 1, cause 3).

Fix: a block records what it starts with. A gap above a group, loose workspace or item probes
just inside that block's top (a drop before it, in its own section); a gap above an empty
section's drop zone probes the zone (a drop into that section); a gap above a header or band
keeps the old probe. This also stops a gap after an expanded group from probing that group's last
member, which nests the dragged group when the reducer allows nesting. Known limit: one gap index
sits between the last Pinned item and the first machine row, and it now means "first in the
machine section"; to put a group last in Pinned, drop it before a Pinned item or use Pin.
Slice 4 removes this class: the drop resolver emits id anchors and the reducer's acceptance
table decides, with no index in between.
