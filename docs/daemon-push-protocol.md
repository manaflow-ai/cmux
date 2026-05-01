# Daemon push protocol (Phase 0 spec)

This is the protocol contract for the push-based daemon architecture. It is the source of truth that Phase 1-4 implementations must match. Companion documents: `docs/remote-daemon-spec.md` (current RPC surface) and `docs/notifications.md` (notification UX).

## 0.1 Message envelope

Every frame on the wire is a single JSON object followed by a newline (for line-delimited transports) or one WebSocket text frame.

Responses correlate to client-initiated requests. They always carry an `id` that matches the request.

```
Request:   { "id": 42, "method": "terminal.subscribe", "params": { ... } }
Response:  { "id": 42, "ok": true,  "result": { ... } }
Response:  { "id": 42, "ok": false, "error":  { "code": "...", "message": "..." } }
```

Events are server-pushed notifications. They never carry an `id`. They always carry `event` (string) and `seq` (monotonic u64, per-connection).

```
Event:     { "event": "terminal.output", "seq": 137, "session_id": "...", ... }
Event:     { "event": "workspace.changed", "seq": 138, ... }
```

Client dispatch rule: check for the `id` field first. If present, it is a response and must be routed to the matching pending request. If absent, check `event` and dispatch by name. Clients MUST NOT match on substring; exact JSON field dispatch only. This replaces the current `event.contains("workspace.changed")` style.

Backwards compatibility: existing `workspace.changed` events already omit `id` and set `event: "workspace.changed"`. New events follow the same shape.

## 0.2 Offsets and ring buffer semantics

Two distinct buffers with different purposes:

- **Session ring buffer** (per-session, 1 MB default). Raw PTY bytes. When full, oldest bytes are evicted and `base_offset` advances. This is the source of truth for terminal history.
- **Subscriber outbound queue** (per subscriber, 4 MB cap). Buffered push frames waiting for network write. This handles slow consumers. It is not durable state.

Offsets are byte positions in the raw PTY output stream. They are monotonically increasing from 0 at session start. A client is always caught up as of some offset; the next push it expects starts at exactly that offset.

Reconnect rules:

| Client's saved offset | Daemon action                                              | Client action                           |
|-----------------------|------------------------------------------------------------|-----------------------------------------|
| `offset >= base_offset` | Send pending data from `offset` onward                    | Normal resume. No terminal reset.       |
| `offset <  base_offset` | Send data from `base_offset`, set `truncated: true`       | Clear screen + replay. State reset.     |

Event payload:

```json
{
  "event": "terminal.output",
  "seq": 42,
  "session_id": "ws-abc",
  "data": "<base64>",
  "offset": 12345,
  "base_offset": 0,
  "truncated": false,
  "eof": false,
  "notifications": null
}
```

`offset` is the byte position immediately after `data`, also called the end offset. The first byte of `data` is at `offset - len(decoded data)`. Clients should save `offset` for the next reconnect. `eof: true` means the PTY closed; no more output will arrive for this session.

## 0.3 Backpressure

Invariants:

- The PTY pump thread NEVER blocks on subscriber network I/O. Writes to per-subscriber outbound queues are non-blocking; if a queue is full the subscriber is marked for disconnect.
- Per-subscriber outbound queue is bounded at **4 MB**. Larger limits (16 MB, unbounded) increase OOM risk when many clients are attached. 4 MB is sized for normal terminal bursts; `cat /dev/urandom | base64` will overrun it and trigger disconnect within seconds, which is the intended recovery path.
- On queue overflow the daemon CLOSES the subscriber's socket. The client reconnects via the normal reconnect path with its last known offset. There is no special "kicked" state.

Fairness: `terminal.output` is latency-sensitive and gets priority in the outbound queue. To prevent control-plane starvation under sustained terminal output, the write pump delivers at least one queued `workspace.changed` event every 100 ms while terminal output is flowing.

## 0.4 Capability negotiation

The `hello` response lists the capabilities this daemon supports. Clients check this list and fall back to legacy paths when a capability is missing.

```json
{
  "id": 1,
  "ok": true,
  "result": {
    "name": "cmuxd-remote",
    "version": "...",
    "workspace_count": 3,
    "capabilities": [
      "session.basic",
      "session.resize.min",
      "session.resize.owner",
      "terminal.stream",
      "terminal.subscribe",
      "workspace.subscribe",
      "proxy.http_connect",
      "proxy.socks5",
      "proxy.stream"
    ]
  }
}
```

New capabilities introduced by this plan:

- `terminal.subscribe` — client can use `terminal.subscribe` + `terminal.output` push instead of polling `terminal.read`.
- `workspace.subscribe` — client can use `workspace.subscribe` + `workspace.changed` push (already shipped).
- `notifications.push` — `terminal.output` events may include a `notifications` field populated from parsed OSC.
- `notifications.remote` — the daemon accepts `daemon.configure_notifications` and dispatches an HTTP push (for APNs delivery) when a notification fires on a session with no live subscribers. See §0.7.

Mismatch behavior:

- **Old client + new daemon**: daemon does NOT push unsolicited events on connections that have not subscribed. Legacy request-response stays intact. Client falls back to `terminal.read` when it does not see `terminal.subscribe` in capabilities.
- **New client + old daemon**: client inspects capabilities, and falls back to `terminal.read` polling when `terminal.subscribe` is absent.

Events are ONLY pushed to connections that explicitly called the matching subscribe RPC. A connection that never subscribed receives only responses to its own requests.

## 0.5 Transport vs session lifetime

The socket and the subscription are independent lifetimes.

- **Transport** (`DaemonConnection` on macOS, `TerminalRemoteDaemonSessionTransport` on iOS) owns the socket, framing, and reconnection. When the network drops, the transport reconnects.
- **Subscription state** lives on the client side as `{session_id, last_offset}` pairs. On reconnect the client re-sends `terminal.subscribe(session_id, offset=last_offset)` for every session it was subscribed to. The daemon replays from `last_offset` (or from `base_offset` with `truncated: true` if it cannot).

The daemon side MAY keep per-connection subscriber state; when the connection dies, the daemon cleans up its subscriber entry. The CLIENT is responsible for restoring subscriptions after reconnect. The daemon does not persist subscriber identity across sockets.

## 0.6 OSC parsing scope

The daemon parses ONLY the sequences below. Everything else flows through unchanged.

| Sequence                   | Action                                                          |
|----------------------------|-----------------------------------------------------------------|
| `BEL` (0x07)               | Increment `bell_count` on the session                           |
| `OSC 0;title ST/BEL`       | Store `last_title` (window title)                               |
| `OSC 2;title ST/BEL`       | Store `last_title` (window title, variant)                      |
| `OSC 7;file://... ST/BEL`  | Store `last_directory` (working directory hint)                 |
| `OSC 99;key=val;... ST/BEL` | Store structured notification (Kitty protocol). Keys: `i`, `d`, `p`, `o`, `a`, `t` for title, `b` for body; concrete subset documented by the OSC state machine implementation in Phase 4.1 |
| `OSC 133;D;<exit_code> ST/BEL` | Store `last_command_exit_code`, set `command_finished = true` |

String terminator (`ST`) is `ESC \` (0x1B 0x5C). `BEL` also terminates OSC. The state machine handles both.

The state machine MUST tolerate sequences split across `feed()` calls, partial escape at chunk boundaries, and UTF-8 multi-byte characters inside title/body fields. On buffer overflow (reasonable cap, e.g. 4 KB per in-progress OSC) the state machine returns to ground and discards the in-progress sequence; it does not crash and does not leak.

CSI, DCS, and other escape sequences are out of scope for daemon-level parsing. They pass through to the terminal emulator on the client side.

## 0.7 Remote notification push (APNs via HTTP endpoint)

For mobile clients that are not connected to the daemon when a notification fires (bell / command finished / OSC 99), the daemon can relay the event to an HTTP endpoint (e.g. a Next.js route on Vercel) which in turn pushes via APNs. This is capability `notifications.remote`.

Configuration RPC:

```
Request:  { "id": 5, "method": "daemon.configure_notifications", "params": {
  "endpoint": "https://example.vercel.app/api/notifications/push",
  "bearer_token": "<shared secret>",
  "device_tokens": ["<apns-device-token-hex>", ...]
}}
Response: { "id": 5, "ok": true, "result": { "configured": true } }
```

Subsequent calls replace the config wholesale. Passing `endpoint: ""` disables remote push entirely. Passing a non-empty endpoint but `device_tokens: []` disables pushes while keeping the endpoint/token strings around for future reconfiguration.

Dispatch rules (daemon side):

1. Trigger only when a notification actually fires, i.e. `bell_count`, `command_seq`, or `notification_seq` on the session advanced since the daemon last dispatched a remote push for that session.
2. Trigger only when the session has NO live terminal.subscribe subscribers on any connection.
3. Trigger only when both `endpoint` and `device_tokens` are non-empty.

If all three hold, the daemon POSTs JSON to `endpoint` on a detached dispatcher thread (never blocks the PTY pump thread):

```
POST <endpoint>
Authorization: Bearer <bearer_token>
Content-Type: application/json
Content-Length: <n>

{
  "device_tokens": ["<hex>", "<hex>"],
  "session_id": "ws-abc",
  "workspace_id": "<uuid-or-null>",
  "notifications": {
    "bell": true,
    "command_finished": { "exit_code": 0 } | null,
    "notification": { "title": "...", "body": "..." } | null
  }
}
```

- `bell` is `true` when the session's `bell_count` advanced since the last remote push, otherwise `false`.
- `command_finished` is the OSC 133;D payload (or null if not advanced).
- `notification` is the OSC 99 payload (or null if not advanced).
- `workspace_id` is the workspace that currently contains the session, or `null` if the session is not bound to any workspace (e.g. during bootstrap).

Timeout: 5 seconds on both send and receive (via `SO_SNDTIMEO`/`SO_RCVTIMEO` for `http://`, via `curl --max-time 5` for `https://`). Non-2xx status, network error, or timeout is logged and dropped without retry. APNs retry policy is the endpoint's responsibility.

Current daemon implementation: the Zig 0.15.2 `std.http.Client` has a latent compile-time bug in `ConnectionPool.resize` which blocks a clean watchdog-based timeout on top of `fetch`. Until that is fixed upstream, the daemon ships a hand-rolled minimal HTTP/1.1 POST over `std.net.Stream` for `http://` endpoints. HTTPS endpoints are supported via a bundled `curl` subprocess (`curl -sS --fail --max-time 5 -X POST -H "Authorization: Bearer ..." -H "Content-Type: application/json" --data-binary @- <endpoint>`), which handles TLS and timeout enforcement outside the daemon process. The daemon requires `curl` on `PATH`; if it is missing, HTTPS pushes are logged once and silently dropped.

## Implementation pointers

- Capability string addition: `daemon/remote/zig/src/server_core.zig` `handleLine` / hello handler (around lines 48-66).
- Subscriber list plumbing: `daemon/remote/zig/src/session_service.zig` (reuse existing `subscriptions` pattern).
- Unix socket read/write separation: `daemon/remote/zig/src/serve_unix.zig`.
- WebSocket dispatch: `daemon/remote/zig/src/serve_ws.zig`.
- OSC state machine: `daemon/remote/zig/src/terminal_session.zig`.
- Remote push config + dispatcher (§0.7): `daemon/remote/zig/src/session_service.zig` — `RemoteNotificationConfig`, `Service.configureNotifications`, `Service.maybePushRemoteNotification`, `simpleHttpPost`.
- `daemon.configure_notifications` RPC handler: `daemon/remote/zig/src/server_core.zig` `handleConfigureNotifications`.
- Swift unified connection: new file `Sources/Sync/DaemonConnection.swift` replaces `DaemonTerminalBridge.swift` and `WorkspaceDaemonBridge.swift`.
- iOS transport: `ios/Sources/Terminal/TerminalRemoteDaemonSessionTransport.swift`.
