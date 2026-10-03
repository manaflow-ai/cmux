# Lane: sidebar

## Active streams
- Sidebar sections (layout document, regions, built-in items, per-section arrangement): sidebar sections lead, design plans/cmux-next/sidebar-sections.md, app branch feat-cmux-next-sidebar-client, store branch feat-cmux-next-sidebar-store2 (cmux-tui `sidebar-layout-v1`, waits for its landing window).
- Next in the store window: `name` on `move-tab-to-new-workspace` (the app keeps the rename fallback for a daemon without it), blob.put/blob.get.

## Landed
- 2026-10-03 (this push) app: a workspace made from a moved tab takes the tab's name (user name, browser page title or host, terminal title, a bare shell title reads as the directory; a group's name, else its first tab's); from a workspace's last tab it keeps a user-set workspace name. One path: TabMoves.toNewWorkspace / TabGroupMoves.toNewWorkspace (drag, tear-off, palette, CLI, Move Pane). Rename is a second command until the daemon field lands; a failed rename keeps the default name and the move stands. A dragged agent tab is refused with a message (R15).
- 2026-10-03 (this push) app: Ctrl-N selects the Nth tab the strip shows after a reorder. StripOrder makes the model the one ordering source: a drop's display index becomes the pane index (TabMoveIndex.paneFinalIndex) or the position inside the group (TabMoveIndex.groupIndex, add-tabs-to-group), the strip's optimistic order ends when the move or group command settles, an app-local tab's drop snaps back. Open: moveGroup and removeFromGroup still send display indexes (R38).
- 2026-10-02 (cfcb6e92ad3) plans: section collapse is per window; the space bar stays.
