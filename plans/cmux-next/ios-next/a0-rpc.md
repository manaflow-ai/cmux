# A0 `rpc`: the `cmux.mobile/1` wire

Status: landed on `feat-cmux-next-ios-a0-rpc`, 2026-10-06. Plan: [PLAN.md](PLAN.md) section 2 (A0).
Binding: OWNERSHIP-PRINCIPLES.md, architecture.md, transport.md, ghostty-next.md sections 2 and 6.

`cmux.mobile/1` is the contract between the iPhone, the Durable Objects and the Mac. It adds as little
as possible: control-plane JSON frames are `cmux.wire/1` frames (backend/packages/ownership
`types.ts`), terminal output is `terminal-snapshot-v1` (`Packages/Shared/CmuxTerminalStream`),
browser and remote desktop are `cmux.rb/1` on `cmux.rd/1` (`cmux-rd-proto`). New here: the session
handshake with capability negotiation, a `read` frame, ephemeral `signal` frames, the stream-plane
record framing, the channel lifecycle, and one catalog that names every message, its family, its plane
and its owner.

Artifacts:

| What | Where |
| --- | --- |
| Catalog (every message: family, kind, plane, direction, owner) | `schemas/mobile-rpc/catalog.json` |
| JSON Schemas (envelope, per-family params) | `schemas/mobile-rpc/envelope.schema.json`, `schemas/mobile-rpc/families/<family>.schema.json` |
| Golden fixtures (JSON frames per family, binary records as hex) | `schemas/mobile-rpc/fixtures/` |
| Swift codec | `Packages/Shared/CmuxMobileWire` (module `CmuxMobileWire`) |
| TS codec | `backend/packages/protocol/src/mobile-wire*.ts` (exported from `@cmux/protocol`) |

## 1. Planes

| Plane | Carrier | JSON frames | Binary |
| --- | --- | --- | --- |
| `control` | hibernating WebSocket to a Durable Object (`/v1/wire/<scope>`, subprotocol `cmux.wire.v1`) | `cmux.wire/1` + section 2 additions | none |
| `stream` | a `CmuxLink` session to the Mac (lane A3; carriers V1 to V3) | JSON-flagged records (section 3) | records (section 3) |

Rule for a family's plane: cloud-owned state and anything a suspended or unreachable Mac must not
block (presence, mirrors, feed, push, pairing, signaling) is `control`. Bytes whose owner is the Mac
session host and whose rate or size would cost a Durable Object request per message (terminal I/O,
video, files) are `stream`.

Ops whose owner is the Mac (workspace and task mutations) are tagged `control`: the phone sends them to
`HostDO`, which forwards the frame to the Mac's socket and relays the Mac's `result`/`reject`/
`request-settled` back (lane B1). When a `CmuxLink` session is up, the client may send the same frame
on the link's `rpc` channel instead; the idempotency key is the same, so the owner dedupes a resend
across carriers. Nothing queues while the owner is unreachable (OWNERSHIP-PRINCIPLES "Offline").

## 2. JSON envelope (both planes)

Every JSON frame is one object with `t`. Receivers ignore unknown fields. A frame type a receiver does
not know is answered with `error {code: "proto.unknown_frame"}` (it is never sent unless a capability
negotiated it).

| `t` | Dir | Fields | Source |
| --- | --- | --- | --- |
| `hello` | C→S | `proto: "cmux.mobile/1"`, `min`, `max` (int versions), `caps[]`, `client {install, platform, app_version, build?}`, `resume[]? {stream, seq}` | new |
| `hello.ok` | S→C | `proto`, `version` (chosen), `caps[]` (intersection), `server_time`, `max_frame` | new |
| `welcome` | S→C | `principal {user, team?, install?}`, `server_time`, `streams[]` | `cmux.wire/1` (DO sends it on connect) |
| `subscribe` | C→S | `stream?`, `after_seq?`, `pending[]?` (unconfirmed idempotency keys) | `cmux.wire/1` |
| `unsubscribe` | C→S | `stream?` | `cmux.wire/1` |
| `snapshot.request` | C→S | `stream?`, `pending[]?` | `cmux.wire/1` |
| `op` | C→S | `op`, `params`, `idempotency_key`, `origin?`, `expected_revision?`, `stream?` | `cmux.wire/1` |
| `read` | C→S | `id`, `op`, `params`, `stream?` | new (reads were HTTP only) |
| `read.result` | S→C | `id`, `value`, `revision` | new |
| `result` | S→C | `tx`, `idempotency_key`, `value`, `revision`, `replayed` | `cmux.wire/1` |
| `reject` | S→C | `tx`, `idempotency_key`, `code`, `message`, `details?`, `retryable`, `replayed` | `cmux.wire/1` |
| `request-settled` | S→C | `tx`, `idempotency_key`, `stream`, `sequence`, `ok` | `cmux.wire/1` |
| `event` | S→C | `stream`, `seq`, `tx`, `op`, `params`, `actor`, `origin`, `at`, `effects?` | `cmux.wire/1` |
| `snapshot` | S→C | `stream`, `seq`, `state`, `decided[]`, `rows?` | `cmux.wire/1` |
| `presence.set` | C→S | `state {active, client}` | `cmux.wire/1` (FeedDO) |
| `signal` | both | `kind`, `session`, `to`, `from?`, `body` | new, ephemeral (section 5.12) |
| `error` | S→C | `id?`, `code`, `message`, `retryable`, `details?` | `cmux.wire/1` |
| `channel.open` / `channel.opened` / `channel.refused` / `channel.close` / `channel.closed` | stream plane, channel 0 | section 3.3 | new |

Envelope fields the plan asks for:

- Message id: an `op` is identified by its client-chosen `idempotency_key` (ULID-like, 8 to 128 chars of
  `[A-Za-z0-9._:-]`); the owner assigns `tx`. A `read` carries a client `id` (per connection, unique
  while in flight). Stream-plane records are identified by `(channel, seq)`.
- Stream id: `stream` is `<kind>:<entity>` (`host:h_…`, `workspace:h_…`, `feed:u_…`, `ssh:u_…`). One
  socket may carry several streams (UserDO secondary streams precedent); frames without `stream` address
  the socket's primary stream.
- Revision: `seq` is the owner's per-stream sequence (u53, starts at 1). A client applies `event` only
  when `seq == mirror.seq + 1`; a jump is a gap and triggers `snapshot.request` (or resubscribe with
  `after_seq`). `revision` in `result`/`read.result` is the decimal string of the seq at the answer.
- Idempotency: every mutation carries `idempotency_key`; replays answer `replayed: true` with the first
  outcome. Resend after reconnect only for intents sent before the disconnect, with their keys.
- Capability negotiation: `hello`/`hello.ok`. The server picks the highest common version in
  `[min, max]` and returns the caps both sides listed. Optional behavior (a new frame type, record flag,
  channel kind or message field with semantics) is used only when its cap is in `hello.ok.caps`.
  Version mismatch: `error {code: "proto.version_unsupported", details: {min, max}}` then close 4002.
- Errors: one shape everywhere, `{code, message, retryable, details?}`, in `reject` (ops),
  `error` (reads, protocol), `channel.refused` and `channel.closed` (channels). Codes are dotted
  `<area>.<reason>`: the shared ones are `validation.invalid`, `auth.unauthenticated`, `auth.forbidden`,
  `idempotency.conflict`, `revision.conflict`, `owner.unreachable`, `proto.unknown_frame`,
  `proto.version_unsupported`, `proto.bad_record`, `channel.unknown_kind`, `channel.credit_exceeded`,
  `channel.not_found`, `channel.closed`; families add their own (listed in the catalog `errors`).
- Versioning: the proto string names the major (`cmux.mobile/1`). Within a major, changes are additive
  and cap-gated. Binary sub-formats carry their own versions where they already have one
  (`snapshot_version` u16, rd `VERSION`). A breaking change is `cmux.mobile/2`, negotiated by `max`.

## 3. Stream plane framing (binary)

### 3.1 Record

Every stream-plane unit is a record. The header is the `cmux.wire/1` channel header from
sync-and-transport.md section 4 (the one `TerminalFrame` already sits behind), little-endian:

```
u32 channel | u64 seq | u8 flags | payload
```

- Message carriers (WebRTC data channel, WebSocket): one record per message, no length.
- Byte-stream carriers (direct TCP, overlay TCP): `u32 LE length` of header + payload, then the record.
  Max record 1 MiB (as `cmux.rd/1` `MAX_STREAM_FRAME`); larger data is chunked by the channel.
- Cost: a keystroke is 13 + 1 + n bytes (17 + 1 + n framed), below one SCTP/DTLS or WireGuard header.

Flags (reserved bits must be 0; a record with an unknown bit is `proto.bad_record` unless a cap
negotiated it):

| Bit | Name | Meaning |
| --- | --- | --- |
| 0x01 | `keyframe` | the payload restores state by itself (terminal `snapshot_ready`); the receiver may drop older queued records of the channel |
| 0x02 | `json` | the payload is one UTF-8 JSON object `{t, ...}` (low-rate channel messages); otherwise binary |
| 0x04 | `credit` | flow control, not data: payload `u64 ack_seq`, `u32 grant_bytes`; `seq` is 0 and not counted |
| 0x08 | `fin` | the sender's last record on this channel direction |

`seq` starts at 1 per channel and direction and grows by 1 for every data record (json or binary).
A receiver that sees a jump on a reliable channel closes it with `proto.bad_record`; on a `datagram`
channel a jump is loss and is allowed.

### 3.2 Channels

Channel 0 is the session channel: only JSON records (`hello`, `hello.ok`, `channel.*`, `error`).
The dialing side (phone) opens odd channel ids, the accepting side (Mac) even ids; an open with the
wrong parity or a used id is refused (pane-protocol decision 3).

| Class | Carrier mapping (A3) | Credit | Used by |
| --- | --- | --- | --- |
| `interactive` | reliable ordered, high priority | yes | terminal, rpc, browser and rd control |
| `bulk` | reliable ordered, low priority | yes | files, terminal history |
| `datagram` | unreliable unordered | no | rd/browser media datagrams |

Credit: the receiver grants a window in `channel.open.window` / `channel.opened.window` and tops it up
with credit records. A sender never has more than the granted bytes of payload unacknowledged; a
violation closes the channel with `channel.credit_exceeded`. The terminal window defaults to
`terminal.viewerBacklogBytes` (262144). The host-side overflow rule of ghostty-next.md section 2 (drop
backlog, send `snapshot_ready`) applies to terminal channels, never a disconnect.

### 3.3 Channel lifecycle (JSON on channel 0)

- `channel.open {channel, kind, class, window, params, resume? {recv_seq}}`
- `channel.opened {channel, window, params, resumed}`
- `channel.refused {channel, code, message, retryable, details?}`
- `channel.close {channel, code?, message?}` (graceful when no code)
- `channel.closed {channel, code?, message?}` (owner's final word; also unsolicited, e.g. kicked)

Resume: after a reconnect the client reopens each channel with the same `params` and `resume.recv_seq`
(the last contiguous seq it applied). The owner either replays (`resumed: true`) or starts fresh
(`resumed: false`); terminal channels always restart from a `snapshot_ready` (ghostty-next.md
section 2), so terminals never need a replay buffer.

### 3.4 Channel kinds and payloads

| Kind | Binary payload | JSON messages (`t`) |
| --- | --- | --- |
| `rpc` | none | `cmux.wire/1` frames from section 2 (`op`, `read`, `result`, ...) to the Mac owner |
| `terminal` | host→viewer: `TerminalFrame` (`u8 kind, u32 generation, u64 offset, u16 snapshot_version?` + payload; `terminal-snapshot-v1`). viewer→host: `TerminalInput` = `u8 kind` (0 `bytes`: Ghostty-encoded keys, mouse and committed text; 1 `paste`: UTF-8 text, the host applies bracketed paste by its own mode) + payload | `terminal.*` (section 5.3) |
| `browser` | one `cmux.rd/1` stream frame without its u32 length: `u8 rd type` (1 control JSON, 2 datagram, 3 bulk) + payload; `cmux.rb/1` messages ride as rd control | none of its own |
| `rd` | same as `browser`, rd service `desktop` | none of its own |
| `files.upload` / `files.download` | `FileChunk` = `u64 offset` + bytes | `files.*` (section 5.6) |

## 4. Catalog

`schemas/mobile-rpc/catalog.json` lists every message:

- `name`: dotted, `<family>.<noun>[.<verb>]`. Ops that already exist in the cloud catalog keep their
  names (`feed.*`, `push.target.*`) and are marked `existing`; their params are the cloud op's params.
- `kind`: `op` (client mutation, echoed as `event`), `read`, `owner` (committed only by the owner,
  seen as `event`), `channel` (a `channel.open` kind), `message` (a JSON record on a channel),
  `record` (a binary record), `signal` (ephemeral relayed frame).
- `plane`: `control` or `stream`. `dir`: `c2s`, `s2c`, `both`. `owner`: the single writer.

Both codecs embed the catalog and a test asserts they equal the JSON file, so a message cannot be added
on one side only.

## 5. Families

Params are in `families/<family>.schema.json`; one fixture per message is in
`fixtures/<family>.json`. Ids: `h_…` host, `ws_…` workspace, `pane_…`, `tab_…`, `term_…` (daemon public
ids), `in_…` install, `fi_…` feed item, `task_…`, `ssh_…`, `sess_…` signaling session.

### 5.1 host (control; owner `HostDO`, registry `TeamDO`; stream `host:<host>`)
`host.list` (read): hosts the principal may reach with presence and caps. `host.presence.set` (owner,
the Mac via its HostDO socket): `online | offline | sleeping | paused`, viewer count. `host.caps.set`
(owner): the Mac's `cmux.mobile` caps and versions, so the phone knows before dialing. `host.wake` (op):
wake a paused VM or a sleeping Mac (`wake` relay frame).

### 5.2 workspace (control; owner the Mac workspace store, mirrored by `HostDO`; stream `workspace:<host>`)
Snapshot state is the host's workspace list with panes and tabs (arrangement only, no scrollback).
Owner events: `workspace.upsert`, `workspace.remove`, `workspace.tab.upsert`, `workspace.tab.remove`,
`workspace.status.set` (tab status `idle | running | needs_input | error`, unread count),
`workspace.preview.set` (C5: a tab's preview line, sent only while the host has viewers). Client ops:
`workspace.create`, `workspace.rename`, `workspace.tab.create`, `workspace.tab.close`, and from C5
`workspace.close` and `workspace.read` (caps `workspace.close`, `workspace.read`, `workspace.preview`;
c5-workspaces.md section 2). Selection and
focus are client view state and never on the wire (OWNERSHIP-PRINCIPLES).

### 5.3 terminal (stream; owner the Mac session host)
Channel `terminal` params `{terminal, viewport {cols, rows, px_width, px_height}, visible, counts,
snapshot {format: "ghostsnp", versions[]}}`; opened returns `{generation, cols, rows,
snapshot_version | null, title}`; `snapshot_version: null` means byte replay fallback. Records:
`terminal.output` (TerminalFrame, keyframe flag on `snapshot_ready`), `terminal.input` (TerminalInput).
Messages: `terminal.viewport` (once per gesture end; the keyboard never changes it),
`terminal.presence` (`visible`, `counts`; the size reducer's inputs), `terminal.snapshot_request`
(the existing `snapshot_request` fields: `terminal, reason, have, request_id`), `terminal.history`
(`before`, `max_bytes`; answered with `snapshot_history` frames), `terminal.read_range` and
`terminal.read_range.result`, `terminal.size` (host: new generation and grid), `terminal.title`,
`terminal.exited`, `terminal.kick` and `terminal.kicked` (`by`, `by_name`).

### 5.4 browser (stream; owner the Mac browser host)
Channel `browser` params `{tab, service: "rb/1", screen}`; the channel carries a `cmux.rd/1` session
running the `cmux.rb/1` service unchanged (navigation, tabs, dialogs, menus, input, clipboard). Media:
rd datagrams on a paired `datagram` channel, or a WebRTC video track when C2 chooses it
(`channel.opened.params.media_track`). The tab record itself (url, title) is workspace-store state
(5.2).

### 5.5 rd (stream; owner the Mac rd host)
Channel `rd` params `{display, service: "desktop"}`; same payload mapping as `browser`.

### 5.6 files (stream; owner the Mac)
Channel `files.upload` params `{name, size, mime, sha256, dest {kind: terminal | composer | path, ...}}`,
opened returns `{upload, offset}` (resume point); records `files.chunk`; message `files.upload.end`
(`sha256`) answered by `files.upload.done` (`path`, `size`). Channel `files.download` params `{path}`,
opened `{size, mime, sha256}`. `files.list` is a read over the `rpc` channel (stream plane).

### 5.7 feed (control; owner `FeedDO`; existing cloud ops)
`feed.list` (read), `feed.answer`, `feed.read`, `feed.archive` (ops), `feed.post` (owner event the phone
mirrors). Shapes are the cloud catalog's (`backend/packages/protocol/src/feed.ts`).

### 5.8 notify (control; owner `UserDO`)
`push.target.register`, `push.target.remove` (existing ops), `notify.activity.register` (Live Activity
push token per task or terminal), `notify.activity.end`, `notify.badge.set` (owner: the unread total
the badge shows; same number as the feed counts).

### 5.9 task (control; owner the target host's task runner, receipts mirrored by `HostDO`)
`task.dispatch` (`host, workspace?, agent, model?, effort?, prompt, attachments[] (upload ids from
5.6), template?`) answered with `{task, workspace, tab}`; `task.cancel`; `task.list` (read);
`task.state.set` (owner: `queued | running | needs_input | done | failed`).

### 5.10 ssh (control; owner `UserDO`; stream `ssh:<user>`)
Synced SSH host records (C9): `ssh.host.upsert`, `ssh.host.remove`, `ssh.known_host.add`. Private keys
never leave the device; records name a public key fingerprint. SSH sessions run on the phone and are
rendered by A2; they are not on this wire.

### 5.11 pairing (control; owner `PairingDO` per code, trust store in `UserDO`)
`pairing.hosts` (read: same-account Macs to pair with), `pairing.offer` (the Mac makes a QR code),
`pairing.claim` (the phone presents the code and its device key), `pairing.trust.set` (owner),
`pairing.revoke`.

### 5.12 signal (control; relayed by `HostDO`, never stored)
`signal.turn_credentials` (read, minted by the backend for Cloudflare Realtime TURN), and ephemeral
`signal` frames with `kind` `offer | answer | ice | ice.end | bye`, a `session` id and `to` (an install
or host). The relay sets `from` to the authenticated install and drops a client-sent `from`, as the
datagram relay rewrites `peer` (transport.md section 6). Admission is the host's compiled reachability.

## 6. Codecs

- Swift `CmuxMobileWire` (Swift 6, iOS 17 / macOS 14, `Sendable`, one type per file): `MobileFrame`
  (JSON envelope, lossless `JSONValue` params), `MobileCatalog.v1` and `MobileMessage`, `StreamRecord`,
  `RecordFlags`, `CreditGrant`, `RecordDeframer` (byte-stream splitting, linear time),
  `TerminalInput`, `FileChunk`, `RdStreamFrame`, typed channel params (`TerminalChannelParams`,
  `TerminalViewport`). Terminal output decodes with `CmuxTerminalStream.TerminalFrame` (dependency,
  not a copy).
- TS `@cmux/protocol` (`mobile-wire.ts`, `mobile-wire-binary.ts`, `mobile-wire-catalog.ts`): Effect
  Schema decoders for every frame, the same binary codec, the catalog.
- Control-plane frames decode through `JSONValue` and then the typed struct (two passes); fine at
  control rates, and stream-plane hot paths never touch JSON.
- Tests on both sides round-trip every fixture (decode, encode, JSON-equal), decode and re-encode every
  binary vector byte-exact, check catalog coverage (every message has a fixture), and on TS validate
  every fixture against the JSON Schemas and every `existing` op's params against its cloud Effect
  Schema.

## 7. What other lanes take from here

- B1: add `hello`/`hello.ok`, `read`, `signal` to the DO gateway (`owner-do.ts`), op forwarding to the
  Mac in `HostDO`, streams `host:`, `workspace:`, `ssh:`.
- A3/B2-B4: carry records; map `class` to channels; message carriers drop the length prefix.
- B5: serve channel kinds `rpc`, `terminal`, `browser`, `rd`, `files.*` and the forwarded control ops.
- C1 terminal, C2 browser, C3 rd, C4 files, C5 workspaces, C6 feed, C7 notify, C8 task, C9 ssh,
  B6/C10 pairing: messages in their family section; add typed param structs in their own modules with
  `MobileFrame` `params.decode(as:)`.

## 8. Open

- Whether workspace ops prefer the link `rpc` channel whenever it is up (latency) or always go through
  `HostDO` (one path). Default here: `HostDO`; the link is an allowed carrier with the same keys.
- Browser media: rd datagrams vs a WebRTC video track (C2 decides; both fit `channel.opened`).
