# Concepts

## Tree

The mux tree is:

```text
session -> workspaces -> screens -> split-tree panes -> tabs
```

A session is one mux backend and one control socket. A workspace owns one or more screens. A screen is the layout selected in the status bar. A screen layout is a binary split tree whose leaves are panes. A pane owns an ordered tab list, and each tab is a surface.

The UI uses tmux-style verbs for screens. Prefix `c` creates a screen, prefix `n` and `p` switch screens, prefix `&` closes a screen, and prefix `,` renames a screen. PTY tabs use prefix `t`, tab chips, and tab context menus.

## Active and Focus State

The session tracks the active workspace. Each workspace tracks its active screen. Each screen tracks its active pane. Each pane tracks its active tab.

Focusing a pane makes that pane's screen and workspace active. Selecting a workspace or screen changes that level's active item. Selecting a tab changes the active tab in one pane.

Pane focus tracks recent activity. When closing the active pane or the last tab in it, mux chooses the most recently active remaining pane on that screen instead of always choosing a neighbor.

## Tabs and Names

Tabs are surfaces. A PTY tab wraps a child process connected to a pseudo-terminal. A browser tab wraps a local Chrome/Chromium target.

`rename-tab` sets the surface name. Empty tab names clear the custom name and fall back to the generated tab label. The old config key `rename-pane` is still accepted as an alias for the `rename-tab` key binding, but the UI rename action targets the tab surface, not the pane object.

Pane names still exist in the control socket through `rename-pane`. They are separate from the tab labels shown in the TUI.

## Smart Split

The modeless `Alt-n` binding creates a new pane with smart split direction. The TUI first tries the focused pane. If that pane cannot split in the chosen direction, it tries the largest pane that can.

Direction follows a zellij-style rule using the terminal cell ratio. Tall enough panes split down. Wide enough panes split right. Panes below the configured size thresholds do not split.

## Collapse Behavior

Closing a tab removes one surface. If the pane still has tabs, the active tab index moves to a remaining tab.

If a pane loses its last tab, that pane is removed from the split tree and its parent split collapses to the remaining child. If that empties the screen, the screen is removed. If that empties the workspace, the workspace is removed. If every workspace is gone, mux emits an `empty` event.

Closing a pane closes all tabs in that pane. Closing a screen closes every pane and tab in that screen. Closing a workspace closes every screen, pane, and tab in that workspace.

## PTY and Browser Surfaces

A PTY surface parses child-process output with libghostty-vt. Frontends render snapshots of that terminal state. Attach clients receive a VT replay first, then a base64 stream of subsequent PTY bytes, plus ordered resize frames when the surface geometry changes.

A browser surface is a local Chrome/Chromium target controlled through the Chrome DevTools Protocol. The local TUI draws browser frames with kitty graphics and forwards keyboard, mouse, and wheel input over CDP. Browser surfaces are listed in the tree, but `attach-surface` does not stream browser pixels as of protocol v6.
