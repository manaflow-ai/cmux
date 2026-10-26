# One app-daemon connection: multiplexed streams, binary frames, a shared-memory output ring

Status: design 2026-10-23 (PL-conn, cmux-4f; owns rule D3 end to end, confirmed by cmux-b6). Rules:
[perf-lead.md](perf-lead.md) D3, D4, D5 (with D1, D6, D8), [PATTERNS.md](PATTERNS.md) P9,
[REVIEW-STANDARD.md](REVIEW-STANDARD.md). Related: [ghostty-integration-DESIGN.md](ghostty-integration-DESIGN.md)
G3/G5/G8 (the agreed binary attach frame), [terminal-host-model-DESIGN.md](terminal-host-model-DESIGN.md)
(holder, daemon is the one parser), [remote-state-ownership.md](remote-state-ownership.md) 1.3 item 4 and 3.2
(the per-view connection costs 3 round trips over SSH).

Amended 2026-10-26 by the chrome-parity IPC program
([chrome-parity/p05-ipc.md](chrome-parity/p05-ipc.md), task 193). Section 3.6 adds the page-relay connection,
the reply/event rule, the daemon-wide sequences, frames in both directions and the reason for a Unix socket instead
of Mach messages. Section 4.6 adds the ring consumer cursor. Where those sections replace earlier text, that text
is marked "amended". PL-conn review of the amendment: requested with task 193, not given yet.

Code read at feat-cmux-next fbbf611f7b4. `app:` = `Packages/macOS/CmuxNext/Sources/`, `core:` =
`cmux-tui/crates/cmux-tui-core/src/`.

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
- Pages get at most one more connection per daemon, the page-relay connection (3.6.1), never one per page.

Targets (perf-lead): attach handshakes per split 0; output bytes copied app-side 0 for local terminals; key
echo and output frame latency no worse, better at STRESS; every daemon op < 2 ms p95.

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

Amended (3.6.4): the client also sends frames to the daemon, the u64 field is `aux` (its meaning depends on the
kind), and kinds 9-20 are added.

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
  (`pop_locked`: initial, control, regular). Amended (3.6.2): replies and control events are one FIFO, and a
  reply never passes an event that its own request emitted.
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
- Amended (3.6.3): the lanes are sequences of one daemon-wide pool, not of a pool per connection. The next item
  is the original rule.
- Lane workers: a per-connection pool of threads that park on a condvar when no lane is runnable (no timer,
  no polling, D6). A lane runs on at most one worker at a time. A worker is spawned only when a lane becomes
  runnable and every worker is busy, so the thread count is the high-water of concurrently busy lanes
  (usually 1-2), never more than today's one dispatcher per view.
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

### 3.6 Changes from the chrome-parity IPC program (2026-10-26)

These sections replace the text marked "amended" above. Each one names its Chromium reference. Where cmux
differs from Chromium, the reason is given.

#### 3.6.1 The page-relay connection

Today each page that talks to the daemon opens its own `DaemonConnection` (`PageRelayChannel.swift:177`). Home's
channel list does the same (`ChiefProfilePageRelay.swift:180`). Page streams cannot go on the control connection.
The control connection is proven role `main`, and a request on it acts as the person. If a page request on it
lost its stream tag, or had a false one, it would get the person's rights. That reverses the fail-safe default
of [request-origin.md](request-origin.md).

- Per daemon, the app has one control connection and at most one page-relay connection. The page-relay
  connection gives role `page_relay` in its hello. Each request on it is judged as page origin at minimum, for
  all contents. The default stays fail-safe.
- Each page is a stream on that connection. `open-stream {page}` binds the origin `page:<id>` to the stream for
  the life of the stream. The origin does not change. Stream 0 of the page-relay connection accepts only
  open-stream and close-stream. It refuses an untagged request.
- Confirmation tokens are bound to (op, params hash, stream). A token issued for stream X fails on stream Y.
  The daemon continues to refuse `origin.confirmation.issue` on a page-relay connection. The control connection
  never accepts `open-stream {page}`.
- Home channels (ChiefProfilePageRelay) open a `home-channels` stream on the same connection. The owner
  pid/generation check stays.
- Old daemons: for that daemon, the app keeps one connection per page (tasks 103, 104, 108).

Chrome reference: `BrowserInterfaceBrokerImpl` (`content/browser/browser_interface_broker_impl.h`) binds the
interfaces of a renderer frame, and the browser checks the committed origin of the frame
(`content/browser/child_process_security_policy_impl.cc`, `CanAccessDataForOrigin`). The origin belongs to the
endpoint. Chrome never reads it from a message. A page stream does the same: its origin is set when the stream
opens.

#### 3.6.2 Reply and event order

- The ordering domain is the sequence. A connection has one control sequence. Control replies and control events
  are ONE FIFO in that sequence.
- A reply goes into the queue after every event that its request emitted. When the app sees a reply, it has
  already seen the events of that request (the event barrier of the app).
- Each stream is its own sequence, and its items stay in its FIFO. Priority sets the order between sequences.
  Priority never changes the order inside one sequence.
- App side: `routedEventCount` counts only the stream-0 (control) events. Stream events do not move the barrier.
- Red tests (task 007): a Rust test sends new-tab during a stream flood; its layout-changed is written before
  its reply. A Swift test reads `eventSequence()` after a reply, with 10 streams active; the value is at least
  the sequence of the echo event of that reply.

This rule replaces the separate control reserve of 3.3. With a reserve, a reply could pass an event of its own
request. Chrome reference: a message pipe gives "reliable in-order delivery", and associated interfaces run
"multiple interfaces over a single message pipe while preserving message ordering"
(`mojo/public/cpp/bindings/README.md`; `mojo/public/cpp/bindings/lib/multiplex_router.cc` dispatches one pipe
in order). `[SupportsUrgent]` changes when the receiver runs a message, but it does not change the order on the
channel. cmux priority obeys the same rule.

#### 3.6.3 Sequences on one daemon-wide pool

- One daemon-wide sequenced pool replaces the lane workers per connection of 3.3. The control sequence of each
  connection and each stream are sequences, each with a priority. Each priority has a fixed number of workers
  (input 2, control cores-2, utility 2, background 1). While a task is in a blocking `RequestPathScope` kind,
  the pool adds one temporary worker. The thread count does not change with the number of connections.
- Stream barrier: a control command whose target surface has an open stream on this connection waits until the
  sequence of that stream is empty. Exception: a command that the schema marks `crosses_stream_ok`, with a
  reason.
- One PTY input FIFO per surface, across connections, so that a paste and keys from two clients do not mix.
- One IO reactor thread reads, frames and flushes all connections (tasks 155, 156). It only routes. The typed
  decode runs on the sequence. Connections of the person (proven role main) go before automation, with a
  starvation bound (task 143).

Chrome reference: `docs/threading_and_tasks.md` ("We prefer sequences to threads"; the IO thread is "each
process's thread for receiving IPC", and each message is "dispatched as a scheduled task" on its bound
sequence); `base/task/thread_pool/thread_group.h` (a fixed pool that adds workers for blocking work marked with
`base/threading/scoped_blocking_call.h`).

#### 3.6.4 Frames in both directions

- The header stays 16 bytes, little endian: magic `0xFF`, kind u8, stream u16, len u32 (32 MiB maximum), aux u64.
  Kinds 1-8 keep their meanings from 3.2 and 4. For them, aux is the absolute PTY offset.
- New kinds: INPUT (9; aux = flow id; raw bytes go into the input FIFO of the surface; no reply), SHARED_BUFFER
  (10; aux = size of the attached descriptor), RING_ACK (11; aux = parsed offset, see 4.6), and REQUEST, REPLY,
  ERROR, TYPED_EVENT, CANCEL (16-20). For kinds 16-20, aux is: u32 request id, u16 method id, u8 priority hint,
  u8 flags (binary, fds, flow, urgent, more).
- The daemon takes the priority from its own method table. A header hint that is different is `bad_message`.
  Routing never parses the payload. A bad frame closes the connection with `bad_message+1` and a reason.
- The daemon grants frames only when the api_revision of the client is the same as its own. All other clients
  keep JSON lines.

#### 3.6.5 Why a Unix socket and not Mach messages

On macOS, the Chrome channel uses Mach messages (`mojo/core/channel_mac.cc`). On Linux and ChromeOS it uses a
Unix socket with SCM_RIGHTS (`mojo/core/channel_posix.cc`). cmux keeps the Unix socket on macOS too:

- The daemon is cross-platform Rust. The same wire runs on Linux Cloud VMs and through `DaemonBridge`, and the
  SSH bridge (3.5) carries its JSON-line form. A Mach transport would be a second transport for macOS only, and
  each wire test would have to run on both.
- The socket already does what cmux needs from Mach ports: descriptors pass with SCM_RIGHTS (ring and shared
  buffers, 4.3), and `getpeereid` identifies the peer (4.5).
- The bulk bytes of a local terminal do not go through the socket. The output ring carries them (section 4).
  Thus the remaining socket cost is per message, not per byte.
- The cost is measured, not assumed. `bench-daemon-latency.py` (task 002) records syscalls per message.
  `bench-typing.py` records the hops app.send -> daemon.pty_write and daemon.output -> app.output_decoded.
  Section 9 has the rows. If the socket makes those hops miss the IPC-9 bound (p99 <= 1 ms), this decision is
  opened again with those numbers. Before frames, the daemon writer makes 2 `write_all` calls per message (the
  text, then `\n`). With frames, it makes one `writev` per batch (task 140).

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
read: a gap. This is the seqlock rule; the reader detects every overwrite, the writer never waits.

Capacity: 1 MiB, the holder's per-terminal ring size (resident only as it fills; one copy of the pages,
shared by daemon and app). A reader 1 MiB behind resyncs by snapshot. Amended (4.6): the writer also never
writes past the acknowledged offset of the readers plus the capacity, so the reserve check finds a lap only when
that rule fails. Slice 3 measures resyncs per minute
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

### 4.6 Consumer cursor (`RING_ACK`)

The seqlock rule of 4.2 finds an overwrite, but it does not prevent one. The writer can lap a span while Ghostty
parses it; the deallocator check then finds a torn span that Ghostty already parsed. The cursor prevents this.

- When the output lane of Ghostty releases a span, the app sends RING_ACK with aux = the parsed offset (the end
  of the released spans). It sends a maximum of one per display frame, from the output lane, never from the main
  thread.
- The daemon keeps the acknowledged offset of each reader. Before it writes a chunk that ends at `e`, it checks
  `e <= min(acked) + capacity` over the live readers of the ring. If the check fails, the daemon does not write
  the chunk into the ring and marks the ring gap-pending. The next RING_ADVANCE of each reader is a gap (3.4),
  and the stream resyncs with a READY.
- A reader in a gap drops its queued spans. When the lane releases the span that it parses, the reader sends a
  last RING_ACK for the spans before the gap. Until that ack, the reader still bounds the writer, so no span in
  parse is overwritten. After that ack and until its READY, the reader does not bound the writer. After the
  READY, its acknowledged offset is the offset of the READY.
- The PTY and the writer never wait. A slow or stopped reader costs a resync. It never applies back-pressure to
  the terminal.
- The readers of one ring are the views of one terminal in one app (local same-euid peers only). A skipped chunk
  is a gap for all of them. A ring per reader prevents that, but costs a copy per reader. The shared result is
  accepted because the views of one app stall together (one output lane).
- The release-time reserve check of 4.4 stays, as the counter `release_laps`. IPC-7 requires it to be 0.

Chrome reference: the producer of a data pipe cannot write past unread data. The consumer gives space back with
`DATA_WAS_READ` (`mojo/core/data_pipe_control_message.h`, `mojo/core/data_pipe_producer_dispatcher.cc`), and a
full producer gets `MOJO_RESULT_SHOULD_WAIT`. cmux is different at one point: the PTY must never wait, so a full
ring skips the chunk and the reader resyncs.

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

Proof rows of the chrome-parity IPC program (p05-ipc done check IPC-17). Each row gives host, sha, macOS, Hz and
the command. "n/a" in Hz: the row measures no frame. "pending" in a value: the run has not been made, and the
row tells which task and batch makes it. A row moves from pending only with the output of its command on the fleet
(VM timing is not evidence). The perf-lead.md section 5 has the same rows in short form.

### 9.1 Before and after (done checks)

Before = batch B0 (after tasks 002 and 005, before task 094 sets streams on). After = the head after task 194.
Both on the same fleet M4 Pro mini, light and STRESS (`perf-stress-session.py`), p50/p95/p99/max from raw
samples.

| Check | Metric and target | Command | Host | sha | macOS | Hz | Before light / STRESS | After light / STRESS |
|---|---|---|---|---|---|---|---|---|
| IPC-2 | attach_handshake_rtts == 0 and 1 request per new view, local and SSH | `python3 scripts/cmux-next/split-latency-bench.py --tag ipc-base --streams` (then `--machine ssh`) | pending (fleet M4 Pro mini; SSH peer aws-m4pro-*) | pending (B0) / pending (after 194) | pending | 120 | pending (B0) | pending |
| IPC-5 | every listed op p95 < 2.0 ms send to reply, small, scale and STRESS | `cd cmux-tui && cargo build --release -p cmux-tui && python3 scripts/bench-daemon-latency.py --bin target/release/cmux-tui --ops all --scenario scale --out artifacts/daemon-latency-base.json` (and `--scenario small`) | pending (fleet M4 Pro mini) | pending (B0) / pending (B3, after 120-127) | pending | n/a | pending (B0) | pending (B3) |
| IPC-7 | `DaemonWireStats.outputBytesCopiedApp` == 0 after `cat` of 50 MB; release_laps == 0; ring resyncs/min == 0 in the STRESS flood | `python3 scripts/cmux-next/bench-typing.py --tag ipc-113 --flood 10 --stress`, then `debug.daemon.wire` | pending (fleet M4 Pro mini) | pending (B0) / pending (B2, after 113) | pending | 120 | pending (B0) | pending (B2) |
| IPC-8 | ping p99 < 2.0 ms during a 256 MiB flood on the same connection; focused echo p95 <= single-terminal p95 + 0.5 ms beside 10 floods | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin target/release/cmux-tui --bulk-interference`; `python3 scripts/cmux-next/bench-typing.py --tag ipc-base --flood 10` | pending (fleet M4 Pro mini) | pending (B0) / pending (B1, before 094) | pending | 120 | pending (B0) | pending (B1) |
| IPC-9 | key to frame p50 <= 8.3 ms, p99 <= 16.7 ms; hops app.send -> daemon.pty_write and daemon.output -> app.output_decoded p99 <= 1 ms | `python3 scripts/cmux-next/bench-typing.py --tag ipc-base --stress` (light: without `--stress`); hops from `python3 scripts/cmux-next/trace.py` on the same run | pending (fleet M4 Pro mini) | pending (B0) / pending (after 194) | pending | 120 | pending (B0) | pending |
| IPC-10 | daemon threads with 50 attached views and 20 extra CLI connections, minus with 0: <= 2; `--queue Q8` empty | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin target/release/cmux-tui --ops all --streams 50`; `python3 scripts/cmux-next/ipc-census.py --queue Q8` | pending (fleet M4 Pro mini) | pending (B0) / pending (after 156) | pending | n/a | pending (B0) | pending |
| IPC-11 | connection layer 0 wakeups/s on both sides (10 terminals, 1 Chromium tab, 10 hidden printing terminals); ConnectionHeartbeat <= 0.07/s; daemon idle 0/s | `scripts/cmux-next/bench-idle.sh` (connection-layer rows) | pending (fleet M4 Pro mini) | pending (B0) / pending (after 194) | pending | 120 | pending (B0) | pending |
| IPC-16 | with `--automation-storm 8`: key echo p95 <= idle + 1 ms, split p95 < 2 ms, automation >= 50 % of its idle throughput | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin target/release/cmux-tui --automation-storm 8` | pending (fleet M4 Pro mini) | pending (B0) / pending (after 143) | pending | n/a | pending (B0) | pending |
| 3.6.5 | syscalls per message (socket cost for the Mach decision) | `python3 cmux-tui/scripts/bench-daemon-latency.py --bin target/release/cmux-tui --ops all --scenario small` (syscalls per message from server-stats) | pending (fleet M4 Pro mini) | pending (B0) / pending (after 140) | pending | n/a | pending (B0); code read: 2 `write_all` per message | pending |
| IPC-12, IPC-14 | 30-minute STRESS soak: 0 crashes, 0 stream-end{overflow} on visible terminals, daemon RSS within +-5 %, slow_requests == 0 | `python3 scripts/cmux-next/ipc-soak.py --minutes 30 --flood 10 --stress` (task 192) | pending (fleet M4 Pro mini) | pending (after 192) | pending | 120 | n/a (soak has no before) | pending |
| Build | incremental build after a leaf edit < 30 s; schema-edit time and rebuilt targets | `cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/build-timing.sh --leaf-edit --schema-edit'` (task 194) | pending (fleet isolated class) | pending (before 025) / pending (after 027) | pending | n/a | pending | pending |

### 9.2 Earlier numbers (other benches, context only)

These are not the done-check commands, so they do not close a row of 9.1. They show the size of the problem.

| Check | Metric | Command | Host | sha | macOS | Hz | Value |
|---|---|---|---|---|---|---|---|
| IPC-2 | new connection (stream open + `identify` + `set-client-info`), then `attach-surface`, p50 / p95 ms | raw daemon client, hq `.cmux-scratch/ffre/split_bench.py` ([remote-state-ownership.md](remote-state-ownership.md) 1.2) | m1max (loaded) and aws-m4pro-1 | 64d57f35a20f | not recorded | n/a | local 2 / 20 then 1 / 23; on aws-m4pro-1 0.2 / 0.4 then 0.2 / 0.2; over SSH 137 / 173 (2 RTT) then 67 / 94 (1 RTT) |
| IPC-5 | send to reply p50 / p95 ms, 40 rounds, 50 background workspaces | `perf-10x-lifecycle` part=daemon ([perf-lead.md](perf-lead.md) section 5, PL-daemon batch 1) | cmuxs-Mac-mini.local (M4 Pro) | 15b43c2c2c3 (before) / b52efda096b (after) | 27.0.1 | n/a | after: new-tab terminal 23.2 / 36.8, split right 21.6 / 30.0, new-workspace 19.9 / 32.2, new browser tab 3.4 / 14.4, close-pane 5.2 / 10.1 |
| IPC-10 | daemon threads per idle terminal | same run as the IPC-5 row | cmuxs-Mac-mini.local (M4 Pro) | b52efda096b | 27.0.1 | n/a | 2.96 |
| IPC-11 | idle wakeups, whole tree, Home (connection layer not split out) | fleet step e44e5f2fc0a2cca452b71dee, standard scenario, Release ([speed-of-sound-DESIGN.md](speed-of-sound-DESIGN.md) section 5) | cmux20 (Apple M6) | e8af890de1 | 27.0 | not recorded | 51.9/s (main 42.6/s) |
| IPC-1, 3, 4, 10 | static census: Q4 side connections outside the allowlist 19 (29 found); Q1 hand-written Swift commands 235; Q2 sniffers 16; Q5 schema gaps 27; Q8 threads without QoS 81; Q14 hand-built `"cmd"` 190; Q15 Command variants 285 | `python3 scripts/cmux-next/ipc-census.py` | Linux VM (static, no build) | fe8a528b785 (perf/chrome-parity) | n/a | n/a | as listed; targets 0 |
