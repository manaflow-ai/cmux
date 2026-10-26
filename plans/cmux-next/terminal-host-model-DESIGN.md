# Terminal host model: one holder for every PTY, one parser in the daemon

Status: decided 2026-10-23 (PL-daemon, perf lead batch 1); slices in section 6; process-model
phases A and B for the Chrome-parity program in section 8 (2026-10-26). Ask (Lawrence):
"one process per terminal ... the original rationale was to make it more resilient in case a
terminal process crashed, but maybe there's another way we can handle it safely?" Related:
[pty-holder.md](pty-holder.md) (frozen tiny holder, D1-D6), [holder-protocol-v1.md](holder-protocol-v1.md)
(one PTY per holder; superseded for terminals by section 4 here),
[ghostty-integration-DESIGN.md](ghostty-integration-DESIGN.md) G2/G3/G5/G8 (agreed with
PL-ghostty 2026-10-23), [speed-of-sound-DESIGN.md](speed-of-sound-DESIGN.md) sec. 3.4 (floor: 2
processes, daemon threads O(cores)).

## 1. Today (code at feat-cmux-next 62c427ab5bd, fleet numbers)

- One `cmux-tui __terminal-host` process per terminal: the whole 324k-line `cmux-tui` binary.
  RSS 10.7 MB, footprint 2.1-2.5 MB per host (new-terminal-100x, aws-m4pro-6). Heavy session
  (150 workspaces): 392 processes, 172 hosts, 3,300 threads, daemon 797 threads.
- Threads per terminal: host 7 + 2 per client (signals, exit, clipboard, parser, pty reader,
  child wait, client writer/reader); daemon 4 (`surface-N-frames`, `surface-N-host`,
  `surface-N-host-frames`, `terminal-host-reaper`) + 4-5 per attached app view.
- Three full VT parses per output byte (host `HostShared.term`, daemon mirror, app Ghostty) and
  three 10 MB scrollbacks. The host is "authoritative"; the daemon mirror seeds a replacement host.
- Resilience today: a host crash is survived because the daemon holds a custody dup of the PTY
  master (SCM_RIGHTS on every connection, `unix/pty_custody.rs`) and rehosts from its mirror
  (`surface/rehost.rs`); a daemon crash is survived because hosts keep running and are adopted.
  The shell only dies when every master fd closes. That, not the process per terminal, is what
  keeps shells alive.
- Create cost on the request path: host bootstrap + Launch round trip + record barrier, 4.3-4.9 ms
  per terminal (spans, aws-m4pro-6), more without a spare host.

## 2. Options

Numbers for 172 terminals (the heavy session). "Blast radius" = what a crash of one process
costs the user.

| Option | Processes cmux adds | Threads (terminal part) | Parses per byte | Holder/host crash | Daemon crash | Create on request path |
|---|---|---|---|---|---|---|
| A. Today: host per terminal | 172 | ~2,200 (9 host + 4 daemon each) | 3 | that terminal redraws (rehost from mirror) | all redraw from hosts | 4.5 ms (process + record barrier) |
| B. One process: daemon owns PTYs and parses | 0 | O(cores) | 2 | n/a | **every shell dies** (last master fd closes) | ~0.7 ms (posix_spawn) |
| C. Sharded hosts, 16 terminals each | 11 | ~11 x 9 + 4 x 172 | 3 | 16 terminals redraw | all redraw | ~4 ms |
| D. **One holder (no VT) + daemon parses + custody dups** | 1 | ~2 holder + O(cores) daemon | 2 | **no shell dies, no redraw**: the daemon still holds every master and its VT state; a new holder takes the fds back | no shell dies; all redraw from the holder's byte rings + last journal snapshot | ~1 ms (holder posix_spawn + one round trip) |
| E. Holder + VT worker pool (16 per worker) | 12 | ~12 x 3 + O(cores) | 2 | as D | control plane survives; 16 terminals redraw per worker crash | ~1 ms + a worker hop for every screen read, snapshot and OSC event |

Memory per terminal: A 2.3 MB host + 1.5 MB daemon mirror; D/E: the host's 2.3 MB goes (the
holder keeps a byte ring per terminal, resident only as filled, 1 MiB cap in memory, spill to its
log); the daemon mirror stays (it is the one parser). Heavy session: about 400 MB less, 171
processes and ~2,000 threads fewer.

## 3. Decision: D

- The thing that keeps shells alive is that some process holds the PTY master, not that each
  terminal has its own process. D keeps two holders of every master (the holder and the daemon),
  so a crash of either loses no shell; only both at once can, as today.
- The holder parses nothing, so the code that can crash on hostile output (the VT parser, Kitty
  graphics, OSC handling) runs in exactly one place outside the app: the daemon. pty-holder.md D2
  (Lawrence: "the daemon parses; the holder keeps only raw output") already decided this.
- E's isolation buys little: the app parses the same bytes with the same Ghostty, so an output
  that crashes the parser also crashes the app's surface; and E adds a hop to every screen read
  agents make. If telemetry ever shows daemon VT crashes, the daemon's parse can move into a
  worker later without touching the holder (the holder wire is the same). Revisited in
  section 8: D stays the default (phase A); E comes back behind a flag (phase B) because the
  Chrome-parity program removes the app's parse (task 241), which removes the reason above.
- Poison pill: a daemon that crashed while parsing would replay the same bytes on restart and
  crash again. No per-chunk disk write guards it; the holder counts, per terminal, daemon links
  that ended without DETACH while it streamed that terminal. A terminal whose stream ended that
  way twice within 10 s is restored from its prologue (the newest snapshot) without the ring
  tail (the daemon gets a GAP and cancels), so one bad stream never loops the daemon. Built
  (review 2): `Terminal::strikes` in `cmux-holder/src/holder.rs`; a daemon sends DETACH for
  each terminal at shutdown, so a clean exit is no strike.

## 4. Holder (crate `cmux-holder`, std + libc only)

- One process per install (bundle id + tag), started by the daemon on first use; `setsid`,
  ignores SIGHUP/SIGINT/SIGTERM except from launchd (pty-holder.md 5.6). Built (review 2): a
  SIGTERM whose sender is pid 1 (logout, shutdown) ends the holder; a holder with no terminal
  and no daemon link exits after 30 s and removes its socket, so an idle holder of an old
  build does not serve new daemons for ever. Still open: identity record and lease as
  holder-protocol-v1 sections 7-8, and handing a busy old-build holder's terminals to a new
  build (an ADOPT handoff).
- Children (review 2): every descriptor the holder inherited is close-on-exec from its first
  instruction, and each shell gets back the soft `RLIMIT_NOFILE` cmux started with
  (`CMUX_TUI_HOST_NOFILE_SOFT`, as a spawned terminal host). A frontend's shell starts through
  login(1) on macOS as on the hosted path; CLOSE and its SIGKILL go to the child's group and
  the PTY's foreground group (no process-table scan, pty-holder.md 4): an interactive shell in
  its own group under login(1) is the foreground group, so it ends with its tab and hangs up
  its own jobs.
- One kqueue: the daemon link socket, every PTY master (EVFILT_READ), every child
  (EVFILT_PROC NOTE_EXIT, then `waitpid` for the status: the holder is the shells' parent). No
  thread per terminal; no timers.
- Per terminal: id (u128), master fd, child pid/pgid, a byte ring (1 MiB) with absolute offsets,
  exit status once reaped.
- The ring is shared memory (wire v4, holder item 1, 2026-10-23): a `memfd` on Linux, an unlinked
  `shm_open` object on macOS, header `magic "CMHR" | layout | capacity | base | end` then the data
  (`cmux-holder/src/ring.rs`). The holder `read`s the PTY straight into it and publishes `end` after
  each read; SPAWNED, LISTED and ADOPT pass the segment as a second descriptor (`FLAG_RING`) and the
  daemon keeps a custody dup next to the master's. A holder that dies loses at most the one read
  whose end it had not published (before: up to 256 KiB of unsent ring plus 1 MiB of queued frames,
  and the next holder numbered the PTY's next byte as if they had arrived: a silent splice). The
  daemon never maps the segment; it hands it to the next holder, which continues the same ring.
  Wire v5 (review 2 of holder items 1-3): ring layout 2 (a published `oldest`) passes only between
  peers of v5 or later, so a v4 holder never gets a segment it cannot read; a v5 holder answers
  every ADOPT with ADOPTED (`oldest u64, end u64`, plus the segment it really writes: the one
  handed over, or a fresh one when that was bad or stale), and the daemon keeps exactly that
  segment as custody. ATTACH carries the offset the daemon parsed, so the credit after an adoption
  or a resume counts from there and the ring never runs more than the credit window plus
  `UNSENT_HIGH_WATER` (768 KiB) past what the daemon parsed.
- Wire: multiplexed holder-protocol frames, `magic "CMHX" | kind u16 | flags u16 | chan u32 |
  len u32 | payload` (chan = terminal slot). Kinds: HELLO/WELCOME (token, version), SPAWN (argv,
  env, cwd, size; reply SPAWNED with pid and the master fd by SCM_RIGHTS: the daemon's custody
  dup), ADOPT (fds by SCM_RIGHTS + ids + offsets: a new holder takes over after a holder crash),
  ATTACH from offset, DATA (offset, bytes), GAP, ACK (trim), WRITE, RESIZE, SIGNAL, CLOSE, EXIT
  (status, end offset), LIST (every terminal: id, pid, offsets, state), PING/PONG, ERROR.
- Input: the daemon writes keystrokes to its own master dup directly (one hop less than today);
  WRITE exists for a daemon that lost its dup. The holder leaves the master non-blocking (the flag
  is shared by every dup), so the daemon's writer waits for POLLOUT on WouldBlock.
- Link speed and fairness (review 2): each end asks for 512 KiB socket buffers (macOS gives
  8 KiB); a reader keeps a cursor and compacts once per `recvmsg`; a DATA frame is built
  straight from the ring. Each pump starts at the next terminal in turn and gives every
  terminal with output an equal share (at least 16 KiB), and frames up to 4 KiB go ahead of
  queued bulk output unless their own terminal has bulk queued (one terminal's frames never
  pass each other), so an echo does not wait behind other terminals' floods.
- CLOSE of a terminal that already ended but whose EXIT an attached daemon has not got yet
  only marks it closing: the holder forgets it after it sent the rest of the output and EXIT.
- Flow control (wire v2, review 1): ACK carries the offset the daemon parsed. The holder sends an
  attached terminal at most 512 KiB past its last ACK and stops reading a master that holds
  256 KiB unsent, so a flood blocks in the PTY as on a direct PTY: no byte is dropped while a
  daemon is attached and the daemon's queue per terminal stays bounded. A DATA offset past what
  the daemon has, or a GAP, cancels the parser's current sequence (CAN) instead of splicing.
- Handshake: a connection becomes the link only after a valid HELLO; a probe or a bad token never
  drops the attached daemon. The daemon it replaces gets ERROR SUPERSEDED and does not reconnect.

## 5. Daemon side

- One holder link thread (kqueue/poll on the holder socket) feeds the existing output path; the
  per-terminal `surface-N-host`, `-host-frames` and `terminal-host-reaper` threads go away, and
  the frame producer becomes one shared thread (pending work: a set of dirty surfaces).
- The daemon mirror is the authority (agreed with PL-ghostty): it answers DA/DSR, serves snapshots,
  and forwards raw bytes to attached views; G5 binary attach frames (`attach-binary-output-v1`,
  header `\xFFCO kind:u8 len:u32 offset:u64`, kinds 1 output, 2 grid marker, 3 JSON event, 4/5
  snapshot) replace base64 JSON; a resize sends a kind-2 marker, a snapshot only on a digest
  mismatch (G2).
- Restore after a daemon crash: LIST, then per terminal its last journal VT snapshot at offset N
  and ATTACH from N; GAP resets and replays from the oldest kept byte, then a same-size RESIZE
  nudges full-screen programs to redraw. Built (review 2, wire v3) without the journal: the
  daemon's reader hands the holder a SNAPSHOT (a VT replay of its parsed screen, at most
  128 KiB, at the exact offset the parser reached) once a burst of 64 KiB went idle or every
  2 MiB of a flood; the holder keeps the newest as the terminal's prologue, and a restarted
  daemon's ATTACH gets it first and the ring from its base. A prologue older than the ring is
  still sent (modes survive) and the daemon cancels before the tail; a re-attach from a ring
  that dropped bytes starts with CAN. Still open: the same-size RESIZE nudge.
- A surface's close (Cmd-W) runs under its runtime lock, so it never connects, starts a holder
  or re-adopts (review 2): without an open link the CLOSE waits for the next link and the
  daemon hangs up the shell's groups itself.
- Holder crash: the daemon still has every master and its parsed state; it starts a new holder
  and ADOPTs every fd. Output written while no holder reads waits in the kernel's PTY buffer (the
  shell blocks, nothing is lost). Exit statuses of shells whose parent died read
  `exit-unobserved`, as today's rehost.
- The replay race at a holder crash (holder item 1, built 2026-10-23): the daemon replays from its
  last fully parsed and confirmed offset, never from the holder's send offset. Its sink keeps each
  queued byte's holder offset (runs, so a seed, a prologue or a CAN takes none), a chunk the reader
  took stays pending until the reader confirms it right after `vt_write`, under the terminal lock
  (`HolderSink::confirm_parsed`), and ACKs carry that confirmed offset. The hand-off reads the
  screen replay and the pending bytes at one instant under the same lock (no drain wait; before:
  a 1 s wait for the queue, then a prologue that claimed `received` while the reader could still
  hold a taken chunk). ADOPT (v4) then carries `base` = confirmed, `resume` = received, the ring
  segment, and a prologue of the replay (the OSC 9;4 progress before the parser's pending sequence,
  which goes last) plus the seed the parser has not finished; the new holder sends this daemon the
  ring from `resume` (the bytes the dead holder read but never sent) and a restarted daemon the
  prologue and the ring from `base`. A terminal from an older holder (no ring) gets a segment the
  daemon makes (`ring::create_segment`) and a prologue of the replay plus every unparsed byte at
  `received`; a v3 holder gets that prologue without a segment. Residual: a control string larger
  than the parser's pending-sequence budget (a multi-MiB Kitty upload) open at the crash is not
  replayed (`vt_replay_resumes_stream` false). Test: `holder_terminals.rs`
  `a_holder_killed_holding_unparsed_output_or_mid_sequence_loses_no_byte` (red on the base: the
  screen stopped after one 512 KiB credit window and the rest of a 10,000-line flood never came).

## 6. Slices

1. `cmux-holder` crate and binary, its wire, and the crash-injection test (a test daemon spawns
   16 shells through a holder, SIGKILLs the holder, ADOPTs the fds into a new holder: every shell
   alive, input and output work, the test's VT screen equals the one before; then drops the daemon
   side and re-attaches from the ring: screen restored). Run on the fleet.
2. Daemon: new terminals on the holder behind `CMUX_TUI_TERMINAL_HOST_MODEL=holder` (default
   off), one link thread, custody dups, restore; the existing host path stays for old terminals.
   Built (2026-10-23): `holder_runtime/` (service, sink, terminal), `surface/holder_spawn.rs`,
   `mux/holder_adoption.rs`; `cmux-tui __holder` and `cmux-tui-host __holder` run the holder.
   A holder terminal runs on the daemon's local runtime (`PtyRuntime::Local` with its holder),
   so the daemon's parser is the only one outside the app. Test: `tests/holder_terminals.rs`
   (no host record; daemon SIGKILL and restart restores every screen from the ring; holder
   SIGKILL keeps every shell and screen; a second restart re-attaches from the new holder).
   Slice 3 (2026-10-23): the reopen seed reaches the parser first; a holder that cannot restart
   ends its terminals lost (respawn path); on ADOPT the daemon hands the new holder a VT replay
   of each screen (its prologue, at most 768 KiB), which the holder sends first to a restarted
   daemon, so a restart after a holder crash restores the whole screen. Fleet A/B (aws-m4pro-7,
   send to reply p50/p95, hosts -> holder): new-tab 31.9/56.9 -> 13.2/55.6 ms, new-workspace
   33.6/52.3 -> 14.1/15.1 ms, unsized split 25.7/47.8 -> 13.5/14.9 ms; 0 host processes.
   Still open: reader, wait and frame threads per terminal (the shared frame producer lands
   from the daemon-speed workstream); default on (slice 4).
   Holder items 1-3 (2026-10-23): wire v4 shared rings and the confirmed-offset hand-off (section
   5); the standalone frozen `cmux-holder` binary, bundled beside `bin/cmux` and started from its
   content-addressed copy, adopting older holders by wire version (pty-holder.md 2); first-text
   timing in holder mode (`debug_spans::output_marks`, new-terminal-100x `host_model=`).
3. G5 binary attach frames and the in-band resize marker (with PL-ghostty's decode).
4. Default on; old `__terminal-host` processes keep their client until none is left (pty-holder 2.2).

## 7. Durability of replies (decided 2026-10-23, perf lead)

No daemon reply waits for the disk. Registry commits (and the conversation store's and chief
registry's) run `synchronous=NORMAL`: a commit is in the WAL, in the kernel's page cache, when it
returns, and a crash, kill or update of the daemon keeps it. One syncer thread per database runs
the WAL checkpoints off every lock (SQLite syncs the WAL before each), and flushes the drive cache
(F_FULLFSYNC) once at close (`workspace_registry/wal_durability.rs`). These are SQLite's own
`synchronous=NORMAL` WAL rules, with the checkpoint moved off the request. Trade-off: a power loss
or kernel panic can take back the tail of replies since the last checkpoint that the kernel had not
yet written back (a tail, never out of order). The same loss ends every shell, host and holder, so
the terminals those replies described are gone anyway; a workspace rename or layout change made in
that tail is lost. A sync per reply was measured and rejected: the next request's WAL writes
waited for it (same fleet mini, new browser tab 4.2 ms p50 without, 22-25 ms with F_FULLFSYNC,
about 11 ms with F_BARRIERFSYNC). Before: each commit F_FULLFSYNCed inside the registry lock (about
4.5 ms on a fleet M4 Pro, 20 ms on a busy Apple SSD), 1-3 per create or close reply, and every
request that needed the lock waited behind it.

## 8. Process model phases for the Chrome-parity program (2026-10-26)

Spec: [chrome-parity/p01-process.md](chrome-parity/p01-process.md) sections 3.5 and 7
(tasks 120-142, 207-211, 241). This section records what that program decided about the VT
parse, and why. Section 3 still holds: the holder parses nothing and keeps only raw output
(pty-holder.md D2, Lawrence 2026-10-23: "the daemon parses; the holder keeps only raw output").

### 8.1 Phase A: decision D is the default

- The daemon parses every holder terminal on a small pool of threads (`vt_pool`, task 120), not
  on one `surface-{id}-reader` thread per terminal. Two groups: visible terminals at
  USER_INITIATED, hidden ones at UTILITY (task 139). A parse task takes at most 64 KiB or 1 ms,
  then goes back to the end of its queue, so a hidden flood delays a visible chunk by at most
  one slice. This is Chrome's priority rule (what the person sees first, background throttled)
  applied to output.
- Exits come from holder EXIT frames after the parse reaches the exit's end offset (task 121);
  one `child-exit` watcher serves every other daemon child (task 207).
- The holder link thread pushes DATA into per-shard bounded queues; credit is today's ACK of
  the confirmed parsed offset (section 5), so the replay race stays closed.
- Phase A is the default because it is decision D with fewer threads: 2 holders of every master
  (holder and daemon), 1 parser outside the app, no extra hop on a screen read.

### 8.2 Phase B: option E behind `CMUX_TUI_VT_WORKERS=process`

- Sandboxed `cmux-vt-worker` processes parse shards of terminals (task 133). The daemon brokers
  them (task 134): spawn, shard, relay ring advances, restart, reseed from the holder prologue
  and ring tail, and the poison-pill strike rule of section 3 per shard.
- Screens and terminal modes go to seqlock pages the daemon maps read-only (tasks 135, 209), so
  a screen read, a snapshot and key encoding never wait for a worker hop. This answers the
  "worker hop on every screen read" cost that section 3 held against E.
- Worker output is untrusted (task 141): every event and page field is bounds-checked; one bad
  frame ends the worker with reason `bad_message` and reseeds it, as Chrome's
  `bad_message::ReceivedBadMessage` ends a renderer
  (`content/browser/bad_message.cc`).
- Shards are by trust class (task 142): local, SSH/remote/cloud, agent-fetched. A worker
  never holds terminals of two classes, so hostile output from a remote host cannot reach a
  local terminal's state.
- Off by default; on in DEV only when its done checks pass (task 137; p01 done checks 13, 15,
  16, 17). If the classification of daemon VT readers (task 208) finds more than 20 `async`
  rows on request paths, phase B stays off and only phase A ships.

### 8.3 Why phase B exists: Chrome's Rule of 2

Chromium `docs/security/rule-of-2.md`: code may have at most 2 of untrustworthy input, an
unsafe language, and high privilege. Terminal output is untrusted (any program, any remote
host, any file `cat` prints). Ghostty's VT parser and the Kitty graphics decoder are unsafe
code (Zig and C libraries, with no memory-safety guarantee). The daemon has high privilege: every session,
every PTY master, the journal, agent credentials. In phase A the daemon has all 3. In phase B
the worker has 2 (untrusted input, unsafe code) and loses the third: its Seatbelt profile
(macOS) or seccomp + landlock (Linux, task 211) denies file opens, fork, exec, network and
Mach lookups after setup. This is what Chrome does with its Data Decoder Service: parsers of
untrusted input run in a sandboxed utility process and return a well-formed IPC reply
(`services/data_decoder/`).

Section 3 rejected E because the app parsed the same bytes with the same Ghostty, so the
isolation bought nothing. That reason holds only while the app parses bytes; see 8.4.

### 8.4 The app-side gap until task 241

- Today the app's Ghostty surface parses every output byte again
  (`GHOSTTY_SURFACE_IO_MANUAL_MIRROR`, `CmuxNextTerminal/TerminalSession.swift`). The app has
  every TCC grant and the keychain: it is the highest-privilege process cmux has. So the app
  breaks the Rule of 2 whatever phase the daemon runs, and a VT or Kitty bug that a hostile
  output reaches can end cmux (p01 risk 9).
- Phase B does not close this gap and nothing in this program claims it does. It removes the
  daemon's exposure only.
- Task 241 is the end state: the app draws from the workers' published screen pages and damage
  lists (cells, styles, cursor, images by reference) and parses no terminal bytes. Then VT
  parses per byte drop to 1 and a crash corpus ends one shard while the app runs. 241 starts as
  a spike; if it cannot be built inside the 72 h, its measured gap and plan go here.

### 8.5 Why the holder-to-app ring was dropped

Old tasks 130 and 132 mapped the holder's ring (section 4) into the app so output could skip
the daemon. They are dropped (p01 section 9):

- They conflict with D3's daemon output ring and its offsets (task 126): the app would read two
  rings with two offset spaces for one terminal.
- They need holder wire v5 changes and CUT/CAN correction frames to the app. The holder outlives
  app and daemon updates, so every holder wire change is a compatibility cost for years;
  this program adds no holder wire change, so `cmux-holder-v3` adoption is unchanged.
- The app would still parse raw bytes, which is the gap 8.4 exists to close. Task 241 (the app
  draws screens, not bytes) is the better end state.
- The app reads D3's daemon ring instead, copy then validate (task 131: one memcpy, re-read the
  oldest offset, snapshot request on a lap).

Reopen 130/132 only if `trace.py` shows the daemon hop costs more than 1 ms p99 on echo after
D3 lands.

### 8.6 Status and numbers

Numbers for these phases go to [perf-lead.md](perf-lead.md) section 6 (one row per p01 done
check). On perf/chrome-parity at 8d533d02c1a none of the phase A or B code has landed:
`vt_pool.rs`, `cmux-vt-worker` and the D3 ring are absent; the holder is still off by default
(`CMUX_TUI_TERMINAL_HOST_MODEL=holder`, `holder_runtime.rs`). Tasks 100, 137 and 241, which
this record depends on, are not on the branch yet.
