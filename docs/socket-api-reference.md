# cmux Socket API Reference

JSON-RPC API over Unix domain socket for programmatic control of cmux.

**Source:** https://cmux.com/docs/api

## Socket Configuration

| Build Type | Path |
|------------|------|
| Release | `/tmp/cmux.sock` |
| Debug | `/tmp/cmux-debug.sock` |
| Tagged debug | `/tmp/cmux-debug-<tag>.sock` |

Override with `CMUX_SOCKET_PATH` env var.

## Protocol

Newline-terminated JSON. Every request has `id`, `method`, `params`. Every response has `id`, `ok`, `result`.

```json
// Request
{"id":"req-1","method":"workspace.list","params":{}}

// Response
{"id":"req-1","ok":true,"result":{"workspaces":[...]}}
```

## Access Modes

| Mode | Description | How to Enable |
|------|-------------|---------------|
| **Off** | Socket disabled | Settings UI or `CMUX_SOCKET_MODE=off` |
| **cmux processes only** | Only cmux-spawned processes | Default |
| **allowAll** | Any local process | `CMUX_SOCKET_MODE=allowAll` |

Legacy values `"full"` and `"notifications"` still accepted.

## CLI Flags

| Flag | Description |
|------|-------------|
| `--socket PATH` | Custom socket path |
| `--json` | JSON output |
| `--window ID` | Target window |
| `--workspace ID` | Target workspace |
| `--surface ID` | Target surface |
| `--id-format refs\|uuids\|both` | Identifier format in JSON output |

## API Methods

### System

| Method | CLI | Description |
|--------|-----|-------------|
| `system.ping` | `cmux ping` | Health check — returns `{"pong":true}` |
| `system.capabilities` | `cmux capabilities` | Lists available methods and access mode |
| `system.identify` | `cmux identify` | Returns focused window/workspace/pane/surface context |

```json
{"id":"ping","method":"system.ping","params":{}}
// → {"id":"ping","ok":true,"result":{"pong":true}}
```

### Workspaces

| Method | CLI | Description |
|--------|-----|-------------|
| `workspace.list` | `cmux list-workspaces` | List all workspaces |
| `workspace.create` | `cmux new-workspace` | Create new workspace |
| `workspace.select` | `cmux select-workspace --workspace <id>` | Switch to workspace |
| `workspace.current` | `cmux current-workspace` | Get active workspace |
| `workspace.close` | `cmux close-workspace --workspace <id>` | Close workspace |

```json
{"id":"ws-select","method":"workspace.select","params":{"workspace_id":"<id>"}}
```

### Surfaces & Splits

| Method | CLI | Description |
|--------|-----|-------------|
| `surface.split` | `cmux new-split <direction>` | Split pane (left/right/up/down) |
| `surface.list` | `cmux list-surfaces` | List surfaces in workspace |
| `surface.focus` | `cmux focus-surface --surface <id>` | Focus a surface |

```json
{"id":"split","method":"surface.split","params":{"direction":"right"}}
```

### Input

| Method | CLI | Description |
|--------|-----|-------------|
| `surface.send_text` | `cmux send "text"` | Send text to focused terminal |
| `surface.send_key` | `cmux send-key <key>` | Send keypress (enter/tab/escape/backspace/delete/up/down/left/right) |
| `surface.send_text` | `cmux send-surface --surface <id> "text"` | Send text to specific surface |
| `surface.send_key` | `cmux send-key-surface --surface <id> <key>` | Send key to specific surface |

```json
// Send to focused
{"id":"s1","method":"surface.send_text","params":{"text":"echo hello\n"}}

// Send to specific surface
{"id":"s2","method":"surface.send_text","params":{"surface_id":"<id>","text":"command"}}

// Send key to specific surface
{"id":"s3","method":"surface.send_key","params":{"surface_id":"<id>","key":"enter"}}
```

### Notifications

| Method | CLI | Description |
|--------|-----|-------------|
| `notification.create` | `cmux notify --title "T" --body "B"` | Create notification |
| `notification.list` | `cmux list-notifications` | List notifications |
| `notification.clear` | `cmux clear-notifications` | Clear all notifications |

```json
{"id":"n1","method":"notification.create","params":{"title":"Title","subtitle":"S","body":"Body"}}
```

### Sidebar Metadata

Status pills, progress bars, and log entries in the workspace sidebar.

**Status:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux set-status <key> <value> [--icon <name>] [--color <hex>]` | `set_status <key> <value> --icon=<name> --color=<hex> --tab=<uuid>` | Set status pill |
| `cmux clear-status <key>` | `clear_status <key> --tab=<uuid>` | Remove status entry |
| `cmux list-status` | `list_status --tab=<uuid>` | List status entries |

**Progress:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux set-progress <0.0-1.0> [--label "text"]` | `set_progress <val> --label=<text> --tab=<uuid>` | Set progress bar |
| `cmux clear-progress` | `clear_progress --tab=<uuid>` | Clear progress bar |

**Logs:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux log [--level <level>] [--source <name>] <msg>` | `log --level=<level> --source=<name> --tab=<uuid> -- <msg>` | Append log entry |
| `cmux list-log [--limit <n>]` | `list_log --limit=<n> --tab=<uuid>` | List log entries |
| `cmux clear-log` | `clear_log --tab=<uuid>` | Clear log entries |
| `cmux sidebar-state` | `sidebar_state --tab=<uuid>` | Dump all sidebar metadata |

Log levels: `info`, `progress`, `success`, `warning`, `error`

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Override socket path |
| `CMUX_SOCKET_ENABLE` | Force enable/disable socket (`1`/`0`, `true`/`false`, `on`/`off`) |
| `CMUX_SOCKET_MODE` | Override access mode (`cmuxOnly`, `allowAll`, `off`) |
| `CMUX_WORKSPACE_ID` | Auto-set: current workspace ID |
| `CMUX_SURFACE_ID` | Auto-set: current surface ID |
| `TERM_PROGRAM` | Set to `ghostty` |
| `TERM` | Set to `xterm-ghostty` |

## Detecting cmux

```bash
# Socket available?
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
[ -S "$SOCK" ] && echo "Socket available"

# CLI available?
command -v cmux &>/dev/null && echo "cmux available"

# Inside a cmux surface?
[ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ] && echo "Inside cmux"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] && echo "In cmux (not plain Ghostty)"
```

## Code Examples

### Python Client

```python
import json, os, socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

def rpc(method, params=None, req_id=1):
    payload = {"id": req_id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        return json.loads(sock.recv(65536).decode("utf-8"))

# List workspaces
print(rpc("workspace.list", req_id="ws"))

# Send notification
print(rpc("notification.create", {"title": "Hello", "body": "From Python!"}, req_id="notify"))
```

### Shell Script

```bash
#!/bin/bash
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"

cmux_rpc() {
    printf "%s\n" "$1" | nc -U "$SOCK"
}

cmux_rpc '{"id":"ws","method":"workspace.list","params":{}}'
cmux_rpc '{"id":"notify","method":"notification.create","params":{"title":"Done","body":"Task complete"}}'
```

### Build Script with Notification

```bash
#!/bin/bash
npm run build
if [ $? -eq 0 ]; then
    cmux notify --title "Build Success" --body "Ready to deploy"
else
    cmux notify --title "Build Failed" --body "Check the logs"
fi
```
