# Windows and Workspaces

Window/workspace lifecycle and ordering operations.

## Inspect

```bash
cmuxterm list-windows
cmuxterm current-window
cmuxterm list-workspaces
cmuxterm current-workspace
```

## Create/Focus/Close

```bash
cmuxterm new-window
cmuxterm focus-window --window window:2
cmuxterm close-window --window window:2

cmuxterm new-workspace
cmuxterm select-workspace --workspace workspace:4
cmuxterm close-workspace --workspace workspace:4
```

## Reorder and Move

```bash
cmuxterm reorder-workspace --workspace workspace:4 --before workspace:2
cmuxterm move-workspace-to-window --workspace workspace:4 --window window:1
```
