# Transport Contract

The command schema is transport-independent. Protocol v5 introduced the Unix domain socket JSON-lines transport. Protocol v6 also implements an opt-in WebSocket transport with the same command and event payloads. Protocol v7 leaves both framing contracts unchanged and adds render-mode negotiation at the command layer. HTTP and SSE remain proposals.

## Protocol Negotiation

The current server reports `protocol:10` from `identify` and `ping`. Clients must inspect `identify.protocol` before using versioned additions. A client selecting `attach-surface` with `mode:"render"` must require `protocol >= 7`; on protocol 6 it must use the default byte mode or refuse the attachment. A client requiring stable split ids or sending `set-split-ratio` must require protocol 8. A client decoding stack layouts or sending `new-pane` must require protocol 9. A client using `set-client-sizing` must require protocol 10 and include its target surface.

There is no transport-level version preamble. Omitting `attach-surface.mode` selects `"bytes"`, and omitting `subscribe.tree_events` selects `"coarse"`; those defaults preserve the exact protocol-v6 attach and tree-event behavior. Unix socket paths, WebSocket upgrade/authentication, request ids, response envelopes, and message framing do not change in protocol 7.

## Unix Socket

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 5 |

### Path Resolution

The default socket path for a session is:

```text
$TMPDIR/cmux-tui-<uid>/<session>.sock
```

The implementation uses Rust `std::env::temp_dir()` for `$TMPDIR`, appends `cmux-tui-<uid>`, and then appends `<session>.sock`. The TUI exports the resolved path to child surfaces as `CMUX_TUI_SOCKET` and legacy `CMUX_MUX_SOCKET`.

The `cmux-tui` process accepts `--session <name>` to select the default socket name and `--socket <path>` to override the path. The socket contains no canonical state. Workspace identity/order, mutation results/tombstones, and frontend projections are stored in SQLite under the platform state directory (macOS: `~/Library/Application Support/cmux-tui/sessions`), or under `--state <root>`. An explicit temporary `--socket` derives an isolated `<socket>.state` root unless `--state` is supplied. `--ephemeral` selects an in-memory registry and is mutually exclusive with `--state`.

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

The server echoes the request `id` value unchanged for decoded command responses. `id` may be any JSON value. The server does not require ids to be unique, but clients that pipeline requests need unique ids to correlate responses.

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

Each client request is one UTF-8 JSON object in one WebSocket text frame. Each response or event is one complete JSON object in one WebSocket text frame. Do not append a newline. Responses and events may be interleaved after `subscribe` or `attach-surface`, exactly as on the Unix socket. For a selected protocol feature, the request/response envelopes, command names, event payloads, attach ordering, and base64 encoding are identical across Unix and WebSocket transports.

WebSocket `permessage-deflate` may be negotiated as optional transport compression. Compression is hop-by-hop WebSocket behavior, not part of the cmux-tui protocol: clients cannot require it for correctness, payload schemas remain JSON text, and intermediaries may enable or disable it independently.

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

### Bind Security

By default the listener accepts only an IP loopback address such as `127.0.0.1` or `[::1]`. cmux-tui refuses a non-loopback address unless `--ws-insecure-bind` is also present. This listener provides no TLS; for remote access, bind deliberately and place it behind a TLS-terminating, authenticated reverse proxy. A WebSocket client has the same authority as a Unix socket client: it can read terminal contents, type into PTYs, and mutate or close the session.

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
