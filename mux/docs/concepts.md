# Concepts

## Tree

The mux tree is:

```text
session -> workspaces -> screens -> split-tree panes -> tabs
```

A session is one mux backend and one control socket. A workspace owns one or more screens. A screen is the visible layout selected in the status bar. A screen's layout is a binary split tree whose leaves are panes. A pane owns an ordered tab list, and each tab is a surface.

## Active state

The session tracks the active workspace. Each workspace tracks its active screen. Each screen tracks its active pane. Each pane tracks its active tab.

Focusing a pane also makes that pane's screen and workspace active. Selecting a workspace or screen changes only that level's active index. Selecting a tab changes the active tab inside one pane.

## Collapse behavior

Closing a tab removes one surface. If the pane still has tabs, the active tab index moves to a neighboring tab when needed.

If the closed tab was the pane's last tab, the pane is removed from the screen's split tree. Its parent split collapses to the remaining child. If that empties the screen, the screen is removed from the workspace. If that empties the workspace, the workspace is removed. When every workspace is gone, the mux emits an `empty` event.

Closing a pane closes all tabs in that pane. Closing a screen closes every pane and tab in that screen. Closing a workspace closes every screen, pane, and tab in that workspace.

## Surfaces

A PTY surface is a child process connected to a pseudo-terminal. Its output is parsed by libghostty-vt, and frontends render snapshots of that VT state. Attach clients receive a VT replay first, then a base64 stream of subsequent PTY bytes.

A browser surface is a local Chrome/Chromium target controlled through the Chrome DevTools Protocol. The local TUI draws browser frames with kitty graphics and forwards keyboard, mouse, and wheel input over CDP. Browser surfaces are listed in the tree but are not streamable through `attach-surface` as of protocol v5.
