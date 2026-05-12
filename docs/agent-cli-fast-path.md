# Agent CLI Fast Path

`cmux agent` is the low-overhead command surface for coding-agent loops that
would otherwise call MCP for every pane read, send, or list operation.

The command is intentionally thin:

- Agents call it with a shell/Bash tool.
- The CLI talks to the running cmux app over the existing local Unix socket.
- No MCP JSON-RPC server, WebSocket bridge, or Node forwarding process is in the
  hot path.
- `batch` runs several operations through one CLI process and one socket
  connection.

## Commands

```bash
cmux agent capture [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>] [--raw]
cmux agent send [--workspace <id|ref>] [--surface <id|ref>] [--enter] [--] <text>
cmux agent send-key [--workspace <id|ref>] [--surface <id|ref>] [--] <key>
cmux agent list-panes [--workspace <id|ref>]
cmux agent list-surfaces [--workspace <id|ref>]
cmux agent batch [--file <path>] <json>
```

All commands print JSON by default. `capture --raw` prints only terminal text
for tools that want tmux-style capture output.

## Batch

Batch input can be an inline JSON array, `--file`, or stdin:

```bash
cmux agent batch '[
  {"op": "list-panes"},
  {"op": "capture", "scrollback": true, "lines": 200}
]'
```

Supported batch operation names:

- `capture`, `read`, `read-screen`
- `send`
- `send-key`, `key`
- `list-panes`, `panes`
- `list-surfaces`, `surfaces`, `list-panels`, `panels`

Use `workspace` and `surface` fields to target explicit cmux handles. When they
are omitted, cmux uses the caller context from `CMUX_WORKSPACE_ID` and
`CMUX_SURFACE_ID`, matching the existing CLI command behavior.

Batch prints one result per operation. If any operation fails, the command exits
non-zero with `"ok": false`, while preserving earlier successful results and the
per-operation error payload.
