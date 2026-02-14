# Windows and Workspaces

Window/workspace lifecycle and ordering operations.

## Inspect

```bash
cmux list-windows
cmux current-window
cmux list-workspaces
cmux current-workspace
```

## Create/Focus/Close

```bash
cmux new-window
cmux focus-window --window window:2
cmux close-window --window window:2

cmux new-workspace
cmux select-workspace --workspace workspace:4
cmux close-workspace --workspace workspace:4
```

## Reorder and Move

```bash
cmux reorder-workspace --workspace workspace:4 --before workspace:2
cmux move-workspace-to-window --workspace workspace:4 --window window:1
```
