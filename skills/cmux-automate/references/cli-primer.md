# cmux CLI Primer for Automation

Use the CLI to inspect, prototype, and verify automations before making them
persistent.

## Handles and Context

- `window:N`, `workspace:N`, `pane:N`, and `surface:N` are short refs accepted by
  most commands.
- UUIDs are accepted too. Use `--id-format both` when a script needs both refs
  and UUIDs.
- Inside cmux terminals, `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` identify the
  caller context. Prefer those defaults for local helper scripts.
- Use `cmux identify --json` to confirm the active socket, window, workspace,
  pane, and surface.

## Topology

Inspect:

```bash
cmux tree
cmux list-windows
cmux list-workspaces
cmux list-panes
cmux list-pane-surfaces --pane pane:1
cmux top
```

Create and route:

```bash
cmux new-window
cmux new-workspace --name "Dev" --cwd . --command "bun dev"
cmux new-split right
cmux new-pane --type browser --direction right --url http://localhost:3000
cmux new-surface --type terminal --pane pane:1
cmux move-surface --surface surface:7 --pane pane:2 --focus false
cmux split-off --surface surface:7 right
cmux reorder-surface --surface surface:7 --before surface:3
cmux trigger-flash --surface surface:7
```

## Terminal Control

Read and send:

```bash
cmux read-screen --surface surface:7 --lines 80
cmux send --surface surface:7 "git status\n"
cmux send-key --surface surface:7 enter
cmux capture-pane --surface surface:7 --scrollback --lines 200
cmux pipe-pane --surface surface:7 --command "rg ERROR"
cmux respawn-pane --surface surface:7 --command "bun test --watch"
```

Use terminal control for setup checks, status probes, and task handoffs. Avoid
sending destructive commands unless the user explicitly asked for that action.

## Browser Control

Common automation:

```bash
cmux browser open http://localhost:3000
cmux browser surface:2 wait --load-state complete --timeout-ms 15000
cmux browser surface:2 snapshot --interactive
cmux browser surface:2 click "button[type='submit']" --snapshot-after
cmux browser surface:2 fill "#email" --text "$EMAIL"
cmux browser surface:2 screenshot --out /tmp/cmux-preview.png
cmux browser surface:2 console list
cmux browser surface:2 errors list
```

State and debugging:

```bash
cmux browser surface:2 cookies get
cmux browser surface:2 storage local get theme
cmux browser surface:2 state save /tmp/cmux-browser-state.json
```

Some advanced browser controls, such as network routing, tracing, viewport,
geolocation, offline mode, screencast, and low-level input, may return
`not_supported` depending on the current cmux browser engine. Prefer
console/errors/screenshot/state commands for portable automations.

## Markdown, Notifications, and Sidebar

```bash
cmux markdown open plan.md --direction right --focus false
cmux notify --title "Tests passed" --body "bun test completed"
cmux list-notifications
cmux jump-to-unread
cmux set-status ci "running"
cmux set-progress 0.4 --workspace workspace:2
cmux log --workspace workspace:2 "Started smoke test"
cmux sidebar-state --json
cmux right-sidebar show
cmux right-sidebar mode dock
```

These commands are useful for scripts that should keep humans oriented while
work runs in the background.

## Events and Hooks

```bash
cmux events --json
cmux hooks setup --yes
cmux hooks setup --agent codex --yes
cmux hooks feed --source codex
cmux feed tui --opentui
```

Use `cmux events` for reactive scripts. Use hooks for agent lifecycle,
permission, question, and completion events.

## Config and Docs

```bash
cmux docs settings
cmux docs dock
cmux config validate
cmux reload-config
cmux settings cmux-json
cmux shortcuts
cmux themes list
```

Use `cmux <command> --help` when a command shape is unclear. Prefer documented
commands over raw `cmux rpc` unless there is no stable CLI wrapper.
