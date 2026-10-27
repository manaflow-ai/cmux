# p05-ipc: one IPC system for app and daemon, built like Mojo

Status: final spec after 3 adversarial reviews (fixer pass, 2026-10-25).
Base: `/Users/lawrence/fun/wt/chrome-parity` at `772cdfc45ac` (origin/feat-cmux-next).
Short paths: `app:` = `Packages/macOS/CmuxNext/Sources/`, `core:` = `cmux-tui/crates/cmux-tui-core/src/`.

This program implements and extends `plans/cmux-next/app-daemon-connection-DESIGN.md` (PL-conn, slices 1-5,
rule D3). No code implements that design yet: `git grep` finds no `attach-streams-v1`, `attach-frames-v1` or
`terminal-output-ring-v1`. This spec does not replace that design. Where this spec changes it (ring consumer
cursor, page-relay connection, reply/event FIFO rule), task 193 writes the change into the design with PL-conn.

Goal: one multiplexed, typed connection per app per daemon (D3). Bindings come from one schema
(`sdk-schema.json` plus `resource-operations-v2.json`), generated at build time for Swift and Rust. Priority
lanes put the person's input first, then control, then bulk, then background. Bulk terminal output uses a
shared-memory ring. A request replies before its journal write and before its terminal host starts (F10, D1).

## How the reviews were applied

Every claim below was checked with `git grep` at `772cdfc45ac`. Summary of decisions:

| Review finding | Check result | Decision |
|---|---|---|
| Q1 count is 235, not 240; Q4 query gives 14, not 16 | Confirmed (235, 14) | Acceptance never hard-codes counts; `ipc-census.py --record` writes them (task 001) |
| Q4 misses multi-line `DaemonConnection(` | Confirmed: AgentPaneGitLink.swift:111, DaemonCompatBackend.swift:14 | Census scans multi-line; also NWConnection unix lane, raw probes, DaemonBridge.open (001) |
| Q3 misses direct `commit_registry_intent(_with)(` callers | Confirmed: workspace_rename.rs:232, effect_commit.rs:53, workspace_commit_intent.rs:129, workspace_registry.rs:3137 | Q3 widened; task 134 |
| Request-side SQLite transactions outside the writer | Confirmed: 137 `unchecked_transaction(`/`.transaction()` hits outside tests | Queue Q13, task 135 |
| v2 ops and the 16 sniffers run inline on the mux-conn reader | Confirmed: connection_frame.rs:69 `handle_resource_line` runs before `scheduler.dispatch` at :114 | Task 086, before streams default on |
| App event barrier depends on reply-after-event order | Confirmed: LineTransport.swift:76-80, :350, :379; DaemonReadyConnection.swift:10 | One FIFO for control replies and control events (052, 007); events emitted at admit time (120) |
| Committed generated files are refused | Confirmed: `scripts/ci/generated_files_guard.py` (Leo 2026-10-21) | All generation is build time (task 027); no `*.generated.*` file is added to git |
| Duplicate compat checker | Confirmed: `cmux-api-compat`, `spec/api-compat.json`, `api-compat.surface.json` | Old task 012 is replaced: extend `api-compat-check` |
| Third copy of fd FIFO and shm ring code | Confirmed: `cmux-holder/src/wire.rs` (recvmsg, SCM_RIGHTS), `ring.rs` (memfd, shm_open, 31-byte names) | Extract into cmux-ipc (051, 110); holder bytes unchanged |
| shm_open name over 31 bytes | Confirmed risk; holder already solves it (`/cmhr<pid>.<n>.<ns>`, ring.rs:490) | Reuse holder naming (110) |
| parking_lot locks have no priority inheritance | Confirmed: Cargo.toml:52, `ReentrantMutex` in registry_connection.rs | PI mutex for ranked locks (138), QoS donation (137) |
| `TerminalSnapshotInflate` runs on the reader thread | Confirmed: TerminalSnapshotInflate.swift:6 | Reader cuts and routes only (144) |
| PageRelayChannel is `@MainActor` and decodes each event on main | Confirmed: PageRelayChannel.swift:25, :64, :106 | Task 109 |
| ChiefProfilePageRelay talks to the same owner as the main connection | Confirmed: ChiefProfilePageRelay.swift:180 (`role: .pageRelay`, same owner pid/generation check) | Task 108; not on the allowlist |
| PTY writes poll POLLOUT on the calling thread | Confirmed: pty_write.rs:53-55 | Async input sink (157), per-surface FIFO (085) |
| Output fan-out copies per viewer | Confirmed: pty_surface.rs:122 `AttachFrame::Output(bytes.to_vec())` | Task 089 |
| A second lane table in cmux-remote | Confirmed: mux_lanes.rs:113, :168 | Task 152 |
| PL-qos model: daemon request threads userInitiated, writer utility; userInteractive only where a frame waits | Confirmed: threading-model.md:70-100 | Task 080 follows that table; PL-qos reviews |
| 59 `mux-*` thread name sites; per-connection threads | Confirmed (59) | IO reactor and one sequenced pool (155-156, 073) |
| PL-conn, PL-qos, PL-trace, PL-arch, PL-telemetry missing from the tell list | Confirmed; PL-conn owns the design | Added; OWNERS row task 107 |
| Page streams on the main connection reverse the fail-safe origin default | Accepted | Not on the main connection: ONE shared page-relay connection per daemon, stream per page (103, 104, 108) |
| SHARED_BUFFER per payload is slower than chunked frames | Plausible, unmeasured | Kept as a pooled bulk channel, lands only with a bench row that wins (115) |
| F10 belongs to PL-daemon and is in flight | Confirmed: threading-model.md:100 "PL-daemon is removing that wait" | Kept in this program (F10 is in its charter) but every F10 task needs a PL-daemon review receipt and rebases on PL-daemon's landed work first; a task that PL-daemon has already done closes with a pointer |
| Admit-then-reply cannot compute revision, CAS and `replayed` before the commit | Accepted | In-memory revision allocator and ledger (132), admitted overlay (133) before 120 |
| Mojo associated-endpoint queueing (no bad_message for a just-opened stream) | Accepted | Pending streams (087) |
| Ring writer laps a span that Ghostty parses | Accepted | Consumer cursor RING_ACK (119) |
| Global u16 id space collides under many agents | Accepted | method_id = family u8 << 8 \| ordinal u8; families append-only (010) |
| Client-asserted lane in the header | Accepted | Daemon uses its own table; a mismatch is bad_message (050, 071) |
| "lane" means two things | Accepted | Schema attribute is `priority`; ordering domains are "sequences" |
| Control op can pass input already queued on a stream | Accepted | Stream barrier rule (010, 073) and per-surface PTY input FIFO (085) |
| Fuzz and census tests must not become CI tests | Accepted (Lawrence 2026-10-23) | Tests registered with `lane = "manual"`; fuzz behind an env var |
| Rust server and CLI stay hand-written | Accepted as a gap to close | Queues Q14 (CLI) and Q15 (Command enum), tasks 028, 029 |
| Hidden terminals get full delivery | Accepted | Stream visibility priority (142) |
| Agents and CLI compete with the person | Accepted | Person-first admission (143) |
| Crash loop on a deterministic bad frame | Accepted | Crash-loop breaker (191) |
| IPC-12 500 ms reconnect is mostly daemon cold start | Accepted | IPC bound is listen() to every READY <= 100 ms; cold start is D7 |
| Dropped from scope | - | Nothing in the reviews was dropped without replacement. Old task 012 is replaced by the api-compat extension. DaemonCompatBackend stays on its own connection (allowlisted), so it leaves task 098 |

## 1. Chrome reference

1. One OS channel per peer process. `mojo/core/README.md`: a Node has one NodeChannel per peer, which "carries
   all traffic to that Node"; each message names its destination Port (`mojo/core/node_channel.h`,
   `mojo/core/ports/node.h`). "A MessagePipe provides reliable in-order delivery of Messages." Handles travel
   inside messages. On macOS, Chrome's channel uses Mach messages (`mojo/core/channel_mac.cc`). cmux uses a Unix
   socket with SCM_RIGHTS on purpose: the Rust daemon is cross-platform, the same wire crosses the SSH bridge
   and Linux Cloud VMs. Task 002 measures the syscall cost per message so this difference is a number.
2. Associated interfaces. `mojo/public/cpp/bindings/README.md`: "running multiple interfaces over a single
   message pipe while preserving message ordering"; "as soon as bar_receiver is sent, bar is usable", so
   messages to an endpoint that is not bound yet are queued, not refused. A pipe error ends every associated
   endpoint. cmux: a view is a client-minted stream; frames for a stream whose open is in flight are queued
   (task 087); connection loss ends every stream.
3. One IDL, generated and validated bindings. `docs/mojo_and_services.md`; `mojo/public/tools/bindings/README.md`:
   "all interface messages are validated during deserialization before they are dispatched", "If a message
   fails validation, it is never dispatched. Instead a connection error is raised". Ordinals are scoped per
   interface. `[Stable]`, `[MinVersion]`, `[Extensible]`; `check_stable_mojom_compatibility.py`. cmux: schema
   families play the interface role (family-scoped ordinals); the existing `api-compat-check` is the compat tool.
4. No sync calls on latency-critical threads ("Sync calls hurt parallelism", "Re-entrancy changes message order",
   "Sync calls may lead to deadlocks"). cmux adds no sync path.
5. Priority by the receiving sequence. `docs/threading_and_tasks.md`: the IO thread is "each process's thread for
   receiving IPC"; "We prefer sequences to threads"; one ThreadPool per process with TaskPriority and
   MayBlock/ScopedBlockingCall compensation. Messages are "dispatched as a scheduled task" on the bound
   sequence, so the IO thread only routes. `[SupportsUrgent]` plus `UrgentMessageScope` tell the receiving
   scheduler to run a message first; it does not reorder the channel. Input has its own interface off the main
   thread (`WidgetInputHandler`). Hidden tabs get `WasHidden()`: no frames, throttled timers, lower priority.
6. Bulk through shared memory. Data pipes are a fixed ring shared by producer and consumer; the producer cannot
   write past unread data; two-phase reads lock their span. `BigBuffer`: inline up to `kMaxInlineBytes =
   64 * 1024`, a shared buffer above; "make a copy of the data before processing it" for untrusted senders.
   Read-only regions are checked on receipt (`CheckPlatformHandlePermissionsCorrespondToMode`).
7. Write fast path. `ChannelPosix::Write` writes on the calling thread when nothing is queued and uses the IO
   thread only on EAGAIN. One kqueue/epoll MessagePump serves every channel.
8. Persistence is never on the reply path. `base/files/important_file_writer.h` (`ScheduleWrite` "does not
   block", coalesces); `PrefService` serves reads from memory; `HistoryBackend` has its own sequence.
9. Blocking and hang discipline. `base/threading/thread_restrictions.h`, `scoped_blocking_call.h`;
   `base/threading/hang_watcher.h` (a watched scope is an atomic store; `RecordHang` calls
   `DumpWithoutCrashing` with the hung thread ids).
10. Priority inversion. `base/synchronization/lock_impl_posix.cc` sets `PTHREAD_PRIO_INHERIT` on Apple;
    `platform_thread_apple.mm` uses `pthread_override_qos_class_start_np` to boost a waited-on thread.
11. Fuzzing. Coverage-guided libFuzzer on ClusterFuzz and MojoLPM, structure-aware fuzzers built from mojom.
12. Bad peers. A renderer that sends a bad message is killed once (ReportBadMessage) and shown as a sad tab;
    there is no reconnect loop.

## 2. cmux today (measured at 772cdfc45ac, no build)

Connections
- Each terminal view opens its own socket: `app:CmuxNextDaemon/Terminal/TerminalAttachment.swift:113`
  `LineTransport(path:)`, then identify + set-client-info, then attach-surface: 2 round trips (3 over SSH).
- Q4 single-line query gives 14 hits; with multi-line constructions (AgentPaneGitLink.swift:111,
  DaemonCompatBackend.swift:14) it is 16. Other app sockets to a daemon: UnixSocketLane
  (`NWConnection(to: .unix`, MobileIrxConnectionServer.swift:76), the raw probe
  SessionTransferService+Chats.swift:128, and one `cmux link dial` child per bridged LineTransport
  (DaemonBridge.open).
- Page relays: one DaemonConnection per page (PageRelayChannel.swift:177) and one for Home channels
  (ChiefProfilePageRelay.swift:180, same owner process as the main connection). PageRelayChannel is
  `@MainActor` and decodes every event into JSONValue on main.
- Daemon: about 5 threads per view (mux-conn reader, mux-line-out, mux-control-dispatch,
  mux-attach-out/mux-snapshot-attach-out, notifications), plus one thread per subscription (mux-events-out,
  mux-resource-*-attach, waits, journal stream, mux-inventory-watch, mux-agent-attach, mux-browser-runtime-out).
  59 `.name("mux-` sites. `MAX_SERVER_CONNECTIONS = 64` (server.rs:2539).
- No SO_SNDBUF/SO_RCVBUF on the app-daemon socket (macOS AF_UNIX default 8 KiB).

Wire and parsing
- JSON lines; output, replays and snapshots are base64 in JSON (render_service.rs:318-352, :434). Base64
  emitters/decoders in 30 files of core:, not only server/.
- App output: 4 copies plus base64 before Ghostty (LineSplitter.swift:23,29; TerminalAttachment+Decoding.swift:153;
  TerminalEventQueue.popMerged). Daemon fan-out copies once per viewer (pty_surface.rs:122).
- Each keystroke: JSONEncoder with convertToSnakeCase, base64, daemon read_line, 16 `try_handle` sniffers
  (connection_frame.rs:44-109), `serde_json::from_str::<Request>`, a discarded reply.
- v2 resource ops and all 16 sniffers run inline on the mux-conn reader (connection_frame.rs:69); only v12
  `Request`s go through `scheduler.dispatch` (:114).
- App: every line decoded as Envelope and again as the typed body; DaemonEvent.decode is a 46-case string
  switch; `state.order.removeAll` O(n) per reply; one DemandTimer per request; actor hop per request;
  `AsyncThrowingStream(.unbounded)` for events; `connection.events` is single-consumer.
- Daemon writer: 2 `write_all` syscalls per message (text, then `\n`).

Schema and bindings
- `cmux-tui/spec/sdk-schema.json` (v12; 285 commands, 87 events, 219 types) and `resource-operations-v2.json`
  (310 ops). Codegen emits 7 languages, no Swift. Those outputs are committed generators; no PR may add one or
  widen its outputs (`generated_files_guard.py`).
- Daemon `enum Command` (server.rs:733-2262) and command_dispatch.rs are hand-written, regex-checked.
- App: 235 hand-written `static let command =` lines; 27 wire names are in no schema (served by sniffers).
- Rust CLI: hand-built `"cmd"` JSON in `cmux-tui/crates/cmux-tui/src` (190 `"cmd"` literals).
- cmux-remote has its own hand-written lane classifier (mux_lanes.rs:113, :168).

Priority, QoS, locks
- One FIFO control dispatcher per connection; no request lanes. Outbound queues are String-only.
- 0 `pthread_set_qos_class_self_np` in cmux-tui. Locks are parking_lot (no priority inheritance);
  RegistryConnection is a `ReentrantMutex`. 11 lock ranks in lock_rank.rs.
- PTY input polls POLLOUT on the calling thread under the runtime lock (pty_write.rs:53).

F10
- Request threads wait for journal-writer receipts under the registry lock; 17 wrapper call sites plus 4 direct
  `commit_registry_intent(_with)(` callers. 137 request-side SQLite transactions. 486
  `query_row`/`prepare` sites in workspace_registry*. Spawning requests reply after host launch.
- perf-lead numbers: creates 20-23 ms p50; split 107-112 ms p50; new terminal 114/660 ms p50/p95 loaded;
  new-frontend-browser-tab 31/46 ms.

## 3. Target design

### 3.1 Connections (D3)
- Per daemon, the app has exactly one control connection (DaemonService) and at most one page-relay connection.
- On the control connection, as client-minted u16 streams: terminal views, session-journal reads, loopback
  forwards, agent-session attaches, the git link (filtered event subscription). No per-stream handshake.
- Page-relay connection: role `page_relay`, so every request on it is page origin at minimum (the fail-safe
  default of request-origin.md is unchanged). Each page is a stream with an immutable origin `page:<id>`.
  Stream 0 on that connection may only open and close page streams. Home channels (ChiefProfilePageRelay) use it.
- Bridged machines: attach-streams-v1 is JSON-line compatible, so bridged endpoints get streams on the one
  bridged connection (no `cmux link dial` child per view). Frames, rings and shared buffers stay local-only.
- Allowlisted transient connections (ipc-targets.json, one reason each): shutdown end-terminals, SessionEnding,
  DaemonSocketMemory probe, DaemonPrestart handoff, Chief connections to another daemon, DaemonCompatBackend
  (mobile), UnixSocketLane (phone lane), the SessionTransfer probe.
- Connection loss ends every stream. The attach machine reattaches on the new epoch with resume_offset.

### 3.2 Frames
- 16-byte LE header: magic 0xFF, kind u8, stream u16, len u32 (<= 32 MiB), aux u64.
  - OUTPUT, GRID, EVENT, SNAPSHOT, SNAPSHOT_MORE, REPLAY, RING, RING_ADVANCE (1-8): absolute PTY offset.
  - INPUT (9): flow id. SHARED_BUFFER (10): size of the attached fd. RING_ACK (11): parsed offset.
  - REQUEST (16), REPLY (17), ERROR (18), TYPED_EVENT (19), CANCEL (20): u32 request id | u16 method id |
    u8 priority hint | u8 flags (binary, fds, flow, urgent, more).
- The daemon takes the priority from its own table; a header hint that differs is bad_message.
- Request ids are per-connection u32; an id is unique among in-flight requests; wrap is documented.
- Routing never parses the payload. A bad frame closes the connection with `bad_message+1` and a reason.
  A frame for a stream whose open is in flight is queued (Pending), not refused.
- Bulk is cut at BULK_FRAME_MAX (measured in 16-64 KiB) with the MORE flag: that is the preemption boundary.
- 512 KiB SO_SNDBUF/SO_RCVBUF on both ends.
- Frames are granted only when the client's api_revision equals the daemon's; otherwise JSON lines with the
  existing api_revision_wire translation.

### 3.3 Schema and generation
- IDL: sdk-schema.json and resource-operations-v2.json. New attributes: `method_id` (family u8 << 8 | ordinal u8;
  families append-only; v12 families 0x01-0x5F, v2 0x60-0xBF, events 0xC0-0xFE), `priority`
  (input|control|bulk|background), `ordering` (sequence, or `independent` only for reviewed read-only reads),
  `durability`, `payload` (json|binary, binary with bounded length-prefixed fields and a layout version byte),
  `stream_scoped`, `crosses_stream_ok` (with a reason), `max_bytes`, `spawns_terminal`, `coalesce`, `urgent`,
  `clients` (macos|ios|cli|sdk), `omit_nil`, `default`. Events: `event_id`, `priority`, `coalesce`.
- All generation runs at build time: cmux-ipc `build.rs` (Rust tables, client types, server family structs) and a
  SwiftPM build-tool plugin running the Swift executable `CmuxNextWireGen` (Swift wire types, method table).
  `generated-files.json` entries are `"status": "build"`; outputs are gitignored.
- Swift generates only methods whose `clients` include `macos` (or `ios` for the iOS product).
- Request types carry only the command name; method id, priority and capability live in the MethodTable in
  CmuxNextIPC.
- Compatibility: `api-compat-check` (cmux-api-compat) gains id, family, priority and binary-layout rules.
  Agents run it; no new CI gate.

### 3.4 Sequences and priority
- Ordering domain = sequence. Sequences: the connection control sequence (control replies and control events in
  ONE FIFO), one sequence per stream, and one PTY input FIFO per surface (across connections).
- A control-lane command whose target surface has an open stream on this connection waits for that stream's
  sequence to drain (stream barrier), unless the schema marks it `crosses_stream_ok` with a reason.
- A reply is enqueued after every event its request emitted. `routedEventCount` counts only stream-0 events.
- Daemon: one IO reactor thread reads, frames and flushes every connection. One daemon-wide sequenced pool runs
  sequences with fixed workers per priority plus blocking compensation. Person-class connections (proven role
  main) are admitted before automation, with a starvation bound.
- Outbound: input-stream items, then control (replies + events), then bulk, then background; starvation bound;
  producer-side coalescing by the schema `coalesce` key; one writev per batch.
- Stream visibility: focused streams' output rides the input priority; hidden streams get no OUTPUT and no
  RING_ADVANCE and resume by offset on show.
- App: one reader thread that only cuts frames and routes; typed decode, snapshot inflate and bulk decode run on
  per-priority serial queues. Writes go inline on non-main threads when higher queues are empty, else to the
  write queue. Main-thread callers always enqueue.
- QoS follows PL-qos (threading-model.md): request and control threads userInitiated, bulk utility, background
  background, journal writer utility. The IO reactor and the input sequence are userInteractive only through a
  PL-qos exception row (they are the analog of Chrome's IO thread, which every key passes through).
- Locks shared across QoS classes are priority-inheriting on macOS; a request that waits on the writer donates
  its QoS.

### 3.5 Shared memory
- Per-terminal output ring (CMAR layout, design section 4), created with the holder's segment code
  (memfd on Linux, unlinked shm_open with a <= 31-byte name on macOS). The app gets an O_RDONLY fd (Linux:
  reopened read-only or F_SEAL_FUTURE_WRITE); the app refuses an fd that maps PROT_WRITE.
- Consumer cursor: the app sends RING_ACK (coalesced to one per display frame). The daemon never writes a
  reader's ring past acked + capacity; it skips and marks a gap instead. The PTY and writer never wait.
- Granted only to a local same-euid Unix peer (getpeereid); never to Remote, WebSocket or bridge clients.
- SHARED_BUFFER: a per-connection pool of reusable regions for payloads above 64 KiB; the daemon copies
  app-provided bytes before parsing. It lands only with a bench row that beats chunked frames.

### 3.6 F10: reply before the journal and before the spawn
- Prepare runs in memory: revision allocator and mutation-ledger cache (including admitted, uncommitted
  intents) seeded at open; the CAS and the replay check run at prepare time.
- Admitted topology goes into an in-memory overlay that prepare and hot reads use before SQLite.
- The writer is apply-only: its only failures are I/O; it retries with coalescing and emits journal-degraded.
- Events are emitted at admit time, before the reply (keeps the app's event barrier true).
- A counted read barrier stays only for cold reads not yet on the overlay; queue Q18 moves them to projections.
- Spawning requests reply with `starting:true` (terminal-async-start-v1).
- RequestPathScope counts sqlite, journal_wait, process_spawn, fs_write, host_wait, sleep, proc_scan,
  child_process, network and registry lock holds > 1 ms, with `#[track_caller]` down to the public call.
- Behind a daemon setting that defaults on in Nightly.

### 3.7 Observability and stability
- server-stats `ipc`, `request_path_io`, `slow_requests` (with a stack of the busy thread); app DaemonWireStats
  and `debug.daemon.wire`; per-method log-bucket histograms on both ends.
- Flow id in the frame header joins app signposts, daemon spans and holder flows (trace.py).
- Fuzzing: proptest readers plus coverage-guided cargo-fuzz targets with a schema-structured generator, run on
  idle fleet minis.
- Crash-loop breaker: 3 bad_message closes from one daemon epoch in 60 s turn frames off for that epoch,
  visibly.
- Old clients keep JSON lines. The per-view path stays behind `CMUX_NEXT_TERMINAL_STREAMS=0` for one release.

## 4. Rules for every task

1. Read CLAUDE.md, PATTERNS.md, REVIEW-STANDARD.md, threading-model.md and the design before the first edit.
2. Commit the red guard first (P13), then the fix. The commit says the fleet red and green result.
3. No build or test on the person's Mac. RUST/SWIFT/BENCH run through `cmux-ci` on the fleet.
4. No new CI gate, CI job or CI test. New Python tests are registered in tests/test-execution.toml with
   `lane = "manual"` and the reason "agents run it on the fleet (Lawrence 2026-10-23)". Fuzz tests run only
   with `CMUX_IPC_FUZZ=1` or `#[ignore]`.
5. No committed generated file. Generators run at build time and their outputs are gitignored.
6. Every IPC change is capability-gated; old daemons, Cloud VMs, iOS, the TUI, SDKs and WebSocket clients keep
   JSON lines.
7. Ordering: replies follow their events on the control sequence; stream items stay in their stream FIFO;
   priority never reorders inside a sequence.
8. No blocking call on the app main thread; no main-thread sendmsg.
9. risk:high tasks (103, 104, 108, 111, 115, 119, 120, 132, 133, 130) need `Review (<reviewer>): SHIP at <sha>`.
   F10 tasks (120-138) also need a PL-daemon review; ring tasks a PL-holder review; 097 and 113 a PL-ghostty
   review; 080, 127, 137, 138, 150, 155 a PL-qos review.
10. Owners to tell: PL-conn (all; owns D3 and the design), PL-daemon (core:), PL-ghostty, PL-holder, PL-cef-helper
    (181), PL-typing (032, 096, 140, 153), PL-qos, PL-trace (078, 180), PL-arch (025, 027), PL-telemetry
    (006, 008, 009).
11. Hot files are serialized: connection_frame.rs only in 062 and 086 (sniffer tasks edit their own ROUTES);
    DaemonTransport/LineTransport.swift: 004 lands before 090, then 091/092/093/191 in that order;
    TerminalAttachment.swift: 095 -> 096 -> 099 -> 114 -> 142; frame_dispatch.rs: 071 -> 078 -> 084 -> 180.
12. Benches run in batches: B0 baseline (after 002, 005), B1 streams (before 094), B2 ring (after 113),
    B3 F10 (after 120-127). A task with a numeric acceptance runs its own bench; the others cite the batch.
13. Every perf claim gives p50/p95/p99/max, light and STRESS, with host, sha, macOS and Hz. VM timing is not
    perf evidence; Tart VMs check macOS 14/15 behavior only.

Test macros: RUST(F) = `cmux-ci run --class isolated --ref SHA --script 'cd cmux-tui && ../scripts/ci/cmux-tui-focused-test.sh F'`;
SWIFT(F) = `cmux-ci run --class isolated --ref SHA --script 'cd Packages/macOS/CmuxNext && ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --filter F'`;
BENCH(cmd) = `cmux-ci run --class isolated --ref SHA --script 'cmd'`; PY(cmd) = portable Python, may run locally.

## 5. Done checks

- IPC-1 (one connection). In STRESS (perf-stress-session.py: 60 workspaces, 10 Chromium workspaces, 10 busy
  terminals, every visible terminal attached), `cmux-tui server-stats --include clients` lists, for the app's
  pid, 1 control connection and at most 1 page-relay connection, and 0 per-view connections.
  `ipc-census.py --check` shows 0 Q4 hits outside the ipc-targets.json allowlist.
- IPC-2 (no per-view handshake). `split-latency-bench.py --streams` reports attach_handshake_rtts == 0 and 1
  request per new view, local and `--machine ssh`. TerminalAttachmentStreamTests: 0 connections and 0 bridge
  spawns per new view.
- IPC-3 (generated bindings). Q1 == 0 hand-written Swift commands; Q5 == 0; Q14 == 0 hand-built `"cmd"` JSON in
  the Rust CLI; Q15 == 0 hand-written daemon Command variants. `generated_files_guard.py` passes and git
  tracks no new generated file.
- IPC-4 (one parse). `git grep -c 'fn try_handle' -- core:server` == 0. server-stats
  ipc.json_parses_per_request <= 1.0 for frames, <= 2.0 for JSON lines (bench-daemon-latency.py --ops all).
- IPC-5 (op latency). `bench-daemon-latency.py --ops all` p95 < 2.0 ms send-to-reply for every listed op
  (v12 and v2 creates, split, close, rename, select, move, browser tab, tab groups), small and scale scenarios,
  and STRESS. Q16 is empty.
- IPC-6 (F10). After the bench: journal.receipt_waits_on_request_threads == 0; request_path_io journal_wait,
  process_spawn, host_wait, fs_write, sleep, child_process, proc_scan, network == 0; request_path_io.sqlite == 0
  and read_barrier_waits == 0 on request threads for the IPC-5 ops. `CMUX_TUI_REQUEST_PATH_IO=panic:journal_wait,process_spawn,host_wait,fs_write,sleep`
  over the cmux-tui-core suite: 0 panics outside the allowlist.
- IPC-7 (zero copy). After `cat` of 50 MB in a local terminal: DaemonWireStats.outputBytesCopiedApp == 0;
  span base address at ghostty_surface_process_output lies in the ring mapping; release-time laps == 0;
  STRESS flood ring resyncs/min == 0; daemon allocations per output chunk == 1 with 3 viewers.
- IPC-8 (head-of-line). `--bulk-interference`: ping p99 < 2.0 ms during a 256 MiB flood on the same
  connection. `bench-typing.py --flood 10`: focused echo p95 <= single-terminal p95 + 0.5 ms. A 5 MB control
  reply decode does not delay stream frames by more than 1 ms p99.
- IPC-9 (shared target). Key->frame p50 <= 8.3 ms, p99 <= 16.7 ms at 120 Hz, light and STRESS; the IPC hops
  app.send -> daemon.pty_write and daemon.output -> app.output_decoded p99 <= 1 ms.
- IPC-10 (threads). Daemon threads with 50 attached views and 20 extra CLI connections minus with 0 <= 2.
  `ipc-census.py --queue Q8` is empty (every IPC, subscription and echo-path thread sets a QoS).
- IPC-11 (idle). 10 terminals and 1 Chromium tab, plus 10 hidden printing terminals: connection layer 0
  wakeups/s on both sides (bench-idle.sh rows), watchdog 0, ConnectionHeartbeat <= 0.07/s, daemon idle 0/s.
- IPC-12 (stability). kill -9 during a 10-stream flood with rings: no app crash; from the new daemon's
  listen() to every stream READY <= 100 ms (daemon start reported apart under D7); every view correct
  (IpcDaemonCrashTests). 100k fuzz inputs per reader: 0 crashes; each bad input closes with bad_message+1.
  8 h cargo-fuzz per target: 0 open crashers. 30-minute STRESS soak: 0 crashes, 0 stream-end{overflow} on
  visible terminals, daemon RSS within +-5%.
- IPC-13 (compat). `cargo run -p cmux-api-compat --bin api-compat-check` passes on the head; `ipc-census.py
  --queue Q6` is empty; IpcCompatMatrixTests pass for old/new app x old/new daemon.
- IPC-14 (hangs). After the soak: slow_requests == 0; MainThreadWatchdog 0 hangs > 250 ms from a daemon wait.
- IPC-15 (order). ReplyEventOrderTests and the 1,000-interleaving property test pass; the paste-plus-keys PTY
  test shows no interleaving.
- IPC-16 (person first). `--automation-storm 8`: app key echo p95 <= idle + 1 ms and split p95 < 2 ms while
  automation keeps >= 50% of its idle throughput.
- IPC-17 (proof). app-daemon-connection-DESIGN.md section 9 and perf-lead.md section 5 have before/after rows
  for IPC-2, 5, 7, 8, 9, 10, 11 and 16 with host, sha, macOS, Hz and the command; incremental build after a
  leaf edit < 30 s (task 194).

## 6. Machine queues

Each queue is printed by `python3 scripts/cmux-next/ipc-census.py --queue QN` as JSON `[{file,line,key}]`;
`--record` writes base counts to plans/cmux-next/ipc-targets.json. The raw query is given so a reviewer can
check it.

- Q1 hand-written Swift commands (tasks 030-043): `git grep -n -E 'static (let|var) command(Name)?(: (String|DaemonCommandName))? = "' -- Packages/macOS/CmuxNext/Sources ':!*.generated.swift'`, grouped by directory (a `DaemonRequest` declares `commandName: DaemonCommandName`; the first form of the query, without `Name`, missed every one of them). 235 at base; `ipc-census.py --record` keeps the current count in ipc-targets.json. `--callers <dir>` lists call-site files.
- Q2 daemon sniffers (063-070): `git grep -n 'fn try_handle' -- cmux-tui/crates/cmux-tui-core/src/server`. 16.
- Q3 F10 receipt waits (121-126, 134): today's wrapper pattern `\.commit_terminal\(|commit_workspace_registry\(|commit_effect_intent\(|\.send_durable(_until)?\(|\.send_producer\(` (17) plus direct callers `commit_registry_intent(_with)?\(` and `flush_terminal_journal\(` outside their definitions, excluding tests.
- Q4 side connections (095, 100-105, 108, 151): multi-line scan for `LineTransport(path:` and `DaemonConnection(` (with the argument on the same or next line), plus `NWConnection(to: .unix`, raw `connect(` to daemon sockets, and `DaemonBridge.open`; minus the allowlist.
- Q5 schema gaps (013-016, 018, 019): Swift wire names minus sdk-schema commands. 27.
- Q6 schema attributes (011): commands without method_id or priority, events without event_id.
- Q7 base64 bulk paths (076, 077, 149): `git grep -n -E 'write_base64_json_(string|parts)\(|general_purpose::STANDARD\.(encode|decode)' -- cmux-tui/crates/cmux-tui-core/src` (30 files).
- Q8 threads without QoS (080, 146, 147, 150): `.name(` sites for mux-*, mux-events-out, mux-resource-*, mux-inventory-watch, mux-agent-attach, mux-browser-runtime-out, terminal-host-client(-input), terminal-host-parser, surface-*, surface-frames, cmux-link-in/out, mux-terminal-work and the journal writer, whose body does not begin with `cmux_tui_platform::qos::set_current`.
- Q9 request-path I/O (128): `CMUX_TUI_REQUEST_PATH_IO=record cargo test -p cmux-tui-core | grep REQUEST_PATH_IO | sort | uniq -c` on the fleet; one task per (kind, site).
- Q10 JSON and base64 in the app connection layer (044, 090, 097): `git grep -n -E 'JSONDecoder\(\)|JSONSerialization\.|WireCoding\.decoder\(\)|base64' -- app:CmuxNextDaemon/{Connection,Terminal,Events,Loopback}`.
- Q11 hand-built v2 envelopes (045, 047): `resourceRequest(`, `ResourceRequestEnvelope(` and `operation: "` in Packages/macOS/CmuxNext/Sources, plus `transport.request(cmd:` building a v2 envelope.
- Q12 events not decoded natively (044): schema events minus DaemonEvent cases.
- Q13 request-side SQLite transactions (135): `git grep -n -E 'unchecked_transaction\(|\.transaction\(\)' -- cmux-tui/crates/cmux-tui-core/src ':!*tests*' ':!*_tests.rs'` (137 at base); one task per store file or an allowlist reason.
- Q14 Rust CLI hand-built requests (028): `"cmd"` JSON literals in `cmux-tui/crates/cmux-tui/src`, grouped by file.
- Q15 daemon Command variants (029): `enum Command` variants in server.rs grouped by schema family.
- Q16 slow ops (002 writes it): ops with p95 > 2 ms in `bench-daemon-latency.py --ops all --scenario scale` after B3; one profiling-and-fix task per op.
- Q17 ranked locks (138): `git grep -n -E 'LockRank::[A-Z]' -- cmux-tui/crates/cmux-tui-core/src`, one item per lock definition.
- Q18 request-path SQLite reads (136): `REQUEST_PATH_IO kind=sqlite` sites from the Q9 run hit by the IPC-5 ops; one task per file.

## 7. Risks

- Security (risk:high). The ring, shared buffers and page streams change the trust boundary. Rings and buffers
  go only to local same-euid Unix peers; fds are read-only and the app refuses a writable mapping; the daemon
  copies app buffers before parsing. Page origin stays fail-safe because page streams live on a page_relay
  connection, never on the main connection. Each risk:high task writes its analysis in request-origin.md.
- Durability. Admit-then-reply can lose admitted intents on power loss; recovery is the last journal state plus
  the holder's live terminals with the A3 notice; mutation_id idempotency keeps retries exact. Behind a daemon
  setting, default on in Nightly.
- F10 ownership. PL-daemon is removing the receipt wait on the base. Every F10 task first rebases on PL-daemon's
  landed work and gets a PL-daemon receipt; duplicated work closes with a pointer.
- Ordering. Priority never reorders a sequence; the reply/event rule, the stream barrier and the per-surface
  PTY FIFO are tested red-first (007, 073, 085).
- Compatibility. Everything is capability-gated; frames need equal api_revision; compat matrix task 118.
- Merge conflicts. Family-scoped ids avoid collisions; api-compat-check before every push; hot files serialized
  (rule 11); sniffer tasks edit only their own ROUTES.
- Build time. Generated Swift is limited to `clients: macos` methods, in a leaf target, per-family files; task
  194 measures leaf-edit and schema-edit rebuilds before and after. The method table (023) is one file: it is
  small data, and every output is rewritten on any schema edit, so per-family files would gain nothing.
- Head-of-line. Streams stay off by default (095) until 056, 072, 086, 087, 099 and 144 land and B1 shows IPC-8;
  task 094 flips the default with that evidence.
- Scope. The CLI-to-app control socket, cmux-pane-protocol and acpmux keep their own framing in this push.
- macOS 14/15. No fleet Mac runs them; shm, SCM_RIGHTS, os_unfair_lock and QoS behavior are checked in Tart VMs
  (117).

## 8. Task table

| id | title | size | risk | queue | depends on |
|---|---|---|---|---|---|
| 001 | ipc-census.py: counts, allowlist, queues Q1-Q18 | M | low | - | - |
| 002 | bench-daemon-latency: all ops, bulk interference, streams, automation storm, Q16 | M | low | Q16 | - |
| 003 | RequestPathScope with full kinds and track_caller | M | normal | - | - |
| 004 | DaemonWireStats and debug.daemon.wire | M | normal | - | - |
| 005 | split-latency-bench --streams, bench-typing --flood | M | low | - | - |
| 006 | Daemon request watchdog (armed flag, 0 idle wakeups) | M | normal | - | - |
| 007 | Reply/event order invariant, red tests | M | normal | - | 050 |
| 008 | Watchdog stack capture | M | normal | - | 006 |
| 009 | Per-method latency histograms both ends | M | normal | - | 004, 023, 082 |
| 010 | Schema meta attributes and validation | M | normal | - | - |
| 011 | Assign family ids and priorities | M | normal | Q6 | 010 |
| 012 | api-compat-check: id, family, priority, layout rules | M | normal | - | 010 |
| 013 | Schema: apps-* | M | low | Q5 | 010 |
| 014 | Schema: agent-cli-intents/job | S | low | Q5 | 010 |
| 015 | Schema: agent-inventory | S | low | Q5 | 010 |
| 016 | Schema: browser-runtime, loopback-open, machine-catalog, client-hello | S | low | Q5 | 010 |
| 017 | check-sdk-schema covers module enums and sniffed cmds | M | low | - | 013-016, 018, 019 |
| 018 | Schema: agent_session_attach/observe | S | low | Q2 | 010 |
| 019 | Schema: agent_transfer, fs_wire, scripts | M | low | Q2 | 010 |
| 027 | Build-time generation infra (build.rs, SwiftPM plugin) | M | normal | - | 010 |
| 020 | CmuxNextWireGen: Swift types | L | normal | - | 027, 011 |
| 021 | CmuxNextWireGen: requests and responses | M | normal | - | 020 |
| 022 | CmuxNextWireGen: events, single-pass decoder | M | normal | Q12 | 020 |
| 023 | Method tables (Rust build.rs, Swift plugin) | M | normal | - | 011, 027, 050 |
| 024 | CmuxNextWireGen: app-used v2 ops | L | normal | Q11 | 020 |
| 025 | SwiftPM targets and test targets | S | normal | - | 027 |
| 026 | Rust server pilot: TerminalIO family generated | L | normal | Q15 | 023 |
| 028 | Rust CLI generated client types (pilot + Q14) | M | normal | Q14 | 023 |
| 029 | Q15: daemon Command families (Tabs + queue) | L | normal | Q15 | 026 |
| 030-043 | Migrate hand-written Swift requests per directory | M | normal | Q1 | 021, 025 |
| 044 | Generated event decode replaces DaemonEvent.decode | M | normal | Q12 | 022, 025 |
| 045 | Q11 in CmuxNextDaemon to generated v2 ops | M | normal | Q11 | 024, 025 |
| 046 | Remove WireCoding encoder key strategy | S | normal | - | 030-045, 047 |
| 047 | Q11 outside CmuxNextDaemon | M | normal | Q11 | 024, 025 |
| 048 | iOS CmuxTUIControl and phone-lane policy on the generated wire | M | normal | - | 021, 025, 016 |
| 050 | cmux-ipc crate: header, kinds, reader, fixtures | M | normal | - | - |
| 051 | cmux-ipc fds: extract holder SCM_RIGHTS FIFO | M | normal | - | 050 |
| 052 | LaneWriter policy (one control FIFO) | L | normal | - | 050 |
| 053 | Rust reader proptest fuzz (env-gated) | S | low | - | 050 |
| 054 | Swift FrameReader (pooled, small-copy rule) | M | normal | - | 050, 025 |
| 055 | Swift FrameWriter with priorities | M | normal | - | 054 |
| 056 | Swift StreamDemux | M | normal | - | 054 |
| 057 | Swift reader fuzz (env-gated) | S | low | - | 054 |
| 058 | DaemonConnection multi-subscriber event fan-out | M | normal | - | 090 |
| 060 | Capabilities and grant rules | S | normal | - | 050 |
| 061 | Daemon dual reader (lines and frames) | M | normal | - | 050, 051, 060 |
| 062 | Single-parse dispatch with per-module ROUTES | L | normal | - | 023, 017 |
| 063-070 | Sniffers to ROUTES | S/M | normal | Q2 | 062 |
| 071 | REQUEST/REPLY/ERROR/CANCEL frames | M | normal | - | 061, 062 |
| 072 | bounded_outbound priorities and chunking | L | normal | - | 052, 061 |
| 073 | Daemon-wide sequenced pool, stream sequences, stream barrier | L | normal | - | 060, 003 |
| 074 | attach-streams-v1 | L | normal | - | 073 |
| 075 | Sizing identity per app | M | normal | - | 074 |
| 076 | OUTPUT/GRID/EVENT frames | L | normal | Q7 | 074, 072, 089 |
| 077 | SNAPSHOT/SNAPSHOT_MORE/REPLAY frames | L | normal | Q7 | 076 |
| 078 | INPUT frames | M | normal | - | 071, 074, 085 |
| 079 | Fold attach threads | L | normal | Q8 | 074, 072 |
| 080 | Daemon QoS per PL-qos | M | normal | Q8 | - |
| 081 | Stream caps | S | normal | - | 074 |
| 082 | server-stats ipc | M | normal | - | 071 |
| 083 | Daemon socket buffers 512 KiB | S | low | - | - |
| 084 | Frames skip API-revision upgrade only at equal revision | S | normal | - | 071 |
| 085 | Per-surface PTY input FIFO | M | normal | - | 073 |
| 086 | v2 ops and sniffed handlers leave the reader | L | normal | - | 003, 062, 073 |
| 087 | Pending streams (associated-endpoint queueing) | M | normal | - | 073, 074 |
| 088 | writev batching | M | normal | - | 072 |
| 089 | Output fan-out without per-viewer copy | M | normal | - | - |
| 090 | DaemonTransport on CmuxNextIPC | L | normal | Q10 | 004, 054, 055, 056 |
| 091 | Nonisolated request path | M | normal | - | 090 |
| 092 | App negotiates frames and streams | M | normal | - | 071, 090, 023 |
| 093 | Bounded event pipeline | M | normal | - | 058 |
| 094 | Turn terminal streams on by default (evidence) | S | normal | - | 095, 099, 072, 056, 086, 087, 144 |
| 095 | TerminalAttachment as a stream (default off) | L | normal | Q4 | 074, 087, 090 |
| 096 | Terminal input as INPUT frames | S | normal | - | 078, 095, 140 |
| 097 | Decode attach frames, span-merging queue | L | normal | Q10 | 076, 077, 095 |
| 098 | Attach call sites pass the connection | S | normal | Q4 | 095 |
| 099 | No reader-blocking backpressure in stream mode | M | normal | - | 095 |
| 100 | SessionJournalRead as a bulk stream | M | normal | Q4 | 073, 090 |
| 101 | LoopbackForwardClient as a stream | M | normal | Q4 | 073, 090, 068 |
| 102 | AgentSessionAttachClient as a stream | M | normal | Q4 | 073, 090, 065 |
| 103 | Daemon: one page-relay connection, per-stream page origin | L | high | - | 073 |
| 104 | App: PageRelayChannel on the shared page-relay connection | M | high | Q4 | 103, 090 |
| 105 | AgentPaneGitLink on the main connection | S | normal | Q4 | 058 |
| 106 | Transient-connection allowlist | S | low | Q4 | 001 |
| 107 | OWNERS rows and tell list | S | low | - | - |
| 108 | ChiefProfilePageRelay on the page-relay connection | S | high | Q4 | 103, 104 |
| 109 | Page relay off the main actor | M | normal | - | 104 |
| 110 | cmux-ipc output ring from holder segment code | M | normal | - | 050 |
| 111 | Daemon ring per terminal, RING/RING_ADVANCE | L | high | - | 110, 051, 074, 076 |
| 112 | Swift SharedOutputRing | M | normal | - | 054 |
| 113 | App ring streams | M | normal | - | 111, 112, 097 |
| 114 | Resume by offset | M | normal | - | 113 |
| 115 | SHARED_BUFFER pool (bench-gated) | L | high | Q7 | 051, 071, 090 |
| 116 | Ring sizing evidence | S | low | - | 113 |
| 117 | macOS 14/15 behavior in Tart VMs | S | low | - | 111, 112, 080, 138 |
| 118 | Old/new compat matrix | M | normal | - | 092, 095 |
| 119 | Ring consumer cursor (RING_ACK) | M | high | - | 111, 113 |
| 132 | F10 prereq: in-memory revisions and ledger | L | high | - | 003 |
| 133 | F10 prereq: admitted-topology overlay | L | high | - | 132 |
| 120 | F10 core: admit then reply | L | high | Q3 | 132, 133, 007 |
| 121 | F10 sites: surface_spawn.rs | S | normal | Q3 | 120 |
| 122 | F10 sites: terminal_lifecycle_commit.rs, terminal_records.rs | S | normal | Q3 | 120 |
| 123 | F10 site: terminal_move.rs | S | normal | Q3 | 120 |
| 124 | F10 sites: workspace_registry.rs, resource_effect_commit.rs | M | normal | Q3 | 120 |
| 125 | F10 sites: resource_effects.rs, feed_local.rs | M | normal | Q3 | 120 |
| 126 | F10: journal-frontend-event admitted reply | M | normal | Q3 | 120 |
| 127 | Journal writer: effect lane first, QoS utility | M | normal | - | 120, 080 |
| 128 | Q9 triage | S | low | Q9 | 003 |
| 134 | F10 direct commit_registry_intent sites | M | normal | Q3 | 120 |
| 135 | Q13 request-side transactions; first presentation_store | L | normal | Q13 | 120, 001 |
| 136 | Q18 projections for request-path reads | L | normal | Q18 | 128, 120 |
| 137 | QoS donation to the journal writer | S | normal | - | 120, 080 |
| 138 | Priority-inheriting ranked locks on macOS | M | normal | Q17 | 080 |
| 130 | Reply before spawn | L | high | - | 120 |
| 131 | App: starting terminals keep the stand-in | M | normal | - | 130, 095 |
| 140 | Inline write fast path both ends | M | normal | - | 055, 072 |
| 141 | Producer-side coalescing | M | normal | - | 052, 055, 011 |
| 142 | Stream visibility priority | L | normal | - | 072, 095, 114 |
| 143 | Person before automation across connections | L | normal | - | 073, 080 |
| 144 | App reader routes only; decode and inflate on queues | M | normal | - | 090, 056 |
| 145 | v2 string stream ids map to frame streams | M | normal | - | 074, 090 |
| 146 | Fold per-subscription event threads | L | normal | Q8 | 073 |
| 147 | Fold v2 attach, wait and journal threads | L | normal | Q8 | 073, 146 |
| 148 | Stream-scoped subscriptions, encode once | M | normal | - | 074, 103 |
| 149 | Binary bulk paths outside server/ | L | normal | Q7 | 071 |
| 150 | QoS for echo-path and holder-link threads | M | normal | Q8 | 080 |
| 151 | Bridged machines: streams on the bridged connection | M | normal | Q4 | 095 |
| 152 | cmux-remote lane classifier from the schema | M | normal | - | 011, 023 |
| 153 | Input while creating as INPUT frames | M | normal | - | 078, 087, 095, 130 |
| 155 | Daemon IO reactor (reads) | L | normal | - | 061 |
| 156 | Reactor writes; mux-line-out deleted | L | normal | - | 155, 073, 088 |
| 157 | Async terminal input sink | M | normal | - | 155, 085 |
| 160 | SSH bridge carries frames | M | normal | - | 076 |
| 161 | App frames over SSH with bridge-frames-v1 | S | normal | - | 160, 097, 151 |
| 180 | Flow id in frames, trace.py | M | normal | - | 071, 092 |
| 181 | Chromium host wire from the schema | M | normal | - | 027 |
| 182 | Coverage-guided and structured fuzzing | M | normal | - | 053, 062, 071 |
| 183 | Binary codec for hot messages | M | normal | - | 023, 071, 092, 012 |
| 190 | Daemon kill -9 stability test | M | normal | - | 113 |
| 191 | Bad-message behavior and crash-loop breaker | S | normal | - | 061, 090 |
| 192 | ipc-soak.py | M | low | - | 113, 099, 006 |
| 193 | Final proof tables and design updates | S | low | - | 192, 002, 005, 194 |
| 194 | Incremental build timing | S | low | - | 025, 027 |

## 9. Task details

Each block: files, change, acceptance (a diff-only reviewer can check it), test phase.

### Phase 0: measure and guard

**p05-ipc-001 ipc-census.py.** Files: scripts/cmux-next/ipc-census.py, plans/cmux-next/ipc-targets.json,
tests/test_ipc_census.py, tests/test-execution.toml. Change: stdlib-only census of every queue in section 6
(multi-line constructor scan; caller-of-wrapper scan for Q3; extra app sockets for Q4; whole core: for Q7;
widened Q8 and Q11; Q13-Q18). `--queue QN`, `--check` (against ipc-targets.json and its allowlist with one reason
per entry), `--record` (writes base counts), `--callers <dir>` (call-site files of a Swift family). Acceptance:
counts printed equal the raw query `wc -l` at the base, written by `--record`, no literal counts in code or test;
fixture tests cover a multi-line constructor and a caller-of-wrapper hit; the test is registered with
`lane = "manual"`; no .github change. Test: PY(python3 -I tests/test_ipc_census.py && python3 scripts/cmux-next/ipc-census.py --queue Q1 --queue Q3 --queue Q4).

**p05-ipc-002 bench-daemon-latency.** Files: cmux-tui/scripts/bench-daemon-latency.py, plans/cmux-next/ipc-targets.json.
Change: `--ops all|create` covering ping, identify, list-workspaces, send, new-tab, create-terminal, split-pane,
close-surface, rename-workspace, select-tab, select-workspace, move-tab, close-tabs, tab-group ops,
new-frontend-browser-tab and v2 workspace.create, tab.create_terminal, pane.split, pane.create,
workspace.ensure_home; `--scenario small|scale`; `--bulk-interference` (BULK_FRAME_MAX 16/32/64 KiB when
advertised); `--streams N`; `--automation-storm N` (N agent connections looping new-tab and rename while the
app connection measures echo and split); syscalls and wakeups per message from server-stats when present;
`--write-q16` writes ops with p95 > 2 ms. JSON output has host, sha, macOS, scenario. Acceptance: modes run
against today's daemon (unadvertised modes are skipped with a note); percentiles from raw samples (no mean-only
rows); output keys in the docstring. Test: BENCH(cd cmux-tui && cargo build --release -p cmux-tui && python3 scripts/bench-daemon-latency.py --bin target/release/cmux-tui --ops all --scenario scale --bulk-interference --out artifacts/daemon-latency-base.json) (batch B0).

**p05-ipc-003 RequestPathScope.** Files: core:request_path.rs, core:lib.rs, core:server/connection_scheduler.rs,
core:server/connection_frame.rs, core:workspace_registry/registry_connection.rs, core:journal_ingress.rs,
core:server/server_stats.rs, cmux-tui/crates/cmux-tui-platform/src/process_resources.rs,
cmux-tui/crates/cmux-tui-platform/src/kinfo_proc.rs, core:git_ops.rs. Change: thread-local RAII scope around every
handler run; `note(kind)` with kinds sqlite, journal_wait, process_spawn, fs_write, host_wait, sleep, proc_scan,
child_process, network, lock_hold_over_1ms; `#[track_caller]` on every wrapper down to the public call;
counters plus a 128-entry site ring in server-stats `request_path_io`; `CMUX_TUI_REQUEST_PATH_IO=record` or
`panic:<kinds>` (debug/test builds only). Acceptance: release cost is one TLS load and one atomic add, no
allocation; a test handler reading the registry raises sqlite by 1 and records the handler's file:line (not the
wrapper's); a terminal-resources call raises proc_scan; panic fires only for listed kinds under
cfg(debug_assertions)/test; lock ranks unchanged. Test: RUST(request_path).

**p05-ipc-004 DaemonWireStats.** Files: app:CmuxNextDaemon/Connection/DaemonWireStats.swift,
app:CmuxNextDaemon/Connection/LineTransport.swift, app:CmuxNextDaemon/Terminal/TerminalEventQueue.swift,
app:CmuxNextApp/Control/DebugDaemonWire.swift, Tests/CmuxNextDaemonTests/DaemonWireStatsTests.swift. Change:
lock-free counters (bytes, lines, frames by kind, JSON decodes per message, outputBytesCopiedApp, connections and
bridge spawns opened by role) and `debug.daemon.wire`. Lands before 090. Acceptance: atomics only on the reader;
test: 2 terminals on a fake daemon read connectionsOpened == 3 (red baseline for 095) and outputBytesCopiedApp > 0
after 1 MiB (red baseline for 113). Test: SWIFT(DaemonWireStatsTests).

**p05-ipc-005 benches.** Files: scripts/cmux-next/split-latency-bench.py, scripts/cmux-next/bench-typing.py.
Change: `--streams` (attach_handshake_rtts, requests per view, `--machine ssh`); `--flood N` (N terminals at
10 MB/s in the measured workspace; key-to-echo and key-to-frame via cmux_flow_trace). Acceptance: both run on
today's build through bench_launch.py and record host, macOS, Hz; p50/p95/p99/max. Test: BENCH(python3 scripts/cmux-next/split-latency-bench.py --tag ipc-base --streams && python3 scripts/cmux-next/bench-typing.py --tag ipc-base --flood 10 --stress) (B0).

**p05-ipc-006 request watchdog.** Files: core:server/request_watchdog.rs, core:server/connection_scheduler.rs,
core:server/server_stats.rs, plans/cmux-next/threading-model.md. Change: each sequence stores busy_since and the
method in atomics; an armed flag means only the first busy transition while disarmed notifies the
`mux-request-watchdog` thread, which sleeps to the earliest deadline (+250 ms), re-checks and disarms when all are
idle; overruns go to a 128-entry `slow_requests` ring and a debug-spans mark. Acceptance: no periodic timer;
300 ms handler gives exactly one entry; idle 2 s gives 0 wakeups; 1,000 short requests give <= 4 watchdog
wakeups/s; thread row with QoS utility. Test: RUST(request_watchdog).

**p05-ipc-007 reply/event order invariant.** Files: core:server/bounded_outbound.rs, core:server/message_writer.rs,
app:CmuxNextDaemon/Connection/LineTransport.swift, Tests/CmuxNextDaemonTests/ReplyEventOrderTests.swift,
cmux-tui/spec/transports.md. Change: write the rule (control replies and control events share one FIFO; a reply
is enqueued after every event its request emitted; stream items share their stream FIFO; routedEventCount counts
only stream 0) and commit red tests that later tasks must keep green. Acceptance: Rust test: new-tab under a
stream flood writes its layout-changed before its reply; Swift test: eventSequence() after a reply >= the reply's
echo event sequence with 10 streams active; stream events do not change routedEventCount. Test: RUST(reply_event_order); SWIFT(ReplyEventOrderTests).

**p05-ipc-008 watchdog stack capture.** Files: core:server/request_watchdog.rs,
cmux-tui/crates/cmux-tui-platform/src/thread_backtrace.rs. Change: frame-pointer backtrace of the busy thread
(macOS thread_suspend/get_state/resume; Linux signal), stored in slow_requests; offline symbolication.
Acceptance: the 300 ms test's backtrace symbolicates to the test handler; capture < 1 ms; idle cost 0. Test: RUST(request_watchdog_stack).

**p05-ipc-009 per-method histograms.** Files: app:CmuxNextDaemon/Connection/DaemonWireStats.swift,
core:server/server_stats.rs, app:CmuxNextApp/Control/DebugDaemonWire.swift. Change: lock-free log-bucket
histograms per method id (app send-to-reply; daemon handler time and lock wait), in debug.daemon.wire, server-stats
ipc and opt-in field data. Acceptance: per-method p50/p95/p99/max agree with bench-daemon-latency within one
bucket; no allocation per request. Test: SWIFT(DaemonWireStatsTests); RUST(server_stats).

### Phase 1: schema and generation

**p05-ipc-010 schema meta.** Files: cmux-tui/spec/sdk-schema.schema.json, cmux-tui/bindings/codegen/ir.py,
cmux-tui/bindings/codegen/validate.py, cmux-tui/bindings/codegen/tests/test_ir.py, cmux-tui/spec/transports.md,
cmux-tui/spec/api-compat.surface.json. Change: attributes of section 3.3 plus a `families` table. Validation
rejects: duplicate ids in a family; ids outside the family's range; unknown priority; `independent` ordering on a
mutating or stream-scoped command; a command that targets a surface/terminal without `stream_scoped` or
`crosses_stream_ok` with a reason; binary payload fields without a bound; a binary payload without a layout
version. Acceptance: `generate.py --check` shows no diff for the 7 existing languages; each rule has a failing
fixture; `api-compat-check` passes with the refreshed surface. Test: PY(python3 -m unittest discover -s cmux-tui/bindings/codegen/tests && python3 cmux-tui/bindings/codegen/generate.py --check); RUST(api_compat).

**p05-ipc-011 assign ids and priorities.** Files: cmux-tui/spec/sdk-schema.json,
cmux-tui/scripts/assign-ipc-method-ids.py, cmux-tui/spec/transports.md. Change: one-shot, kept script; ordinals in
file order per family; priority rule table (input: send, browser-key*/mouse*/wheel*, browser-insert-text,
resize-attached-view, scroll-surface; bulk: terminal-events, journal and history reads, fs reads, icon assets;
background: inventory refresh, stats; else control); snapshot-request is stream-ordered; durability
reply_before_journal except a listed set; spawns_terminal from the Swift TerminalSpawningRequest set; `clients`
from ipc-census (`macos` for the Q1 names, `cli` for Q14 names). Acceptance: Q6 empty; second run gives no diff;
every independent method is read-only (validate); api-compat-check passes. Test: PY(python3 cmux-tui/scripts/assign-ipc-method-ids.py --check && python3 cmux-tui/scripts/check-sdk-schema.py); RUST(api_compat).

**p05-ipc-012 api-compat-check rules.** Replaces the separate Python checker. Files:
cmux-tui/crates/cmux-api-compat/src/schema.rs, cmux-tui/crates/cmux-api-compat/src/change.rs,
cmux-tui/spec/api-compat.json, cmux-tui/crates/cmux-api-compat/tests/api_compat.rs. Change: reject reused or
renumbered method_id/event_id, removal without a tombstone, a family renumber, a priority change without
`priority_changed_reason`, a binary layout change without a layout version bump; for both schema files.
Acceptance: each rule has a failing and a passing fixture; `cargo run -p cmux-api-compat --bin api-compat-check`
passes on the head after 011. Test: RUST(api_compat).

**p05-ipc-013..016, 018, 019 schema gaps.** Files: cmux-tui/spec/sdk-schema.json, cmux-tui/spec/commands.md and
the module that serves each name (013 server/apps.rs, 12 names; 014 agent_cli_intents.rs, agent_cli_job.rs,
6 names; 015 agent_inventory.rs, agent_inventory_watch.rs, 3 commands and 2 events; 016 browser_runtime.rs,
loopback_forward.rs, connection_frame/machine_catalog.rs, client_hello.rs; 018 agent_session_attach.rs,
agent_session_observe.rs; 019 agent_transfer.rs (+access_requests, agent_update), fs_wire.rs, scripts.rs).
Change: request/result types, capability, family ids and priorities; no behavior change. Acceptance: the names
leave Q5 (016: Q5 empty); field names equal the serde fields (017 check); emitters regenerate cleanly;
api-compat-check passes. Test: PY(python3 cmux-tui/scripts/check-sdk-schema.py && python3 scripts/cmux-next/ipc-census.py --queue Q5).

**p05-ipc-017 check-sdk-schema coverage.** Files: cmux-tui/scripts/check-sdk-schema.py,
cmux-tui/scripts/test_check_sdk_schema.py. Change: also parse `enum Command` in apps.rs and scripts.rs and the
literal cmd strings of each sniffer module. Acceptance: a fixture with an unschema'd apps.rs variant fails; the tree
passes. Test: PY(python3 -I cmux-tui/scripts/test_check_sdk_schema.py && python3 cmux-tui/scripts/check-sdk-schema.py).

**p05-ipc-027 build-time generation infra.** Files: cmux-tui/crates/cmux-ipc/build.rs,
Packages/macOS/CmuxNext/Package.swift, Packages/macOS/CmuxNext/Plugins/CmuxNextWireGenPlugin/plugin.swift,
Packages/macOS/CmuxNext/Sources/CmuxNextWireGen/main.swift, scripts/ci/generated-files.json, .gitignore.
Change: build.rs reads both schema files with serde_json and writes to OUT_DIR; a SwiftPM build-tool plugin runs
the Swift executable CmuxNextWireGen with the schema files as declared inputs and writes into the plugin work
directory. Manifest entries `"status": "build"`. Acceptance: `python3 scripts/ci/generated_files_guard.py`
passes; git tracks no new `*.generated.*` or `generated/` file; a clean fleet build produces the outputs; a
leaf Swift edit does not rerun the generator. Test: cmux-ci build cmux --ref SHA; RUST(cmux_ipc).

**p05-ipc-020 CmuxNextWireGen: types.** Files: app:CmuxNextWireGen/ (TypeEmitter.swift, Schema.swift),
Tests/CmuxNextWireGenTests/TypeEmitterTests.swift. Change: emit, per family file, the types reachable from
`clients: macos` methods: object, enum with `.unknown(String)` when extensible, tagged_union, literal, ref,
optional/nullable; explicit CodingKeys; public, Sendable, Equatable; typed ids via a naming map;
`omit_nil`/`default` honored. Acceptance: deterministic (two runs equal); golden test of 6 shapes; no
keyEncodingStrategy, no force unwrap; each file under the god-file cap. Test: SWIFT(CmuxNextWireGenTests).

**p05-ipc-021 requests and responses.** Files: app:CmuxNextWireGen/RequestEmitter.swift,
Tests/CmuxNextWireGenTests/RequestEmitterTests.swift. Change: `public struct <Name>Request: DaemonRequest` with
`command` and Response only (id, priority and capability live in the MethodTable); spawns_terminal adds
TerminalSpawningRequest; stream-scoped adds `stream: UInt16?`. Acceptance: one type per `clients: macos`
command; golden: SendInputRequest fixture JSON equals the hand-written encoder (key-order-insensitive); the test
lists dictionary-valued fields whose bytes change on purpose. Test: SWIFT(CmuxNextWireGenTests).

**p05-ipc-022 events.** Files: app:CmuxNextWireGen/EventEmitter.swift, Tests/CmuxNextWireGenTests/EventEmitterTests.swift.
Change: `DaemonWireEvent` with a case per event plus `unknown(name, raw)`; `decode(line:)` finds the name with a
byte scan (full-parse fallback) then decodes once; `decode(eventID:payload:)` for TYPED_EVENT. Acceptance: a
counting decoder over 20 fixture lines shows 1 decode per event. Test: SWIFT(CmuxNextWireGenTests).
A TYPED_EVENT payload is the event's JSON object, `event` included; an id the table does not know is `unknown`,
never an error. CmuxNextWireGenPlugin builds the fixture schema's `DaemonWireEvent` into CmuxNextIPCTests
(`--event-output`), where the counted decode runs. Follow-up p05-ipc-195 (after 020) passes `--event-output` for
CmuxNextIPC itself, once TypeEmitter's payload types build.

**p05-ipc-023 method tables.** Files: cmux-tui/crates/cmux-ipc/build.rs, cmux-tui/crates/cmux-ipc/src/methods.rs,
app:CmuxNextWireGen/TableEmitter.swift, app:CmuxNextIPC/MethodTable.swift. Change: per-family dense arrays
id -> {name, priority, ordering, durability, payload, stream_scoped, crosses_stream_ok, max_bytes, coalesce,
urgent} for v12, v2 and events; name -> id lookup. Acceptance: O(1) lookup without allocation; a test checks the
tables against the schema; no committed output. Test: RUST(methods_table); SWIFT(MethodTableTests).

**p05-ipc-024 v2 ops.** Files: app:CmuxNextWireGen/ResourceEmitter.swift, Tests/CmuxNextWireGenTests/ResourceEmitterTests.swift.
Change: typed params, results and the 28 errors for app-used v2 ops; an envelope builder replacing hand-written
ResourceRequestEnvelope uses. Acceptance: golden: 3 ops encode to today's lines. Test: SWIFT(CmuxNextWireGenTests).

**p05-ipc-025 SwiftPM targets.** Files: Packages/macOS/CmuxNext/Package.swift,
app:CmuxNextDaemonWire/DaemonRequest.swift, app:CmuxNextDaemon/Requests/DaemonRequest.swift,
plans/cmux-next/architecture-layers.json. Change: leaf targets CmuxNextDaemonWire (Foundation) and CmuxNextIPC
(CmuxNextCompat), test targets CmuxNextIPCTests, CmuxNextDaemonWireTests, CmuxNextWireGenTests; move DaemonRequest,
EmptyResponse and coding helpers; CmuxNextDaemon re-exports. PL-arch reviews. Acceptance: arch-layers.py --counts
shows 0 new violations; fleet build compiles. Test: cmux-ci build cmux --ref SHA; SWIFT(CmuxNextDaemonTests).

**p05-ipc-026 Rust server pilot (TerminalIO).** Files: cmux-tui/crates/cmux-ipc/build.rs (server family
emitter), cmux-tui/crates/cmux-tui-core/src/server.rs. Change: TerminalIO Command variants become build-time
generated structs (serde from presence/default). Acceptance: deserialization agrees with the old enum on
spec/fixtures and 1,000 proptest lines; the hand-written family variants are deleted. Test: RUST(server_generated_terminal_io).

**p05-ipc-028 Rust CLI client types.** Files: cmux-tui/crates/cmux-ipc/build.rs (client emitter),
cmux-tui/crates/cmux-tui/src/cli/wire.rs, cmux-tui/crates/cmux-tui/src/cli/lifecycle.rs,
plans/cmux-next/ipc-targets.json. Change: generated client request structs with method ids; migrate the 2 pilot
files; write Q14 per file group. Acceptance: pilot files have 0 hand-built `"cmd"` literals; golden JSON equal;
Q14 recorded. Test: RUST(cli_wire).

**p05-ipc-029 Q15 Command families.** Files: cmux-tui/crates/cmux-tui-core/src/server.rs,
cmux-tui/crates/cmux-ipc/build.rs, cmux-tui/scripts/check-sdk-schema.py, plans/cmux-next/ipc-targets.json.
Change: write Q15 (one task per family); migrate Tabs; remove its entries from the regex drift check.
Acceptance: Q15 written; Tabs passes fixture equality and 1,000 proptest lines. Test: RUST(server_generated_tabs).

**p05-ipc-030..043 Swift migrations.** One directory per task: 030 Requests/Tabs, 031 Profiles, 032 TerminalIO
(tell PL-typing; echo test), 033 TabGroups, 034 Screens, 035 Agents, 036 Apps (after 013), 037 Session,
038 Layout + TabMove, 039 Workspace + Creation (client-minted ids kept), 040 Bookmarks, History, Projection,
Terminals, Machines, Resource and Requests/PairingResponseRequest.swift, 041 Conversations, 042
CloudConversations, 043 Connection/, Loopback/, Chief/, Tree/, CmuxNextApp/Handlers, CmuxNextTasks (after
014-016). Files: the directory plus `ipc-census.py --callers <dir>`. Change: delete hand-written structs;
call sites use generated types (typealias only where a public name must stay). Acceptance: Q1 has 0 hits in the
directory (043: Q1 empty); wire-golden test of every migrated request equals pre-migration JSON
(key-order-insensitive) except listed dictionary-valued fields, which the daemon accepts in both forms. Off the
critical path. Test: SWIFT(CmuxNextDaemonTests).

**p05-ipc-044 event decode.** Files: app:CmuxNextDaemon/Events/DaemonEvent+Decoding.swift,
app:CmuxNextDaemon/Events/DaemonEvent.swift. Change: map DaemonWireEvent onto DaemonEvent; delete the string
switch, the per-call decoder and double decodes. Acceptance: 1 JSON decode per event on a 20-event fixture;
existing DaemonEvent tests pass unchanged. Test: SWIFT(DaemonEvent).

**p05-ipc-045 / 047 Q11.** 045: Q11 hits in CmuxNextDaemon (DaemonConnection.swift, StateResourceClient.swift,
ResourceRelay.swift, AgentCLIJobCarrier.swift); 047: the rest (CmuxNextApp/History, CmuxNextHomeEngine,
CmuxNextPalette and others listed by the census). One commit per file; split over 400 lines. Acceptance: Q11
hits gone in scope; golden lines unchanged. Test: SWIFT(CmuxNextDaemonTests).

**p05-ipc-046 WireCoding.** Files: app:CmuxNextDaemon/Requests/WireCoding.swift. Change: remove the encoder's
convertToSnakeCase and `.sortedKeys` (the decoder has no key strategy). Acceptance: `git grep -c convertToSnakeCase
-- Packages/macOS/CmuxNext/Sources/CmuxNextDaemon` == 0; golden tests pass. Test: SWIFT(CmuxNextDaemonTests).

**p05-ipc-048 iOS.** Files: Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/CmuxTUI/CmuxTUIControl.swift,
CmuxTUIBrowser.swift, scripts/cmux-next/gen-phone-lane-fields.py, Packages/macOS/CmuxNext/Package.swift (product).
Read ios/AGENTS.md first. Change: CmuxNextDaemonWire as a product for `clients: ios`; migrate the 2 files;
phone-lane generator reads the new meta. Acceptance: golden JSON equal; generator idempotent and includes allowed
new names. Test: PY(python3 scripts/cmux-next/gen-phone-lane-fields.py --check); cmux-ci run --class isolated --ref SHA --script 'scripts/ci/ios-package-tests.sh CmuxMobileSSH'.

### Phase 2: cmux-ipc and CmuxNextIPC

**p05-ipc-050 cmux-ipc crate.** Files: cmux-tui/crates/cmux-ipc/{Cargo.toml,src/lib.rs,src/frame.rs,src/reader.rs},
cmux-tui/Cargo.toml, cmux-tui/spec/fixtures/ipc-frames/, cmux-tui/spec/transports.md. Change: pure crate,
deny(unwrap/panic); header of section 3.2 incl. RING_ACK and the MORE flag; FrameReader over BytesMut yields
Json(&str) or Frame{header, Bytes} without copying; typed BadMessage. Acceptance: round trip per kind; split read
at every byte boundary; bad magic/oversize/unknown kind -> BadMessage; golden .bin files equal encoder output.
Test: RUST(cmux_ipc).

**p05-ipc-051 fds from the holder.** Files: cmux-tui/crates/cmux-ipc/src/fds.rs,
cmux-tui/crates/cmux-holder/src/wire.rs. Change: move the holder's recvmsg/SCM_RIGHTS fd FIFO into cmux-ipc
(<= 4 fds per frame, CLOEXEC, MSG_CTRUNC = BadMessage); the holder uses it; wire bytes unchanged. PL-holder reviews.
Acceptance: holder tests pass byte for byte (holder-v3 adoption fixtures included); socketpair test passes 3 fds
over 2 frames in order; no fd leak; `rg -n recvmsg cmux-tui/crates/cmux-holder/src` finds none outside cmux-ipc
calls. Test: RUST(cmux_holder); RUST(cmux_ipc_fds).

**p05-ipc-052 LaneWriter.** Files: cmux-tui/crates/cmux-ipc/src/lane_writer.rs. Change: queues input-stream,
control (replies AND events, one FIFO), bulk, background; per-stream FIFO and credit of 2; starvation bound (bulk
>= 1 frame per 8 higher frames); chunk at BULK_FRAME_MAX with MORE; byte bound: overflow ends the largest bulk
stream; producers never block; coalesce hook (141). Acceptance: property tests: FIFO per stream; control
wire order of replies and events equals emit order; an input frame behind 100 MiB bulk leaves within one chunk;
bounds hold; no per-pop allocation beyond queue nodes. Test: RUST(lane_writer).

**p05-ipc-053 Rust reader fuzz.** Files: cmux-tui/crates/cmux-ipc/tests/fuzz_reader.rs. Change: 100k random and
mutated inputs through FrameReader and method lookup, only with CMUX_IPC_FUZZ=1. Acceptance: 0 panics; every
input ends in frames or BadMessage; < 60 s. Test: RUST(fuzz_reader) with CMUX_IPC_FUZZ=1.

**p05-ipc-054 Swift FrameReader.** Files: app:CmuxNextIPC/{FrameHeader,FrameReader,ReadBuffer}.swift,
Tests/CmuxNextIPCTests/FrameReaderTests.swift. Change: recvmsg into pooled refcounted read buffers; cut JSON lines
and 0xFF frames; no-copy slices only for OUTPUT/SNAPSHOT/REPLAY payloads >= 4 KiB; copy JSON lines and small
frames; fd FIFO. Acceptance: golden fixtures decode like Rust; large OUTPUT payload base address lies in the read
buffer; a held small event retains <= its own size; bad input gives a typed error. Test: SWIFT(FrameReaderTests).
Interface (057's fuzz `Subject` calls exactly this; change both together): `FrameReader(limits:
FrameReader.Limits(maxLine: Int, maxFramePayload: UInt32))`, a limit of 0 accepted (only empty lines or empty
payloads pass); `negotiateFrames()`; besides the recvmsg path, `push(_: UnsafeRawBufferPointer)` that copies bytes
received elsewhere, allowed at any time, also after `markEndOfStream()` and after a bad message; `markEndOfStream()`;
`next() throws(BadMessage) -> Message?` (nil: needs bytes, or a clean end), `Message` an enum of exactly
`.json(line)` and `.frame(Frame)`, the line an owned `Collection<UInt8>` without its `\n` that stays valid after
later calls (not a `String`); `Frame.header.encode() -> [UInt8]` gives the 16 wire bytes and `Frame.payload` is a
`Collection<UInt8>`; `BadMessage.reason: String` is the Rust `BadMessage::reason()` string. Rules: the order of
checks and the reason strings of cmux-ipc reader.rs and frame.rs (050). A message boundary at 0xFF is a frame:
`frames_not_negotiated` before `negotiateFrames()`; once its 16 header bytes are there, `unknown_kind`, then
`oversize` (len > min(maxFramePayload, 32 MiB)), then for call kinds `unknown_priority` and `unknown_flags`, for
stream-data kinds stream 0 is `data_on_control_stream`; a partial frame at the end of stream is `truncated`. Any
other boundary starts a JSON line up to `\n`: longer than maxLine (delimiter excluded) is `line_too_long`, also
before its `\n` arrives; bytes that are not strict UTF-8 are `invalid_utf8` (the reader checks, not the JSON
decoder); at the end of stream an unterminated trailing line is a message. The first bad message is the answer of
every later call, whatever bytes come after it.

**p05-ipc-055 Swift FrameWriter.** Files: app:CmuxNextIPC/FrameWriter.swift,
app:CmuxNextDaemon/Connection/SocketWriter.swift, Tests/CmuxNextIPCTests/FrameWriterTests.swift. Change:
nonblocking writes on `com.cmuxterm.next.daemon.write` (qos userInitiated, threading-model row); priority queues
input > control > bulk; 64 MiB bound with `.backlog`; sendmsg with fds; call order within a priority. Acceptance:
an input frame enqueued after 8 MiB of bulk is written next; no blocking write on the caller; SocketWriter tests
pass. Test: SWIFT(FrameWriterTests).

**p05-ipc-056 StreamDemux.** Files: app:CmuxNextIPC/StreamDemux.swift, Tests/CmuxNextIPCTests/StreamDemuxTests.swift.
Change: stream -> sink, registered before the open is sent; bounded sinks (8 MiB output); overflow drops,
marks resyncing and calls the owner's resync hook once; reader never waits; unknown stream counted until
stream-end. Acceptance: a stopped consumer on A does not delay B or control replies; exactly one resync. Test: SWIFT(StreamDemuxTests).

**p05-ipc-057 Swift fuzz.** Files: Tests/CmuxNextIPCTests/FrameFuzzTests.swift. Change: 100k seeded mutated inputs,
only with CMUX_IPC_FUZZ=1. Acceptance: 0 crashes; < 60 s. Test: SWIFT(FrameFuzzTests) with CMUX_IPC_FUZZ=1.

**p05-ipc-058 event fan-out.** Files: app:CmuxNextDaemon/Connection/DaemonConnection.swift,
app:CmuxNextDaemon/Connection/EventSubscription.swift, Tests/CmuxNextDaemonTests/EventFanOutTests.swift. Change:
`subscribe(filter:limit:)` with a bounded inbox per subscriber; overflow resyncs that subscriber only; DaemonStore
keeps its subscriber; a second iteration of `events` traps in Debug. Acceptance: store plus 2 filtered
subscribers each get every matching event of 10k in order; a stopped subscriber delays no other; no drain loop
left in AgentPaneGitLink.swift. Test: SWIFT(EventFanOutTests).

### Phase 3: daemon wire, sequences and streams

**p05-ipc-060 capabilities.** Files: core:server/capabilities.rs, core:server/cmd_server.rs, cmux-tui/spec/transports.md.
Change: advertise ipc-frames-v2, attach-streams-v1, attach-frames-v1, terminal-output-ring-v1; frames, ring and
shared buffers only on a local Unix peer with equal api_revision; attach-streams-v1 also on bridged links; never
on WebSocket or relay. Acceptance: tests for local, remote-entry, WebSocket, bridged and N-1 revision clients.
Test: RUST(capabilities).

**p05-ipc-061 dual reader.** Files: core:server/line_connection.rs, core:Cargo.toml. Change: FrameReader on recvmsg
replaces read_line; JSON lines unchanged byte for byte; frames only after negotiation, else BadMessage; zeroize
kept. Acceptance: existing connection tests unchanged; interleaved lines and frames test; a frame before
negotiation closes with bad_message. Test: RUST(line_connection).

**p05-ipc-062 single-parse dispatch.** Files: core:server/connection_frame.rs, core:server/request_head.rs,
core:server/command_dispatch.rs, core:server/routes.rs. Change: borrowed RequestHead {id, cmd|op, stream} parsed once
(RawValue params); lookup in the generated table; each module exports a `ROUTES` const and routes.rs holds the one
list, so 063-070 never edit connection_frame.rs; unmigrated modules are reached through their entry, never a
substring scan; error replies byte-identical. Acceptance: json_parses_per_request <= 2.0 for lines on the bench
ops; spec/fixtures replies identical. Test: RUST(connection_frame).

**p05-ipc-063..070 sniffers to ROUTES.** 063 agent_cli_intents + agent_cli_job; 064 agent_inventory +
agent_inventory_watch; 065 agent_session_attach + agent_session_observe; 066 agent_transfer, access_requests,
agent_update; 067 apps (module enum parsed through its entry); 068 browser_runtime + loopback_forward (loopback data
as bulk stream data); 069 connection_frame/machine_catalog + fs_wire; 070 page_router (allow list kept, reached
through the v2 op table) + scripts. Files: those modules only. Change: try_handle becomes a typed handler in the
module's ROUTES. Acceptance: Q2 loses the files (070: `git grep -c 'fn try_handle' -- core:server` == 0); module
tests pass with identical replies. Test: RUST(<module>).

**p05-ipc-071 request frames.** Files: core:server/frame_dispatch.rs, core:server/message_writer.rs,
core:server/line_connection.rs. Change: REQUEST routes by method id; priority from the table (a differing hint is
bad_message); REPLY/ERROR echo the id with today's JSON body; CANCEL fires ConnectionCancellation. Acceptance: the
bench ops as lines and frames give equal JSON; unknown method id closes with bad_message; CANCEL ends a wait-for.
Test: RUST(frame_dispatch).

**p05-ipc-072 outbound priorities.** Files: core:server/bounded_outbound.rs, core:server/message_writer.rs,
core:server.rs. Change: items carry a priority; pop order per LaneWriter; control replies and events share one
FIFO; bulk chunked at BULK_FRAME_MAX chosen from the 16/32/64 KiB bench (numbers in the commit). Acceptance: a ping
reply is written at most one chunk after a queued 32 MiB snapshot starts; 007 tests green; backpressure tests pass;
bulk-interference ping p99 < 2 ms. Test: RUST(bounded_outbound); BENCH(python3 cmux-tui/scripts/bench-daemon-latency.py --bulk-interference).

**p05-ipc-073 sequenced pool.** Files: core:server/sequenced_pool.rs, core:server/stream_lanes.rs,
core:server/connection_scheduler.rs. Change: one daemon-wide pool; each connection control sequence and each stream
is a sequence with a priority; fixed workers per priority (input 2, control cores-2, utility 2, background 1) plus
one temporary worker while a task is inside a RequestPathScope blocking kind; stream barrier: a control command
targeting a surface with an open stream on this connection waits for that stream to drain unless
`crosses_stream_ok`; per-sequence caps reuse CONNECTION_SURFACE_QUEUE_CAPACITY (full = known-not-delivered).
Acceptance: red first: a send blocked on POLLOUT on stream A does not delay stream B or a ping (2 ms bound);
"exit\n" on the stream then close-surface on control keeps order; per-sequence FIFO property test; 0 idle wakeups;
thread count independent of connections. Test: RUST(sequenced_pool); RUST(stream_lanes).

**p05-ipc-074 attach-streams-v1.** Files: core:server/cmd_attach.rs, core:server/attach_lifecycle.rs,
core:surface/attach_tap.rs, cmux-tui/spec/events.md. Change: attach-surface takes `stream` (duplicate =
stream_in_use); READY and attach events tagged; view requests carry and check `stream`; idempotent cancel-stream;
stream-end{reason} last; id reusable only after stream-end. Acceptance: two attaches on one connection, one reader
stopped, the other's echo and a control reply within bound; no frame of a stream after its stream-end. Test: RUST(attach_streams).

**p05-ipc-075 sizing identity.** Files: core:server/client_registry_views.rs, core:mux/client_sizing_state.rs.
Change: views of one connection are leases of one client; detach-client of the whole client ends every stream.
Acceptance: two views of one terminal on one connection are one participant; kicking one view detaches only it.
Test: RUST(client_sizing).

**p05-ipc-076 OUTPUT/GRID/EVENT.** Files: core:server/render_service.rs, core:surface/attach_tap.rs,
core:server/attach_frames.rs. Change: negotiated output as raw OUTPUT (absolute offset) sharing 089's Bytes, GRID
on resize, EVENT for other attach events; colors sidecar as OUTPUT then EVENT at the same offset. Acceptance: Q7
output emitters have a frame variant; offsets continuous over 10k chunks; bytes equal the decoded JSON path.
Test: RUST(attach_frames).

**p05-ipc-077 snapshot frames.** Files: core:server/terminal_snapshot.rs, core:server/render_messages.rs,
core:surface/snapshot_attach.rs. Change: meta_len u32 + JSON meta + raw bytes (history raw DEFLATE); bulk, chunked.
Acceptance: Q7 snapshot/replay emitters have frame variants; round-trip equality on 5 fixture terminals. Test: RUST(snapshot_frames).

**p05-ipc-078 INPUT frames.** Files: core:server/frame_dispatch.rs, core:server/cmd_terminal_io.rs. Change: kind 9
writes raw bytes through the per-surface input FIFO (085) on the stream sequence; flow id to cmux_flow_trace (tell
PL-trace); no reply; failure -> EVENT input-failed{reason, bytes}. Acceptance: 10k INPUT frames in order with 0
replies; one input-failed for an ended terminal; 0 JSON parses (counter). Test: RUST(input_frames).

**p05-ipc-079 fold attach threads.** Files: core:server/attach_lifecycle.rs, core:server/cmd_attach.rs,
core:server/snapshot_attach_out.rs. Change: for stream attaches, attach-out, snapshot-attach-out and notification
threads become work items on the connection's sequences; legacy per-view keeps threads. Acceptance: 50 stream
attaches add <= 2 threads. Test: RUST(attach_threads).

**p05-ipc-080 daemon QoS.** Files: cmux-tui/crates/cmux-tui-platform/src/qos.rs, core:server.rs,
core:server/line_connection.rs, core:server/sequenced_pool.rs, plans/cmux-next/threading-model.md. Change:
`qos::set_current` (pthread_set_qos_class_self_np on macOS, no-op on Linux); per the PL-qos table: mux-server and
control userInitiated, bulk utility, background background, mux-ws-* utility; mux-conn/reactor and input workers
userInteractive only through a PL-qos exception row with the reason "IO thread every key passes". PL-qos reviews.
Acceptance: Q8 mux-* hits set QoS; a macOS test reads qos_class_self() in each body. Test: RUST(qos).

**p05-ipc-081 stream caps.** Files: core:server.rs, core:server/cmd_attach.rs. Change: MAX_STREAMS_PER_CONNECTION
4096 and a server-wide cap; over a cap only that open fails (busy). Acceptance: 4097th stream refused, connection
usable. Test: RUST(stream_caps).

**p05-ipc-082 server-stats ipc.** Files: core:server/server_stats.rs, core:diagnostics.rs. Change: per connection
streams, sequence depths, frames/bytes by kind, json_parses_per_request, write syscalls per message, write stalls,
bad_message, ring resyncs and laps; atomics. Acceptance: `server-stats --include ipc` fields non-zero after
traffic. Test: RUST(server_stats).

**p05-ipc-083 daemon socket buffers.** Files: core:server/listen.rs. Change: SO_SNDBUF/SO_RCVBUF 512 KiB on accepted
Unix sockets; log the effective value once. (The app end is in 090.) Acceptance: getsockopt >= 512 KiB in a test;
bulk-interference write stalls numbers in the commit. Test: RUST(listen).

**p05-ipc-084 frames and API revision.** Files: core:server/api_revision_wire.rs, core:server/pending_handoff.rs,
core:server/frame_dispatch.rs. Change: frames exist only at equal api_revision (060), so no upgrade parse runs for
frames; during a pending handoff a frame request gets an ERROR equal to the text refusal. Acceptance: handoff
error code equal; 0 upgrade parses for frames; an N-1 client gets downgraded JSON. Test: RUST(pending_handoff); RUST(api_revision_frames).

**p05-ipc-085 per-surface PTY input FIFO.** Files: core:server/cmd_terminal_io.rs, core:server/stream_lanes.rs,
core:pty_write.rs, core:lock_rank.rs. Change: every `send` (any connection) and INPUT for surface X goes through one
per-surface input FIFO; a bounded write is never interleaved. Acceptance: red first: a 1 MiB control `send` plus
1k INPUT keys on the stream never interleave inside the paste; lock rank documented. Test: RUST(pty_input_order).

**p05-ipc-086 v2 and sniffed handlers off the reader.** Files: core:server/connection_frame.rs,
core:server/origin_gate.rs, core:server/resource_connection.rs, core:server/connection_scheduler.rs. Change: every
parsed message (v2 ops and module routes included) goes to the connection control sequence in arrival order;
only identify, client-hello and cancel stay inline. Acceptance: red first: a v2 op held 300 ms does not delay
reading the next line and a stream `send` behind it is written within 2 ms (blocked on 073: a stream is its own
sequence there; until it lands a `send` waits its turn on the control sequence); interleaved v2/v12 reply in arrival
order; debug assertion: no handler on a mux-conn thread. Test: RUST(resource_connection); RUST(connection_frame).

**p05-ipc-087 pending streams.** Files: core:server/stream_lanes.rs, core:server/frame_dispatch.rs,
core:server/cmd_attach.rs, core:server/line_connection.rs. Change: the reader marks stream S Pending when it routes
an attach-surface/open-stream REQUEST whose header names S (no payload parse); a Pending stream queues frames and
stream requests (1 MiB INPUT, 256 requests); the open drains in order or ends with stream-end{reason} and one
input-failed for queued bytes; only never-announced ids are bad_message. Acceptance: attach{7} + 3 INPUT without
waiting reach the PTY in order after READY; stream 9 never announced gives bad_message+1; overflow ends only
stream 7. Test: RUST(stream_pending).

**p05-ipc-088 writev batching.** Files: core:server/bounded_outbound.rs, core:server/line_connection.rs. Change: pop
every ready item up to 256 KiB and write one writev of IoSlices (headers and payloads unconcatenated).
Acceptance: 100 queued messages take <= 1 + ceil(bytes / 256 KiB) writes; priority order unchanged;
write_syscalls_per_message < 0.2 in the bench. Test: RUST(bounded_outbound).

**p05-ipc-089 output fan-out.** Files: core:surface/pty_surface.rs, core:surface/attach_tap.rs,
core:server/render_service.rs. Change: AttachFrame::Output holds `bytes::Bytes`; one allocation per chunk shared
by all taps; merges use a small rope. Acceptance: 3 viewers x 10k chunks = 1 allocation per chunk; bytes equal per
viewer; viewer_backlog_bytes unchanged. Test: RUST(attach_tap).

### Phase 4: app transport and terminal streams

**p05-ipc-090 DaemonTransport.** Files: app:CmuxNextDaemon/Connection/{LineTransport,LineTransport+Pipeline,
LineTransport+Envelope,LineSplitter,DeadlineHeap}.swift. Change: FrameReader/FrameWriter; O(1) waiters (dictionary
plus id ring); one deadline heap and one DemandTimer per connection; one decode per response; 512 KiB socket
buffers; public API unchanged; LineSplitter deleted. Acceptance: LineTransport tests pass; 1 DemandTimer per
connection; JSON decodes per reply == 1; getsockopt >= 512 KiB. Test: SWIFT(LineTransportTests); SWIFT(CmuxNextDaemonTests).

**p05-ipc-091 nonisolated request path.** Files: app:CmuxNextDaemon/Connection/DaemonConnection.swift,
DaemonConnection+QuietHandoff.swift. Change: request reads a Mutex snapshot; handoff hold is an atomic gate plus a
continuation list; atomic inFlight. Acceptance: 0 actor hops per request (executor probe); quiet-handoff tests pass;
no `assumeIsolated` added. Test: SWIFT(DaemonConnectionTests).

**p05-ipc-092 negotiate.** Files: app:CmuxNextDaemon/Connection/{DaemonHandshake,HandshakeLines,
DaemonRequestExecutor,DaemonCapabilities}.swift. Change: frames on local Unix at equal api_revision; streams on
local and bridged; REQUEST frames use the MethodTable. Acceptance: real-daemon test: equal results for the bench
ops in both modes; old-daemon fixture works. Test: SWIFT(DaemonHandshakeTests); cmux-ci run --class isolated --ref SHA --script 'scripts/ci/cmux-next-daemon-test-packages.sh'.

**p05-ipc-093 bounded events.** Files: app:CmuxNextDaemon/Connection/DaemonConnection.swift, EventGate.swift,
app:CmuxNextDaemon/Store/DaemonStore+Driver.swift. Change: no `.unbounded` stream; the store's 058 subscriber is
the bounded EventInbox (4096, coalescing, one resync on overflow). Acceptance: `git grep -c 'bufferingPolicy:
.unbounded' -- Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection` == 0; 100k-event flood: bounded
memory, one resync. Test: SWIFT(DaemonStoreTests).

**p05-ipc-094 streams default on.** Files: app:CmuxNextDaemon/Terminal/TerminalAttachment.swift,
plans/cmux-next/app-daemon-connection-DESIGN.md. Change: flip CMUX_NEXT_TERMINAL_STREAMS and its setting on (local
and bridged once 151 lands). Acceptance: the commit cites B1: bulk-interference ping p99 < 2 ms, flood echo p95 <=
single + 0.5 ms, 5 MB decode stall < 1 ms (host, sha, macOS, Hz). Test: BENCH(python3 scripts/cmux-next/bench-typing.py --tag ipc-094 --flood 10 --stress && python3 cmux-tui/scripts/bench-daemon-latency.py --bulk-interference).

**p05-ipc-095 TerminalAttachment stream.** Files: app:CmuxNextDaemon/Terminal/TerminalAttachment.swift,
app:CmuxNextDaemon/Connection/DaemonConnection+Terminals.swift. Change: mint the id; register the sink before
attach-surface; no per-view identify; view commands carry `stream`; detachNow sends cancel-stream; id freed at
stream-end; default off. Acceptance: 0 connections per new view with the flag on (red in 004);
attach_handshake_rtts == 0; TerminalByteChannel API unchanged. Test: SWIFT(TerminalAttachmentStreamTests); BENCH(python3 scripts/cmux-next/split-latency-bench.py --tag ipc-095 --streams).

**p05-ipc-096 INPUT frames from the app.** Files: app:CmuxNextDaemon/Terminal/TerminalAttachment.swift. Change:
enqueueInput writes an INPUT frame through 140's inline path from the io_write_cb thread; no JSONEncoder, no base64.
Tell PL-typing. Acceptance: 10k keys in order; 0 JSON encodes per key; echo p95 not worse (numbers). Test: SWIFT(TerminalAttachmentStreamTests); BENCH(python3 scripts/cmux-next/bench-typing.py --tag ipc-096 --flood 10).

**p05-ipc-097 decode attach frames.** Files: app:CmuxNextDaemon/Terminal/{TerminalAttachment+Decoding,
TerminalEventQueue,TerminalSnapshotFrame}.swift. Change: map frames onto TerminalChannelEvents with offset
continuity (gap -> resync); slices; merge adjacent slices by range, never across GRID or non-output events.
PL-ghostty reviews. Acceptance: 0 copies (base address in read buffer); gap test gives snapshot-request and a
correct screen; Q10 hits in Terminal/ gone. Test: SWIFT(TerminalAttachmentFrameTests).

**p05-ipc-098 attach call sites.** Files: app:CmuxNextApp/DaemonTerminalIO.swift,
app:CmuxNextApp/TabContentCache+RemoteTerminals.swift. Change: use DaemonService's machine connection.
DaemonCompatBackend stays on its own allowlisted connection. Acceptance: no `TerminalAttachment.attach(endpoint:`
outside the legacy fallback and DaemonCompatBackend. Test: cmux-ci build cmux --ref SHA; SWIFT(CmuxNextDaemonTests).

**p05-ipc-099 no reader-blocking backpressure.** Files: TerminalEventQueue.swift, TerminalAttachment.swift. Change:
in stream mode never block; over 8 MiB drop, snapshot-request{stream, overflow}, drop until READY; blocking only on
the legacy path. Acceptance: a stopped consumer on A does not delay B or replies; one resync. Test: SWIFT(TerminalEventQueueTests).

### Phase 5: side connections and page relays

**p05-ipc-100 SessionJournalRead.** Files: app:CmuxNextDaemon/Requests/Resource/SessionJournalRead.swift. Change: v2
stream on the shared connection, bulk, independent. Acceptance: Q4 hit gone; journal read tests pass. Test: SWIFT(SessionJournalReadTests).

**p05-ipc-101 Loopback.** Files: app:CmuxNextDaemon/Loopback/{LoopbackForwardClient,LoopbackStreamTable}.swift.
Change: stream frames on bulk. Acceptance: Q4 hit gone; loopback tests pass. Test: SWIFT(LoopbackForwardTests).

**p05-ipc-102 AgentSessionAttachClient.** Files: app:CmuxNextDaemon/AgentSession/AgentSessionAttachClient.swift.
Change: a stream on the shared connection. Acceptance: Q4 hit gone; tests pass. Test: SWIFT(AgentSessionAttachTests).

**p05-ipc-103 daemon page-relay connection (risk:high).** Files: core:server/origin_gate.rs, core:request_origin.rs,
core:server/client_hello.rs, core:server/page_router.rs, plans/cmux-next/request-origin.md. Change: a page_relay
connection may open many page streams; open-stream{page} binds `page:<id>` for the stream's life; stream 0 accepts
only open/close; every request is judged with the stream origin and the page-router allow list; tokens bound to
(op, params hash, stream); origin.confirmation.issue stays refused on page_relay connections; the main connection
never accepts page streams. Acceptance: policy tests: no page stream request acts as user; origin immutable; a token
for stream X fails on Y; untagged request on the page_relay connection refused; open-stream{page} on a main
connection refused; analysis in request-origin.md; review receipt. Test: RUST(origin_gate); RUST(page_access).

**p05-ipc-104 PageRelayChannel (risk:high).** Files: app:CmuxNextApp/Pages/PageRelayChannel.swift,
app:CmuxNextApp/Pages/PageRelayConnection.swift. Change: one shared page_relay connection per daemon with a stream
per page (the API exposes a stream handle with no untagged send); events narrowed per stream; resync on stream-end;
fallback per page for old daemons. Acceptance: Q4 hit gone; 5 pages = 1 page-relay connection; 103's tests pass end
to end; review receipt. Test: SWIFT(PageRelayChannelTests).

**p05-ipc-105 AgentPaneGitLink.** Files: app:CmuxNextDaemonService/AgentPaneGitLink.swift. Change: a 058 filtered
subscription on DaemonService's connection instead of a new connection with a drain task. Acceptance: Q4 hit gone;
git link tests pass. Test: SWIFT(AgentPaneGitLinkTests).

**p05-ipc-106 allowlist.** Files: plans/cmux-next/ipc-targets.json, plans/cmux-next/app-daemon-connection-DESIGN.md.
Change: reasons for each transient site of section 3.1. Acceptance: `ipc-census.py --check` IPC-1 passes with only
allowlisted sites. Test: PY(python3 scripts/cmux-next/ipc-census.py --check).

**p05-ipc-107 OWNERS.** Files: plans/cmux-next/OWNERS.md. Change: row for cmux-tui/crates/cmux-ipc/,
app:CmuxNextIPC/, app:CmuxNextDaemonWire/, app:CmuxNextWireGen/ (owner PL-conn, who decided, date); tell list.
Acceptance: guardrails.py names the owner for a push touching cmux-ipc. Test: PY(python3 scripts/cmux-next/guardrails.py --list).

**p05-ipc-108 ChiefProfilePageRelay (risk:high).** Files: app:CmuxNextHomeEngine/ChiefProfilePageRelay.swift.
Change: open a `home-channels` page stream on the owner's page-relay connection; keep the owner pid/generation check
by binding to the connection epoch. Acceptance: Q4 hit gone; 0 extra connections with Home channels open; 103's
origin tests pass for this page; receipt. Test: SWIFT(ChiefProfilePageRelayTests).

**p05-ipc-109 page relay off main.** Files: app:CmuxNextApp/Pages/PageRelayChannel.swift,
app:CmuxNextApp/Pages/PageConnectionWatch.swift. Change: nonisolated channel with Mutex state; event bytes pass
through undecoded; at most one main post per page per display frame. Acceptance: 0 main hops per page call before
send; 0 app JSON decodes per relayed event; 1,000-event flood gives <= 1 main post per frame per page. Test: SWIFT(PageRelayChannelTests).

### Phase 6: shared memory

**p05-ipc-110 output ring.** Files: cmux-tui/crates/cmux-ipc/src/{shm.rs,output_ring.rs},
cmux-tui/crates/cmux-holder/src/ring.rs. Change: move the holder's segment creation (memfd; unlinked shm_open with
the <= 31-byte name scheme, CLOEXEC handling) into cmux-ipc; the holder uses it (layout bytes unchanged); add CMAR
layout 1 (reserve/end atomics, wrap, 1 MiB default, 64 MiB max); RO fd: macOS O_RDONLY open before unlink, Linux
reopen /proc/self/fd/N O_RDONLY or F_SEAL_FUTURE_WRITE. PL-holder reviews. Acceptance: lap detection, wrap, oversize
chunk keeps the last capacity bytes, no name outlives creation, name length <= 31 (test), RO fd refuses writes;
holder tests pass byte for byte. Test: RUST(output_ring); RUST(cmux_holder).

**p05-ipc-111 daemon ring (risk:high).** Files: core:surface/pty_surface.rs, core:surface/attach_tap.rs,
core:server/attach_frames.rs, core:server/capabilities.rs. Change: ring on the first ring attach; written in output
order; RING frame with the RO fd; RING_ADVANCE merged (newest end wins); grant only to local same-euid peers.
Acceptance: ring bytes equal parser bytes at the same offsets; remote/WebSocket/bridge never get RING; one
RING_ADVANCE in flight per stream; receipt. Test: RUST(output_ring_attach).

**p05-ipc-112 SharedOutputRing.** Files: app:CmuxNextIPC/SharedOutputRing.swift, Tests/CmuxNextIPCTests/SharedOutputRingTests.swift.
Change: verify mmap(PROT_WRITE, MAP_SHARED) fails (success = protocol error), then PROT_READ map and close the fd;
refcounted; spans via Data(bytesNoCopy:deallocator:); reserve rule at cut and release; last release unmaps.
Acceptance: a writable fd is refused; lap during a held span marks lapped; unmap after the last release. Test: SWIFT(SharedOutputRingTests).

**p05-ipc-113 app ring streams.** Files: TerminalAttachment+Decoding.swift, TerminalEventQueue.swift. Change: RING
maps; RING_ADVANCE gives <= 2 spans; gap -> resync; merge only adjacent spans of one mapping. Acceptance:
outputBytesCopiedApp == 0 after 50 MB (red in 004); span base address at ghostty_surface_process_output inside the
mapping. Test: SWIFT(TerminalRingTests); BENCH(python3 scripts/cmux-next/bench-typing.py --tag ipc-113 --flood 10 --stress) (B2).

**p05-ipc-114 resume by offset.** Files: core:server/cmd_attach.rs, TerminalAttachment.swift. Change:
attach-surface{resume_offset}: RING + RING_ADVANCE from it when inside the ring, else READY. Acceptance: resume with
no snapshot inside, with snapshot outside. Test: RUST(resume_offset); SWIFT(TerminalRingTests).

**p05-ipc-115 SHARED_BUFFER pool (risk:high, bench-gated).** Files: cmux-tui/crates/cmux-ipc/src/shared_buffer.rs,
core:server/frame_dispatch.rs, app:CmuxNextIPC/SharedBuffer.swift, app:CmuxNextDaemon/Connection/LineTransport.swift.
Change: a per-connection pool of reusable regions for payloads > 64 KiB (snapshot history, icon assets, paste-image
upload); daemon copies app bytes before parsing; local same-euid only. Acceptance: the commit has a bench row where
the pool beats chunked frames by >= 20% in throughput or CPU, else the task closes with the row and no code; 10 MB
paste-image = 1 frame + 1 fd; mutation after send does not change the parsed bytes; no fd leak; receipt.
Test: RUST(shared_buffer); SWIFT(SharedBufferTests); BENCH(python3 cmux-tui/scripts/bench-daemon-latency.py --bulk-interference).

**p05-ipc-116 ring sizing.** Files: scripts/cmux-next/ipc-soak.py, plans/cmux-next/app-daemon-connection-DESIGN.md.
Change: resyncs/min in STRESS and a 50 MB/s cat; capacity changes only with the number. Acceptance: section 9 rows
with host, sha, Hz. Test: BENCH(python3 scripts/cmux-next/ipc-soak.py --minutes 10 --flood 10).

**p05-ipc-117 macOS 14/15.** Files: scripts/cmux-next/os-matrix.sh, app-daemon-connection-DESIGN.md. Change: run
output_ring, cmux_ipc_fds, qos, pi_mutex and SharedOutputRingTests in Tart 14/15 (behavior only). Acceptance: rows
pass and are recorded. Test: scripts/cmux-next/os-matrix.sh --build JOB --os 14,15.

**p05-ipc-118 compat matrix.** Files: Tests/CmuxNextDaemonTests/IpcCompatMatrixTests.swift,
core:../tests/ipc_compat_matrix.rs. Change: pinned old cmux-tui binary and an old-client fixture; attach, bench ops,
events. Acceptance: new app + old daemon = per-view JSON; old client + new daemon = byte-identical JSON; new pair =
frames. Test: cmux-ci run --class isolated --ref SHA --script 'scripts/ci/cmux-next-daemon-test-packages.sh IpcCompatMatrixTests'.

**p05-ipc-119 ring consumer cursor (risk:high).** Files: cmux-tui/crates/cmux-ipc/src/output_ring.rs,
core:server/attach_frames.rs, app:CmuxNextIPC/SharedOutputRing.swift, app-daemon-connection-DESIGN.md. Change: app
sends RING_ACK{offset} (coalesced to one per display frame); daemon never writes a reader's ring past acked +
capacity, it skips and marks gap-pending; next RING_ADVANCE is a gap; release-time lap check stays as a counter.
PL-ghostty and PL-holder sign off. Acceptance: the flood-while-holding test shows 0 torn spans parsed (release
laps == 0) and exactly one gap/resync; writer latency unchanged (numbers); receipt. Test: RUST(output_ring); SWIFT(SharedOutputRingTests); BENCH(python3 scripts/cmux-next/ipc-soak.py --minutes 10 --flood 10).

### Phase 7: F10 (PL-daemon review on every task)

**p05-ipc-132 in-memory revisions and ledger (risk:high).** Files: core:workspace_registry/{workspace_commit_intent,
mutation_ledger,registry_intent,terminal_commit_intent}.rs. Change: revision counter and a bounded
mutation_id -> (fingerprint, result, revision) cache seeded at open, including admitted uncommitted intents; CAS
and replay at prepare time; the writer writes exactly the admitted revisions. Acceptance: 2 identical mutation_ids
admitted back to back give 1 apply and replayed:true; reply revision == committed row revision; CAS conflict
refused at prepare; writer-side CAS failures 0 over the suite; revisions unchanged after a writer retry. Test: RUST(mutation_ledger); RUST(registry_intent).

**p05-ipc-133 admitted overlay (risk:high).** Files: core:workspace_registry/{registry_connection,admitted_overlay,
workspace_commit_intent}.rs. Change: topology prepare and hot reads consult admitted, uncommitted intents first.
Acceptance: two back-to-back creates with a 50 ms injected writer delay both reply < 2 ms; the second sees the
first's topology; read_barrier_waits == 0 on that path. Test: RUST(admitted_overlay).

**p05-ipc-120 admit then reply (risk:high).** Files: core:workspace_registry/{registry_intent,registry_connection}.rs,
core:journal_ingress/effect_intents.rs, core:mux/event_emit.rs. Change: commit_registry_intent_with admits (sequence),
enqueues and returns an Admitted receipt with prepare-time results; events emitted at admit, before the reply; cold
reads wait on a counted barrier; writer is apply-only (I/O retry with coalescing, journal-degraded); the
commit_registry_intent_locally fallback is counted and removed or allowlisted; daemon setting, default on in
Nightly. Acceptance: red first: create-terminal reply excludes a 50 ms writer delay; read-after-write sees it;
writer failure gives journal-degraded and no lost in-memory state; 007 tests green; lock ranks unchanged; receipt.
Test: RUST(registry_intent); RUST(journal_ingress); BENCH(python3 cmux-tui/scripts/bench-daemon-latency.py --ops create).

**p05-ipc-121..126 Q3 sites.** 121 mux/surface_spawn.rs (:110, :272); 122 terminal_lifecycle_commit.rs and
terminal_records.rs (tombstone order by admit sequence); 123 terminal_move.rs; 124 workspace_registry.rs (:3350,
:3387) and resource_effect_commit.rs (create-workspace p95 < 2 ms); 125 resource_effects.rs and feed_local.rs
(idempotent effect receipts); 126 journal.rs, journal_ingress.rs, sdk-schema.json: journal-frontend-event replies
admitted:true under frontend-journal-v2, old clients keep committed:true. Change: use the Admitted receipt.
Acceptance: the file's Q3 hits gone; request_path_io.journal_wait == 0 for the ops; module tests pass. Test: RUST(<module>).

**p05-ipc-127 journal writer.** Files: core:journal_ingress.rs, core:journal_ingress/coalesce.rs. Change: drain
durable/effect intents before terminal batches; commit within 1 ms at idle; QoS utility. PL-qos reviews.
Acceptance: with 256 KiB of terminal batches queued, an admitted intent commits first. Test: RUST(journal_ingress); BENCH (B3).

**p05-ipc-128 Q9 triage.** Files: plans/cmux-next/ipc-targets.json. Change: record run; one p05-ipc-3NN task per
(kind, site) shaped like 121, or a reason. Acceptance: the list equals the run's site set. Test: cmux-ci run --class isolated --ref SHA --script 'cd cmux-tui && CMUX_TUI_REQUEST_PATH_IO=record cargo test -p cmux-tui-core 2>&1 | grep REQUEST_PATH_IO | sort | uniq -c'.

**p05-ipc-134 direct callers.** Files: core:mux/workspace_rename.rs (:232), core:mux/resource_effects/effect_commit.rs
(:53), core:workspace_registry/workspace_commit_intent.rs (:129), core:workspace_registry.rs (:3137). Change: Admitted
receipt; the rename settle closure becomes the writer-failure path. Acceptance: sites leave Q3; rename p95 < 2 ms
with a 50 ms writer delay; journal_wait == 0 for rename. Test: RUST(workspace_rename).

**p05-ipc-135 Q13 transactions.** Files: core:workspace_registry/presentation_store.rs,
core:workspace_registry/presentation_store/frontend_browser_history.rs, plans/cmux-next/ipc-targets.json. Change:
presentation_store writes (put_frontend_browser at :1145 and others) become RegistryIntents; write the Q13 list with
a task or reason per hit. Acceptance: new-frontend-browser-tab p95 < 2 ms; sqlite count for the op == 0; every Q13
hit has a task or reason. Test: RUST(presentation_store); BENCH(python3 cmux-tui/scripts/bench-daemon-latency.py --ops all).

**p05-ipc-136 Q18 projections.** Files: plans/cmux-next/ipc-targets.json and one core:workspace_registry/*.rs per
child task. Change: write Q18 from the record run; each child serves its reads from a registry-owned in-memory
projection updated at admit. Acceptance: queue lists every (site, op); each child has a golden test (projection ==
SQLite after N random mutations); after all children IPC-6's sqlite and read_barrier_waits are 0. Test: Q9 record run; BENCH (B3, STRESS).

**p05-ipc-137 QoS donation.** Files: cmux-tui/crates/cmux-tui-platform/src/qos.rs, core:journal_ingress.rs,
core:workspace_registry/registry_connection.rs. Change: qos::override_start/end via
pthread_override_qos_class_start_np; barrier and receipt waits boost the writer (refcounted, highest wins). PL-qos
reviews. Acceptance: under 8 utility hogs, barrier wait p99 drops (numbers); writer reads USER_INTERACTIVE only
while a waiter exists; 0 overrides at idle; Linux no-op. Test: RUST(read_barrier_qos).

**p05-ipc-138 PI ranked locks.** Files: cmux-tui/crates/cmux-tui-platform/src/{pi_mutex,lib}.rs, core:lock_rank.rs,
core:workspace_registry/registry_connection.rs. Change: PiRawMutex (lock_api over boxed os_unfair_lock on macOS,
parking_lot on Linux) behind a type alias for every Q17 lock, including the reentrant registry connection. PL-qos
reviews. Acceptance: a test enumerates ranks and finds the alias; macOS inversion test (background holder, 8
background hogs, user-interactive waiter): wait p99 <= 2x the uncontended hold; lock-rank checks unchanged. Test: RUST(pi_mutex).

**p05-ipc-130 reply before spawn (risk:high).** Files: core:mux/terminal_create.rs, core:mux/terminal_work.rs,
core:server/cmd_terminals.rs, cmux-tui/spec/sdk-schema.json. Change: under terminal-async-start-v1, create-terminal,
new-tab and split reply after admit with starting:true; launch/adoption on TerminalWorkPool emits terminal-started
or terminal-start-failed; input-while-creating keeps working; attach to a starting terminal gets READY when up.
PL-holder reviews. Acceptance: red first: with a 200 ms host delay create reply p95 < 2 ms and terminal-started
after; failure emits terminal-start-failed and rolls back by mutation_id; receipt. Test: RUST(terminal_async_start); BENCH(... --ops create).

**p05-ipc-131 app starting terminals.** Files: app:CmuxNextDaemonService/{NewTerminalTabCommand,PaneSplitCommand}.swift,
app:CmuxNextDaemon/Connection/DaemonConnection.swift. Change: no spawnTimeout under the capability; stand-in attaches
at once as a stream; terminal-start-failed rolls back through ActionEffect and the refusal HUD. Acceptance: reply
resolves the intent before terminal-started; failure removes the stand-in exactly; split p95 numbers. Test: SWIFT(NewTerminalTabCommandTests); BENCH(split-latency-bench --streams).

### Phase 8: Chrome-grade scheduling and throughput

**p05-ipc-140 inline write fast path.** Files: app:CmuxNextIPC/FrameWriter.swift, core:server/message_writer.rs,
core:server/bounded_outbound.rs. Change: on a non-main thread, when every equal-or-higher queue is empty and no
partial frame is pending, write nonblocking under the writer lock; on EAGAIN or partial queue the rest; main-thread
callers always enqueue. Acceptance: idle connection: 1,000 INPUT frames cause 0 writer-queue hops and 1,000 echo
OUTPUTs 0 mux-line-out wakeups; 055/072 priority tests pass; main never calls sendmsg (assertion test). Test: SWIFT(FrameWriterTests); RUST(message_writer).

**p05-ipc-141 producer coalescing.** Files: cmux-tui/crates/cmux-ipc/src/lane_writer.rs,
core:server/bounded_outbound.rs, app:CmuxNextIPC/FrameWriter.swift. Change: a queued unsent item with the same
(id, coalesce key) is replaced (additive fields sum); app input-priority continuous methods coalesce per stream to
one per display refresh. Acceptance: 1,000 size-state events behind a blocked socket send 1; 100 resizes in a frame
send 1; order with non-coalescable items kept (property test). Test: RUST(lane_writer_coalesce); SWIFT(FrameWriterTests).

**p05-ipc-142 stream visibility priority.** Files: core:server/cmd_attach.rs, core:server/attach_frames.rs,
core:server/bounded_outbound.rs, cmux-tui/spec/sdk-schema.json, TerminalAttachment.swift,
app:CmuxNextTerminal/TerminalOutputLane.swift, app:CmuxNextApp/TabContentCache+Lifecycle.swift. Change:
set-stream-priority{stream, focused|visible|hidden} (input, coalesced); focused output rides input priority;
hidden gets no OUTPUT/RING_ADVANCE (daemon still parses, marks dirty); hidden TerminalOutputLane drops to utility;
show resumes by offset or snapshot; sent from TabContentCache .show/.hide. PL-ghostty coordinates. Acceptance: flood
10 visible: focused echo p95 <= single + 0.5 ms; 10 hidden printing terminals: 0 app wakeups/s and 0 frames for
them; show renders the correct screen with no extra frame. Test: RUST(stream_priority); SWIFT(TerminalAttachmentStreamTests); BENCH(bench-typing --flood 10 --stress && scripts/cmux-next/bench-idle.sh --hidden-flood 10).

**p05-ipc-143 person first.** Files: core:server/request_priority.rs, core:server/sequenced_pool.rs,
core:server/client_registry.rs, core:server/worker_admission.rs. Change: classify connections at hello (proven role
main = person, else automation); pool priority by class; the registry lock and worker permits admit a waiting
person request first, with a starvation bound. Acceptance: `--automation-storm 8`: echo p95 <= idle + 1 ms, split
p95 < 2 ms, automation >= 50% of idle throughput. Test: RUST(request_priority); BENCH(bench-daemon-latency.py --ops all --automation-storm 8).

**p05-ipc-144 app reader routes only.** Files: LineTransport.swift (DaemonTransport), app:CmuxNextDaemon/Connection/DecodeLanes.swift,
app:CmuxNextDaemon/Terminal/TerminalSnapshotInflate.swift, TerminalAttachment+Decoding.swift, app:CmuxNextIPC/StreamDemux.swift.
Change: reader cuts and routes by header/envelope id; input and stream output delivered inline; control decode on a
userInitiated serial queue, bulk and snapshot inflate on per-stream utility/BackgroundWork .cpu serial work.
Acceptance: a 5 MB reply decode delays stream frames < 1 ms p99; a 4 MiB history on A delays B and a ping < 1 ms;
no inflate on the reader (Debug assertion); control order unchanged (property test). Test: SWIFT(LineTransportTests); SWIFT(TerminalAttachmentFrameTests).

**p05-ipc-145 v2 stream ids.** Files: core:server/resource_connection.rs, core:server/session_event_stream.rs,
LineTransport+Envelope.swift, app:CmuxNextDaemon/Connection/DaemonConnection+SessionEvents.swift. Change: under
frames, map each `stream_<hex>` to a u16 frame stream at open; one demux and one cancel/end path. Acceptance:
session.events items reach the store with 0 envelope decodes; end and cancel behave the same. Test: RUST(session_stream); SWIFT(DaemonStoreTests).

**p05-ipc-146 subscription threads.** Files: core:server/cmd_subscribe.rs, core:server/session_event_stream.rs,
core:server/conversation_events.rs, core:server/agent_inventory_watch.rs. Change: mux-events-out,
mux-resource-session-events, mux-resource-conversation-events, mux-inventory-watch become work items on the
connection's sequences. Acceptance: 10 subscriptions on one connection add <= 1 thread; 0 idle wakeups. Test: RUST(cmd_subscribe).

**p05-ipc-147 v2 attach/wait/journal threads.** Files: core:server/{resource_attach,resource_waits,journal_stream,
agent_session_attach,browser_runtime,cmd_attach}.rs. Change: same for mux-resource-*-attach, terminal-wait,
session-journal, mux-agent-attach, mux-browser-runtime-out, mux-render-attach-out. Acceptance: 5 journal reads, 5
agent attaches, 5 waits add <= 2 threads. Test: RUST(resource_attach); RUST(journal_stream).

**p05-ipc-148 stream subscriptions, encode once.** Files: core:server/cmd_subscribe.rs, core:event_bus.rs,
core:server/origin_gate.rs. Change: `subscribe {stream}` binds a filter to a stream; serialize each event once per
filter class into `Arc<[u8]>`. Acceptance: 10 subscribers = 1 serialization per event per class; a page stream
hears only its page; page_access_tests pass. Test: RUST(cmd_subscribe); RUST(page_access).

**p05-ipc-149 binary bulk paths.** Files: core:server/agent_session_attach.rs, core:server/loopback_forward.rs,
core:fs_ops/ops.rs, core:server/terminal_history.rs, app:CmuxNextDaemon/Loopback/LoopbackStream.swift. Change: binary
stream frames (SHARED_BUFFER only if 115 landed) instead of base64; LoopbackStream uses a bounded credit queue.
Acceptance: 0 base64 encodes on frame connections for these ops (counter); byte equality; no `.unbounded` in
Loopback/. Test: RUST(loopback_forward); RUST(fs_wire); SWIFT(LoopbackForwardTests).

**p05-ipc-150 echo-path QoS.** Files: core:terminal_host.rs, core:holder_runtime/service.rs, core:surface.rs,
core:journal_ingress.rs, cmux-tui/crates/cmux-holder/src/link.rs, threading-model.md. Change: QoS for
terminal-host-client(-input), terminal-host-parser, surface-*, surface-frames, cmux-link-in/out, mux-terminal-work
and the journal writer per the PL-qos table. PL-qos and PL-holder review. Acceptance: Q8 empty for these names;
macOS test reads qos_class_self(); bench-typing STRESS p99 not worse. Test: RUST(qos); BENCH(bench-typing --tag ipc-150 --flood 10 --stress).

**p05-ipc-151 bridged streams.** Files: TerminalAttachment.swift, app:CmuxNextDaemon/Connection/{DaemonBridge,
DaemonHandshake}.swift, app:CmuxNextDaemonService/DaemonService.swift. Change: attach-streams-v1 on the bridged
connection; remote views, loopback and agent attaches become streams there. Acceptance: fake bridge executable: 5
remote views spawn 0 more children; split-latency-bench --streams --machine ssh gives 0 handshake rtts; old remote
daemons keep the per-view path. Test: SWIFT(TerminalAttachmentStreamTests); BENCH(split-latency-bench --tag ipc-151 --streams --machine ssh).

**p05-ipc-152 cmux-remote lanes.** Files: cmux-tui/crates/cmux-remote/src/mux_lanes.rs,
cmux-tui/crates/cmux-remote-protocol/src/frame.rs, cmux-tui/crates/cmux-ipc/build.rs. Change: one vocabulary
(input = interactive, control, bulk, tunnel, background); classifier generated at build time; frames classified from
the header. Acceptance: test compares generated vs old table for every name, differences listed with a reason;
frames 0 JSON parses. Test: RUST(mux_lanes).

**p05-ipc-153 input while creating.** Files: app:CmuxNextDaemon/Terminal/CreatingTerminalInput.swift,
core:server/creating_input.rs, core:server/cmd_attach.rs. Change: bind the client stream to the minted terminal id at
create (Pending stream); keys go as INPUT frames, queued until start. Tell PL-typing. Acceptance: 200 keys during a
200 ms host start arrive in order with 0 replies and 0 JSON encodes; first-key-after-split echo p95 numbers. Test: SWIFT(CreatingTerminalInputTests); RUST(creating_input).

**p05-ipc-155 IO reactor reads.** Files: core:server/io_reactor.rs, core:server/line_connection.rs, core:server.rs,
core:Cargo.toml. Change: one mio reactor thread owns accepted sockets, recvmsg into each FrameReader, routes to
sequences; per-connection mux-conn deleted. PL-qos reviews its QoS. Acceptance: 100 CLI connections add 0 threads;
line_connection tests pass; 0 reactor wakeups at idle. Test: RUST(io_reactor); RUST(line_connection).

**p05-ipc-156 reactor writes.** Files: core:server/io_reactor.rs, core:server/bounded_outbound.rs,
core:server/line_connection.rs. Change: outbound flush on writability in the reactor; mux-line-out deleted.
Acceptance: 50 stream attaches + 20 CLI connections keep daemon threads within +-2; 072/088 tests pass. Test: RUST(io_reactor); BENCH(bench-daemon-latency.py --ops all --streams 50).

**p05-ipc-157 async input sink.** Files: core:pty_write.rs, core:surface/input.rs, core:pty_input_room.rs. Change: one
nonblocking try; the rest goes to a bounded per-terminal buffer drained in order by the reactor; overflow or dead
PTY gives one input-failed; same for hosted input. Acceptance: a non-reading child plus 10k INPUT frames: no worker
blocks (host_wait and lane poll counts 0), bytes arrive in order once read, a ping p99 < 2 ms meanwhile. Test: RUST(async_input_sink).

### Phase 9: bridge, tracing, codecs, stability, proof

**p05-ipc-160 SSH bridge frames.** Files: cmux-tui/crates/cmux-remote/src/{mux_codec,mux_lanes,bridge}.rs. Change:
pass 0xFF messages through by header; one lane per stream; advertise bridge-frames-v1. Acceptance: interleaved
OUTPUT/EVENT of 3 streams keep per-stream order and bytes. Test: RUST(mux_codec).

**p05-ipc-161 app frames over SSH.** Files: DaemonHandshake.swift, DaemonBridge.swift. Change: frames on bridged
endpoints only with bridge-frames-v1; never ring or shared buffers. Acceptance: bridged endpoint gets frames, never
RING; old bridges keep JSON. Test: SWIFT(DaemonHandshakeTests).

**p05-ipc-180 flow id.** Files: DaemonRequestExecutor.swift, core:server/frame_dispatch.rs, scripts/cmux-next/trace.py,
plans/cmux-next/trace.md. Change: flow flag + 8-byte id; daemon spans and cmux_flow_trace; trace.py joins app ->
daemon -> reply. Tell PL-trace. Acceptance: a split trace shows one flow; flow off costs one branch. Test: BENCH(python3 scripts/cmux-next/trace.py record --app --tag ipc-180 -- split).

**p05-ipc-181 Chromium host wire.** Files: cmux-tui/spec/chromium-host-wire.json, app:CmuxNextWireGen/HostWireEmitter.swift,
cmux-tui/bindings/codegen/emit_cpp.py (build-time path for the shim), app:CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostFrame.swift,
scripts/ci/generated-files.json. Change: describe the 64-byte frames; generate Swift and C++ codecs at build time,
replacing the hand-kept golden pair. Coordinate with PL-cef-helper. Acceptance: golden frame tests pass on both
sides from generated code; generated_files_guard passes. Test: cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/test-chromium-host-wire-cpp.sh'; SWIFT(ChromiumHostFrameTests).

**p05-ipc-182 structured fuzzing.** Files: cmux-tui/crates/cmux-ipc/fuzz/fuzz_targets/frame_reader.rs,
cmux-tui/crates/cmux-tui-core/fuzz/fuzz_targets/dispatch_structured.rs, cmux-tui/crates/cmux-ipc/build.rs (arbitrary
request generator from the schema), scripts/cmux-next/ipc-fuzz-fleet.sh. Change: cargo-fuzz targets for the reader +
fd queue, RequestHead + table + body decode, and schema-structured request sequences across streams on a test Mux;
8 h per target on idle minis; crashers become fixtures under spec/fixtures/ipc-frames/crashers with a regression
test. No CI job. Acceptance: targets build on the fleet; generator covers 100% of method ids (printed); 0 open
crashers or one task per crasher. Test: cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/ipc-fuzz-fleet.sh --hours 8'.

**p05-ipc-183 binary hot codec.** Files: cmux-tui/crates/cmux-ipc/build.rs (hot layouts),
app:CmuxNextWireGen/HotEmitter.swift, cmux-tui/spec/sdk-schema.json. Change: fixed LE layouts with a layout version
byte for resize-attached-view, set-client-sizing, scroll-surface, snapshot-request and the size-state,
scroll-changed, surface-resized and digest events (title-changed stays JSON); refused when api_revision differs.
Acceptance: golden bytes equal in Rust and Swift; 0 JSON parses for these on frames; api-compat-check covers the
layouts. Test: RUST(hot_codec); SWIFT(HotCodecTests).

**p05-ipc-190 kill -9 test.** Files: Tests/CmuxNextDaemonTests/IpcDaemonCrashTests.swift. Change: real binary, 10
flooding ring streams, kill -9. Acceptance: no crash; listen() to every READY <= 100 ms; correct screens; ring
unmaps after the last span. Test: cmux-ci run --class isolated --ref SHA --script 'scripts/ci/cmux-next-daemon-test-packages.sh IpcDaemonCrashTests'.

**p05-ipc-191 bad message and crash-loop breaker.** Files: core:server/line_connection.rs, LineTransport.swift,
Tests/CmuxNextDaemonTests/BadFrameTests.swift. Change: close on any BadMessage with a reason counter; 3 closes from one
daemon epoch in 60 s stop frames for that epoch: JSON lines, a log, a visible diagnostic and a DaemonWireStats
counter. Acceptance: 20 malformed fixtures per side each close with bad_message+1 and no crash; the breaker test
falls back after the third close and shows the diagnostic. Test: RUST(bad_message); SWIFT(BadFrameTests).

**p05-ipc-192 soak.** Files: scripts/cmux-next/ipc-soak.py. Change: STRESS, 10 floods, switches and splits through
the socket; samples ipc stats, slow_requests, RSS, hangs, stream-end reasons. Acceptance: report keys for IPC-12 and
IPC-14; runs through bench_launch.py. Test: BENCH(python3 scripts/cmux-next/ipc-soak.py --minutes 30 --flood 10 --stress).

**p05-ipc-193 proof and design updates.** Files: plans/cmux-next/app-daemon-connection-DESIGN.md,
plans/cmux-next/perf-lead.md, plans/cmux-next/threading-model.md. Change: before/after rows (IPC-2, 5, 7, 8, 9, 10,
11, 16); the threading rows; the design changes of this spec (page-relay connection, ring cursor, reply/event rule,
Unix socket vs Mach reason with 002's syscall numbers) with PL-conn. Acceptance: every row has host, sha, macOS,
Hz and command; `ipc-census.py --check` passes. Test: PY(python3 scripts/cmux-next/ipc-census.py --check).

**p05-ipc-194 build timing.** Files: plans/cmux-next/app-daemon-connection-DESIGN.md. Change: incremental build after
a leaf edit and after a one-field schema edit, before and after 025/027. Acceptance: rows with host, sha, seconds;
leaf edit < 30 s; schema-edit time and rebuilt target count recorded. Test: cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/build-timing.sh --leaf-edit --schema-edit'.
