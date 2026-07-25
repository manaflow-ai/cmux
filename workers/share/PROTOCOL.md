<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# cmux share protocol v2

One Durable Object owns each unguessable share code. The host Mac has one
WebSocket and each guest browser has one. The Durable Object owns admission,
roles, presence, bounded chat history, subscriptions, and session lifetime.
The host owns workspace layout and terminal input authority. Control messages
use JSON protocol 2. Terminal data uses the binary CMXS transport version 1.

V2 shares zero or one workspace. Its layout can contain terminal, browser,
agent, and other leaves. Only terminal leaves accept subscriptions, terminal
frames, chat bubble anchors, cursors, or guest input. Other leaves render as
placeholders.

V2 excludes composer synchronization, browser pointer and key forwarding,
follow mode, pixel or video frames, guest layout changes, and pane resizing.
Unknown verbs and malformed JSON are protocol errors.

## Authentication and connection

Clients connect to:

```text
wss://<worker>/v2/share/sessions/<code>/ws?token=<share JWT>
```

Native clients may use `Authorization: Bearer` instead. The short-lived
Ed25519 JWT has `iss=cmux`, `aud=cmux-share`, a Stack user `sub`, `email`,
`code`, `protocolVersion=2`, `terminalTransportVersion=1`, and optional literal
boolean `host` and `create` claims. The issuer sets a 300-second lifetime.
Session codes, user ids, and emails are byte-bounded and reject every Unicode
general-category `Cc` control character.

The worker verifies the token offline, binds the Durable Object id to the
verified code, strips `Authorization` and `Cookie`, and forwards only verified
identity headers. The Durable Object attaches that identity to the WebSocket.
Client JSON cannot select or override the relayed user id.

Only a host token with `create=true` can create a session. Host refresh tokens
can reconnect but cannot create. A guest for a missing code receives HTTP 404.
The `/v1` and unknown-version paths return HTTP 404. A connected client that
sends a JSON `hello` with any protocol other than 2 closes with
`4406/unsupported protocol`.

`GET /healthz` publishes the exact runtime contract and deployed Worker
identity:

```json
{
  "ok": true,
  "service": "cmux-share",
  "protocolVersion": 2,
  "terminalTransportVersion": 1,
  "deploymentId": "<Cloudflare Worker version id>"
}
```

The deployment id comes from the Cloudflare version metadata binding. The web
API checks this response before minting a share token, preventing an old
Worker deployment from creating a blank or partially compatible session.

Sessions end when the host sends `end` or remains disconnected for 120 seconds.
The Durable Object persists the end timestamp and retains an ended-code
tombstone for ten minutes, twice the create-token lifetime. The original
create token therefore expires at least five minutes before the cleanup alarm
deletes all Durable Object storage.

One storage alarm serves cursor draining, host-disconnect grace, and tombstone
cleanup. Each phase schedules the next absolute deadline. Early or restored
alarms re-arm the same deadline. Only an alarm at or after the validated
tombstone boundary may delete storage; inconsistent restored timestamps fail
closed without deletion.

## Admission and roles

Guests begin pending until the host approves their Stack user id as `editor`
or `viewer`. Denial blocks that user for the session. Viewers cannot send
terminal input. Host-user browser connections use the editor role but do not
replace the authoritative host socket.

The session holds at most 32 WebSockets, host included, and 16 pending
connections. An excess socket first receives:

```json
{"t":"error","code":"session_full","message":"session is full"}
```

or:

```json
{"t":"error","code":"too_many_pending","message":"too many pending join requests"}
```

It then closes with code `4429` and is not retained. A reconnecting host may
replace the existing host at capacity. The host slot remains reserved during
the disconnect grace period.

## JSON envelope

All control messages are JSON text frames with a `t` discriminator. Client
JSON must be less than 64 KiB of UTF-8. Server JSON must be less than 1 MiB of
UTF-8; an encoder result at or above the ceiling closes only its target with
code `1011` and records a payload-free invariant log. Runtime validators copy
only recognized fields and reject malformed values, invalid ids, non-finite
numbers, and unsupported verbs.

### Guest to Durable Object

- `hello`: `{"t":"hello","proto":2}`
- `cursor`: `{"t":"cursor","pos":{"ws","pane","x","y"} | null}`
- `chat`: `{"t":"chat","text","bubble":{"ws","pane","x","y"}?}`
- `input`: `{"t":"input","ws","pane","data"}`
- `terminal-resync`: `{"t":"terminal-resync","ws","pane"}`
- `sub`: `{"t":"sub","ws","pane"}`
- `unsub`: `{"t":"unsub","ws","pane"}`
- `focus`: `{"t":"focus","ws":<id|null>}`
- `ack`: `{"t":"ack","nonce":"<opaque string>"}`

Cursor coordinates are finite numbers in `[0,1]`. A cursor or chat bubble is
kept only when its workspace is shared and its pane is a current terminal leaf.
Guest input is relayed only for an active editor, the shared workspace, and the
exact terminal pane in the latest stored host layout. Input is limited to
16 KiB of UTF-8.

Each connection can subscribe to at most 64 current terminal leaves. Layout
updates immediately remove subscriptions to deleted or non-terminal leaves and
report the new counts to the host.

Non-host application ingress has a fixed one-second budget of 120 non-ACK
messages and 512 KiB of UTF-8 per socket. Pending, viewer, invalid, and
unknown/replayed ACK messages consume it. An exact same-socket outstanding ACK
is exempt. Exceeding this abuse budget closes only the sender with code `4008`
and reason `rate_limited`.

### Host to Durable Object

- `hello`: `{"t":"hello","proto":2,"shared":[...],"layouts":[...]}`
- `layout`: `{"t":"layout","layout":{...}}`
- `shared`: `{"t":"shared","shared":[...]}`
- `approve`: `{"t":"approve","user","role"}`
- `deny`: `{"t":"deny","user"}`
- `kick`: `{"t":"kick","user"}`
- `role`: `{"t":"role","user","role"}`
- `cursor`, `chat`, and `focus`: same shapes as guest messages
- `end`: `{"t":"end"}`

`shared` contains at most one workspace. `layouts` contains at most its matching
layout. A layout has at most 128 leaves and depth 16. Split ratios are finite
numbers strictly between zero and one. Pane ids are unique within a layout.

### Durable Object to clients

- `session-state`: full shared workspace, layout, participants, bounded chat,
  and the receiver's role
- `presence`: current approved participants and focus
- `access-pending`, `access-denied`, and `access-request`
- `layout` and `shared`
- `cursor` and `chat`
- `role-changed` and `kicked`
- `resync`
- `session-ended`
- `error`
- `ack-request`: `{"t":"ack-request","nonce":"<opaque string>"}`

The host also receives `guest-input`, `guest-resync`, and `guest-sub`.
`guest-input.user` and `guest-resync.user` always come from the verified
socket attachment.

## Terminal transport

Binary frames use a fixed 56-byte header. All integers are unsigned and
network byte order:

```text
0   magic             4 bytes  "CMXS"
4   transportVersion  u8       1
5   kind              u8
6   flags             u16      0
8   epoch             16-byte UUID
24  sequenceStart     u64
32  sequenceEnd       u64
40  rows              u16
42  columns           u16
44  workspaceLength   u16
46  paneLength        u16
48  userLength        u16
50  reserved          u16      0
52  payloadLength     u32
56  workspace UTF-8, pane UTF-8, user UTF-8, opaque payload
```

Kinds are:

- `1 baseline`: host to subscribed guests. Epoch is nonzero, start equals end,
  rows and columns are nonzero, and user is empty. Payload is a complete VT
  baseline that xterm can write directly. It starts with private OSC 777,
  `cmux-theme-v1;<base64url TerminalTheme JSON>`, terminated by ST. The cmux
  viewer installs that validated theme as xterm's reset base before parsing the
  remaining standard VT stream. Other terminal parsers safely ignore the
  private OSC.
- `2 output`: host to subscribed guests. Epoch is nonzero, geometry is either
  empty or has nonzero rows and columns, user is empty, and end equals start
  plus payload byte length. Payload is the next contiguous raw PTY byte range.
- `3 input`: editor guest to host. Epoch, sequences, geometry, and user are
  empty. Payload is 1 to 16 KiB of raw terminal input.
- `4 forwarded input`: Durable Object to host. It has the input shape, but the
  Durable Object rewrites the frame and inserts the verified socket user id.

The complete frame must be less than 1 MiB. The declared identifier and payload
lengths must consume the frame exactly. Exact-limit, oversized, truncated,
invalid-UTF-8, unknown-kind, invalid-version, invalid-sequence, and invalid-role
frames are rejected without forwarding a prefix. Oversize closes the sender
with `1009`; other invalid binary closes the sender with `4400`.

The Durable Object treats a validated payload as opaque. It routes host
baseline and output only to active subscribers of the exact current terminal
pane. It accepts input only from an active editor subscribed to that exact
pane. Viewers, pending guests, stale subscriptions, non-terminal leaves, and
caller-supplied identities cannot send terminal input.

The host sends a baseline when a pane gains its first subscriber, after an
epoch change, and after `guest-resync`. A guest requests resync only while
active and subscribed. Requests are limited to two per socket and eight per
room in each fixed one-second window. Excess requests receive one bounded
`rate_limited` error per socket per window.

Every logical JSON or binary payload is followed by one `ack-request`. Before
sending either frame, the Durable Object generates a fresh
`crypto.randomUUID()` nonce and serializes a compact `[nonce, chargedBytes]`
entry into that socket's hibernation attachment. The charge is the exact
payload UTF-8/binary size, exact ACK-request UTF-8 size, and a conservative
ten-byte WebSocket framing allowance for each frame. Payload is sent first,
then its ACK request.

A socket may hold at most 128 outstanding entries and strictly less than 2 MiB
of charged bytes. A prospective 129th entry or total at or above 2 MiB closes
only that socket with code `4008` and reason `slow_client`. Unknown, duplicate,
replayed, and cross-socket ACKs release zero credit. A serialization failure or
either send failure closes and disconnects that socket with `1011`; dispatch
never continues with untracked payload. Healthy sockets and reconciled presence
and subscription effects continue.

ACK nonces are opaque strings of 1 to 64 UTF-8 bytes without Unicode
general-category `Cc` control characters. A generated UUID collision with the
socket's current window is retried four times before failing closed.

The Durable Object does not buffer or reorder terminal frames. A guest detects
an epoch or sequence gap, stops acknowledging dependent output, and requests a
new baseline. Delivery credit is released only after the browser terminal has
consumed the payload. Concurrent host and guest PTY input is serialized by
arrival at the authoritative host.

The viewer keeps one FIFO delivery batch for every payload whose xterm write is
still pending, up to the relay's 128-entry window. It emits each ACK only after
xterm's write callback and never lets a later payload displace earlier credit.
Outbound guest traffic created while a payload is pending follows that
payload's ACK.

xterm's public `onData` includes both user input and terminal-generated DA,
DSR, OSC-query, window, and focus replies. The pinned xterm 6.0.0 integration
forwards `onData` only when xterm's synchronous user-input signal fired
immediately before it. `onBinary` remains byte-exact for xterm's binary mouse
reports. Ghostty stays the sole owner of application-query replies on the host
PTY.

## Chat, cursors, and persistence

Chat text is limited to 4,000 UTF-8 bytes. Storage retains the newest messages
within both a 500-message limit and a 256 KiB serialized limit. Persisted grants
and denials are capped at 256 entries each.

Chat accepts two messages per socket and eight per room per fixed one-second
window. Excess chat is not persisted or fanned out; each socket receives at
most one bounded `rate_limited` error per window. Terminal input accepts 60
ordered editor messages per socket and 240 per room per window across JSON and
binary input combined. A 61st valid editor input closes that sender with
`4008/rate_limited`; room exhaustion drops the input without closing a healthy
peer. Sub/unsub accepts 64 real mutations per socket and 256 per room per
window, with one bounded error per socket and window. Existing-sub and
missing-unsub operations are idempotent and produce no host update.

Cursor traffic accepts 30 updates per socket per fixed one-second window. The
room emits at most 240 source broadcasts and 4,096 recipient deliveries per
window. Excess positions coalesce to the latest value in one bounded dirty
entry per sender. Later windows drain dirty senders round-robin so one sender
cannot permanently starve another.

The WebSocket hibernation API serializes validated identity and the compact
delivery-credit window. On wake, attachments are validated before use.
Membership is rebuilt, but snapshot/resync effects remain pending until a
waking ACK has first released its old persisted entry. Volatile focus, rate
windows, cursors, and subscriptions are rebuilt. Approved clients receive a
fresh `session-state` and `resync`, then re-send `focus`, `sub`, and cursor
state. The host re-sends `hello` and baselines for active subscriptions.
Snapshots include all 256 grants plus the host; if combined valid state reaches
the 1 MiB server ceiling, oldest chat is omitted from that snapshot only until
it fits. An ended tombstone also re-arms its fixed cleanup deadline on wake,
including legacy state that predates the persisted end timestamp.

A successful wake with surviving sockets writes one `hibernation_restore`
information event containing only the bounded survivor socket count and
outstanding ACK entry count. The event never includes a share code, token,
identity, workspace, pane, terminal payload, or chat content.
