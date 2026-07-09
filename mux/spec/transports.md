# Transport Contract

The command schema is transport-independent. Protocol v5 implements a Unix domain socket JSON-lines transport. Protocol v6 proposes HTTP, SSE, and WebSocket transports that preserve the same command and event payloads.

## Unix Socket

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 5 |

### Path Resolution

The default socket path for a session is:

```text
$TMPDIR/cmux-mux-<uid>/<session>.sock
```

The implementation uses Rust `std::env::temp_dir()` for `$TMPDIR`, appends `cmux-mux-<uid>`, and then appends `<session>.sock`. The TUI exports the resolved path to child surfaces as `CMUX_MUX_SOCKET`.

The `cmux-mux` process accepts `--session <name>` to select the default socket name and `--socket <path>` to override the path.

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

### Optional Socket Token

Protocol v6 may add an optional token to the socket transport for parity with HTTP. Filesystem permissions remain the primary protection. The exact framing is deferred until the v6 implementation.

A compatible deferred design is an initial auth line before any command:

```text
{"auth":"<token>"}
{"ok":true}
```

If auth fails, the server responds with `{"ok":false,"error":"invalid token"}` and closes the connection. The Unix socket transport must not use the HTTP `Authorization` header because its framing is JSON-lines, not HTTP.

## HTTP

| Field | Value |
| --- | --- |
| status | proposed |
| since | proposed protocol 6 |

HTTP is opt-in. The server binds localhost by default when enabled:

```text
cmux-mux --http 127.0.0.1:0
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

`{surface}` accepts an implemented numeric id or, when protocol v6 short ids are enabled, a short id. WebSocket messages are text JSON objects using the same `vt-state`, `output`, and `detached` event schemas from `events.md`.

The attach ordering contract is identical to the socket `attach-surface` command for the negotiated protocol. Protocol v5 sends `vt-state`, then live `output`, then `detached`. Protocol v6 sends `vt-state`, then zero or more `resized` or `output` events, then `detached`; each `resized` event carries a fresh replay and requires the client to replace its mirror before applying later output.

## HTTP Auth

| Field | Value |
| --- | --- |
| status | proposed |
| since | proposed protocol 6 |

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
