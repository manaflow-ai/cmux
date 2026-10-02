# cmux-next screen groups

User request (2026-10-02): "we also need to add 'screen groups', which can
just reuse code from how we do grouping of horizontal tabs."

## What existed before this change

- A screen is one of a workspace's layouts (strip columns of panes); a
  workspace with two or more screens shows the screen bar at its bottom
  (`ScreenBarController`), a `TabStripView` whose tabs are the screens.
- Daemon (cmux-tui `mux/screen_groups.rs`, capabilities
  `screen-metadata-v1`, `screen-groups-v1`, served by the pinned
  f39636c811a): screen groups per workspace with id, name, one of nine
  colors and a shared collapsed flag; each screen in at most one group,
  members contiguous after the pinned screens (the order is normalized
  before every commit); saved screen groups; Rust reducer tests in the same
  file.
- PR #16174 (feat-cmux-next-acpmux, cmux-tui 52103e740, pin commit
  1b2705ee8b5): `mux/state_screens.rs`, one durable commit path for raw and
  protocol-v2 screen changes; v2 operations `screen.update`, `screen.move`,
  `screen_group.create|add_screens|remove_screens|update|ungroup|get|list`
  with idempotency keys (`state-resources-v1`).
- App: the daemon client (`DaemonConnection+Screens`), the action catalog
  (`ActionCatalog+ScreenGroups`, every action with a `cli` form),
  `ScreenGroupHandlers`, `ScreenGroupCommands`, palette pickers, and the
  screen bar rendering screen groups through the same strip chips,
  collapse, colors, rename, editor bubble, drag and hover cards as pane
  tab groups.

So screen groups already reused the tab strip's grouping UI. What the two
command layers still copied, and what this change shares or fixes:

| Rule | Before | Now |
| --- | --- | --- |
| New group color | tab groups grey; screen groups first unused | `TabGroupOrdering.nextColor` for both (first unused, never auto-picks blue) |
| Selection when a group collapses over it | first item outside the group (both) | `TabGroupOrdering.selectionAfterCollapsing` for both (nearest visible to the right, else left), as the strip reducer |
| Owning daemon | `TabGroupMoves` local daemon; `TabGroupHandlers` the active window's | `GroupOwnership` (the daemon whose tree holds the group) for both; a target on another machine is refused |
| Idempotency | screen group commands had none | v2 `screen_group.*` with a per-intent key where `state-resources-v1` is served |

## Decisions

- Collapse state is shared store state (the daemon's group record), not
  per-client view state: the daemon already stores it for tab groups and
  screen groups, Chrome syncs it with the group, and a per-client copy
  would be a second writer for the same fact. Revisit if a client needs a
  private collapse (record it in its own per-client view record then).
- `state-resources-v1` is `awaitingPin`: advertised, used when a daemon
  serves it, not required of the pinned f39636c811a. The pin cut that
  brings 52103e740 or later moves it to `optional`; screen group
  create/add/remove/update/ungroup then always carry idempotency keys.
- Move, close, save and placed adds have no v2 operation yet; they stay on
  the raw commands until #16174 adds them.
- Automatic group colors skip blue (no blue in colors cmux picks itself);
  the editor still offers all nine colors (architecture.md 7: group colors
  are content).

## Known gaps (review, 2026-10-02)

- The tab group action gate (`ctx.needs(tabGroups)`) checks the daemon
  that was active when the actions were bound, not the group's owner: a
  remote daemon without `tab-groups-v1` is not refused up front (its
  command fails instead).
- Saved tab group unsave and delete read the active daemon's saved
  records; saved groups live in personal state on the home daemon
  (`personalOnHome`), so this matches today, but it is not routed through
  `GroupOwnership`.
- The app sends each idempotency key once; nothing resends a failed
  request with the same key yet, so replay is possible but unused.
