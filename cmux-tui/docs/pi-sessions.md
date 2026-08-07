# Persistent Pi sessions

Run Pi inside a named cmux TUI session on the SSH host. The TUI daemon owns the PTY, so Pi keeps running when an SSH client disconnects.

```sh
cmux-tui --headless --session agents
cmux-tui agent hooks install pi
cmux-tui attach --session agents
```

The installed Pi extension reads the durable terminal ID from `CMUX_TUI_TERMINAL_ID` and reports Pi's real `ctx.sessionManager.getSessionId()` through the local `CMUX_TUI_SOCKET`. It never assigns a Pi session ID. Reconnecting clients can inspect and attach to the same terminal:

```sh
cmux-tui --session agents agent list
cmux-tui attach --session agents --terminal term_...
```

## SSH security boundary

The daemon, PTY, Pi process, hook, and Unix socket all stay on the SSH host. A client connects with `cmux-tui relay --session agents` over SSH standard input and output. Do not reverse-forward a local cmux socket, copy a local relay credential to the host, or expose arbitrary local RPC. The SSH transport uses `ClearAllForwardings=yes` and `ForwardAgent=no`; future macOS `cmux ssh` integration must preserve this client-to-remote authority direction.
