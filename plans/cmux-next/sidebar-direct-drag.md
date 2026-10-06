# Sidebar direct drag

Status: exploration, cx-tab-kinds-3, 2026-10-05. Does not merge until Leo or the team has tried it.
Builds on sidebar-sections.md (sections, regions, tiles) and the workspace list drag (R77, nxdog30).

Leo (2026-10-05): things do not need a wiggle or an edit mode to be draggable. Rows and tiles drag
directly at any time: press, move, drop. A click still selects, and a small movement threshold
(`SidebarStyle.dragThreshold`) keeps clicks from turning into drags. An edit mode, if one exists at
all, only adds what a direct drag cannot do: remove, add from the gallery, make or rename folders.

## Usage

**Reorder a tile.** Press a tile at the top of the sidebar and move the pointer. After a few points
the tile lifts and follows the pointer in both directions; the other tiles make way. Release to
drop it in the slot it shows. Escape cancels. A press that does not move opens the tile as before.

**Move a workspace into a folder.** Folders are workspace groups. Drag a workspace row onto a
group's header: it joins that group. Drag it onto the middle of another workspace that is not in a
group: a new group holding both appears where the target was; rename it from the header's context
menu (Rename Group...). Dropping near a row's top or bottom edge still reorders, as today.

**Remove a tile.** Right-click the tile and choose Remove from Sidebar.

**Add a tile.** Right-click the tiles shelf and choose Add to Sidebar..., then pick the item.

## What is new here

| Flow | Before | This PR |
| --- | --- | --- |
| Reorder a tile | drag ran, but the lifted card only followed vertically | the card follows the pointer in both directions |
| Workspace onto a group header | joins the group | unchanged |
| Workspace onto a workspace | reorders | the middle of an ungrouped row makes a group with both |
| Remove a tile | context menu | unchanged |
| Add a tile | context menu | unchanged |

Not in this PR: an edit mode, dragging a workspace row onto the tiles shelf to pin it, dropping one
tile onto another to make a tile folder, and moving items to the toolbar, the tab strip or the dock
(those need the shared placement model with cx-next-spaces-3 and the toolbar lane).
