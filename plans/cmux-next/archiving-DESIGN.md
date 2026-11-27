# Archiving sidebar items (2026-10-23)

Ask (Aziz): "add the ability to archive tabs/items within the sidebar hierarchy: archiving moves the
item to the end of its group (or root, if ungrouped) and shows it dimmed; unarchive restores it."

## Rules

1. **Archive stays in place in the hierarchy.** An archived item keeps its section and its group. It
   moves to the end of its own sibling list: the end of its group, or the end of its section's top
   level when it has no group. A later archive goes after the earlier ones.
2. **Archived items list last.** Every move keeps the archived run at the tail of each sibling list
   (`archive::archived_side`, as `pinned_side` keeps pins first): a drop below an archived item, a new
   workspace (`adopt`, `item.add`) and an unplaced live workspace drawn before it is adopted land
   above the archived tail. An archived item dragged among unarchived ones stays in the tail and stays
   archived.
3. **Dimmed.** The row of an archived item, and every row under an archived group, draws dimmed
   (`view::Row.archived`, the FFI row flag `CMUX_SIDEBAR_ROW_ARCHIVED`). An archived workspace still
   opens on click.
4. **Unarchive restores.** The mark goes, and the item goes back after the sibling it followed when it
   was archived (`extra.unarchive_to.after`), while that sibling is still in the same list and is not
   archived itself. An item that was first goes back first. Otherwise it goes last among the
   unarchived siblings.
5. **Pins.** Archive unpins a member pinned in its group. Pin unarchives first, then pins.
6. **Persistence.** The mark is the item's own row in the daemon's sidebar document
   (`extra.archived`, `extra.unarchive_to`), so it survives a restart and syncs to every window. The
   ops are the reducer's `archive` and `unarchive`, sent through `sidebar.apply`; the app's mirror
   runs the same reducer, so the dimmed row draws at once.
7. **Undo.** Archive and Unarchive are one undo step each (the document's inverse is the item's old
   row).
8. **Several at once.** Items archived in one change come back in their order: each remembers the
   sibling it followed before anything moved, and Unarchive puts them back in list order.
9. **Ungroup** places the members after the group without the group's mark: they draw undimmed.
10. **New workspaces.** The daemon's `workspace.list` order puts an unplaced workspace above the
    machine section's archived tail for `Bottom`, and for `AfterCurrent` when the active one is
    archived (`sidebar_doc_order.rs`), so it does not jump when it is adopted.

## Surfaces

The right-click menu of a workspace row (More), a group header (Options) and a link or tab row in a
list reads Archive or Unarchive for the item under the pointer (one catalog action per object, as
Pin/Unpin); Cmd-Shift-P, the CLI (`workspace archive-unarchive`, `workspace-group toggle-archive`,
`sidebar toggle-item-archive`) and MCP run the same actions. A band tile (Pinned, custom and app
sections) does not offer it: tiles draw no dimmed look, and app sections are provider-owned.

## Auto-archive and groups (2026-10-25)

auto-archive-DESIGN.md: a group whose last unarchived member archives is archived too
(`extra.archived_by`), Unarchive of a member restores its groups, and a live drop into an archived
group restores it. Idle workspaces archive per `workspaces.autoArchive.style` (default: suggest).

## Open

- Band tiles: the CLI can still archive one (it moves last, undimmed).
- A group's member line is not dimmed with its header.
- The multi-selection menu reads Archive Workspace, not a selection title.
- A legacy-store re-sync of a row whose old neighbor is archived sends a no-op move (`sidebar_doc_sync`).

## Tests

`sidebar_doc::archive_tests` (Rust, the reducer and the view rows). Client: the row reads the
archived flag from the mirror's typed rows.

## Drawn: one Archive section (2026-10-31, Lawrence 19197)

The document keeps rule 1 (an archived item keeps its section and group) and rule 2 (archived items list last). The
list draws them apart: archived workspaces and wholly archived groups (archived, or every workspace archived) sit
under one "Archive (N)" row at the bottom of the sidebar, closed by default (`SidebarLayout+ArchiveSection`). The
active workspace, a filter, the session tree and Group by Status draw them in place.
