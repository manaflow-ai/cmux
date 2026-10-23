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

## Surfaces

The right-click menu of a workspace row, a group header and a link or tab item reads Archive or
Unarchive for the item under the pointer (one catalog action per object, as Pin/Unpin).

## Tests

`sidebar_doc::archive_tests` (Rust, the reducer and the view rows). Client: the row reads the
archived flag from the mirror's typed rows.
