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

### Binary frames (cmux-ipc, not yet negotiated)

The `cmux-ipc` crate defines binary frames that a local Unix connection will
carry next to JSON lines once a client negotiates them. The daemon does not
advertise or grant `ipc-frames-v2` until its reader reads frames
(p05-ipc-061; [Framed IPC grants](#framed-ipc-grants)). Until then, a frame
on any connection is a bad message. WebSocket, relay and bridged connections
keep JSON lines only.

A message that starts with byte `0xFF` is a frame; any other first byte starts
a JSON line. `0xFF` never appears in UTF-8, so the two cannot be confused.
Each frame is a 16-byte little-endian header and then `len` payload bytes:

| Bytes | Field | Notes |
| --- | --- | --- |
| 0 | magic | `0xFF` |
| 1 | kind | table below |
| 2-3 | stream | u16; 0 is the connection's control sequence, other values are client-minted streams |
| 4-7 | len | u32 payload bytes, at most 33,554,432 (32 MiB) |
| 8-15 | aux | u64 whose meaning depends on the kind |

| Kind | Value | aux |
| --- | --- | --- |
| OUTPUT, GRID, EVENT, SNAPSHOT, SNAPSHOT_MORE, REPLAY, RING, RING_ADVANCE | 1-8 | absolute PTY offset |
| INPUT | 9 | flow id |
| SHARED_BUFFER | 10 | byte size of the attached fd |
| RING_ACK | 11 | the reader's parsed PTY offset (consumer cursor) |
| REQUEST, REPLY, ERROR, TYPED_EVENT, CANCEL | 16-20 | request id u32, method id u16, priority hint u8, flags u8 |

Values 0, 12-15 and 21-255 are unassigned. Priority hints are input 0,
control 1, bulk 2, background 3. Call flags are binary `0x01`, fds `0x02`,
flow `0x04`, urgent `0x08` and more `0x10`; MORE marks a message cut into
chunks, the boundary where higher-priority frames may go first. Kinds 1-9 and
11 never use stream 0.

The receiver validates the header as soon as its 16 bytes arrive, before it
reads or allocates the payload. A bad magic byte, an unassigned kind,
priority or flag bit, a length over the limit, terminal data on stream 0, a
frame before negotiation, a JSON line over 16,777,216 bytes or not UTF-8, or
a close inside a frame is a bad message. The receiver stops reading and closes
the connection with `bad_message` and the reason (`bad_magic`, `unknown_kind`,
`oversize`, `data_on_control_stream`, `unknown_priority`, `unknown_flags`,
`frames_not_negotiated`, `line_too_long`, `invalid_utf8`, `truncated`).
Nothing after the bad byte is interpreted.

An INPUT frame (p05-ipc-078) is the raw bytes of a `send` to the surface of
the attach stream it names, with no JSON and no base64. Its aux is the key
press's flow id (0: none), which joins the daemon's flow hops to the echo, as
`send`'s `flow` does. It runs on its stream's sequence after that stream's
earlier items, is never parsed and is never answered. When its bytes do not
reach the terminal, the stream gets the event `input-failed{stream, reason,
bytes}` ([events.md](events.md#input-failed)); while the terminal stays ended,
later INPUT on the same open of the stream sends no second event. INPUT obeys
a line's gates: after a shutdown acknowledgement or a committed handoff it
closes the connection, and during a pending handoff it is refused with
`daemon_handoff`. INPUT sent right behind its stream's `attach-surface` waits
for that reply ([events.md](events.md#attach-streams)). An INPUT frame on a
stream the connection never announced is a bad message (`unknown_stream`),
and so is one from a remote-relay client (`remote_input`).

#### Bulk payloads: SNAPSHOT, SNAPSHOT_MORE, REPLAY

A snapshot viewer's `snapshot` events (READY, local-history READY, history and
images chunks) go as SNAPSHOT frames and the `vt-state` replay as a REPLAY
frame (p05-ipc-077). The payload of one event is:

| Bytes | Field | Notes |
| --- | --- | --- |
| 0-3 | meta_len | u32 little endian |
| 4.. | meta | one UTF-8 JSON object, `meta_len` bytes |
| then | raw | `data_len` bytes, then `pending_len` bytes (REPLAY only, when present) |

The meta is the event's JSON line without its base64 fields (`data`, and
`pending` for `vt-state`), plus `data_len` and, when the replay has a pending
sequence, `pending_len`. The raw bytes are what those fields decode to: a
history chunk's raw DEFLATE, the GHOSTSNP READY prefix, the Kitty replay
stream, the VT replay and its pending sequence. aux is the PTY offset of the
READY or of the replay cut. A writer cuts a long event into chunks: a SNAPSHOT
continues as SNAPSHOT_MORE frames with the same aux; a REPLAY continues as
REPLAY frames with the same aux, because its payload bytes (the prefix, the
meta and the synthesized VT replay) are not PTY bytes. The next OUTPUT starts
at that same offset. The reader takes the offset from the first frame, appends chunks
until it holds `4 + meta_len + data_len + pending_len` bytes, and then has the
whole event. A frame that would pass the 32 MiB payload limit is not built;
that event goes as its JSON line.

Golden vectors for every kind, one mixed stream and each bad-message case are
in `spec/fixtures/ipc-frames` with a `manifest.json` that describes them in
plain fields. Every implementation decodes them the same way.

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

### Reply and event order

Each connection has one control sequence (stream 0): command replies, the events of its `subscribe`
stream, and the items of its `session.events` stream. The server writes them in one FIFO, in the
order they were enqueued. Every other stream (attach output, journal reads, loopback forwards,
agent-session attaches and other resource streams) keeps its own FIFO: its items are never
reordered among themselves, but priority may move them relative to other streams. Each such stream
rides a lane, and the writer takes lanes in this order: input streams, the control FIFO, bulk
streams (attach output and the other streams today), background streams. The order has a
starvation bound: a lower lane passed over for 8 items writes one, so an event flood never starves
attach output; the bound never changes the order inside a FIFO. Streams of one lane take turns of 2
items. On a connection that carries frames, a stream frame longer than the daemon's frame cut
(`bulk_frame_max` in `identify` with `revisions`, 32 KiB unless `CMUX_IPC_BULK_FRAME_MAX` sets it)
is written in chunks with the MORE flag or as SNAPSHOT then SNAPSHOT_MORE, so a reply waits for at
most one chunk. These rules hold on the Unix socket and WebSocket transports:

1. Control replies and control events share one FIFO.
2. **Not in force until chrome-parity p05-ipc-120 lands.** After p05-ipc-120, a reply is enqueued
   after every event its request emitted, so it is written after them. Today the request emits its
   events into the subscriber mailbox before it returns, but the subscription's thread moves them
   to the FIFO later, and the reply, enqueued as soon as the command returns, is usually written
   first.
3. Items of a stream stay in their stream's FIFO; a stream's overflow drops only its own items
   and never a reply.
4. Control-sequence items use their stream's queue budget and backpressure, never the control
   reserve, so an event flood ends its subscription with `overflow` and never closes the connection.

**Not in force until p05-ipc-120 lands (rule 2):** a client may use "events read before this
reply" as a barrier, because every event the request emitted is in it. Today that barrier can miss
the request's own events. The macOS app's `LineTransport.routedEventCount` (and the `eventBarrier`
of a reply) counts only stream-0 lines: raw events and the lines of a stream the client registered
on the control sequence (`session.events`). The lines of any other stream never move it, and on a
connection without a stream handler the app drops them. Regression tests: `cargo test -p
cmux-tui-core --lib reply_event_order` (the two `*_under_stream_flood_*` tests are ignored and red
until p05-ipc-120; run them with `-- --include-ignored`) and `ReplyEventOrderTests` (CmuxNext).
`new-tab` changes the tree, not a split layout, so its echo is `tree-changed`; `set-split-ratio`
is the `layout-changed` case.

A reconnect creates a new transport generation. Old pending ids, event buffers, and stream handles never cross generations. A client resends authentication, calls `identify`, registers subscriptions before fetching snapshots, checks generation values, and reattaches surfaces. Network loss uses capped exponential delay with jitter and one in-flight attempt. Static-token rejection is terminal. Reconnect-credential rejection discards that credential once and enters one pairing attempt. Pairing denial, expiry, or rate limiting requires user action.

vNext adds client-generated `stream_id` to `subscribe` and `attach-surface`, echoes it on every event, and adds idempotent `cancel-stream`. Request timeout remains distinct from stream cancellation.

## Framed IPC grants

Status: `attach-streams-v1` is in the daemon (p05-ipc-074,
[events.md](events.md#attach-streams)); the other three are a grant rule
only. The daemon advertises and grants a capability only after its
transport is in the daemon, so `identify` lists only `attach-streams-v1` of
the four and `set-client-info` grants only it. A request that names a
`stream` on a connection without the grant is refused with
`streams_not_granted`. The task that adds a transport also turns on its
capability: p05-ipc-061 for `ipc-frames-v2` and the ring task for
`terminal-output-ring-v1`
(`plans/cmux-next/chrome-parity/p05-ipc.md`, sections 3.1 and 3.2). Mojo
works the same way: it exposes an interface only after its implementation
is bound.

| Capability | What it enables | Requires |
| --- | --- | --- |
| `ipc-frames-v2` | 16-byte framed messages next to JSON lines, `SHARED_BUFFER` included | none |
| `attach-streams-v1` | Client-minted streams on one connection. Their items stay JSON lines. | none |
| `attach-frames-v1` | Attach output as `OUTPUT`, `GRID`, `SNAPSHOT` and `REPLAY` frames on a stream | `ipc-frames-v2`, `attach-streams-v1` |
| `terminal-output-ring-v1` | The per-terminal shared-memory output ring (`RING`, `RING_ADVANCE`, `RING_ACK`) | `attach-frames-v1` |

`identify` lists each capability that is in the daemon and that the
connection can be granted in its current state. After the client declares an
`api_revision` other than the daemon's, `identify` no longer lists the
capabilities that need the same revision. A client gets a grant when it
echoes the capability in `set-client-info` and its connection meets the rule
below. The client must also get, or already hold, every capability in the
Requires column. The daemon ignores a capability that it does not grant, as
it does for any other capability, and the reply stays `{}`.

| Connection | Grants |
| --- | --- |
| Direct local peer on the Unix socket, with `api_revision` equal to the daemon's (declared in `set-client-info`) | all four |
| Direct local peer at any other revision, or with no declared revision | `attach-streams-v1` |
| Framed bridge (`bridge-hello` with `bridge-frames-v1`, below) with `api_revision` equal to the daemon's | `ipc-frames-v2`, `attach-streams-v1`, `attach-frames-v1` |
| Framed bridge at any other revision, or with no declared revision | `attach-streams-v1` |
| Bridge that the daemon identifies at accept | `attach-streams-v1` |
| Unverified Unix peer | `attach-streams-v1` |
| WebSocket | none |
| Remote entry (`cmux link` peer) | none. The remote gate refuses them with `remote_denied`. |
| Page relay (`client-hello role:page_relay`) or a page's connection | none |

The daemon classifies a Unix peer at accept, from kernel facts only:

- A direct local peer runs as the daemon's effective user (`SO_PEERCRED` or
  `getpeereid`), and its executable is not one of cmux's byte bridges.
- A bridge is this build's `cmux-mobile-host`, or a peer whose executable is
  the daemon's own executable or `cmux`, `cmux-tui`, `cmux-tui-ssh`,
  `cmux-remote` or `cmux-relay` in the daemon's folder. These executables
  include `cmux relay`, `cmux link dial --service owner_session` and the
  remote daemon's dialer. The daemon cannot see the subcommand, so every
  connection from these executables counts as a bridge.
- An unverified peer is one for which the kernel reports no user or no
  executable, or reports a user other than the daemon's (root).

Streams are JSON lines, so a bridge carries them, and the daemon's revision
translation applies to them. Frames, the ring and shared buffers carry
payloads that the daemon does not translate. They also pass descriptors over
SCM_RIGHTS, which only a direct local peer can receive. This follows Mojo:
platform handles pass only on a channel that can carry them
(`mojo/core/channel_posix.cc`), and unversioned interfaces assume that both
ends come from one build. A bridge that the daemon does not identify reaches
it as a direct peer. The dialing client knows about the bridge, so it echoes
only `attach-streams-v1` until the bridge can carry frames
(`bridge-frames-v1`, p05-ipc-161).

A bridge that reads frames says so on its own connection. When `identify`
lists `bridge-hello-v1`, the bridge may send
`{"cmd":"bridge-hello","features":["bridge-frames-v1"]}` as the
connection's very first line. The reply is `{"features": [...]}`, the
features that the daemon took. The far client's `client-hello` window stays
open behind it. The daemon takes `bridge-frames-v1` only from a peer that
the kernel showed to be of the daemon's user, with no role, and not the
phone host's lane. The connection is then a framed bridge. It may get
frames at the daemon's revision, but never `terminal-output-ring-v1`,
because a bridge cannot pass a descriptor. A `bridge-hello` anywhere else
is `bridge_hello.window_closed`, and off a local Unix connection it is
`bridge_hello.local_only`. An error closes the hello window, as for
`client-hello`. A daemon that does not list `bridge-hello-v1` would take
the line as the connection's first line, so a bridge never sends it there.

The SSH bridge (`cmux-remote`, service `mux-control`) can carry frames. Its
remote end lists `bridge-frames-v1` in the open features of the mux stream,
next to `mux-input-v1`. With it, both ends read a message that starts with
`0xFF` by its 16-byte header, never as a line. A header that fails
validation, or a payload over the line budget of its direction, ends the
connection before any payload byte is read. Every item of one attach
stream uses one lane per direction: frames, lines that name the stream, and
replies to requests that name it. A `send` that names a stream stays a JSON
line. The local end of a bridge whose remote end did not list the feature
refuses a frame and closes the connection. The remote end opens its daemon
connection with `bridge-hello` (above) when that daemon lists
`bridge-hello-v1`, so the far client is a framed bridge there: the daemon
grants it frames at its revision, and never the ring.

Each `set-client-info` first removes every grant that the connection's
current state does not allow, for example after an `api_revision` other
than the daemon's. To get the grant again, the client must echo the
capability again in a later `set-client-info`. A later page-relay
`client-hello` also ends every grant. The daemon checks a grant again each
time the grant is used.

An equal `api_revision` does not prove that the two method tables are
equal: a new command is additive and needs no new revision. A REQUEST frame
with a method id or priority hint that the daemon's table does not have
closes the connection. A method that the daemon serves only as a line gets
the ERROR `method_not_framed` before it runs, so a retry would run it after
the requests written behind it. So, on a connection that is offered
`ipc-frames-v2`, `identify {revisions: true}` also returns
`sdk_schema_digest` (FNV-1a 64 of the `sdk-schema.json` bytes that the
daemon's method tables come from, as 16 lowercase hex digits) and
`framed_methods` (the method ids that the daemon answers on frames, in id
order). A client sends REQUEST frames only when its own table has the same
digest, and only for the methods in `framed_methods`. It sends every other
command as a line.

### Attach frames

Status: encoder only (p05-ipc-076). `attach-frames-v1` stays unbound until
the outbound queue carries stream frames, so no connection gets these yet.

On a stream granted `attach-frames-v1`, the byte attach events of
`attach-surface` (see [events](events.md)) arrive as frames instead of JSON
lines. The aux of every one is an absolute PTY offset: the count of output
bytes the terminal published before the frame. The first `OUTPUT` of an
attach starts at the offset the attach's replay was taken at.

| Event | Frames | Payload |
| --- | --- | --- |
| `output` | `OUTPUT` at the offset of its first byte | the raw PTY bytes |
| `output` with `colors` or `flow` | `OUTPUT`, then `EVENT` at the same offset | `EVENT`: the `output` event text without `data` |
| `resized` | `GRID` at the current offset | `meta_len` (u32 LE), the `resized` event text without `replay` and `pending`, then the replay bytes, then the pending bytes |
| `colors-changed`, `detached`, `overflow` | `EVENT` at the current offset | the event text |

`OUTPUT` offsets are contiguous: each one starts where the previous one
ended, also across the chunks of a long payload. A reader that sees a gap
lost bytes and resyncs. The server does not skip bytes when its outbound
byte budget is full: it waits and sends the same frame at the same offset,
as it does for a JSON line. A `GRID` meta has `pending_len`, the byte count of
the pending sequence at the end of the payload, only for a viewer that
advertised `terminal-pending-sequence-v1` and only when the sequence is not
empty. For any other viewer, the pending bytes end the replay, as in its
`resized` line. Putting the payload bytes back as base64 gives the JSON
event of the line path.

## Framed IPC method attributes

Status: schema only. No transport reads these attributes yet; JSON-line
clients ignore them. The framed transport
(`plans/cmux-next/chrome-parity/p05-ipc.md`, section 3) routes a frame by its
method id and never parses the payload, so `sdk-schema.json` gives each
command and event the facts that routing needs. This follows Mojo: ordinals are
scoped to an interface (`mojo/public/tools/bindings/README.md`), and every
message is validated before dispatch, so a field without a bound cannot appear
in a binary layout.

`families` (top level) maps a kebab-case family name to `{id, description,
next_ordinal}`. `id` is one byte: commands use `0x01`-`0x5F`, events
`0xC0`-`0xFE`, and `0x60`-`0xBF` is reserved for `resource-operations-v2.json`.
Families are append-only: an id is never reused or renumbered.
`next_ordinal` (optional, 0-256) is the next ordinal to give in the family:
every ordinal below it was given once, so it stays reserved after its command
or event is removed. Every id of the family must be below it. When `families` is present,
every command needs `method_id`, `priority` and `durability`, and every event needs
`event_id` and `priority`.

Command attributes:

| Attribute | Meaning |
| --- | --- |
| `method_id` | u16, `family << 8 \| ordinal`. Unique in its family; the family must be a declared command family. |
| `priority` | `input`, `control`, `bulk` or `background`. The daemon uses its own table; a frame header hint that differs is `bad_message`. |
| `priority_changed_reason` | Why `priority` changed. `api-compat-check` requires a new one on every `priority` change. |
| `ordering` | `sequence` (default) or `independent`. Only a `read_only` command that is not `stream_scoped` may be `independent`. |
| `durability` | `read_only`, `memory`, `reply_before_journal` or `reply_after_journal`. Required, no default. A `spawns_terminal` command is never `read_only`. |
| `payload` | `json` (default) or `binary`. A binary payload needs `layout_version`. |
| `layout_version` | 1-255, the first byte of a binary layout; bumped on every layout change. |
| `stream_scoped` | The command runs on the stream that names its surface, in that stream's FIFO. A `read_only` one waits only for the items queued before it, then leaves the FIFO: later items do not wait for its reply. |
| `crosses_stream_ok` | Why the command may pass items already queued on its target surface's stream. Excludes `stream_scoped`. |
| `max_bytes` | Bound of the encoded request, 1 to 32 MiB (the frame length limit). |
| `spawns_terminal` | The command can start a terminal host (the reply carries `starting:true` under F10). Set when any form of the command starts one. |
| `coalesce` | `{key, additive}`: a queued unsent item with equal `key` fields is replaced; numeric `additive` fields are summed. |
| `urgent` | Run first on the receiving sequence (Mojo `[SupportsUrgent]`). It never reorders the channel. Only `input` or `control`. |
| `clients` | Non-empty subset of `macos`, `ios`, `cli`, `sdk`; absent means every client. The Rust method tables hold every framed method; the Swift method table (p05-ipc-023) holds only methods whose `clients` include `macos`, and the client generators will do the same (p05-ipc-020 for Swift, p05-ipc-048 for iOS). |

Event attributes: `event_id` (u16 in a declared event family), `priority`,
`priority_changed_reason` and `coalesce` (fields of the payload).

Field attributes: `omit_nil` (an optional member is omitted instead of written
as `null`; not allowed on a required member), `max_bytes` (UTF-8 bound of a
string member, or of each item of an array of strings) and `default` (it must
match the member type; `null` only on a `nullable` member).

Stream barrier rule. A command whose request has a `surface`, `surfaces`,
`terminal`, `terminal_id`, `terminal_ids` or `view` member can target a
surface that has an open stream on the connection. Such a command must be
`stream_scoped`, or give a `crosses_stream_ok` reason; otherwise it could pass
input already queued on that stream.

Binary layout rule. Every length-prefixed part of a binary request or result
is bounded: a string member needs `max_bytes` (on an array of strings it
bounds each item), an array needs `max_items`, an object cannot allow
additional properties, and maps, `opaque_json`, untagged unions and recursive
types have no binary layout.

`bindings/codegen/validate.py` (through `ipc_meta.py`) enforces these rules
whenever the SDK generator loads the schema.

### Assigning method ids

`sdk-schema.json` declares `families`, so every command has `method_id` and
`priority` and every event has `event_id` and `priority` (queue Q6 of
`scripts/cmux-next/ipc-census.py` is empty). `cmux-tui/scripts/assign-ipc-method-ids.py`
writes them. Run it after adding a command or event; run it with `--check`
to see that the schema is current. It never changes an existing id, family,
`priority`, `ordering` or `durability`, so a second run gives no diff. It
advances each family's `next_ordinal` and never lowers it, so an id is never
given twice, even after its command is removed. `clients` and
`spawns_terminal` follow their sources on every run, so `--check` fails when
a source changed and the schema did not. The `ios` source is the iOS client's
command table, `CmuxTUICommand` in `Packages/iOS/CmuxMobileSSH`; the Mac's phone
lane generator (`scripts/cmux-next/gen-phone-lane-fields.py`) refuses a
`clients: ios` command that `DaemonLanePolicy.allowedCommands` does not allow.

`api-compat-check` (cmux-api-compat, `src/wire.rs`) compares the ids of
`sdk-schema.json` and `resource-operations-v2.json` with the append-only
ledger `spec/api-compat.wire.json` and refuses: an id or family byte given to
a second name, live or removed, in either file (both files share one family
byte space and one frame id space); a family or id outside its file's range,
or in a family the file does not declare; a renumbered method, event or
family; a name removed from a schema file while its ledger entry has no
`"removed": "<why>"` tombstone, and a tombstoned name that comes back; a
`priority` change without a `priority_changed_reason` that differs from the
last recorded one; and a binary layout change (request, result or a type they
reach) without a higher `layout_version`. A schema that stops stating a
priority keeps the recorded one. After adding ids, run it with `--write` to
record them. To remove a command, event or family, add the tombstone to its
ledger entry by hand; that is the only hand edit. CI passes `--base <rev>`, so
the rules start from the base's ledger: an entry dropped from it, or an id,
priority or layout edited in it, is reported and the check fails until
`--write` puts the entry back.

In `resource-operations-v2.json` the same attributes are optional and typed by
`resource-operations-v2.schema.json`: top-level `families` (ids `0x60`-`0xBF`)
and, on a transported operation, `method_id`, `priority`,
`priority_changed_reason`, `payload` and `layout_version`. A binary
operation's layout covers its `params` and `result`. Local operations run in
the app and have no wire attributes.

| Attribute | Rule |
| --- | --- |
| family | Each wire name matches exactly one family in the script's table. A name that matches none or two stops the script. |
| ordinal | The family's `next_ordinal`, in file order. The first command of a family has ordinal 0. |
| `priority` | Commands: `input` for `send`, `send-key`, `paste-image`, `browser-key*`, `browser-mouse*`, `browser-wheel*`, `browser-insert-text`, `resize-attached-view`, `scroll-surface`, and an agent chat's `agent-session-prompt`, `agent-session-cancel` and `agent-session-permission` (the person's input to the attached session). Every command that writes a surface's PTY input has this one priority, because a client keeps call order only inside one priority. The other `agent-session-*` commands, their log pages and images included, are `control`. `bulk` only for reads: journal and history reads, attachment reads, `get-blob`, `fs.read` and `agent-transfer-read`. `fs.list` keeps a listing snapshot and `fs.stat` answers one fixed-size entry, so both are `control`. A write, such as an upload, `put-blob`, `fs.write` or `agent-transfer-write`, is `control`, so a later command that names what it wrote (the `fs.rename` of a written part, the `agent-transfer-finish` of written pages) cannot pass it. `background` for stats (`server-stats`, `machine-usage`, `terminal-resources`). All other commands are `control`. Events: `input` for `output`, `render-delta`, `render-state` and `frame`, which draw the terminal. `bulk` for `surface-output`. `background` for usage and inventory refreshes. All other events are `control`. |
| `ordering` | `independent` only for three stats reads that do not see this connection's earlier requests: `server-stats`, `machine-usage` and `machine-listening-tcp`. A cloud command is never `independent`: it needs the lease that the connection set with `cloud-session-set`. `fs.read` and `fs.stat` are not `independent` either: they see the files that the connection's own `fs.write`, `fs.mkdir`, `fs.rename` and `fs.delete` changed. |
| `durability` | `read_only` for reads, `memory` for state that the journal never records (input, streams, leases, presence, subscriptions), and `reply_after_journal` for `journal-frontend-event`, whose reply reports the commit, for `apps-set` and `apps-store`, which write `apps.json` before they reply, for `agent-cli-intents-record`, `-settle`, `-attach` and `agent-cli-update-job`, which reply after their SQLite commit so a restarted app finds the intent or job it was told about, and for `fs.write` and `fs.rename`, which answer after their fsync. The other `apps-*` commands are `memory`: every one of them registers the connection for app events, and mounts, runs, log follows and providers last only as long as the connection. `cancel-request` is `memory` too: it only cancels an in-flight `apps-run` or script cell of this connection and journals nothing. The `agent-session-*` commands are `memory` (attachments and what they send to acpmux, which keeps the session and the folder trust), except `agent-session-events` and `agent-session-media`, which are `read_only`, and `agent-session-start`, which binds the tab and is `reply_before_journal`. All other commands are `reply_before_journal` (F10). A command that changes state is never `read_only`, even when its name sounds like a read: `cloud-selfhost-info` writes the lease's account, `browser-host-provider` starts the browser host and `snapshot-request` admits a snapshot on its stream, so all three are `memory`. `fs.list` (its listing snapshot), access requests (a status read takes a delivered secret), script cells and sessions, and the chat move and agent CLI update steps that acpmux keeps are `memory` too. `agent-transfer-receive` and `-finish` are `memory` although they write a receive or landed chat record: the write is best effort (a failed save is only logged), so their reply does not report a commit. |
| `stream_scoped` | Set on every command that names a surface, terminal or view, unless the script gives a `crosses_stream_ok` reason. Reasons exist for these command groups: commands that create a terminal by `terminal_id`, commands that open a stream, process-state reads, and list filters. |
| `spawns_terminal` | The script's reviewed list of daemon commands that can start a terminal host: the creates (`new-tab`, `new-pane`, `split`, `new-workspace` and the rest), `run`, `restart-tab`, `create-surface-with-receipt`, `apply-layout`, `sidebar-plugin`, both saved-group reopens, `move-tab-to-split` and `move-tab-to-column`, which start one with `respawn`, and `agent-cli-update-job`, whose workspace runs the update in a terminal. The list must hold every Swift request type that conforms to `TerminalSpawningRequest`; the script stops otherwise. |
| `clients` | `sdk` for every command. `macos` for the Swift wire names (census Q1) and the names a Swift client sends by name, listed in the script's `MACOS_CALL_SITES` (the `agent-session-*` commands of `AgentSessionAttachClient.swift`). `cli` for the names that the Rust CLI builds by hand (census Q14) and for the names it passes to a call helper (the script's `CLI_CALL_HELPER_SENDS`: `fs.*`, `agent-transfer-*`, `access-request*`). |

`snapshot-request` is `stream_scoped`: it is ordered on its surface's stream.

`wait-for` is `stream_scoped` and `read_only`: it starts after the items
queued before it on its surface's stream, then waits for its match outside
the FIFO. A `send` sent after it, which produces the match, is not queued
behind the wait.

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
