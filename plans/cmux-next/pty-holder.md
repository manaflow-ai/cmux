# Frozen terminal and agent holders, no process scanning, perfect restore

Epic: cx-t2sqm. Lane: ptyh-noscan. Status: slice 1 (guard) landed 3b015e45086f; decisions D1-D5 taken (section 8).

Order (2026-10-14): the code and process that holds a PTY is as small as
possible and is assumed to never be updated. Quitting or updating cmux never
stops a terminal or an agent. ACP agents get the same promise. Restore after
quit, update or crash is perfect. No process scanning, ever.

## 1. What runs today

### 1.1 Terminal host (`cmux-tui __terminal-host`)

- Spawned by the daemon (`terminal_host_runtime/unix/standby.rs`, a spare is
  kept ready). argv: `cmux-tui __terminal-host --bootstrap-stdio --owner
  <bundle>:<tag>@<daemon pid>`; a replacement adds `--adopt-pty-fd 3`.
- Binary: the WHOLE `cmux-tui` executable (macOS: a content-addressed copy
  under `~/Library/Application Support/cmux-tui/host-exe/<sha256>/`, pinned by
  a shared flock; Linux: `/proc/self/exe`; Windows: a 40-line `cmux-tui-host`
  shim over the same library). It links ghostty-vt, rusqlite, tokio,
  tungstenite and the rest of cmux-tui-core (~324k lines). The host path is
  ~13.8k lines of `terminal_host_runtime/**` + 2.5k protocol + 1.6k cmux-pty.
- Holds: PTY master + child (process group), the authoritative ghostty-vt
  parser (`HostShared.term`), an 8 MiB / 4096-frame raw output ring for smart
  renderers, replay snapshots (grid, scrollback, graphics-protocol images, colors, cwd,
  progress), viewer-size arbitration, a capability store, OSC 7501 program
  status. Disk: record JSON, `.exit` sidecar (fsynced before Exit),
  `.signals` breadcrumb, a flocked lease file.
- Wire: `terminal_host_protocol.rs`, 32-byte LE header, magic `CMTH`, 16 MiB
  cap, `PROTOCOL_VERSION = 4`, `HOST_RECORD_VERSION = 4`. ~40 message kinds
  (Bootstrap/Ready/Hello, Snapshot, Output, Resized, Colors, Title, Pwd, Bell,
  Exit, ResyncRequired, Launch, LaunchAdopt, PtyCustody, Clipboard*, Input,
  Paste, ViewerSize, Terminate, MintCapability...). Hello flags are gated by
  `supports_*` booleans in the record because old hosts reject unknown bits.
  Daemon retries versions 4..1; no common version = "unadoptable" record,
  kept visible, never killed.
- Discovery: records under `<state>/terminal-hosts-<session token>/<id>.json`,
  written by the host before Ready; sockets `/tmp/cmux-th-<uid>/<id>.sock`;
  liveness = flock on the lease file (Live/Dead/Indeterminate). No process
  scan on macOS/Linux desktop for discovery.
- Kill triggers: normal daemon shutdown and version handoff keep hosts.
  `shutdown-daemon --end-terminals` ends them (test teardown). **A host with
  no client stream for 10 min (`HOST_ORPHAN_GRACE`, cx-hostorphan) ends its
  terminal**: after a quit longer than 10 min, the terminals are gone. This
  breaks the promise (decision D1). Cloud park (`cmux-host/src/linux/procs.rs`)
  sweeps `/proc` and SIGKILLs every `__terminal-host` of the user, older
  builds included.
- State only in the daemon: workspace registry/journal (layout, tabs,
  bindings, exit receipts), session shutdown marker, agent/hook state, and a
  second VT replica per surface (used to seed a replacement host).
- Security: dir 0700 + owner checks, socket 0600, records 0600 O_NOFOLLOW,
  32-byte owner token over the bootstrap pipe and in the record, one-use
  renderer tokens. No peer-credential check. No per-build socket isolation:
  every build and tag of a user shares `/tmp/cmux-th-<uid>`.

### 1.2 Agent host (`acpmux __agent-host` / `cmux acp __agent-host`)

- Spawned by the acpmux daemon with `setsid`, bootstrap `SpawnSpec` over
  stdin (argv, full env, cwd, translator, codex bridge, socket, buffer cap).
  Binary: the WHOLE acpmux/cmux multicall. ~2.7k lines in `agent_host/**`,
  but it links tokio, serde, the Claude stdio translator and the in-process
  Codex bridge (`cmux_codex_acp` / `codex_app_server`).
- Holds: the harness process group and its stdio pipes, an in-memory replay
  log numbered by `h` kept until `Ack` (64 MiB back-pressure cap), `acked_h`,
  `max_out_id`, exit code, translator state (Claude session id, modes,
  config options). Nothing persisted by the host.
- Wire `agent-host/1`: u32 BE length + JSON tagged by `t`, 64 MiB cap.
  `PROTOCOL_MIN = PROTOCOL_MAX = RECORD_VERSION = 1`. Frames: Hello, Resume,
  Line, Ack, Terminate, Detach, Query / HostHello, Incompatible, Entry, DetachAck,
  TerminateAck, Superseded, QueryReply. No capability set; builds carried but
  never compared. No common version = unadoptable, left running.
- Discovery: `<acpmux home>/hosts/<sid>.json` (0600), `<sid>.<nonce>.live`
  flock, `<sid>.sock`; reattach by `Resume{after}` from the session log's
  last `hostSeq`, then `recover_work` rebuilds open turns, prompts and
  permission requests. No `session/load` for a live host.
- Kill triggers: daemon restart detaches (hosts live). Quit Everything ends
  them. The idle reaper stops a harness with no client, no turn, no pending
  permission (it resumes later with `session/load`). Pooled hosts exit after
  10 min idle or above the 1 GB tree RSS cap (measured with `ps`).
- Isolation: per acpmux home (tags get their own home); NIGHTLY and Release
  share `~/.acpmux`.

## 2. Target: one tiny frozen holder

One small executable, `cmux-holder`, in its own crate with only `std` and
`libc` (Windows: `windows-sys`). No tokio, no serde, no ghostty-vt, no
sqlite, no translator. Target size: under 3k lines. Two modes:

- `--pty`: owns the PTY master and the child process group.
- `--pipes`: owns an agent harness's stdin/stdout/stderr and its group.

It keeps an output log with absolute byte offsets: an in-memory ring (default
8 MiB) spilling to an append-only file beside its record (capped, default
64 MiB, oldest segment dropped). Everything else (VT parsing, terminal state,
snapshots, renderers, journal, UI, ACP translation, Codex bridge, agent
logic) lives in the replaceable daemon/app. The Codex bridge and the Claude
translator become harness-side processes (the holder's child), so an agent
holder never needs them in-process.

The holder binary is distributed content-addressed (as `host-exe` does
today); old holders keep running their own copy, pinned by its lock. A cmux
update makes a new copy even when the holder code did not change: release and
nightly strip the holder (`strip-release-bundle.sh`) and re-sign it with a
secure timestamp (`sign-cmux-bundle-helpers.sh`), so its SHA-256 changes in
every signed build (review 1 of holder items 1-3). Only unsigned builds of
unchanged code reuse a copy. If reuse across releases matters later, name the
copy by a hash of the unsigned code (for example the Mach-O `LC_UUID`).

Built (terminals, holder item 2, 2026-10-23): crate `cmux-holder`, bin
`cmux-holder`, std and libc only, about 3.6k lines with its unit tests. It ships as
`Contents/Resources/bin/cmux-holder` beside `bin/cmux` (artifact
`cmux-tui-holder-<target>`, built in its own cargo invocation, signed like
every helper by `sign-cmux-bundle-helpers.sh`, notices mapped). The daemon
starts every holder from a verified content-addressed copy of it under
`~/Library/Application Support/cmux-tui/host-exe/<sha256>/cmux-holder`
(`host_exe::holder_executable`), named by the holder file's own hash; the
binary carries no build identity, so an unsigned build whose holder code did
not change reuses the copy (a signed build's re-signed holder has a new hash). `cmux-holder --version` prints `cmux-holder wire MIN-MAX`; a daemon
starts only a holder whose range it speaks, else the holder built into
`cmux-tui-host` (`__holder`). A running holder holds its copy's
`in-use.lock` shared for its whole life. An update keeps every holder: the
socket is derived from the session's host root, which an update keeps, and
the new daemon adopts the running (older) holder by the lower wire version
(test: `holder_terminals.rs`
`a_new_daemon_adopts_an_older_holder_by_its_wire_version` against the
frozen version 3 fixture `cmux-holder-v3`). The terminal wire is
`magic "CMHX"` (terminal-host-model-DESIGN.md section 4), versions 1-4; the
`CMHL` v1 below is the earlier draft and is superseded for terminals.

### 2.1 Holder wire protocol v1 (frozen)

Full spec (frame layouts, kind values, error codes, corpus):
`plans/cmux-next/holder-protocol-v1.md`. Summary:

Framing: `magic "CMHL" u32 | kind u16 | flags u16 | len u32 | payload`. Little
endian. Max payload 1 MiB. Payloads are fixed binary structs plus byte
strings; no JSON in the holder.

| Kind | Dir | Meaning |
| --- | --- | --- |
| HELLO | d->h | versions min/max, capability bits wanted, owner token |
| WELCOME | h->d | chosen version, capability bits granted, identity record bytes |
| ATTACH | d->h | `from_offset`; the holder streams DATA from there (or GAP if dropped). A terminal the daemon SPAWNed or ADOPTed holds at most 256 KiB unsent (`UNSENT_HIGH_WATER`) until its ATTACH, DETACH or the end of the link: the daemon sends SPAWN and ATTACH as two writes, and a holder that read freely between them could lose the terminal's first output to the ring. A client that SPAWNs and never ATTACHes blocks its shell at 256 KiB; the daemon always ATTACHes. |
| DATA | h->d | `offset`, bytes |
| GAP | h->d | `requested`, `oldest_available` (log rolled past it) |
| DETACH | d->h | stop streaming; the holder keeps running |
| WRITE | d->h | bytes to the PTY / harness stdin |
| RESIZE | d->h | cols, rows, px width, px height (pty mode) |
| SIGNAL | d->h | signal number, target: group or leader |
| ACK | d->h | offset the daemon has durably consumed (log may trim before it) |
| EXIT | h->d | wait status, end offset, time; also written to `<id>.exit` |
| CLOSE | d->h | end the child: SIGHUP/SIGTERM, then SIGKILL after `grace_ms` |
| PING/PONG | both | liveness of the link only |
| ERROR | h->d | code (UNKNOWN_KIND, BAD_TOKEN, ...) for a request; link stays up except after BAD_TOKEN / NO_COMMON_VERSION |

Rules that keep it frozen:
- A holder answers an unknown kind with ERROR UNKNOWN_KIND and keeps the link.
- New features are optional capability bits. A daemon must work with a
  holder that grants none of them, forever. Bits are never reused.
- The daemon speaks every version >= 1 it has ever shipped; a holder never
  needs to speak a newer one. The conformance corpus (recorded transcripts of
  every v1 exchange) runs in CI against the current daemon client and a
  holder built from the oldest supported holder commit.
- Identity record and exit record formats are versioned and only grow
  (new fields are optional; readers ignore unknown fields).

### 2.2 Migration from today's hosts

Today's `__terminal-host` (protocol 4) keeps working: the daemon keeps its
client for v1..v4 hosts until no live host of that kind remains in telemetry
for one release cycle. New terminals use `cmux-holder` once it lands; the VT
parser and smart-renderer ring move to the daemon (the daemon already runs a
replica). Agent hosts move the same way: new agents start under
`cmux-holder --pipes`, old `agent-host/1` hosts keep their client.

## 3. Discovery and restore without scanning

- At spawn the holder writes an identity record (atomic, 0600, O_NOFOLLOW):
  schema, id, mode, install (12-hex hash of bundle id + tag), session, cwd, argv,
  start time, protocol min/max, capability bits, socket path, lease nonce.
  The record has no pid fields: nothing finds or signals a holder by pid.
- Today (cx-t2sqm.13 landed): host records live in `<state>/terminal-hosts-<session token>/` (one per build, since each build has its own app session). Records may name a socket in the per-install directory `/tmp/cmux-th-<uid>/<session token>/` or the legacy flat one; new hosts still bind flat so a rollback to an older build never strands a terminal, and a later build switches the bind (cx-t2sqm.18). Target for `cmux-holder`:
- Records and sockets live in a per-install runtime directory (0700):
  `<runtime>/cmux/holders/<install id>/`, where the install id is a short
  hash (12 hex) of BuildIdentity's stable part (bundle id + tag), NOT the
  version. `<runtime>` is `$XDG_RUNTIME_DIR` on Linux and
  `/tmp/cmux-<uid>` on macOS (short, so a socket path stays under the
  104-byte `sun_path` limit; records may live in Application Support with
  the socket path inside them). An update of
  NIGHTLY finds NIGHTLY's holders; a DEV tag never sees them. (Per-version
  directories would make an update lose every terminal.)
- Liveness = flock probe on the lease file + socket connect. Death = connect
  refused + lease free, or an `<id>.exit` record. Never ps, proc_listpids,
  sysctl, libproc, `/proc` walks or pid probing.
- Restore: the new daemon lists the registry directory, connects to each
  socket, HELLOs, reads WELCOME's identity, loads its last journaled terminal
  snapshot (state at offset N), sends ATTACH from N, and replays DATA through
  its VT. On GAP (log rolled past N) it resets the terminal, replays from the
  oldest offset, and nudges a redraw with a same-size RESIZE; it records the
  loss. Agents: the daemon replays harness output from its last ACKed offset,
  then rebuilds open turns from its session log (today's `recover_work`).
- The daemon snapshots each terminal's VT state with its offset into the
  journal on a bounded schedule driven by output volume (not a timer poll),
  and always on clean shutdown/handoff. ACK trims the holder log only up to
  the newest durable snapshot offset.

## 4. No process scanning

Guard: `scripts/cmux-next/check-no-process-scan.py` (cmux-next checks job,
test `scripts/cmux-next/tests/check-no-process-scan.test.sh`). It fails on any
new enumeration call or foreign-process read in product code and ratchets the
baseline (`scripts/cmux-next/process-scan-baseline.tsv`) down only.

Audit (2026-10-14, 103 lines in 36 files):

| Site | What it does | Plan |
| --- | --- | --- |
| acpmux `adopt_live.rs` | `ps -axww` to find an OpenCode outside acpmux by argv (Claude Code and Codex now use their own holder records: the session registry by pid and start time, the thread writer lock) | remove: OpenCode holder record (cx-t2sqm.2) |
| acpmux `agent_host/tree.rs` | `ps` descendants to end setsid escapees | remove: holder-owned group; Linux cgroup/pidfd; Windows job (cx-t2sqm.3) |
| acpmux `hub/pool/reaper.rs` | `ps -A` tree RSS for the pool cap | remove: holder-reported rusage of its group, or drop the cap (cx-t2sqm.3) |
| terminal host `session_cleanup.rs`, `host_scope.rs` | `/proc` walk + `ps -axo` for session members, cgroup reads | remove: signal the session/group the holder owns (cx-t2sqm.4) |
| `cmux-tui-platform/platform.rs` | foreground process name and cwd via `proc_pidpath`, `PROC_PIDVNODEPATHINFO`, `/proc/<pid>/*` | remove: OSC 7 cwd + OSC 7501 / shell integration command (cx-t2sqm.5) |
| `process_resources.rs`, `resource_router/content.rs` | process tree walk for terminal-resources | remove: holder rusage, Linux cgroup, Windows job list (cx-t2sqm.6, D3) |
| `unix_process_scope.rs` | hook cleanup tracker: `proc_listpids(ALL)` at a fixed rate | remove: the seccomp/sandbox fence + group kill already bound hooks (cx-t2sqm.7) |
| `cmux-tui-hook` `ancestor_route.rs`, `tmux_route.rs` | walks ancestor argv/env to route a hook | remove: `CMUX_*` env routing only (cx-t2sqm.8) |
| `windows_processes.rs` | Toolhelp32 snapshot for tree/foreground | remove: Job Object process list (cx-t2sqm.9) |
| `ghostty_helper.rs`, `machine_update/apply.rs`, `cmux-host` linux procs/team_ssh, remote-browser `smoke.rs` | ps tables, `/proc/<pid>/exe`, Cloud park sweep | remove (cx-t2sqm.10) |
| Swift `ProcessUsage.swift`, `AcpmuxServerPeer.swift` (UID socket sweep), `ChiefHostStop`, `AcpmuxVersionHandoff` | usage diagnostics, peer lookup by port, binary check before stop | remove (cx-t2sqm.11) |
| `adopted_child.rs` | one held child's zombie state | keep |
| peer checks (`peer_process.rs`, `UnixSocketPeer`, `ComputerUseHelperV2`, `AgentPanePersonInput`, `PeerProcess`) | identity of the one process on a connected socket | keep (authentication, not discovery) |
| `ControlPeerAncestry.swift`, CUA helper `PeerInspector.swift` | authorize a peer by walking its ancestors | remove (cx-t2sqm.11, D5) |
| `SystemProcessLineage.swift` (Task Manager Kill Process, added 2026-10-19) | authorizes ending a named pid by walking its ancestors to the app or a daemon and reading executable paths | remove (cx-t2sqm.11, D5): end only pids the Task Manager's own sample listed |
| CEF `ChromiumHelperProcess`, `CEFChildProcessMonitor` | this app's own Chromium children | keep |
| `process_identity.rs` | names the sender of a received signal in a log | keep |
| browser-host `egress_*` | security guard: who holds a loopback listener (`proc_listpids(UID)`, per loopback connection) | keep until D4 |

Agent detection is hooks and OSC 7501 only: a harness reports itself; cmux
never infers an agent from a process name, argv, foreground group or tree.

## 5. Quit, update, restart

- App quit, app update, daemon crash, daemon version handoff and the
  "Restart cmux-tui" button never end a holder. They DETACH (or just drop the
  link). Only an explicit user close (tab close with confirmation, Quit and
  End Terminals, `close-terminal`) sends CLOSE.
- No orphan timer in normal installs (D1). Leaks are prevented by ownership,
  not timers: every holder has a record in its install's registry, the app
  shows holders with no placement in a "Running in background" list, and the
  user (or an explicit setting) ends them.
- Tagged DEV builds and tests may set an orphan grace (env, as today) so
  agents' test runs do not leave terminals for days (cx-h7m67).
- Landed (cx-t2sqm.16): hosts of normal installs have no orphan grace; the
  host records `orphan_grace_secs`. Transition limit: hosts already running
  from an older build keep their built-in 10 min timer; they survive an
  update only when the new daemon adopts them within 10 min (the app
  restarts the daemon at once, so this holds for a normal update, not for a
  quit longer than 10 min before the update).
- Still open: a plain SIGTERM from any sender ends an orphaned host after
  2 s (`host_signals.rs`, `HOST_SIGTERM_ORPHAN_MIN`), so a cleanup script or
  `pkill` can end terminals. Next slice: honor only PID 1 (system shutdown)
  and an explicit CLOSE.

## 6. Security

- Registry dir 0700 owned by the uid; records/sockets 0600; O_NOFOLLOW,
  single-link checks (as today).
- The holder checks the peer uid (`getpeereid` / `SO_PEERCRED`) equals its
  own before HELLO, then the owner token (constant time). A wrong token gets
  ERROR BAD_TOKEN and the link is closed.
- Threat model (D6, Lawrence 2026-10-14): the holder protects against other
  users only (socket peer uid + owner token). Any process of the same uid,
  including an agent in another terminal, is trusted like a shell of that
  user; there is no code-identity check. The owner token stays out of the
  registry (the daemon keeps it in its own store) so a stale record never
  hands it out.
- Per-install directories keep DEV tags, NIGHTLY and Release apart; an
  install only lists its own directory. Cross-install adoption is an explicit
  user action (cx-14hn5), never automatic.

## 7. Slices

1. Audit + NO-PROCESS-SCAN guard + this design (landed, cx-t2sqm.1).
2. Holder protocol v1 spec file + conformance corpus; behavior test at the
   socket: spawn a host, end the daemon, start a daemon of another version,
   reattach, input/output continuity (cx-t2sqm.12, cx-t2sqm.14). Terminals
   already have this test (`terminal_host_recovery/upgrade.rs`, run by the
   cmux-tui.yml step "Previous release upgrade adoption" against the pinned
   release daemon); agent hosts have none yet.
3. Per-install registry directory + identity records; reattach by registry
   and connect only (cx-t2sqm.13).
4. Remove scan sites, one bead each (cx-t2sqm.2 .. .11).
5. `cmux-holder` crate and binary; move VT and renderer ring to the daemon
   (cx-t2sqm.15).

## 8. Decisions (decided 2026-10-14)

- D1 (Lawrence): no orphan timer in normal installs (NIGHTLY, release, RC,
  standalone release cmux-tui); a terminal lives until the user closes it.
  Tagged DEV and staging builds, debug builds and tests keep the 10 min
  grace. The host records its grace in `orphan_grace_secs`.
- D2 (Lawrence): the daemon parses. The holder keeps only raw output with a
  capped on-disk log.
- D3 (chief): macOS CPU/memory per terminal = one total for the terminal's
  process group; a full process tree only on Linux (cgroup) and Windows
  (job object).
- D4 (chief): the browser egress guard becomes an allow-list of loopback
  ports cmux opened; every other loopback port is refused. No process list.
- D5 (chief): peer checks that walk parent processes (control socket,
  computer-use helper) become a capability token the app gives its
  children.
- D6 (Lawrence): no code-identity check in the holder; it protects only
  against other users (socket peer uid + owner token).
- Pipe mode uses one shared offset space; the holder drops the oldest output
  and never blocks the child (chief, confirmed 2026-10-14).
