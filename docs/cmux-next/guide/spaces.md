# Spaces and columns

Group windows and workspaces into spaces, and dock columns to the window.

A space is a named set of windows and workspaces, for example Work and Personal. Each space has its own color, icon, theme, terminal defaults, and groups. The sidebar shows your spaces at the top or bottom (sidebar.showSpaces, sidebar.spacesPosition).

## Switch spaces

Use Next Space, Previous Space, or Select Space 1…9. The default keys are on the Keyboard shortcuts page. From the CLI:

```bash
cmux space switch
cmux space new-workspace
cmux space new-window
```

## Change a space

```bash
cmux space rename
cmux space set-color
cmux space set-icon
cmux space set-theme
cmux space set-defaults
cmux space move-left
cmux space delete
```

Set Space Terminal Defaults gives new terminals in the space their folder, shell, and environment. Set Space Theme changes the colors of every window in the space.

## Columns

A column is a strip of panes. Dock a column to the left, right, top, or bottom of the window: it stays there when you switch workspaces. Float it to put it over the window, or undock it to put it back in the workspace.

```bash
cmux column dock-left
cmux column dock-bottom
cmux column float
cmux column undock
cmux column width-half
cmux column center
```

- [Workspaces, panes, tabs, and groups](workspaces.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
