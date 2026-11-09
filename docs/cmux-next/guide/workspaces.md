# Workspaces, panes, tabs, and groups

How cmux-next lays out your work.

A window holds workspaces. A workspace holds panes. A pane holds tabs: terminals, browsers, chats, files, and more.

## Panes

```bash
cmux pane split-right
cmux pane split-down
cmux pane equalize-splits
cmux pane move-to-new-workspace
```

## Tabs

```bash
cmux tab new-terminal
cmux tab new-browser
cmux tab rename
cmux tab move-to-pane-left
```

## Workspace groups

Groups gather related workspaces in the sidebar. A group has a name, color, and icon. It can hold subgroups, and you can pin, collapse, or mark it read.

```bash
cmux workspace-group create
cmux workspace-group add-workspace
cmux workspace-group set-color
cmux workspace-group collapse-all
```

## Hibernation

A workspace you have not opened for a while hibernates: its pages and chats are unloaded to free memory. Terminals and agents keep running. Pinned workspaces, workspaces with running commands or agents, and workspaces you keep awake never hibernate. Change it with workspaces.hibernation.enabled and workspaces.hibernation.idleMinutes.

- [Spaces and columns](spaces.md)
- [Command palette](command-palette.md)
