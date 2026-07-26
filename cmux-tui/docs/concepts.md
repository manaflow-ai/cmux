# Concepts

## Tree

The mux tree is:

```text
session -> workspaces -> screens -> split-tree panes -> tabs
```

A session is one mux backend and one control socket. A workspace owns zero or more screens. A screen is the layout selected in the status bar. A normal screen owns one binary split tree whose leaves are panes. A horizontally scrollable screen owns an ordered list of stable columns, and each column owns its own split tree. The server projects those columns into the existing split-tree protocol shape for compatibility. A pane owns an ordered tab list, and each tab is a surface.

Protocol v8 assigns each interior split node a stable `SplitId`. Frontends use it as divider identity and resize that exact node with `set-split-ratio`. The id survives ratio, focus, tab, and leaf-order changes. It disappears only when its node collapses.

The UI uses tmux-style verbs for screens. Prefix `c` creates a screen, prefix `n` and `p` switch screens, prefix `&` closes a screen, and prefix `,` renames a screen. PTY tabs use prefix `t`, tab chips, and tab context menus.

## Active and Focus State

The session tracks the active workspace. Each workspace tracks its active screen. Each screen tracks its active pane. Each pane tracks its active tab.

Focusing a pane makes that pane's screen and workspace active. Selecting a workspace or screen changes that level's active item. Selecting a tab changes the active tab in one pane.

Pane focus tracks recent activity. When closing the active pane or the last tab in it, mux chooses the most recently active remaining pane on that screen instead of always choosing a neighbor.

## Tabs and Names

Tabs are surfaces. A PTY tab wraps a child process connected to a pseudo-terminal. A browser tab wraps a local Chrome/Chromium target.

`rename-tab` sets the surface name. Empty tab names clear the custom name and fall back to the generated tab label. The old config key `rename-pane` is still accepted as an alias for the `rename-tab` key binding, but the UI rename action targets the tab surface, not the pane object.

Pane names still exist in the control socket through `rename-pane`. They are separate from the tab labels shown in the TUI.

## Automatic Layout

The modeless `Alt-n` binding creates a new pane and reapplies Zellij's default distribution inside the focused horizontal column. Each column preserves its own pane creation order across swaps and manual splits. A screen without horizontal columns is one implicit column, so the default behavior is unchanged.

## Viewport Panes

`Ctrl-b g` creates a terminal immediately after the horizontal column containing the focused pane. Its default width is two thirds of each frontend's viewport. Supporting frontends retain each column's independent width and expose overflow through a horizontal scrollbar. Ordinary split and startup behavior remain tiled.

## Layout Undo

Each screen keeps an in-memory history of its latest structural layout actions. `Ctrl-b U` undoes the newest entry on the focused screen. Repeated changes to one divider are coalesced. Undoing pane creation requires confirmation because it closes the pane's live surfaces. The confirmation carries the exact layout revision, so a later layout action makes an older prompt fail without closing anything. A direct pane close clears the history because the mux cannot recreate the closed process.

## Collapse Behavior

Closing a tab removes one surface. If the pane still has tabs, the active tab index moves to a remaining tab.

If a pane loses its last tab, that pane is removed from the split tree and its parent split collapses to the remaining child. If that empties the screen, the screen is removed. A canonical workspace remains in the durable registry when its final screen or terminal disappears; it becomes an empty workspace and is still projected to every frontend. Only an explicit `close-workspace` mutation tombstones it. If every workspace is explicitly closed, mux emits an `empty` event.

Closing a pane closes all tabs in that pane. Closing a screen closes every pane and tab in that screen. Closing a workspace closes every screen, pane, and tab in that workspace.

## PTY and Browser Surfaces

A PTY surface parses child-process output with libghostty-vt. Frontends render snapshots of that terminal state. Attach clients receive a VT replay first, then a base64 stream of subsequent PTY bytes, plus ordered resize frames when the surface geometry changes.

A browser surface is a local Chrome/Chromium target controlled through the Chrome DevTools Protocol. The local TUI draws browser frames with kitty graphics and forwards keyboard, mouse, and wheel input over CDP. Protocol-v7 attach clients receive an initial `browser-state` event with the latest optional frame, followed by updated `browser-state` and base64 PNG `frame` events.
