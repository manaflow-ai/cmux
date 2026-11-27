# Transport Contract

This document covers private protocol-v12 transport negotiation. The public
resource protocol defines its transport parity in
[`resource-api-v2.md`](resource-api-v2.md).

The raw command schema is transport-independent. Protocol v5 introduced the Unix domain socket JSON-lines transport. Protocol v6 also implements an opt-in WebSocket transport with the same command and event payloads. Protocol v7 leaves both framing contracts unchanged and adds render-mode negotiation at the command layer. HTTP and SSE remain proposals.

## Protocol Negotiation

The current server reports `protocol:12` from `identify` and `ping`. Clients must inspect `identify.protocol` before using versioned additions. A client selecting `attach-surface` with `mode:"render"` must require `protocol >= 7`; on protocol 6 it must use the default byte mode or refuse the attachment. A client requiring stable split ids or sending `set-split-ratio` must require protocol 8. A client decoding stack layouts or sending `new-pane` must require protocol 9. A client using `set-client-sizing` must require protocol 10 and include its target surface. Protocol 11 changes terminal creation and `run` lifecycle response shapes and adds terminal renderer minting. Protocol 12 adds lifecycle readiness to the strict `identify` response. A client sending `shutdown-daemon` with `force:true` must require the additive `daemon-handoff-force-v1` capability. A remote TUI routing browser pointer input must also require the additive `browser-pointer-frame-guard-v1` capability and use its guarded command names; legacy clients can continue using the original optional-guard commands. A browser `attach-surface` connection must advertise that capability through `set-client-info` on the same socket before attaching. A client sending `new-pane-right` or interpreting `Screen.viewport_splits` must require the additive `viewport-splits-v1` capability. A client sending `set-viewport-pane-width` or interpreting `Screen.viewport_base_width` must require `viewport-column-resize-v1`. A client sending `set-column-dock` must require `dock-columns-v1`; a client without it ignores `Screen.columns[].dock`. A client sending `undo-layout` must require `layout-undo-v1`.

There is no transport-level version preamble. Omitting `attach-surface.mode` selects `"bytes"`, and omitting `subscribe.tree_events` selects `"coarse"`; those defaults preserve the exact protocol-v6 attach and tree-event behavior. Unix socket paths, WebSocket upgrade/authentication, request ids, response envelopes, and message framing do not change in protocol 7.

Byte viewers that keep their own theme advertise `terminal-color-overrides-v1`
using `set-client-info` before `attach-surface`. Supporting servers then add
application-authored special-color provenance to that attachment's color
sidecars (see `events.md`); unadvertised attachments keep the legacy wire shape.

Byte viewers that write their own sequences after a replay (color sidecars)
advertise `terminal-pending-sequence-v1` the same way. Their `vt-state` and
`resized` replays then end at a parser boundary and carry the incomplete
sequence separately as `pending`; unadvertised attachments receive those bytes
at the end of the replay instead.

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

It appends `cmux-tui-<uid>/<session>.sock`. When that path exceeds the
platform Unix-socket limit, the server first uses the same leaf below `/tmp`.
If the session leaf itself is still too long, the server and every SDK first
use `<runtime-base>/cmux-tui-hashed-<uid>/<sha256>.sock` when that path fits,
then use `/tmp/cmux-tui-hashed-<uid>/<sha256>.sock` only when the preferred
runtime base is also too long. Here `<runtime-base>` is the first non-empty
value of `XDG_RUNTIME_DIR`, `TMPDIR`, or `/tmp`, and `sha256` is the full
lowercase SHA-256 digest of the session's UTF-8 bytes. The separate directory
prevents a digest leaf from aliasing an ordinary session name. The TUI exports
the resolved path to child surfaces as `CMUX_TUI_SOCKET` and legacy
`CMUX_MUX_SOCKET`. SDKs must prefer an explicit socket or `CMUX_TUI_SOCKET`,
then implement the same byte-length and path-resolution algorithm. Empty
socket environment values are treated as unset.

The server validates session text before joining it into the path. A name must
be a non-empty single path component. `.`, `..`, `/`, `\\`, NUL, control
characters, and Unicode line separators are rejected. Existing names with
spaces, Unicode, leading punctuation, colons, or long text remain valid.
Clients that can target an older protocol-v9 server must apply the same
validation before computing a socket path. SDKs must expose a fallible
validation path before opening a derived socket. Legacy non-fallible helpers
must never join invalid text into the normal socket root; they may return a
distinct, hash-derived per-input error path for source compatibility. That
path is outside the normal `cmux-tui-<uid>` session directory and is never a
server-derived session socket. A compatibility hash is only a deterministic
namespace guard, not a cryptographic identity. SDK connectors must use the
fallible path and must not open a compatibility path. For SDK discovery,
explicit socket paths and `CMUX_TUI_SOCKET` / `CMUX_MUX_SOCKET` overrides
remain authoritative and do not require a session component.

The `cmux-tui` process accepts `--session <name>` to select the default socket name and `--socket <path>` to override the path. The socket contains no canonical state. Workspace identity/order, mutation results/tombstones, and frontend projections are stored in SQLite under the platform state directory (macOS: `~/Library/Application Support/cmux-tui/sessions`), or under `--state <root>`. An explicit socket does not change the state root. `--ephemeral` selects an in-memory registry and is mutually exclusive with `--state`.

A normal non-headless invocation first attempts to attach when its selected
socket already exists. This happens before state-root selection, so `--state`
and `--ephemeral` do not force a new owner when that socket is live; use a
unique session or socket to isolate ownership. If no daemon accepts the
connection, those flags apply to the newly created owner.

One process holds an exclusive cross-platform writer lease for each session
database. SQLite uses WAL, foreign keys and `synchronous=NORMAL`: an
acknowledged change survives a crash of the daemon at once. The WAL reaches
the disk at each checkpoint, which the daemon runs off the request path, and
the drive cache is flushed at close; a power loss may lose a tail of changes,
never their order (SQLite's WAL guarantee). A second daemon for the same state/session fails startup instead
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
| object{id?:any,ok:false,error:string,error_code?:string,error_delivery?:"known-not-delivered"|"ambiguous"}
```

`error_code` is an additive machine-readable classification for commands that
define one. Clients must continue to display or log `error` and ignore unknown
codes.

Decode errors return:

```text
object{ok:false,error:"bad request: ..."}
```

`clear-history` errors include `error_delivery`. `"known-not-delivered"` proves that neither a
clear nor fallback input reached the terminal. `"ambiguous"` means terminal delivery may have
started before the error. Clients must treat a missing or unknown value as `"ambiguous"`.

### Id Correlation

The v9 server echoes any JSON request `id` unchanged. Portable SDKs restrict ids to strings or JavaScript-safe integers and keep them unique among pending requests. Other JSON shapes have no portable equality contract.

Event lines do not carry request ids.

### Security Model

The v5 socket security model is filesystem permissions:

| Path | Mode |
| --- | --- |
| Runtime directory | `0700` |
| Socket file | `0600` |

Before binding, the server creates the final socket parent if needed, rejects a
symlink or non-directory, verifies ownership by the effective user, and
tightens group/other permissions. It then refuses to clobber a live socket,
removes a stale socket, binds the listener, and sets socket permissions. On
clean shutdown, it removes the socket file. These checks cover the final
parent; because `create_dir_all` can follow intermediate links, a future
component-by-component `openat`/`O_NOFOLLOW` walk is needed if an untrusted
process can replace an intermediate parent during creation.
The relay's ensure-daemon path performs the same final-parent ownership/mode
validation after `create_dir_all` and has the same intermediate-parent
limitation.

Access to the Unix socket is equivalent to access to the mux session. A client can type into PTYs, read screens, close surfaces, and change focus. Hosts must keep the runtime directory private.

The Unix socket does not use the WebSocket auth preamble. Its filesystem permissions remain the access boundary.

`CMUX_TUI_SOCKET` and `CMUX_MUX_SOCKET` inherited by a child are ambient full-session capabilities. Untrusted child processes must not inherit them.

### Implemented transport message limits

WebSocket messages are limited to 4 MiB on inbound connections. Unix
JSON-lines and relay mux uploads accept at most 16,777,216 UTF-8 payload bytes;
the JSON-lines delimiter is excluded. Relay framing may split a line across
carrier frames, but it does not raise this Unix ingress limit. Server-to-client
remote session messages, including render attach and VT replay responses, may
use the separate 33,554,432-byte budget. Receivers reject an oversized message
before decoding or allocating its payload.

## Relay Stdio

| Field | Value |
| --- | --- |
| status | implemented client transport primitive |
| since | protocol 9 client |

`cmux relay` copies bytes between stdin/stdout and one existing local Unix session socket:

```text
cmux relay --session main
cmux relay --socket /absolute/path/to/session.sock
```

Relay does not start a mux server, render a TUI, authenticate a caller, or interpret command payloads. Its stdout contains only server protocol bytes. When stdin is a terminal because a provider allocated a PTY, relay enables raw terminal mode for its lifetime to prevent echo and newline conversion. Providers should use a pipe when possible. When relay stdin reaches EOF, relay half-closes the Unix socket write side and continues copying server output. The server stops accepting requests on that connection, completes every parsed request, and then closes the response stream. Requests for one surface remain ordered, and an active `clear-history` also blocks later lifecycle commands. Requests for unrelated surfaces may complete first, so clients must correlate responses by request id.

The implemented SSH machine connector starts relay as:

```text
ssh -T [-p PORT] [-i IDENTITY_FILE] -- [USER@]HOST 'BINARY' relay --session SESSION
```

SSH supplies authentication, encryption, host verification, and process transport. The connector splits child stdout and stdin into independently owned reader and writer halves. Its JSON-lines adapter removes one line delimiter before giving a complete message to `RemoteSession` and appends one delimiter when sending. EOF cancels pending session requests and closes the child process transport.

Complete-message framing is the session-client boundary. Unix sockets and relay stdio use JSON lines. WebSocket adapters use one text frame per message without adding a newline. A future transport can supply different framing without changing terminal mirroring or the machine rail.

### PTY lifecycle errors and `terminal_gone`

The PTY relay dialect reports errors as JSON frames. A `pty_error` frame has this
shape:

```text
object{version:uint,type:"pty_error",ptyId:string,code:string,message:string}
```

The `terminal_gone` code is definitive only for a resource lookup. The relay
emits it after a successful, schema-valid `list-workspaces` response contains no
live PTY with the requested resource reference. A missing, non-success, or
malformed control response uses `failed`, because it does not prove that the
terminal is gone. A numeric surface reference is checked by `attach-surface`,
so an attach failure also remains `failed` unless a future control contract adds
an explicit not-found result.

Clients must close the failed local PTY view after `terminal_gone`, discard input
queued for that resource, and avoid retrying the same resource reference. They
may retry `failed` after a new authenticated transport generation when the
command's ownership and idempotency rules permit it. The generated PTY error
contract also defines `overflow`, `trust_revoked`, and `busy`. These additive
operational codes are enabled only after outer relay protocol version 7; the PTY
frame itself remains version 4. Older Workers receive `failed` with the same
retry or reattach instruction in `message`. Unknown codes are protocol-invalid.

Frames for one PTY are ordered on the logical stream. A reconnect creates a new
transport generation, and clients must re-authenticate and rediscover the
resource before opening it again. A transport close is not proof that the PTY is
gone. Repeated opens must follow the command's ownership and idempotency
contract; this relay does not add a separate request-id or retryable field to
the `pty_error` envelope.

WebSocket adapters must preserve JSON message order and treat a closed socket as
an ambiguous delivery boundary, never as proof that a PTY is missing. This is an
application-level rule on top of RFC 6455 framing.

Relay grants the remote SSH principal the authority of the selected local Unix socket. Deployments must restrict SSH admission and the remote socket with the same care as direct socket access.

The server classifies relay traffic as Unix because relay terminates at the Unix socket. The remote SSH principal therefore receives local-admin operations, including `shutdown-daemon` and `pairing-response` (deny only; approving a pairing needs a human surface, see Authentication and Pairing). Deployments that need less authority must use a future distinct relay profile.

## WebSocket

| Field | Value |
| --- | --- |
| status | implemented |
| since | protocol 6 |

WebSocket is opt-in and can run alongside either the local TUI or `--headless`:

```text
cmux --ws 127.0.0.1:7681
cmux --headless --ws 127.0.0.1:7681 --ws-token <secret>
```

A headless daemon has no TUI of its own to approve a pairing, so `--headless --ws` on a non-loopback address without `--ws-token` (or `server.ws_token`) refuses to start (fail closed). On a loopback address it mints a credential into a user-only file instead (App listener and page files below). The rule that only a human surface approves a pairing holds against same-user agents on signed builds only: on an unsigned DEV build the app's install-key prover is a same-user file, so a same-user process can pass as the app (identity.md threat model).

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

### App listener and page files

The cmux app starts its daemon with `server ensure --ws-loopback --ws-allow-origin <list>` (cli.md), where the list is every first-party page origin of the app (`cmux-page://cmux.home-channels,cmux-page://cmux.history,...`; cx-hnmbt.10), so each page can open its own WebSocket and gets its page id from its Origin (page-router.md). That owner listens on `127.0.0.1:<ephemeral port>`. A headless daemon whose loopback listener has no configured token mints a 256-bit credential and writes it, with the listener's addresses, to `<socket>.websocket.json` next to its socket (mode 0600, in the user-only socket directory; written to a private temporary file and renamed):

```json
{"version":1,"url":"ws://127.0.0.1:52311/","pages":"http://127.0.0.1:52311/pages/","token":"<64 hex>","pid":4242}
```

The token is never on a command line, in the environment, or in a log. A same-user host (the app) reads the file and gives the token to its own pages; a person gives it to a browser tab or pairs the tab instead. The file is removed when its daemon exits; a reader that finds a stale file sees `pid` and the connection failure. The same-user boundary is the one the Unix socket already has: a process that can read the file can also use the socket. Windows (planned): the same file protected by the user-only ACL of the state directory (cx-jdb.9).

The listener also serves page files, the first step of `page-router-v1` (hq-99 R7). A plain HTTP `GET` or `HEAD` without a WebSocket upgrade for `/pages/<page>/[<file>]` answers a file of the page bundle directory: `CMUX_TUI_PAGES_DIR` (a host that bundles the pages sets it; the app sets its bundled `pages` folder), else `share/cmux-tui/pages` next to the binary's directory (the portable layout for Linux and Windows), else `CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages` next to it (the macOS app, whose binary is `Contents/Resources/bin/cmux-tui`, so an owner the CLI or an agent starts from the bundled binary serves the same pages), each tried for the binary path as invoked and with symlinks resolved, else every request is `404`. The request passes the same Host and Origin rule as a WebSocket handshake before any file is read (`403` otherwise); path segments are plain names (letters, digits, `.`, `_`, `-`, never a leading dot, no percent escapes), at most four, and the resolved file stays under the bundle root (`404` otherwise). An HTML file carries `Content-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data:; connect-src 'self' ws://<Host>; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, and every file carries `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`. A page served this way has the listener's own origin, so its WebSocket passes the localhost rule with no flag, and it still authenticates with the credential or a pairing. Each page has a page id, its folder name (`home-channels` for Channels); per-page operation allow lists keyed on that id (for example `history.*` reads only for page `history`) apply to `cmux.protocol/2` requests of a connection whose page id comes from a page relay or from a `cmux-page://cmux.<page>` Origin (`page-router-v1`, page-router.md); a page served by this listener shares its origin, so it has no page id and the authority of its authenticated connection.

With `ws-attachments-v1` the listener also answers download links of local conversation attachments: a plain HTTP `GET` or `HEAD` of `/attachments/<token>`, where the path came from `conversation-attachment-link` (commands.md). The request passes the same Host and Origin rule first (`403` otherwise). The token is 64 lowercase hex digits, random, kept in memory only, and valid for 10 minutes (and never after a restart); an unknown, expired or malformed token, a caller who is no longer a participant, or a record that is gone answers `404`, because each request checks the participant and the record again. One `Range: bytes=` range (`a-b`, `a-`, `-n`) answers `206 Partial Content` with `Content-Range`; a range past the end answers `416` with `Content-Range: bytes */<size>`; several ranges or another unit answer the whole body (`200`). Every `200` and `206` answer carries `Accept-Ranges: bytes`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: sandbox; default-src 'none'`, `Cache-Control: private, max-age=600`, `Referrer-Policy: no-referrer` and `Cross-Origin-Resource-Policy: cross-origin` (the token is the credential, so a page of another origin may show it, when that page's own policy admits the listener's origin). Text types are served as `text/plain; charset=utf-8`; raster images and the poster and preview images are `Content-Disposition: inline`, every other type `attachment`, with the link's file name.

A running owner that started without this listener (the CLI or an agent started it, or an app build before it) opens it on request: `ws-listen {allow_origin?, allow_origins?}` on the Unix socket (commands.md `ws-listen`, capability `ws-listen-v1`; `allow_origins` with `ws-listen-origins-v1`) binds the loopback listener, writes the same credential file and returns the endpoint, never the credential. The app calls it when the credential file is missing; for an owner without `ws-listen-v1` the app hands the owner off to its bundled build (terminals keep running), so a page never waits forever on a missing listener.

### Authentication and Pairing

Every WebSocket authenticates before protocol commands are dispatched. Interactive clients request pairing as their first frame:

```json
{"pair":{"request":true}}
```

The server returns a 60-second six-digit challenge. It sends the same challenge to trusted Unix-socket subscribers as `pairing-requested`. Only a human surface approves it: the TUI that runs the daemon (in process) or the verified cmux app (the `frontend` actor). Any other local connection, an attached or SSH-relayed TUI, an agent in a pane, a script or the CLI included, may deny but not approve (`pairing-response` and `pairing_request.resolve` refuse the approval with `origin_forbidden`). Approval is an explicit action (the `y` key or the Approve button; Enter does not approve), so input typed while the prompt appears cannot admit a client. Approval authorizes the waiting socket and returns an eight-hour reconnect credential. The comparison code is not a secret.

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

Before any frame, every handshake passes the localhost listener rule, and no flag turns it off. `Host` must be a loopback name, a name added with `--ws-allow-host`, or (only on a non-loopback bind) an IP address literal; a DNS-rebound name is refused with 403. `Origin` must be absent (a native client), one of the listener's own origins (`http://` plus a loopback name or a `--ws-allow-host` name, on the listener's port), or one added with `--ws-allow-origin`; `null` is always refused. The token or pairing step runs after this rule. A browser challenge identifies only its TCP peer, which is normally loopback. Known gap: the approval prompt does not yet show the client's Origin and path.

### Bind Security

By default the listener accepts only an IP loopback address such as `127.0.0.1` or `[::1]`. cmux-tui refuses a non-loopback address unless `--ws-insecure-bind` is also present. That flag widens the bind address only: the `Host` and `Origin` rule still applies, so names clients use to reach a wide bind must be listed with `--ws-allow-host`. This listener provides no TLS; for remote access, bind deliberately and place it behind a TLS-terminating, authenticated reverse proxy. An authenticated WebSocket client can read terminal contents, type into PTYs, and use ordinary control and frontend mutations, including closing session topology. With `ws-conversations-v1` it also reads and writes the local conversations as `user_local` (commands.md `conversation-list`; cmux#13742). With `ws-cloud-conversations-v1`, a connection that authenticated with a pairing-store credential (an approved pairing, or the verified app's `page-credential`) also uses the cloud lease the verified app set, as the person (commands.md `cloud-session-set`); it never sets or clears a lease. The static or file token never carries the Cloud lease: any same-user process can read the file. It cannot use Unix-only `local-admin` commands: `shutdown-daemon` and `pairing-response` reject WebSocket callers. Provider-owned workspace commits also require their separate provider authority.

Static tokens and reconnect credentials are bearer credentials with ordinary control and frontend authority, excluding `local-admin` and `provider-authority`. Reconnect credentials are memory-only, survive for eight hours, are invalid after daemon restart, and have no v10 list or revoke API. Prefer secret files over process arguments when a future `--ws-token-file` becomes available. Credentials must never appear in URLs, logs, debug output, or generated diagnostics.

## Concurrency, streams, and reconnect

The v10 server begins commands serially in receive order on each connection. A blocking `wait-for` delays later commands on that connection. A client request timeout stops local waiting only; it does not cancel execution, and a late mutation may still commit.

After a timeout, clients must not retry a non-idempotent legacy mutation until a
snapshot or event reconciles the original outcome. A durable mutation retries
with the same `(origin, mutation_id)` so the server can replay its receipt.

Repeated `subscribe` calls and repeated attachments create independent server streams without public stream ids. Closing a local iterator on a shared connection does not cancel its server stream. A v10 client that needs independent cancellation uses a dedicated connection and closes it. On one shared connection, use at most one subscription and one attachment per surface.

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
cmux --http 127.0.0.1:0
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
GET /api/v1/events?events=bell,agent-changed&surfaces=1,a8f3k2
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
