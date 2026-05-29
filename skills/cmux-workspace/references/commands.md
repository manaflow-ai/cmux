# cmux Workspace Command Reference

Use these commands from a cmux terminal. Most commands infer the caller workspace from `CMUX_WORKSPACE_ID`, but explicit flags are safer for automation.

## Context

```bash
cmux identify --json
cmux current-workspace --json
cmux capabilities --json
cmux ping
```

## Windows and Workspaces

```bash
cmux list-windows
cmux current-window
cmux new-window
cmux focus-window --window window:2
cmux close-window --window window:2

cmux list-workspaces
cmux list-workspaces --json
cmux new-workspace --name "task" --cwd "$PWD"
cmux new-workspace --command "npm run dev"
cmux new-workspace --layout '{"root":{"type":"terminal"}}'
cmux current-workspace
cmux select-workspace --workspace workspace:2
cmux rename-workspace --workspace workspace:2 -- "new name"
cmux close-workspace --workspace workspace:2
cmux reorder-workspace --workspace workspace:4 --before workspace:2
cmux move-workspace-to-window --workspace workspace:4 --window window:1
```

## Panes and Surfaces

```bash
cmux list-panes --workspace "$CMUX_WORKSPACE_ID"
cmux list-pane-surfaces --workspace "$CMUX_WORKSPACE_ID" --pane pane:1
cmux list-panels --workspace "$CMUX_WORKSPACE_ID"
cmux tree --workspace "$CMUX_WORKSPACE_ID"

cmux new-split right --workspace "$CMUX_WORKSPACE_ID"
cmux new-split down --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID"
cmux new-pane --workspace "$CMUX_WORKSPACE_ID" --type terminal --direction right
cmux new-pane --workspace "$CMUX_WORKSPACE_ID" --type browser --url http://localhost:3000
cmux new-surface --workspace "$CMUX_WORKSPACE_ID" --type terminal --pane pane:1
cmux new-surface --workspace "$CMUX_WORKSPACE_ID" --type browser --pane pane:1 --url http://localhost:3000

cmux focus-pane --workspace "$CMUX_WORKSPACE_ID" --pane pane:2
cmux focus-panel --workspace "$CMUX_WORKSPACE_ID" --panel surface:3
cmux close-surface --workspace "$CMUX_WORKSPACE_ID" --surface surface:3
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux reorder-surface --surface surface:7 --before surface:3
cmux move-tab-to-new-workspace --surface surface:7 --title "browser"
```

## Input

```bash
cmux send "echo hello\n"
cmux send-key enter
cmux send --surface "$CMUX_SURFACE_ID" "git status\n"
cmux send-key --surface "$CMUX_SURFACE_ID" enter
cmux read-screen --surface "$CMUX_SURFACE_ID"
```

**Cross-workspace targeting:** `send`, `send-key`, and `read-screen` resolve `--workspace` from `$CMUX_WORKSPACE_ID`. When targeting a surface outside the caller's workspace, you must pass `--workspace` explicitly. Omitting it produces the misleading `Error: invalid_params: Surface is not a terminal`.

## Sidebar Metadata

```bash
cmux set-status build "running" --workspace "$CMUX_WORKSPACE_ID" --icon hammer --color "#ff9500"
cmux clear-status build --workspace "$CMUX_WORKSPACE_ID"
cmux list-status --workspace "$CMUX_WORKSPACE_ID"
cmux set-progress 0.5 --workspace "$CMUX_WORKSPACE_ID" --label "Building"
cmux clear-progress --workspace "$CMUX_WORKSPACE_ID"
cmux log --workspace "$CMUX_WORKSPACE_ID" --level info -- "Build started"
cmux list-log --workspace "$CMUX_WORKSPACE_ID" --limit 20
cmux clear-log --workspace "$CMUX_WORKSPACE_ID"
cmux sidebar-state --workspace "$CMUX_WORKSPACE_ID" --json
```

## Notifications and Attention

```bash
cmux notify --title "Done" --body "Task complete"
cmux list-notifications --json
cmux clear-notifications
cmux trigger-flash --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID"
cmux surface-health --workspace "$CMUX_WORKSPACE_ID" --json
```

## Config and Docs

```bash
cmux docs api
cmux docs browser
cmux docs settings
cmux settings path
cmux settings cmux-json
cmux settings shortcuts
cmux reload-config
```

## Tagged Reloads

```bash
./scripts/reload.sh --tag <short-tag>
CMUX_SOCKET_PATH=/tmp/cmux-debug-<short-tag>.sock cmux identify --json
```
