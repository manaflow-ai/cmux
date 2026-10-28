# One app-daemon connection: multiplexed streams, binary frames, a shared-memory output ring

Status: design 2026-10-23 (PL-conn, cmux-4f; owns rule D3 end to end, confirmed by cmux-b6). Rules:
[perf-lead.md](perf-lead.md) D3, D4, D5 (with D1, D6, D8), [PATTERNS.md](PATTERNS.md) P9,
[REVIEW-STANDARD.md](REVIEW-STANDARD.md). Related: [ghostty-integration-DESIGN.md](ghostty-integration-DESIGN.md)
G3/G5/G8 (the agreed binary attach frame), [terminal-host-model-DESIGN.md](terminal-host-model-DESIGN.md)
(holder, daemon is the one parser), [remote-state-ownership.md](remote-state-ownership.md) 1.3 item 4 and 3.2
(the per-view connection costs 3 round trips over SSH).

Code read at feat-cmux-next fbbf611f7b4. `app:` = `Packages/macOS/CmuxNext/Sources/`, `core:` =
`cmux-tui/crates/cmux-tui-core/src/`.

Updated 2026-10-28 at perf/chrome-parity 52f69cc3023 by chrome-parity p05-ipc-193 (the p05-ipc program,
`plans/cmux-next/chrome-parity/p05-ipc.md`, implements this design). The program changes four things here,
for PL-conn to confirm: one shared page-relay connection (2.2), the reason cmux keeps a Unix socket where
Chrome uses Mach (2.3), the reply/event order rule (3.6) and the ring consumer cursor (4.4). Section 1 is
the state before the program; the other sections say what landed and what is still to come.

## 1. Today

- Every terminal view opens its own daemon connection: `TerminalAttachment.attach` makes a new `LineTransport`
  (`app:CmuxNextDaemon/Terminal/TerminalAttachment.swift:117`), then pipelines `identify` + `set-client-info`
  (one round trip), then `attach-surface` (one more). Over an SSH machine the connection is also a new link
  stream that waits for three `opened` markers (`cmux-remote/src/bridge.rs:192,221-268`): 3 sequential round
  trips per pane (remote-state-ownership 1.2: 137 + 67 ms on m1max to aws-m4pro-1). `split-latency-bench.py`
  step 4 times exactly this handshake.
- Per view the daemon runs a reader thread, a `mux-line-out` writer thread, a `mux-control-dispatch` thread
  (`core:server/line_connection.rs`, `connection_scheduler.rs:207`), an attach worker and a notification thread
  (`cmd_attach.rs`, `attach_lifecycle.rs:34`). The daemon admits at most 64 connections
  (`core:server.rs:2501` `MAX_SERVER_CONNECTIONS`); STRESS has 12 x 2 measured terminals plus the rest.
- Output is JSON with base64 `data` (`core:server/terminal_snapshot.rs:509-516`, `render_service.rs:346`).
  App side, per chunk: `read` into a 256 KiB buffer, `LineSplitter` copies into `pending` and again into a
  line `Data` (`app:CmuxNextDaemon/Connection/LineSplitter.swift:23,29`), `JSONDecoder` base64-decodes into a
  third `Data` (`TerminalAttachment+Decoding.swift:153`), `TerminalEventQueue.popMerged` appends into a
  fourth (`TerminalEventQueue.swift:156-161`). Four copies and a base64 decode before Ghostty parses.
- Backpressure blocks the attach connection's reader thread (`TerminalEventQueue.push`, above 8 MiB). That
  is safe only because the connection carries one view; on a shared connection it would stall every
  stream and the control plane.

## 2. Target

- One connection per app per daemon: the control connection `DaemonConnection` already owned by
  `DaemonService` (one per machine, `app:CmuxNextDaemonService/DaemonService.swift:37`). Every terminal view
  is a stream on it. Opening a view costs one request (`attach-surface`) and no handshake: identity and
  capabilities were negotiated once when the connection opened.
- A local terminal's output reaches Ghostty from a shared-memory ring the daemon writes; the app copies no
  output byte (Ghostty parses straight from the mapping).
- Remote daemons, and any stream whose ring is not mapped, carry output in binary frames on the stream.
  No base64 and no JSON for output, replays or snapshots on a client that negotiated frames (D4).
- A slow stream never stalls another stream or the control plane, in either direction (D5).

Targets (perf-lead): attach handshakes per split 0; output bytes copied app-side 0 for local terminals; key
echo and output frame latency no worse, better at STRESS; every daemon op < 2 ms p95.

### 2.1 Connections that stay

Chrome keeps one IPC channel per child process (`content/browser/renderer_host/render_process_host_impl.cc`
`InitializeChannelProxy`) and accepts other channels only when they go to another process or are short-lived
and bounded. cmux does the same. `scripts/cmux-next/ipc-census.py` queue Q4 counts every app socket to a
daemon; `plans/cmux-next/ipc-targets.json` allowlists the sites below, with one reason each.
`ipc-census.py --check` fails on an allowlist entry that matches no site, so an entry goes away with its
site. Done check IPC-1: 0 Q4 sites outside the allowlist.

| Site (`app:`) | Kind | Why it stays |
|---|---|---|
| `DaemonService.start` (`CmuxNextDaemonService/DaemonService.swift`) | control | The one connection per daemon (local and each machine). |
| `DaemonConnection.connectOnce`, `LineTransport.init` bridge open | control | The control connection's own transport and bridge child; the census counts each at its constructor already. |
| `DaemonPrestart.init` | control | The control connection's first attempt, begun at the top of `main`. `DaemonService` adopts it or closes it. |
| `DaemonConnection.shutdownDaemon` (end terminals) | transient | Runs after the control connection closed (a reconnect would start a new daemon) and waits for every host, longer than the control deadline. |
| `SessionEnding.closeEveryWorkspace` | transient | Quit's End Everything, after the control connection closed; closed before `shutdown-daemon`. |
| `DaemonSocketMemory.acceptsConnections` | transient | The launch probe of the remembered socket: connects and closes, sends no request. |
| `ChiefConversationOwner.start` | other daemon | The Chief owner is another daemon (its own session and socket); this is its one control connection. |
| `DaemonCompatBackend.connect` (`CmuxNextMobile/Compat`) | mobile | The mobile host's own connection while a phone is attached, so phone traffic never waits behind the Mac's tree mirror. |
| `UnixSocketLane.connect` (`CmuxNextMobile/DaemonLane`) | phone lane | Splices a paired phone's lane to the daemon under `DaemonLanePolicy`; the daemon sees the phone as its own client. |
| `SessionTransferService.answers` | not a daemon | Probes the source build's acpmux socket; closes at once. |

Sites that move onto the control or page-relay connection, so they are not allowlisted:
`TerminalAttachment.attach` (p05-ipc-095), `SessionJournalRead.read` (100), `LoopbackForwardClient.connect`
(101), `AgentSessionAttachClient.connect` (102), `PageRelayChannel` and `PageRelayDedicatedStreams.openStream`
(104), `AgentPaneGitLink.open` (105), `ChiefProfilePageRelay` (108, landed). Its task removes each one from Q4.

Every raw `connect(2)` of the app goes through `UnixSocketAddress.connect`, and Q4 counts each caller of it
(`ADDRESS.connect(fd)` on a `UnixSocketAddress(path:)` the file binds), not the helper. So
`LineTransport.connect` (under `DaemonConnection.connectOnce`) and `SessionTransferService.answers` have
their allowlist entries. `DaemonConnection.shutdownDaemon` and `SessionEnding.closeEveryWorkspace` still have
none: they open through the shared `LineTransport.open` (`DaemonBridge.swift`), which the census counts at the
helper, and an entry on the helper would also hide `TerminalAttachment` and `LoopbackForwardClient`. They get
entries when Q4 counts each caller of `LineTransport.open`.

### 2.2 The page-relay connection (p05-ipc-103, 104, 108)

Change to the target above: per daemon the app has one control connection and at most one page-relay
connection, not one control connection only. Pages (Home channels, the History page, Markdown and the other
React pages) are streams on that one connection, never on the control connection.

- Why a second connection: the daemon derives a request's origin from the connection's role
  (`request-origin.md`). The control connection derives `user` or `agent`; a `page_relay` connection derives
  `page` for every request, whatever the request says. A page stream on the control connection would make the
  fail-safe default depend on a per-request tag, so one app bug in the tag could run page JavaScript as `user`.
  Chrome keeps the same split: a renderer's messages are judged by the process they came from, never by a
  field inside the message (`content/browser/child_process_security_policy_impl.cc`).
- Wire: `client-hello {role: "page_relay", streams: true}`, capability `page-streams-v1`. Stream 0 only
  opens and closes page streams (`open-stream {stream, page}`, `close-stream {stream}`); every
  `cmux.protocol/2` request names its stream in its origin claim, and the stream's page is fixed for its
  life. Mojo's associated interfaces are the model: many endpoints on one pipe, order kept per endpoint
  (`mojo/public/cpp/bindings/README.md`). The full wire and the security analysis are in
  `request-origin.md` "Page streams".
- Status at 52f69cc3023: the daemon side (103) and Home channels (`ChiefProfilePageRelay`, 108) landed.
  `PageRelayChannel` still opens one connection per page (`PageRelayDedicatedStreams`) until 104 lands; the
  History page keeps a one-page relay until `subscribe {stream}` (148) gives a stream its page's events.

### 2.3 Why a Unix socket, not Mach messages

Chrome's channel on macOS is Mach messages (`mojo/core/channel_mac.cc`); cmux keeps a Unix-domain socket with
SCM_RIGHTS for descriptors:

- The daemon is a cross-platform Rust binary. The same wire runs on Linux (Cloud VMs), across the SSH bridge
  (`cmux-remote`) and through `cmux link dial`; Mach ports exist only on macOS and do not cross a byte stream.
- The ring and shared buffers need only descriptor passing, which SCM_RIGHTS gives on both platforms; the
  holder already uses it (`cmux-holder/src/wire.rs`, now in `cmux-ipc` `fds.rs`, p05-ipc-051).
- The cost is a number, not a guess: `bench-daemon-latency.py` section `syscalls` gives syscalls and context
  switches per message for ping, send and list-workspaces (p05-ipc-002; macOS counters only, Linux rows are not
  evidence). Its row is in section 9. Mach would be reconsidered only if that row shows the socket hop above the
  IPC-9 hop budget (app.send to daemon.pty_write p99 <= 1 ms).

## 3. Wire

Three additive capabilities, each advertised by the daemon in `identify` and by the client in its
connection's `set-client-info`. A peer without one keeps today's behavior for that part.

| Capability | What it adds | Transports |
|---|---|---|
| `attach-streams-v1` | client-minted stream ids, many attaches per connection, stream lanes for requests, `cancel-stream`, `stream-end` | all (JSON lines) |
| `attach-frames-v1` | the stream's events as binary frames (section 3.2) | byte-clean transports only (3.5) |
| `terminal-output-ring-v1` | the shared-memory ring (section 4) | local Unix socket, same uid |

### 3.1 Streams (`attach-streams-v1`)

- `attach-surface` takes `stream` (u16, 1-65535), minted by the client, unique among the streams the
  connection has open. The daemon refuses a duplicate (`stream_in_use`). The id is the client's handle from
  the first byte: the READY snapshot that precedes the reply is already tagged, so the client routes it
  before it has the reply (today the daemon sends READY before the reply, and only "one attach per
  connection" makes that routable).
- Every event of that attach carries the id: JSON events get `"stream": N`; frames carry it in the header.
  This covers the attach's own events and the client-scoped ones the registry sends on attach streams
  (`size-state`, `scroll-changed`, `notification`, `detached`, `overflow`, `digest`).
- Requests that act for a view carry the same `stream` (top-level field next to `cmd`): `send`,
  `resize-attached-view`, `release-attached-view-size`, `set-client-sizing`, `set-size-counts`,
  `set-size-policy`, `snapshot-request`, `detach-attached-view`, `scroll-surface`. The daemon checks that the
  stream is this connection's and names that surface.
- `cancel-stream {stream}` ends a stream at once, also one whose `attach-surface` has not answered yet
  (idempotent: an unknown or ended id answers `ended`). `detach-attached-view` stays valid.
- The last item of every stream is `stream-end {stream, reason}` (`detached`, `overflow`, `canceled`,
  `refused`). Only after it may the client reuse the id: no late frame of an old stream can reach a new one.
- Sizing identity: views of one connection are leases of one client (today each view was its own client).
  The registry already supports several leases per (client, surface) (`client_registry_views.rs:44-82`:
  `view_leases`, `geometry_lease`), and the participant of a view of terminal T is `c<client>[@placement]`
  (`mux/client_sizing_state.rs:139`). Two views of one terminal in one app therefore become one participant
  whose size is the geometry lease's (the focused view in the key window claims it, as today). "Sized for"
  is a cross-device notice and is unchanged. Decided: an app is one sizing participant.
- Kick: `detach-client` aimed at a participant detaches that view only (`own_view_detach_target`, existing);
  aimed at the whole client it now ends every stream of the app and the control connection: the same as
  "disconnect this device". The app shows its disconnect state and does not auto-reconnect (`disconnected-by`).

### 3.2 Binary frames (`attach-frames-v1`)

On a connection that negotiated frames, daemon to client is a sequence of messages; each is either a JSON
line (first byte `{`) or a frame (first byte `0xFF`, never the first byte of UTF-8 JSON). Client to daemon
stays JSON lines.

Header, 16 bytes, little endian:

```
0   u8   0xFF      magic
1   u8   kind
2   u16  stream    the attach stream (1-65535)
4   u32  len       payload bytes, at most 33,554,432 (the existing server message budget)
8   u64  offset    absolute PTY stream offset; meaning per kind
```

This is the agreed G3/G5 header (`\xFFCO` + kind u8 + len u32 + offset u64, also 16 bytes) with the two
spare magic bytes carrying the stream id: on one shared connection a frame must name its stream, and the
one byte that matters for the framing is `0xFF`. No code sends `\xFFCO` yet.

| kind | name | payload | offset |
|---|---|---|---|
| 1 | OUTPUT | raw PTY bytes | offset of the first payload byte |
| 2 | GRID | JSON meta: `cols`, `rows`, optional `history_rows`, `history_digest` (G2 in-band resize marker) | stream offset of the resize |
| 3 | EVENT | one JSON event object, no newline (`size-state`, `colors-changed`, `scroll-changed`, `notification`, `digest`, `detached`, `overflow`, `stream-end`) | stream offset the event applies after |
| 4 | SNAPSHOT | `meta_len u32`, JSON meta (today's `snapshot` fields without `data`), raw data | the READY's cut |
| 5 | SNAPSHOT_MORE | same shape, `phase` `history` or `images` (history stays raw DEFLATE) | the READY's cut |
| 6 | REPLAY | `meta_len u32`, JSON meta (`vt-state` / `resized` fields without `data`, plus `pending_len`), replay bytes then pending bytes | stream offset of the replay's end |
| 7 | RING | JSON meta `{capacity, base, layout}`; one descriptor rides on this frame (SCM_RIGHTS) | ring end when sent |
| 8 | RING_ADVANCE | empty | new ring end: bytes up to here are published |

The p05-ipc program adds kinds in both directions (`cmux-tui/crates/cmux-ipc/src/frame.rs` `FrameKind`); the
u64 at byte 8 is `aux`, an offset for kinds 1-8 and 11:

| kind | name | direction | aux |
|---|---|---|---|
| 9 | INPUT | client to daemon (p05-ipc-078) | flow id |
| 10 | SHARED_BUFFER | both (p05-ipc-115, only with a bench row that beats chunked frames) | size of the attached descriptor |
| 11 | RING_ACK | client to daemon (p05-ipc-119) | the stream offset the client has parsed (4.4) |
| 16-20 | REQUEST, REPLY, ERROR, TYPED_EVENT, CANCEL | both (p05-ipc-071) | u32 request id, u16 method id, u8 priority hint, u8 flags |

- A colors sidecar (`OutputWithColors`) is an OUTPUT (or RING_ADVANCE) followed by an EVENT
  `colors-changed` at the same offset; the client applies colors after the bytes up to that offset. Order
  inside a stream is the wire order, as today.
- GRID decodes to the existing resize event of the attach stream and is applied on the lane in stream
  order, exactly like today's resize (`TerminalSession.applyCanonicalGrid`, then `TerminalGridLock.lock`
  behind every earlier chunk); the reader never acts on it (PL-ghostty review, required). Its
  `history_rows` / `history_digest` feed the local-history READY check; until ghostty-next has an in-band
  reflow, the app still asks for a local-history READY at a resize, so the digest fields are optional.
- The client checks offset continuity: an OUTPUT whose offset is not the end of the last one, outside a
  snapshot, is a gap (section 3.4), never a splice.
- Frame size: the daemon cuts OUTPUT payloads at `OUTPUT_FRAME_MAX`. With at most two queued frames per
  stream (existing `OUTBOUND_BACKPRESSURED_STREAM_CAPACITY`), what queues ahead of one stream's frame is at
  most 2 x `OUTPUT_FRAME_MAX` per other busy stream (section 3.3), so the cap bounds head-of-line delay for
  an echo. Its value comes from the slice-1 fleet run (echo p95 beside 10 floods at 16, 64 and 256 KiB);
  the commit records the numbers.

### 3.3 Flow control (D5)

Daemon to client, per stream:
- The viewer queue (`surface/attach_tap.rs`, bounded by `viewer_backlog_bytes`, 8 MiB default) drops to a
  snapshot when the stream falls behind (existing `fall_behind`). Unchanged.
- At most two frames of one stream wait in the connection's outbound queue (existing backpressure,
  `bounded_outbound.rs` `push_regular_backpressured`). The queue is FIFO across streams, so it round-robins
  the busy streams frame by frame; control replies and events have their own reserve and go first
  (`pop_locked`: initial, control, regular). Changed by p05-ipc-052 and 072: the writer takes lanes in the
  order input streams, the control FIFO (replies and control events together, 3.6), bulk, background, with a
  starvation bound of 8 items; bulk frames are cut at `bulk_frame_max` (32 KiB default) with the MORE flag.
- With the ring, output bytes do not travel on the socket at all: a stream sends one 16-byte RING_ADVANCE per
  drained batch; the viewer queue merges advances (keeps the newest end), so one is in flight at a time.

Client side (`app:CmuxNextDaemon/Connection`):
- The connection's reader thread never waits for a consumer. Each stream has its own bounded queue
  (8 MiB of output, as today's per-view high-water). When a stream's queue would pass it, the reader drops
  that stream's queued output, marks it resyncing, sends `snapshot-request {stream, reason:"overflow"}`, and
  drops the stream's output until the next READY. Other streams and control replies keep flowing.
- Ring streams queue spans of the mapping (no bytes); their bound is the ring itself (section 4.4).

Client to daemon (requests), per stream lane:
- Today one dispatcher thread runs a connection's requests in order (`connection_scheduler.rs`). On a shared
  connection that would put a key for terminal A behind a slow request for terminal B (an attach waits up
  to 1 s for a hosted resize, `cmd_attach.rs:57`; a `send` to a PTY whose program stopped reading waits for
  POLLOUT, `pty_write.rs`). That is head-of-line blocking the per-view connections never had.
- With `attach-streams-v1`, a request with `stream` runs on that stream's lane; every other request runs on
  the control lane (the existing dispatcher, unchanged order). Lanes are independent FIFOs, exactly the
  ordering domains that separate connections gave: requests of one view stay in order, views and the
  control plane do not wait for each other.
- Lane workers (changed by p05-ipc-073): one daemon-wide sequenced pool, not a pool per connection
  (`core:server/sequenced_pool.rs`). Every connection's control sequence and every stream sequence run on it,
  with fixed workers per priority (`mux-seq-input`, `mux-seq-control`, `mux-seq-utility`,
  `mux-seq-background`) that park on a condvar when no sequence is runnable (no timer, no polling, D6), plus
  one temporary worker while a running task is inside a blocking scope. A sequence runs on at most one worker
  at a time. This is Chrome's one ThreadPool with sequences (`docs/threading_and_tasks.md`, "prefer sequences
  to threads"); thread rows in `threading-model.md`.
- Per-lane queue bounds: the existing per-connection request byte and count caps apply per lane
  (`CONNECTION_SURFACE_QUEUE_CAPACITY`, `..._BYTE_CAPACITY`); a full lane refuses its request with
  `known-not-delivered`, as a full connection queue does today.

### 3.4 Gaps and resync

A gap is: an OUTPUT offset that does not continue the stream, an overflowing client queue, a lapped ring
(4.4). The client answers every gap the same way: drop the stream's pending output, `snapshot-request`,
apply nothing until a READY, continue at the READY's offset. The daemon's READY is taken under the
terminal lock at the parser's offset (existing `take_viewer_snapshot`), so ring bytes and OUTPUT from that
offset on continue it exactly.

### 3.5 Which transports carry frames

- Local Unix socket: yes (the app connects directly).
- Paired servers through `DaemonBridge` (`cmux link dial`): yes; after the dial line every hop copies opaque
  bytes (`dial_cli.rs:191-206`, `link/inbound.rs:149-176`).
- SSH machines (`cmux-tui remote connect`): not in slices 1-4. The SSH bridge splits on `\n` and parses JSON
  in both directions and spreads one connection across lanes (`cmux-remote/src/mux_codec.rs:34-54`,
  `mux_lanes.rs:113-200`, `services.rs:1350`). The app does not advertise `attach-frames-v1` there and gets
  JSON with `stream` ids (3.1 still removes the 3 round trips per pane). Slice 5 teaches the bridge frames
  ("the SSH link keeps the framed stream"): the remote side reads a `0xFF` message by its header, sends all
  frames of one stream on one lane (OUTPUT on Bulk keeps the stream's order only if the stream's EVENTs ride
  the same lane: per-stream lane, not per-kind), and the app side writes them unchanged.
- WebSocket: no (text messages only, `websocket_listener.rs:422-448`); those clients keep JSON.

The client decides by endpoint (it knows which path it opened); the daemon never grants `attach-frames-v1`
to the remote entry transport (`ClientTransport::Remote`) or a WebSocket.

### 3.6 Reply and event order (p05-ipc-007, 052, 120)

Change to 3.3: control replies do not have a reserve that goes before events. On one shared connection the
app uses "the events read before this reply" as a barrier (`LineTransport.routedEventCount`, a reply's
`eventBarrier`), so a reply that passes its own events breaks the store's read-your-writes. The rule, written
in full in `cmux-tui/spec/transports.md` "Reply and event order":

1. Stream 0 (the control sequence) is one FIFO: command replies, the events of the connection's `subscribe`
   and the items of `session.events`. Priority never reorders inside it (p05-ipc-007, LaneWriter p05-ipc-052).
2. A reply is enqueued after every event its request emitted. This needs events emitted at admit time, before
   the reply (p05-ipc-120); until 120 lands the rule is not in force, and the two
   `*_under_stream_flood_*` tests of `reply_event_order` are ignored and red.
3. Every other stream (attach output, journal reads, loopback forwards, agent-session attaches) keeps its own
   FIFO; priority may move it relative to other streams, never inside itself. `routedEventCount` counts stream
   0 only, so a terminal flood never moves the barrier.
4. A control-lane command whose surface has an open stream on the connection waits for that stream's queued
   items (the stream barrier, p05-ipc-073), unless the schema marks it `crosses_stream_ok` with a reason.

Mojo keeps the same promise per pipe ("reliable in-order delivery", `mojo/core/README.md`) and gives priority
only through the receiving scheduler (`[SupportsUrgent]`), never by reordering the channel.

## 4. The output ring (`terminal-output-ring-v1`)

### 4.1 Who writes, who reads

- One ring per terminal, made by the daemon on the first ring attach. The single writer is the daemon's
  output path: `PtySurface::broadcast_attach_output` (`core:surface/pty_surface.rs:110`), which already
  counts the stream offset (`snapshot_position.add_output`) and feeds every viewer, under the terminal's
  output order. The ring holds exactly the bytes the daemon parsed, at the same offsets as its snapshots
  (the holder agreement: the daemon is the one parser; the holder's own ring is the holder-to-daemon hop and
  is not this ring).
- Readers: the app's ring streams of that terminal (one per attached view). Readers never write the ring.
- Snapshot viewers only (the app's normal attach). A byte-replay attach keeps OUTPUT frames.

### 4.2 Layout (little endian)

```
0   magic "CMAR"  (4)
4   layout u32 = 1
8   capacity u64
16  base u64       offset of the first byte this ring held
24  end u64        atomic: offset after the last published byte
32  reserve u64    atomic: offset after the last byte the writer has started to write
40  zero to 64
64  data[capacity]; the byte at offset o is at data[o % capacity]
```

Writer, per chunk of n bytes at `e = end`: `reserve.store(e+n)`; release fence; copy the bytes (one or two
`memcpy` across the wrap); `end.store(e+n, Release)`. A chunk larger than the capacity keeps its last
`capacity` bytes. Reader of `[s, t)`: read the bytes (Ghostty parses them in place), acquire fence, then
`reserve.load()`: if `reserve > s + capacity` the writer may have overwritten part of `[s, t)` while it was
read: a gap. This is the seqlock rule; the reader detects every overwrite, the writer never waits. With
the consumer cursor (4.4, p05-ipc-119) the writer also never overwrites a span a reader has not acked.

Capacity: 1 MiB, the holder's per-terminal ring size (resident only as it fills; one copy of the pages,
shared by daemon and app). A reader 1 MiB behind resyncs by snapshot. Slice 3 measures resyncs per minute
in the STRESS flood (10 printing terminals) and the 50 MB/s `cat` flood; if any appear with a healthy app,
the size is raised with that number as its reason.

### 4.3 Mapping and lifetime

- Made with `memfd_create` on Linux and an unlinked `shm_open` object on macOS (name of 128 random bits,
  `O_CREAT|O_EXCL`, mode 0600, opened once read-write for the daemon and once read-only for readers, then
  unlinked at once: no name outlives the call). Close-on-exec.
- Passed in a RING frame with SCM_RIGHTS on the stream's own connection, so the descriptor and the frame
  arrive together and in stream order. The client reads with `recvmsg`, keeps received descriptors in
  arrival order, and a RING frame takes the oldest. A RING frame without a descriptor, a descriptor
  without a RING frame, a bad magic, layout, size or capacity (> 64 MiB) is a protocol error that ends the
  connection (the reconnect path, never a silent fallback).
- The client maps the read-only descriptor `PROT_READ, MAP_SHARED` and closes it. The mapping is owned by
  a reference-counted ring object: the stream holds one reference and every span of output handed to
  Ghostty holds one (`Data(bytesNoCopy:deallocator:)`). The last release unmaps. So detach, `stream-end`,
  connection loss and app quit unmap once Ghostty has finished the last span, never under it.
- The daemon unmaps its view when the terminal ends; a reader's mapping keeps the pages valid until it
  unmaps (POSIX object lifetime), so a daemon exit or crash never faults the app.
- Daemon restart: the connection drops, streams end, the app reattaches to the new daemon (snapshot, new
  ring). Holder restart: the daemon keeps every master and keeps writing the ring (terminal-host-model 5);
  nothing changes for the app.
- Reconnect and resume by offset: a reattach names `resume_offset` (the end the app parsed). When the daemon
  still holds the terminal's ring and the offset is inside it, the attach skips the READY and sends RING plus
  RING_ADVANCE from that offset; otherwise a READY as today. (Slice 3; saves the snapshot on a stream
  restart inside one daemon, e.g. after a client queue overflow that recovered.)

### 4.4 Reading and zero copy

- RING_ADVANCE to `t`: the reader turns `[cursor, t)` into at most two spans (wrap). It checks the
  `reserve` rule when it cuts the spans, before anything is queued (PL-ghostty review, required): if
  `t - cursor > capacity` or `reserve > cursor + capacity` the bytes are already lost or being overwritten,
  nothing is queued, and the stream goes straight to the gap path (3.4). Only spans that pass are queued as
  `.output(Data(bytesNoCopy: base + s % cap, count:, deallocator: .custom { release, validate }))`.
- The deallocator runs when Ghostty's lane has parsed the span and dropped it, and checks the rule again: a
  writer that lapped the reader during the parse marks the stream lapped (the next event is the resync).
  The check at cut time keeps a torn span from reaching the mirror's parser, grid lock and local-history
  digest whenever the lap had already begun; the second check covers a lap that starts during the parse,
  whose READY then replaces the terminal state.
- Consumer cursor (change by p05-ipc-119, not landed at 52f69cc3023). The two checks above detect a lap but
  cannot stop one: a writer that laps a span Ghostty is still parsing has already torn it. So the reader also
  tells the writer how far it has parsed: the app sends RING_ACK with aux = the end of the last span its lane
  released, coalesced to one per display frame. The daemon keeps each reader's acked offset and never writes
  the ring past the lowest of them plus `capacity`. A chunk that would pass it is not written to the ring,
  and every reader of the ring is marked gap-pending: its next RING_ADVANCE is a gap (3.4, resync by READY).
  The ring is one per terminal, so a chunk skipped for the slowest reader is missing for the others too;
  they are views of one app, which resync together. The PTY and the writer never wait: a slow reader loses
  its place and resyncs, it never slows the terminal. The release-time check stays, as a
  counter (`release_laps`, 0 when the cursor works). Chrome's data pipes have the same rule: the producer
  cannot write past unread data and a two-phase read holds its span (`mojo/public/c/system/data_pipe.h`);
  cmux differs only in that its producer skips instead of waiting, because the PTY must keep flowing for
  every other viewer. PL-ghostty and PL-holder sign off on 119.
- Each OUTPUT frame and each span is its own `.output` event in stream order. Spans merge only with the
  adjacent span of the same mapping, never across a GRID, SNAPSHOT, REPLAY or any other event (PL-ghostty
  review, required: a merge must not move bytes past a grid lock). Since G4, `.output` goes from the
  session's events loop straight to the lane; every other event hops to main in stream order.
- Copies app-side: none. The span reaches `ghostty_surface_process_output` through `withUnsafeBytes`
  (`app:CmuxNextTerminal/TerminalOutputLane.swift:59-62`). Every stage between must pass the `Data` through
  without appending: `TerminalEventQueue` merges spans by range instead of `append` (one span covering two
  adjacent spans of one mapping, or no merge across a wrap); `TerminalStepQueue` (`app:CmuxNextBridge`) and
  the lane already pass `Data` through. Guard: a test reads the span's base address at
  `process_output` and checks it lies inside the mapping.

### 4.5 Security

- The ring carries the terminal's output, which the stream already carries; the same peer may read it. The
  daemon grants it only on a local Unix connection whose peer has the daemon's euid (`getpeereid`), and
  that is trusted by the existing origin gate as the app (`request_origin`); never on the remote entry,
  a relay, a WebSocket, or a `DaemonBridge` link.
- The reader's descriptor is read-only (opened `O_RDONLY` before the unlink), so a reader cannot change the
  ring. The daemon never reads the data area back, so nothing a reader does reaches the parser.

## 5. App side

- `LineTransport` becomes a message transport: the reader loop reads with `recvmsg` (descriptors) into a
  fresh buffer per read, cuts JSON lines and `0xFF` frames, and hands frames to a `StreamDemux`
  (stream id to sink) without copying: a frame payload is a slice of the read buffer.
- `TerminalAttachment` keeps its public surface (`TerminalByteChannel`, `events`, the synchronous command
  path) and becomes a stream on the machine's `DaemonConnection`: it mints the stream id, registers its sink
  before it sends `attach-surface`, and sends every command on the shared transport with `stream`. No
  `identify`, no `set-client-info` per view. `detachNow` sends `cancel-stream`; the id is freed at
  `stream-end` or when the connection ends.
- Reconnect: when `DaemonConnection` replaces its transport, every stream on the old one ends with
  `connectionLost`; the existing attach machine reattaches on the new connection epoch
  (`app:CmuxNextApp/TerminalLinkWatch.swift:82-86`). No new reconnect path.
- Decode ownership: the frame decode is part of the connection layer (`CmuxNextDaemon/Connection`) and maps
  to the existing `TerminalChannelEvent`s, so PL-ghostty's surface files see the same events (the agreed
  Swift decode hand-off: PL-conn writes it, PL-ghostty reviews it).

## 6. Versioning

- Old app, new daemon: no capability, today's per-view connections and JSON.
- New app, old daemon: the daemon does not advertise the capabilities; the app uses per-view connections.
- One release keeps the per-view path in the app behind `CMUX_NEXT_TERMINAL_STREAMS=0` (default on), then
  slice 4 deletes it. The daemon keeps JSON/base64 output for the other clients (iOS `CmuxMobileSSH`,
  `cmux-next-ios` CmuxMobileLive, the cmux-tui TUI, the Rust and TypeScript SDKs, chatmux-relay) until each
  negotiates frames; nothing changes for them.

## 7. Slices

Each lands on feat-cmux-next with a red guard first (P13), Rust checks via `scripts/ci/cmux-tui-rust-check.sh`,
the app and `cmux-unit` compile and suites via `cmux-ci`, and the split and new-terminal benches light and
STRESS before and after.

1. **Streams and frames on one connection (daemon + app transport).** `attach-streams-v1`,
   `attach-frames-v1`, stream lanes, `cancel-stream`, `stream-end`; app `LineTransport` frame decode and
   `StreamDemux` with non-blocking per-stream queues. Red: a daemon test attaches two streams on one
   connection, floods one through a reader that stops, and requires the other stream's echo and a control
   reply within the bound (today: one connection's dispatcher serializes them); a frame codec round trip;
   a lane test where a blocked `send` on stream A does not delay `send` on stream B.
2. **TerminalAttachment on streams.** Views attach on the machine's connection; no per-view handshake.
   Red: `split-latency-bench.py` new mode `--streams` reports `attach_handshake` 0 round trips; an app test
   counts connections opened per new view (1 today, 0 after).
3. **Shared-memory ring.** Daemon writer, RING / RING_ADVANCE, app mapping, zero-copy spans, lap detection,
   resume by offset. Red: copied-bytes counter app-side for local output (> 0 today, 0 after); a lap test
   (reader holds a span while the writer laps) requires a resync and a correct screen.
4. **Remove the per-view path** after one release: the flag, the per-view `LineTransport`, the blocking
   `TerminalEventQueue` mode.
5. **SSH bridge frames** (cmux-remote): frames over the link, per-stream lane, `stream` kept on `send`.

## 8. Files (for coordination)

Daemon, connection and stream layer only: `core:server/{line_connection, message_writer, bounded_outbound,
render_service, connection_scheduler, connection_frame, cmd_attach, terminal_snapshot, attach_lifecycle,
capabilities, client_registry, client_registry_views}.rs`, new `core:server/{attach_frames, stream_lanes}.rs`;
for the ring `core:surface/{pty_surface (broadcast_attach_output only), attach_tap, snapshot_attach}.rs` and
new `core:surface/output_ring.rs`; specs `cmux-tui/spec/{transports, events}.md`. Not touched: the request
handlers' logic, the journal, holder code (`cmux-holder`, `holder_runtime/`), the parser.

App: `app:CmuxNextDaemon/Connection/{LineTransport, LineSplitter}.swift` and new frame/demux files,
`app:CmuxNextDaemon/Terminal/*`, the attach call site in `app:CmuxNextApp/DaemonTerminalIO.swift` (pass the
connection instead of the endpoint), `app:CmuxNextMobile/Compat/DaemonCompatBackend.swift` (same). Not
touched: `CmuxNextTerminal` (TerminalSession, TerminalOutputLane, TerminalSurfaceView), Ghostty.

## 9. Measurements

These are the before/after rows of the p05-ipc done checks (IPC-17 in `chrome-parity/p05-ipc.md` section
5). Each row names its command; a measured cell gives p50 / p95 / p99 / max (no mean alone), light and
STRESS (`scripts/cmux-next/perf-stress-session.py`: 60 workspaces, 10 Chromium workspaces, 10 busy
terminals), and the host, sha, macOS and display Hz it ran at. Every bench writes those fields in its JSON
(`host`, `source.sha` or the daemon's `build_commit`; `bench_launch.py` adds the display's refresh). VM and
Linux timing is not evidence: owned fleet Macs only (`cmux-ci run --class isolated --ref SHA --script ...`).
Daemon-only rows have no display: their Hz cell is `-`.

Batches (p05-ipc rule 12): B0 is the "before" of every row (perf/chrome-parity before the flag flips, with
`CMUX_NEXT_TERMINAL_STREAMS` off); B1 after the streams default (094); B2 after app ring streams (113); B3
after admit-then-reply (120-127). A row's "after" is the batch that closes its check.

At 52f69cc3023 (2026-10-28) no row is measured: B0 has not run on the fleet, the soak (192) and build timing
(194) scripts have not landed, and 094, 113 and 120 are open. A cell says `not measured` until a batch
fills it with its numbers and fields; nothing here is an estimate.

| Check | Row and target | Command (each through `cmux-ci run --class isolated --ref SHA --script '...'`) | Before (B0): host, sha, macOS, Hz, result | After: batch, host, sha, macOS, Hz, result |
|---|---|---|---|---|
| IPC-2 | Handshake round trips per new view == 0, requests per view == 1, app connections per view == 0; local and SSH (`ipc2` block) | `python3 scripts/cmux-next/split-latency-bench.py --tag ipc-b0 --streams` and the same with `--machine ssh --ssh-host HOST` | not measured | B1: not measured |
| IPC-5 | Send-to-reply p95 < 2.0 ms for every `ipc5_ops` op (v12 and v2 creates, split, close, rename, select, move, browser tab, tab groups), small and scale; Q16 empty | `cd cmux-tui && cargo build --release -p cmux-tui && python3 scripts/bench-daemon-latency.py --bin target/release/cmux-tui --ops all --scenario small,scale --write-q16 --out artifacts/daemon-latency.json` | not measured | B3: not measured |
| IPC-7 | After `cat` of 50 MB in a local terminal: `output_bytes_copied_app` == 0 (`debug.daemon.wire`), release laps == 0, STRESS flood ring resyncs/min == 0 | `python3 scripts/cmux-next/bench-typing.py --tag ipc-b2 --flood 10 --stress`, then `CMUX_TAG=ipc-b2 scripts/cmux-debug-cli.sh app call debug.daemon.wire` | not measured | B2: not measured |
| IPC-8 | Ping p99 < 2.0 ms on the connection that carries a 256 MiB flood (`bulk-L-ping-same`, per frame cut 16, 32, 64 KiB) | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin cmux-tui/target/release/cmux-tui --scenario small --bulk-interference 16,32,64 --out artifacts/ipc8.json` | not measured | B1: not measured |
| IPC-8 | Focused echo p95 <= single-terminal p95 + 0.5 ms beside 10 flooders at 10 MB/s | `python3 scripts/cmux-next/bench-typing.py --tag ipc-b1 --flood 10` and `--flood 10 --stress` | not measured | B1: not measured |
| IPC-9 | Key to frame p50 <= 8.3 ms, p99 <= 16.7 ms at 120 Hz; hops app.send to daemon.pty_write and daemon.output to app.output_decoded p99 <= 1 ms | `python3 scripts/cmux-next/bench-typing.py --tag ipc-b1` and `--stress`; the two hops need the flow id of p05-ipc-180 (trace.py joins app, daemon and reply), not landed | not measured | B1: not measured |
| IPC-10 | Daemon threads with 50 attached views and 20 CLI connections minus with 0: <= 2 | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin cmux-tui/target/release/cmux-tui --scenario small --streams 50 --out artifacts/ipc10.json` (`daemon_threads_before`, `daemon_threads_after`) | not measured | after 155 and 156: not measured |
| IPC-11 | 10 terminals, 1 Chromium tab, 10 hidden printing terminals: connection layer 0 wakeups/s on both sides, daemon idle 0/s | `scripts/cmux-next/bench-idle.sh ipc-b0 --scenarios terminals,chromium-static,chromium-hidden --measure 60` | not measured | B1: not measured |
| IPC-16 | Key echo p95 <= idle + 1 ms and split p95 < 2 ms with 8 automation clients, automation >= 50% of its idle throughput (`ipc16` block) | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin cmux-tui/target/release/cmux-tui --scenario small --automation-storm 8 --out artifacts/ipc16.json` | not measured | B3: not measured |
| 2.3 | Syscalls and context switches per message for ping, send, list-workspaces (`syscalls` section; macOS counters only) | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin cmux-tui/target/release/cmux-tui --scenario small --ops base --out artifacts/syscalls.json` | not measured | B1 (frames): not measured |
| IPC-17 | Incremental app build after a leaf edit < 30 s; after a one-field schema edit: seconds and targets rebuilt (p05-ipc-194, before and after 025 and 027) | `scripts/cmux-next/build-timing.sh --leaf-edit --schema-edit` (lands with 194) | not measured | not measured |
| IPC-12, 14 | 30-minute STRESS soak: 0 crashes, 0 `stream-end {overflow}` on visible terminals, daemon RSS within +-5%, `slow_requests` == 0 | `python3 scripts/cmux-next/ipc-soak.py --minutes 30 --flood 10 --stress` (lands with 192) | not measured | not measured |

Counts of the static queues are not measurements: `python3 scripts/cmux-next/ipc-census.py` prints them,
`--check` holds each at or below its recorded count in `plans/cmux-next/ipc-targets.json`.
