# 2026-11-26 (lane/instant-splits-side-d): the Cmd-B slide moves for D

Sidebar-Look: Leo, 2026-11-08: "our animations should be so fast" (the instant-splits goal: every split, pane and
side-panel transition settles within 120 ms).

The sidebar's show and hide (Cmd-B, the toolbar toggle, the float's slide) take `split`'s time, about 100 ms, the one
motion length D every pane transition moves on (`SidebarContainerView.widthSpring`). Before, the show took `appear`'s
160 ms and the hide `disappear`'s 130 ms; on the split-scale bench's lightest cell (s1-empty-w1) side_open settled at
163 ms and side_close at 133 ms against the 120 ms budget (cmuxterm-hq goals/instant-splits.md, gap row 5). Same
curve, same path, same frames on the window's motion clock; only the length changes. Reduce Motion is still instant.
Test: `SidebarSlideOnDTests`.
