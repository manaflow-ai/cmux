# Sidebar ordering: one model (Lawrence, 2026-10-20)

Ask: "Move to Top … is still behind the groups. Or maybe it's because some groups are pinned, but
then I also need to have the concept of pinned groups. … right now I need to right-click and then
go do more group actions … bring them into this normal UI."

## Root cause

1. **The groups above the moved workspace were pinned groups.** On the sidebar document
   (`sidebar-doc-v1`, the live path), Pin Group moves the group into the Pinned band
   (`SidebarDocStore+Intents`, `.setGroupPinned`). The band lists above every machine section, so
   Move to Top (slot 0 of the machine section) correctly lands under it.
2. **Nothing showed that those groups were pinned, and they could not be unpinned.**
   `SidebarDocSections.model` mapped every document group with `pinned: false`. So the header drew
   no pin, and `workspaceGroup.togglePin` (`!group.pinned`) always sent Pin. A group that had been
   pinned once stayed in the band.
3. The older cause (Move to Top landing right above the first group when the client had no
   document item for the loose rows) was fixed in 4beb5aa624e. The running nightly (fc1d07a)
   has that fix.

## The model

The sidebar is a list of bands, top to bottom:

1. **Pinned**: pinned workspaces (tiles) and pinned groups, in the order the person put them.
2. **Each machine section**: loose workspaces and unpinned groups, freely interleaved. A loose
   workspace may sit above a group.

The rules:

- **Pinned first.** A pinned group or workspace is in the Pinned band. Pin moves it there (last in the band); Unpin
  moves it back to the end of its machine section (the reducer's `unpin`). "Pinned groups sort first" is a fact of where
  the group lives, not a sort key, so the optimistic and authoritative orders cannot disagree.
- **Move to Top** puts the object first in its own container. A loose workspace goes first in its
  machine section, above every unpinned group. A grouped workspace goes first in its group. A
  group goes first in its band. Move to Top never crosses the pinned boundary: that is what Pin does.
- A pinned group's header shows its pin glyph, and its menu reads **Unpin Group**.

Not changed: on daemons without the sidebar document (the personal-order fallback), `pinned`
still means "saved group, kept when its workspaces close" and does not change the order.

## The group header menu

A right-click on a group header opens the group's one flat menu at once, as Finder and Safari
do. It no longer opens the editor bubble. A click on the name or on ··· still opens the editor
(name, color, common rows). The editor has no "More Group Actions…" row.

Top-level rows (at most 12, the menu rule of 2026-10-01): New Workspace in Group · Rename…,
Color ▸, Pin/Unpin Group, Options ▸ (Set Icon, Remove Icon, read state, Collapse All, Expand All,
Collapse Others, Edit Group Config, Duplicate, Copy Group ID) · Collapse/Expand Group · Move to Top, Move ▸ (Up,
Down, Bottom, Window, New Window, Space, Section, Sort by Name/Last Used/Directory) · Ungroup,
Close Group, Delete Group, Close Other Groups.

Every row is also a Cmd-Shift-P command (`WorkspaceGroupFlatMenuTests`).

## A new workspace is first, in one change (Lawrence, 2026-10-20)

Ask: "Command-N to make a new workspace does not make it the top … Always make it at the top with
a single state change, a single render, and have zero jank at all."

### Root cause

The daemon was already right: `create-workspace` is one commit that writes the workspace, its
personal row and its sidebar document item at the `workspaces.newPlacement` slot (default `top`:
first in the machine section, below Home, above groups). The app broke it in two places.

1. **The new row listed at the bottom for a moment.** The app hears of a create twice:
   `workspace-added` on the event stream, then the document item (with the personal row) on
   `session.events`. Between the two, the workspace is live but the document does not place it, and
   `SidebarDocSections.sections` listed such a row after every placed row. Cmd-N's press-time row
   (`PendingWorkspaceRows`) gave way to the live row at the bottom, and the item's arrival moved it
   to the top: a jump down, then a jump up. 176f443172b only ordered those rows among themselves.
   The list did it a second time on its own: when the machine section holds link items,
   `SidebarDocProjection.machineNodes` re-walks the document order and put every node the
   document does not place after the placed ones (the fleet frame strip showed `new1` drawn on
   top, then last, then on top again, with no document item and no personal row yet). And the
   personal-order fallback (`PersonalSidebar.mixedSections`, `personalOrder`, used for every row
   the document does not place) listed a workspace without a personal row last; the new row's
   personal row comes in the same `session.events` batch as its item, so it too was last until then.
2. **The app wrote the order a second time.** Once the daemon reported the workspace,
   `applyPendingPlacements` resolved `workspaces.newPlacement` again and sent its own
   `sidebar.apply` (adopt + move) to the slot the create had already given it: a second state
   change, a second batch, a second render, and a reorder raced against the item's arrival.

Unread rows were not part of it: rows reorder by attention only with
`notifications.attention.moveToTop` (off by default), and a notification moves only its own
workspace.

### The rule

- **The daemon is the only writer of order.** A create places the workspace in the commit that
  makes it. This Mac's daemon applies `workspaces.newPlacement` itself, so the app sends no move
  for that slot (`NewWorkspaceDefaultSlot.move` is nil when the slot is the daemon's own top or
  bottom). The app moves a new workspace only to a slot the daemon cannot know: inside the current
  workspace's group, after the window's current workspace, an explicit slot (New Workspace
  Above/Below), or a workspace of another machine (its create writes no row in this Mac's order).
- **A live workspace the document does not place yet lists where the daemon puts it.** Under
  `top` that is first in the machine section, below a leading Home row, above every group, newest
  first; under `bottom`, last. This is the same rule as the daemon's `workspace.list`
  (`state/sidebar_doc_order.rs`), so the item's arrival changes nothing on screen. The list's
  document arrangement keeps such a node at its mapped slot (right before the placed row after it).
  On this Mac's daemon a workspace without a personal row yet is a create whose row is on the way
  (the daemon writes one in every create): the personal order lists it first below Home too.
- **One row from the press.** The press-time row, the live row and the placed row are the same
  row at the same index: the frame sequence for a Cmd-N is the old list, then the list with the new
  row at index 0, and nothing after.

### Tests

- cmux-tui `state/new_workspace_top_tests.rs`: a create is one commit whose batch carries the new
  workspace's sidebar item, and the document lists it first below Home.
- `SidebarDocNewWorkspaceTopTests`: a live workspace without an item lists first below Home, above
  groups and an unread row; rapid creates list newest first.
- `RapidWorkspaceCreateTests.fiveQuickCmdNDrawEachNewRowFirstInEveryFrameAboveUnreadRows` (live
  daemon, the real window): every frame the sidebar list draws during five quick Cmd-N has the new
  rows first, newest first, the old rows unmoved, and the app sends no sidebar move.

Not changed: under `afterCurrent` an unplaced row keeps the press-time row at the window's slot
(#23014's hold) and the app sends one move after the create; Cmd-N inside a group still sends one
move into the group. `top` is the default again in the app, as in the daemon.
