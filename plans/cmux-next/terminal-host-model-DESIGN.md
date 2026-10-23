# Terminal host model: one holder for every PTY, one parser in the daemon

Status: decided 2026-10-23 (PL-daemon, perf lead batch 1); slices in section 6. Ask (Lawrence):
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
  worker later without touching the holder (the holder wire is the same).
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
  login(1) on macOS as on the hosted path; CLOSE and its SIGKILL go to every process group on
  the PTY (the child's, the foreground group, and on macOS each process whose controlling
  terminal it is), so a shell in its own group under login(1) ends with its tab.
- One kqueue: the daemon link socket, every PTY master (EVFILT_READ), every child
  (EVFILT_PROC NOTE_EXIT, then `waitpid` for the status: the holder is the shells' parent). No
  thread per terminal; no timers.
- Per terminal: id (u128), master fd, child pid/pgid, a byte ring (1 MiB) with absolute offsets,
  exit status once reaped.
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
3. G5 binary attach frames and the in-band resize marker (with PL-ghostty's decode).
4. Default on; old `__terminal-host` processes keep their client until none is left (pty-holder 2.2).

## 7. Durability of replies (decided 2026-10-23, perf lead)

Lands with PL-daemon batch 1 (branch `pl-daemon-wip`, the daemon request speed workstream). No daemon reply waits for the disk. Registry commits run `synchronous=NORMAL`: a commit is in the
WAL, in the kernel's page cache, when it returns, and a crash, kill or update of the daemon keeps
it. One syncer thread F_FULLFSYNCs the WAL for every commit since its last flush, off every lock
(`workspace_registry/wal_durability.rs`). Trade-off: a power loss or kernel panic within that one
flush (about 5 ms) can take back a reply the client already has; the same loss ends every shell,
host and holder, so the terminal the reply described is gone anyway, and a workspace rename or
layout change made in those milliseconds is lost. Before: each commit F_FULLFSYNCed inside the
registry lock (about 4.5 ms on a fleet M4 Pro, 20 ms on a busy Apple SSD), 1-3 per create or close
reply, and every request that needed the lock waited behind it (60-80 ms p95 on every op).
