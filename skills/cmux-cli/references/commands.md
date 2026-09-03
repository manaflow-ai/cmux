# cmux CLI Command Examples

Run `cmux --help` first for the current full command list. These examples show common shapes and safe defaults.

## Open

```bash
cmux <path>
cmux open <path-or-url>...
cmux open . --focus false
cmux open https://example.com --workspace "${CMUX_WORKSPACE_ID:-}" --focus false
```

## Windows and Workspaces

```bash
cmux list-windows --json
cmux current-window --json
cmux new-window
cmux focus-window --window window:1
cmux close-window --window window:2
cmux list-workspaces --window window:1 --json
cmux current-workspace --json
cmux new-workspace --name "debug auth" --cwd "$PWD" --focus false
cmux rename-workspace --workspace workspace:2 "build logs"
cmux close-workspace --workspace workspace:2
cmux reorder-workspace --workspace workspace:3 --before workspace:1 --dry-run
cmux move-workspace-to-window --workspace workspace:3 --window window:2
```

## Panes and Surfaces

```bash
cmux list-panes --workspace "${CMUX_WORKSPACE_ID:-}" --json
cmux list-pane-surfaces --workspace "${CMUX_WORKSPACE_ID:-}" --json
cmux new-pane --workspace "${CMUX_WORKSPACE_ID:-}" --type terminal --direction right --focus false
cmux new-surface --workspace "${CMUX_WORKSPACE_ID:-}" --pane pane:2 --type terminal --focus false
cmux move-surface --surface surface:4 --pane pane:2 --focus false
cmux reorder-surface --surface surface:4 --before surface:2 --focus false
cmux split-off --surface surface:4 right --focus false
cmux close-surface --surface surface:4
```

## Terminal IO

```bash
cmux read-screen --surface "${CMUX_SURFACE_ID:-}" --scrollback --lines 200
cmux send --surface "${CMUX_SURFACE_ID:-}" "echo ok\n"
cmux send-key --surface "${CMUX_SURFACE_ID:-}" enter
cmux capture-pane --surface "${CMUX_SURFACE_ID:-}" --scrollback --lines 200
cmux clear-history --surface "${CMUX_SURFACE_ID:-}"
cmux respawn-pane --surface surface:4 --command "npm test"
```

## Browser

```bash
cmux browser status
cmux browser open https://example.com --focus false
cmux browser identify --surface surface:5
cmux browser snapshot --surface surface:5 --compact
cmux browser click "button[type=submit]" --snapshot-after
cmux browser fill "input[name=email]" "person@example.com"
cmux browser screenshot --out /tmp/cmux-browser.png --json
```

Use `skills/cmux-browser/SKILL.md` for detailed browser automation rules.

## Markdown and Diffs

```bash
cmux markdown open README.md --focus false
cmux diff --source unstaged --cwd "$PWD" --focus false
git diff | cmux diff - --focus false
```

## Notifications and Sidebar State

```bash
cmux notify --title "Build finished" --body "All checks passed" --workspace "${CMUX_WORKSPACE_ID:-}"
cmux list-notifications --json
cmux mark-notification-read --workspace "${CMUX_WORKSPACE_ID:-}"
cmux clear-notifications --workspace "${CMUX_WORKSPACE_ID:-}"
cmux set-status build running --workspace "${CMUX_WORKSPACE_ID:-}" --color "#ff9500"
cmux set-progress 0.4 --label "Building" --workspace "${CMUX_WORKSPACE_ID:-}"
cmux log --workspace "${CMUX_WORKSPACE_ID:-}" --level info -- "Started build"
cmux sidebar-state --workspace "${CMUX_WORKSPACE_ID:-}" --json
cmux clear-status build --workspace "${CMUX_WORKSPACE_ID:-}"
cmux clear-progress --workspace "${CMUX_WORKSPACE_ID:-}"
```

## Right Sidebar

```bash
cmux right-sidebar show --workspace "${CMUX_WORKSPACE_ID:-}" --no-focus
cmux right-sidebar mode feed --workspace "${CMUX_WORKSPACE_ID:-}" --no-focus
cmux right-sidebar hide --workspace "${CMUX_WORKSPACE_ID:-}" --no-focus
```

## Settings and Config

```bash
cmux docs settings
cmux settings path
cmux config paths
cmux config doctor
cmux config validate
cmux reload-config
cmux shortcuts
```

## Themes

```bash
cmux themes list
cmux themes set <theme-name>
cmux themes clear
```

## Authentication and Cloud VMs

```bash
cmux auth status
cmux login
cmux logout
cmux vm ls
cmux vm new
cmux vm shell <vm-id>
cmux vm exec <vm-id> -- <command>
cmux vm ssh <vm-id>
cmux vm rm <vm-id>
```

## Agent Hooks, Teams, and Feed

```bash
cmux hooks setup
cmux hooks setup --agent codex
cmux hooks uninstall --agent claude
cmux hooks <agent> install
cmux hooks <agent> uninstall
cmux hooks feed --source codex --event Stop
cmux feed tui
cmux feed clear
cmux claude-teams
cmux codex-teams
cmux omo
cmux omx
cmux omc
```

## Events and RPC

```bash
cmux events --after 0 --limit 50 --json
cmux events --name workspace.created --reconnect
cmux rpc <method> '{"key":"value"}'
```

## tmux Compatibility

```bash
cmux capture-pane --surface surface:4 --scrollback --lines 200
cmux resize-pane --pane pane:2 -R --amount 10
cmux pipe-pane --surface surface:4 --command "cat > /tmp/pane.log"
cmux wait-for -S build-done
cmux wait-for build-done --timeout 30
cmux swap-pane --pane pane:2 --target-pane pane:3 --focus false
cmux break-pane --surface surface:4 --focus false
cmux join-pane --target-pane pane:2 --surface surface:4 --focus false
cmux find-window --content --select "server ready"
cmux set-buffer --name scratch "hello"
cmux paste-buffer --name scratch --surface surface:4
cmux display-message --print "workspace=#{workspace_id}"
```
