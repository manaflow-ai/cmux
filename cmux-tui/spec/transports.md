# Transport Contract

The command schema is transport-independent. Protocol v5 introduced the Unix domain socket JSON-lines transport. Protocol v6 also implements an opt-in WebSocket transport with the same command and event payloads. Protocol v7 leaves both framing contracts unchanged and adds render-mode negotiation at the command layer. HTTP and SSE remain proposals.

## Protocol Negotiation

The current server reports `protocol:9` from `identify` and `ping`. Clients must inspect `identify.protocol` before using versioned additions. A client selecting `attach-surface` with `mode:"render"` must require `protocol >= 7`; on protocol 6 it must use the default byte mode or refuse the attachment. A client requiring stable split ids or sending `set-split-ratio` must require protocol 8. A client decoding stack layouts or sending `new-pane` must require protocol 9.

There is no transport-level version preamble. Omitting `attach-surface.mode` selects `"bytes"`, and omitting `subscribe.tree_events` selects `"coarse"`; those defaults preserve the exact protocol-v6 attach and tree-event behavior. Unix socket paths, WebSocket upgrade/authentication, request ids, response envelopes, and message framing do not change in protocol 7.

## Unix Socket

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 5 |

### Path Resolution

The server resolves the runtime root in this order:

```text
$XDG_RUNTIME_DIR
$TMPDIR
/tmp
```

It appends `cmux-tui-<uid>/<session>.sock`. When that path exceeds the platform Unix-socket limit, the server uses its short `/tmp` fallback. The TUI exports the resolved path to child surfaces as `CMUX_TUI_SOCKET` and legacy `CMUX_MUX_SOCKET`. SDKs must prefer an explicit socket or `CMUX_TUI_SOCKET`, then implement the same resolution algorithm.

Protocol v9 does not validate session text before joining it into the path. Callers must currently restrict session names to `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and reject `.`, `..`, separators, and control characters. vNext makes that validation mandatory in the server.

The `cmux-tui` process accepts `--session <name>` to select the default socket name and `--socket <path>` to override the path. The socket contains no canonical state. Workspace identity/order, mutation results/tombstones, and frontend projections are stored in SQLite under the platform state directory (macOS: `~/Library/Application Support/cmux-tui/sessions`), or under `--state <root>`. An explicit socket does not change the state root. `--ephemeral` selects an in-memory registry and is mutually exclusive with `--state`.

A normal non-headless invocation first attempts to attach when its selected
socket already exists. This happens before state-root selection, so `--state`
and `--ephemeral` do not force a new owner when that socket is live; use a
unique session or socket to isolate ownership. If no daemon accepts the
connection, those flags apply to the newly created owner.

One process holds an exclusive cross-platform writer lease for each session
database. SQLite uses WAL, foreign keys, `synchronous=FULL`, and macOS
`fullfsync`. A second daemon for the same state/session fails startup instead
of racing. Corruption or an unsupported schema also fails closed; the daemon
never silently falls back to ephemeral state.

### Framing And Canonical Envelope

Each request is one UTF-8 JSON object followed by `\n`. Empty or whitespace-only lines are ignored. Each command response is one JSON object followed by `\n`.

Connections are full duplex after `subscribe` or `attach-surface`. Event lines and response lines may be interleaved. Each line is complete JSON. Clients must route by `event` vs `id`.

This section is the canonical request and response envelope definition for all transports. `commands.md` defines command-specific fields and response `data` shapes.

Request envelope:

```text
object{id?:any,cmd:string,...command params}
```

Response envelope:

```text
object{id?:any,ok:true,data:any}
| object{id?:any,ok:false,error:string}
```

Decode errors return:

```text
object{ok:false,error:"bad request: ..."}
```

### Id Correlation

The v9 server echoes any JSON request `id` unchanged. Portable SDKs restrict ids to strings or JavaScript-safe integers and keep them unique among pending requests. Other JSON shapes have no portable equality contract.

Event lines do not carry request ids.

### Security Model

The v5 socket security model is filesystem permissions:

| Path | Mode |
| --- | --- |
| Runtime directory | `0700` |
| Socket file | `0600` |

When binding, the server creates the runtime directory if needed, refuses to clobber a live socket, removes a stale socket, binds the listener, and then sets socket permissions. On clean shutdown, it removes the socket file.

Access to the Unix socket is equivalent to access to the mux session. A client can type into PTYs, read screens, close surfaces, and change focus. Hosts must keep the runtime directory private.

The Unix socket does not use the WebSocket auth preamble. Its filesystem permissions remain the access boundary.

`CMUX_TUI_SOCKET` and `CMUX_MUX_SOCKET` inherited by a child are ambient full-session capabilities. Untrusted child processes must not inherit them.

### Implemented v9 limits

WebSocket protocol messages are limited to 4 MiB. Unix JSON-lines readers and relay readers currently have no equivalent application limit and may buffer an unterminated line. SDK readers also differ. This is a v9 security limitation, not permission to send unbounded messages.

vNext applies a 4,194,304-byte client-to-server UTF-8 message limit on every transport and a 16,777,216-byte server-to-client limit. The JSON-lines delimiter is excluded. A receiver closes on an oversized message or invalid UTF-8. WebSocket limits apply after reassembly, and an oversized WebSocket closes with code `1009`.

## Relay Stdio

| Field | Value |
| --- | --- |
| status | implemented client transport primitive |
| since | protocol 9 client |

`cmux-tui relay` copies bytes between stdin/stdout and one existing local Unix session socket:

```text
cmux-tui relay --session main
cmux-tui relay --socket /absolute/path/to/session.sock
```

Relay does not start a mux server, render a TUI, authenticate a caller, or interpret command payloads. Its stdout contains only server protocol bytes. When stdin is a terminal because a provider allocated a PTY, relay enables raw terminal mode for its lifetime to prevent echo and newline conversion. Providers should use a pipe when possible.

The implemented SSH machine connector starts relay as:

```text
ssh -T [-p PORT] [-i IDENTITY_FILE] -- [USER@]HOST 'BINARY' relay --session SESSION
```

SSH supplies authentication, encryption, host verification, and process transport. The connector splits child stdout and stdin into independently owned reader and writer halves. Its JSON-lines adapter removes one line delimiter before giving a complete message to `RemoteSession` and appends one delimiter when sending. EOF cancels pending session requests and closes the child process transport.

Complete-message framing is the session-client boundary. Unix sockets and relay stdio use JSON lines. WebSocket adapters use one text frame per message without adding a newline. A future transport can supply different framing without changing terminal mirroring or the machine rail.

Relay grants the remote SSH principal the authority of the selected local Unix socket. Deployments must restrict SSH admission and the remote socket with the same care as direct socket access.

The server classifies relay traffic as Unix because relay terminates at the Unix socket. The remote SSH principal therefore receives local-admin operations, including `shutdown-daemon` and `pairing-response`. Deployments that need less authority must use a future distinct relay profile.

## WebSocket

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 6 |

WebSocket is opt-in and can run alongside either the local TUI or `--headless`:

```text
cmux-tui --ws 127.0.0.1:7681
cmux-tui --headless --ws 127.0.0.1:7681
```

The equivalent config is:

```json
{"server":{"ws":"127.0.0.1:7681"}}
```

`server.ws` and the `--ws` value are socket addresses (`IP:port`, with brackets around IPv6). The command-line flag takes precedence over config. WebSocket is disabled when neither is set.

### Framing

Each client request is one UTF-8 JSON object in one reassembled WebSocket text message. Each response or event is one complete JSON object in one text message. RFC 6455 fragmentation is transport-internal. Do not append a newline. Responses and events may be interleaved after `subscribe` or `attach-surface`, exactly as on the Unix socket. For a selected protocol feature, the request/response envelopes, command names, event payloads, attach ordering, and base64 encoding are identical across Unix and WebSocket transports.

Transport compression is not part of the cmux-tui contract. Clients cannot require it for correctness.

Binary frames are not protocol messages and cause the connection to close. The server accepts a normal WebSocket upgrade on any request path and does not require a WebSocket subprotocol.

This framing exactly matches the TypeScript SDK's `WebSocketTransport`: `send(json)` sends that string as one text frame, and every received text frame is delivered as one complete JSON message.

### Authentication and Pairing

Every WebSocket authenticates before protocol commands are dispatched. Interactive clients request pairing as their first frame:

```json
{"pair":{"request":true}}
```

The server returns a 60-second six-digit challenge. It sends the same challenge to trusted Unix-socket subscribers as `pairing-requested`. A local or attached TUI approves or denies it. Approval authorizes the waiting socket and returns an eight-hour reconnect credential. The comparison code is not a secret.

Set `--ws-token <token>` or `server.ws_token` to add a non-interactive static-token bypass; the command-line flag takes precedence over config:

```json
{"server":{"ws":"127.0.0.1:7681","ws_token":"replace-with-a-secret"}}
```

Static and server-issued reconnect credentials use this transport-level preamble:

```json
{"auth":{"token":"replace-with-a-secret"}}
```

The preamble is not a protocol command, has no `id`, and receives no success response. After sending it, the client may immediately send normal protocol requests. A missing, malformed, oversized, or incorrect authentication or pairing frame closes the connection with WebSocket policy code `1008` before dispatch. Pre-authentication frames are capped at 4 KiB, and authenticated protocol frames are capped at 4 MiB.

The listener permits one pending request per source address, five starts per minute per address, 16 pending challenges, 64 total sockets, and 4 MiB frames. Pairing expires after 60 seconds and at most 64 reconnect credentials remain valid in memory.

The current listener accepts every WebSocket Origin and request path. A browser challenge identifies only its TCP peer, which is normally loopback. Deployments must not treat pairing as an Origin check. vNext adds an explicit Origin allowlist and includes normalized Origin and path in the trusted approval prompt.

### Bind Security

By default the listener accepts only an IP loopback address such as `127.0.0.1` or `[::1]`. cmux-tui refuses a non-loopback address unless `--ws-insecure-bind` is also present. This listener provides no TLS; for remote access, bind deliberately and place it behind a TLS-terminating, authenticated reverse proxy. An authenticated WebSocket client can read terminal contents, type into PTYs, and use ordinary control and frontend mutations, including closing session topology. It cannot use Unix-only `local-admin` commands: `shutdown-daemon` and `pairing-response` reject WebSocket callers. Provider-owned workspace commits also require their separate provider authority.

Static tokens and reconnect credentials are bearer credentials with ordinary control and frontend authority, excluding `local-admin` and `provider-authority`. Reconnect credentials are memory-only, survive for eight hours, are invalid after daemon restart, and have no v9 list or revoke API. Prefer secret files over process arguments when a future `--ws-token-file` becomes available. Credentials must never appear in URLs, logs, debug output, or generated diagnostics.

## Concurrency, streams, and reconnect

The v9 server begins commands serially in receive order on each connection. A blocking `wait-for` delays later commands on that connection. A client request timeout stops local waiting only; it does not cancel execution, and a late mutation may still commit.

Repeated `subscribe` calls and repeated attachments create independent server streams without public stream ids. Closing a local iterator on a shared connection does not cancel its server stream. A v9 client that needs independent cancellation uses a dedicated connection and closes it. On one shared connection, use at most one subscription and one attachment per surface.

The server event broadcaster holds 4,096 events per subscriber. The connection writer also has a 256-message, 16 MiB regular queue and a separate 256-message, 16 MiB control reserve. Stream overflow discards that stream's queued events, emits one stream-scoped `overflow`, and can leave unrelated streams and command responses usable. Exhausting the control reserve or the two-second write deadline closes the connection.

A reconnect creates a new transport generation. Old pending ids, event buffers, and stream handles never cross generations. A client resends authentication, calls `identify`, registers subscriptions before fetching snapshots, checks generation values, and reattaches surfaces. Network loss uses capped exponential delay with jitter and one in-flight attempt. Static-token rejection is terminal. Reconnect-credential rejection discards that credential once and enters one pairing attempt. Pairing denial, expiry, or rate limiting requires user action.

vNext adds client-generated `stream_id` to `subscribe` and `attach-surface`, echoes it on every event, and adds idempotent `cancel-stream`. Request timeout remains distinct from stream cancellation.

## HTTP

| Field | Value |
| --- | --- |
| status | proposed |
| since | proposed protocol 10 |

HTTP is opt-in. The server binds localhost by default when enabled:

```text
cmux-tui --http 127.0.0.1:0
```

The implementation must not bind a non-loopback address unless the user explicitly supplies one. HTTP is disabled unless a bearer token exists or the user passes `--http-insecure-localhost`.

### Command Endpoint

All commands use a single endpoint:

```text
POST /api/v1/command
```

The request body is the same JSON command object used on the socket:

```json
{"id":1,"cmd":"read-screen","surface":1}
```

The response body is the same response envelope:

```json
{"id":1,"ok":true,"data":{"text":"ready> "}}
```

The API intentionally does not expose a REST resource tree. Command names, params, results, and errors stay 1:1 with `commands.md`.

### Events Endpoint

Subscribe events use server-sent events:

```text
GET /api/v1/events
```

Optional query parameters mirror proposed `subscribe` filters:

```text
GET /api/v1/events?events=bell,agent-state-changed&surfaces=1,a8f3k2
```

Each event is sent as:

```text
event: mux
data: {"event":"bell","surface":1}

```

Clients must parse the JSON in `data`. The SSE stream does not send command responses.

### Attach Endpoint

Attach streams use WebSocket:

```text
GET /api/v1/attach/{surface}
```

`{surface}` accepts an implemented numeric id or, when protocol v6 short ids are enabled, a short id. WebSocket messages are text JSON objects using the same `vt-state`, `resized`, `output`, `colors-changed`, and `detached` event schemas from `events.md`.

The attach ordering contract is identical to the socket `attach-surface` command for the negotiated protocol. Protocol v5 sends `vt-state`, then live `output`, then `detached`. Protocol v6 sends `vt-state`, then zero or more `resized`, `output`, or `colors-changed` events, then `detached`; each `resized` event carries a fresh replay and requires the client to replace its mirror before applying later output. The additive `vt-state.colors` object and `colors-changed` event have the same schema on every transport.

## HTTP Auth

| Field | Value |
| --- | --- |
| status | proposed |
| since | proposed protocol 10 |

When HTTP is enabled securely, the server mints one token per mux session at:

```text
$RUNTIME/<session>.token
```

`$RUNTIME` is the same directory that contains the Unix socket. The token file must be owner-readable only. Clients send:

```text
Authorization: Bearer <token>
```

The server compares bearer tokens using constant-time comparison. Missing, malformed, or wrong tokens fail before command dispatch.

Auth error responses:

| HTTP status | Body | Condition |
| --- | --- | --- |
| `401` | `{"ok":false,"error":"missing bearer token"}` | Header absent |
| `401` | `{"ok":false,"error":"bad authorization header"}` | Header does not use bearer format |
| `403` | `{"ok":false,"error":"invalid bearer token"}` | Token compare fails |
| `403` | `{"ok":false,"error":"http disabled without token"}` | HTTP requested without token and without insecure localhost opt-in |

Non-auth error responses:

| HTTP status | Body | Condition |
| --- | --- | --- |
| `200` | normal response envelope | Command decoded and dispatched, even when `ok:false` |
| `400` | `{"ok":false,"error":"bad request: ..."}` | Malformed JSON or request shape |
| `404` | `{"ok":false,"error":"not found"}` | Unknown HTTP path |
| `405` | `{"ok":false,"error":"method not allowed"}` | Wrong method for path |
| `500` | `{"ok":false,"error":"internal server error"}` | Transport-level server failure before command dispatch |

`--http-insecure-localhost` permits HTTP without a token only when the bind address is loopback. It must fail for non-loopback binds.
