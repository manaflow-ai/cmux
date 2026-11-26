Fix tab ordering and focus in `focusorder.py`.

Bug report: "Workspace `two` has pinned tabs `mail` and `chat`. I dragged tab `logs` from workspace `one` into
`two` at position 0 and it landed in front of my pinned tabs, unpinned."

Contract. In every group, all pinned tabs come before all unpinned tabs, after every call. A tab placed at a
position (by `open`, `move` or `reopen`) goes there if that keeps the rule, else to the nearest position that does;
its pinned state never changes by being placed. When a group's active tab leaves the group (closed, or moved to
another group), the group activates the tab most recently active in that group that is still in that group; if
there is none, the tab now at the departed tab's old position, else the last tab, else nothing. A group's active
tab is always one of its own tabs. `reopen` puts the tab back in its group at the index it had when closed (clamped
to the strip, then the pinned rule), with its pinned state, and activates it.
