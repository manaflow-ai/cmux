# Sidebar ordering and organizing actions: audit (u2418)

Ask (Lawrence, 2026-10-19): "I need an option to move a group to the top and move a workspace to
the top of a group. Think of all the missing things like this that we need to add and make sure
to add all of them."

Compared against: Finder (sidebar Favorites, folders: Move/Sort/Group/Clean Up), Chrome tab groups
(group bubble: name, color, New tab in group, Ungroup, Close group, Move group to new window;
tab menu: Add to group ▸ list + New group, Remove from group), Arc spaces (folders: move to
top/bottom, pin/unpin, archive, sort), Slack sidebar (custom sections: Move section up/down/top,
Sort by alpha/recent, Collapse all other sections, Move conversation to section ▸, Create section),
VS Code explorer (Collapse Folders, sort order setting, multi-select move), cmux classic (Move to
Top, Move Up/Down, Pin, Close Others/Above/Below).

Every action is one catalog `ActionDescriptor` with one registry handler. The right-click menu
and the ··· (more) menu both come from `ContextMenuCatalog` placements, the palette lists every
`.palette` action, the CLI offers every `cliNamed` action as `cmux <noun> <verb>` (and every other
action as `cmux action run <id>`), and MCP runs the same ids. `ActionSurfaceParityTests.
everyMenuItemRunsItsOwnActionThroughTheRegistry` walks every generated menu item and checks that it
runs its own action with the menu's target, so a new placement is covered without new wiring.

Legend: **had** = present before this change; **ADDED** = added by this change; **FIXED** = present
but wrong or hidden, changed by this change; **not built** = left out, with the reason.

## Group (workspace group header: right-click → group editor → More Group Actions, or ··· )

| Action | Finder / Chrome / Arc / Slack / VS Code / classic | cmux-next | Id |
| --- | --- | --- | --- |
| Move to Top | Arc, Slack (Move to top) | **ADDED** | `workspaceGroup.moveToTop` |
| Move to Bottom | Arc, Slack | **ADDED** | `workspaceGroup.moveToBottom` |
| Move Up / Move Down | Slack | had; **FIXED**: the handler gave a group-order index where the intent counts section rows, so with loose rows above the groups Move Up did nothing or jumped | `workspaceGroup.moveUp` / `.moveDown` |
| Rename | all | had | `workspaceGroup.rename` |
| Change Color | Chrome | had (Appearance ▸ Color ▸ 9 colors) | `workspaceGroup.setColor`, `.color.*` |
| Collapse / Expand | all | had | `toggleFocusedWorkspaceGroupCollapsed`, `.collapse`, `.expand` |
| Collapse All / Expand All | VS Code, Slack | had | `workspaceGroup.collapseAll` / `.expandAll` |
| Collapse All Others | Slack ("Collapse all other sections") | **ADDED** (also expands this group) | `workspaceGroup.collapseOthers` |
| Ungroup (keep workspaces) | Chrome | had (undo with Cmd-Z) | `workspaceGroup.ungroup` |
| Delete Group (keep workspaces) | Chrome | had (undo toast) | `workspaceGroup.delete` |
| Close All Workspaces in Group | Chrome (Close group) | had | `workspaceGroup.closeWorkspaces` |
| Close Other Groups | — | had | `workspaceGroup.closeOthers` |
| Duplicate | Arc | had | `workspaceGroup.duplicate` |
| New Workspace in Group | Chrome (New tab in group) | had | `workspaceGroup.newWorkspace` |
| Sort Group by Name | Finder, Slack (alphabetical) | **ADDED** (sorts only this group's members) | `workspaceGroup.sortByName` |
| Sort Group by Last Used | Slack (recent activity) | **ADDED** | `workspaceGroup.sortByLastUsed` |
| Sort Group by Directory | Finder (Kind) | **ADDED** | `workspaceGroup.sortByDirectory` |
| Pin / Unpin Group | Arc | had | `workspaceGroup.togglePin` |
| Icon / Remove Icon | Slack (emoji) | had | `workspaceGroup.setIcon` / `.clearIcon` |
| Move to Window / New Window / Space / Section | Chrome (Move group to new window) | had | `workspaceGroup.moveToWindow` … |
| Mark Read / Unread / Clear Notifications | Slack | had | `workspaceGroup.markRead` … |
| Copy Group ID | — | had | `workspaceGroup.copyID` |
| Next / Previous Group | — | had | `nextWorkspaceGroup` / `prevWorkspaceGroup` |

## Workspace (row right-click and row ··· )

| Action | Reference | cmux-next | Id |
| --- | --- | --- | --- |
| Move to Top of Group | Arc, Slack | had as "Move Workspace to Top" (top of the row's container), but hidden under More ▸ Move and titled without the group; **FIXED**: a grouped row's menu reads "Move to Top of Group", and Move ▸ is a top-level row | `palette.moveWorkspaceToTop` |
| Move to Bottom of Group | Arc | same as above, "Move to Bottom of Group" | `workspace.moveToBottom` |
| Move Up / Move Down | classic | had (Ctrl-Opt-Cmd-[ / ]; Cmd-Opt-Up/Down while the sidebar has focus) | `moveWorkspaceUp` / `moveWorkspaceDown` |
| Move to Group ▸ (list + New Group…) | Chrome (Add to group ▸) | had (choices submenu with the New Group trailer) | `moveWorkspaceToGroup`, `workspace.moveToNewGroup` |
| Remove from Group | Chrome | had | `removeWorkspaceFromGroup` |
| Group Selected Workspaces | Chrome, Finder (New Folder with Selection) | had | `groupSelectedWorkspaces` |
| Pin / Unpin | Arc, classic | had | `palette.toggleWorkspacePin` |
| Duplicate | Arc | had | `workspace.duplicate` |
| Close Others in Group | Chrome (Close other tabs) | had | `workspace.closeOthersInGroup` |
| Close Others / Above / Below | classic | had | `palette.closeOtherWorkspaces` … |
| Move to Window / New Window / Space, Merge into… | Chrome | had | `moveWorkspaceToWindow` … |
| Sort all by Name / Last Used / Directory | Finder | had (sidebar background ▸ Sort) | `workspace.sortBy*` |

## Multi-selection (Cmd/Shift-click several rows, then right-click or ···)

The menu targets the right-clicked row; before this change only Move to Window / New Window and
Group Selected acted on the whole selection.

| Action | cmux-next |
| --- | --- |
| Move to Top / Bottom (of the group) | **ADDED**: the selection moves as one block, in sidebar order |
| Move to Group ▸ / Move to New Group | **ADDED**: every selected row |
| Remove from Group | **ADDED**: every selected row |
| Move to Window / New Window, Group Selected | had |
| Move Up / Down | not built: the keyboard path (`SidebarModel.moveSelection`, Cmd-Opt-Up/Down in the sidebar) already moves the selection as a block; the menu verb still moves one row |
| Pin / Duplicate / Close | not changed in this pass |

## Keyboard

- Cmd-Opt-Up/Down: taken app-wide by Focus Pane Up/Down, and Cmd-Opt-Shift-Up/Down by Move Tab
  Up/Down, so neither is free for a global default. While the sidebar has focus, Cmd-Opt-Up/Down
  already moves the selected rows (`KeyboardReorder`).
- Move Workspace Up/Down keep Ctrl-Opt-Cmd-[ / ].
- Move Group to Top / Up / Down / to Bottom, Collapse Other Groups and Move Workspace to Top are
  now `.keyboard` actions: no default, but bindable in Settings ▸ Keyboard and `cmux.json`.

## Persistence and undo

- Order is the sidebar document's (or, without it, the home daemon's personal order), so it
  survives a restart. A document move is one undo step (Edit ▸ Undo, Cmd-Z), named "Move".
- Without the sidebar document (older daemons), personal-order moves have no undo step (unchanged).
