# Concepts

## Tree

The mux tree is:

```text
session -> workspaces -> screens -> split-tree panes -> tabs
```

A session is one mux backend and one control socket. A workspace owns zero or more screens. A screen is the layout selected in the status bar. A normal screen owns one binary split tree whose leaves are panes. A horizontally scrollable screen owns an ordered list of stable columns, and each column owns its own split tree. The server projects those columns into the existing split-tree protocol shape for compatibility. A pane owns an ordered list of tab placements. A PTY tab projects a session-owned terminal resource, and several tabs may project the same terminal. A browser tab owns one single-view browser surface. The raw protocol's legacy `surface` ID identifies the tab placement.

Protocol v8 assigns each interior split node a stable `SplitId`. Frontends use it as divider identity and resize that exact node with `set-split-ratio`. The id survives ratio, focus, tab, and leaf-order changes. It disappears only when its node collapses.

The UI uses tmux-style verbs for screens. Prefix `c` creates a screen, prefix `n` and `p` switch screens, prefix `&` closes a screen, and prefix `,` renames a screen. PTY tabs use prefix `t`, tab chips, and tab context menus.

## Active and Focus State

The shared compatibility tree records default active workspace, screen, pane, and tab values. A frontend may use them for initial placement or a deliberately shared projection, but they are not global user focus. Each frontend keeps its current workspace, screen, pane, tab, text selection, scroll position, crop, pan, hover, drag, and key-prefix state in client memory. Focusing or selecting in one frontend therefore does not move another frontend's focus or viewport. Legacy focus commands update the compatibility defaults for clients that explicitly use them.

The compatibility tree's pane-focus metadata tracks recent activity. When closing its active pane or the last tab in it, mux chooses the most recently active remaining pane on that screen instead of always choosing a neighbor.

## Frontend Projections

The workspace tree is one durable shared backend projection. Frontends may also store opaque schema-versioned documents with `put-frontend-projection`: `personal` scope belongs to one stable user, profile, or device subject, while `shared` scope belongs to a collaboration view. Either document may place one terminal UUID several times and may deliberately save focus or viewport preferences. Unsaved focus, selection, scroll, crop, pan, hover, drag, and key-prefix state remain client-local. A projection owns presentation only; removing it never closes a terminal.

## Tabs and Names

A terminal resource wraps one child process connected to one pseudo-terminal, its ordered input and output, retained history, canonical grid, and graphics state. A PTY tab is a named view placement of that resource. A browser tab wraps one local Chrome/Chromium target and cannot have a second placement.

`rename-tab` sets the placement-local name. Empty tab names clear the custom name and fall back to the generated tab label. The old config key `rename-pane` is still accepted as an alias for the `rename-tab` key binding, but the UI rename action targets the tab placement, not the pane object.

Pane names still exist in the control socket through `rename-pane`. They are separate from the tab labels shown in the TUI.

## Automatic Layout

The modeless `Alt-n` binding creates a new pane and reapplies Zellij's default distribution inside the focused horizontal column. Each column preserves its own pane creation order across swaps and manual splits. A screen without horizontal columns is one implicit column, so the default behavior is unchanged.

## Viewport Panes

`Ctrl-b g` creates a terminal immediately after the horizontal column containing the focused pane. Its default width is two-thirds of each frontend's viewport. Supporting frontends retain each column's independent width and expose overflow through a horizontal scrollbar. Ordinary split and startup behavior remain tiled.

## Layout Undo

Each screen keeps an in-memory history of its latest structural layout actions. `Ctrl-b U` undoes the newest entry on the focused screen. Repeated changes to one divider are coalesced. Undoing pane creation requires confirmation because it removes the pane's tab placements and closes single-view browser surfaces. PTY terminal resources remain session-owned. The confirmation carries the exact layout revision, so a later layout action makes an older prompt fail without changing anything. A direct pane close clears the history because the journal cannot reconstruct exact removed tab membership or a closed browser target.

## Collapse Behavior

Closing a tab removes one placement. A PTY terminal remains addressable with zero or more placements; closing its process requires `terminal.close`. A browser closes with its only tab. If the pane still has tabs, the active tab index moves to a remaining tab.

If a pane loses its last tab, that pane is removed from the split tree and its parent split collapses to the remaining child. If that empties the screen, the screen is removed. A canonical workspace remains in the durable registry when its final screen or terminal view disappears; it becomes an empty workspace and is still projected to every frontend. Only an explicit `close-workspace` mutation tombstones it. If every workspace is explicitly closed, mux emits an `empty` event.

Closing a pane removes all tab placements in that pane. Closing a screen removes every pane and placement in that screen. Closing a workspace tombstones that workspace and removes all of its placements. These tree operations detach PTY terminal views without ending their processes; browser surfaces close because they are single-view.

## PTY and Browser Surfaces

A terminal runtime parses child-process output once with libghostty-vt. Every PTY tab or attached frontend renders a view of that shared terminal state while keeping its own selection, scroll offset, crop, pan, and scale. Inline Kitty image storage, aliases, quota, cell pixels, and placement anchors belong to the terminal runtime rather than any one view. Attach clients receive a VT replay first, then a base64 stream of subsequent PTY bytes, plus ordered resize frames when canonical geometry changes. Graphics survive projection, attach, remote mirroring, scrolling, and resize within the configured replay and transport byte limits; graphics beyond the replay budget may be omitted.

A browser surface is a local Chrome/Chromium target controlled through the Chrome DevTools Protocol. The local TUI draws browser frames with kitty graphics and forwards keyboard, mouse, and wheel input over CDP. Protocol-v7 attach clients receive an initial `browser-state` event with the latest optional frame, followed by updated `browser-state` and base64 PNG `frame` events.
