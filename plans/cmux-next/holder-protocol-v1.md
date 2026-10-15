# Holder wire protocol v1 (frozen)

Epic cx-t2sqm, bead cx-t2sqm.12. Design: `plans/cmux-next/pty-holder.md`
section 2. Status: spec. The recorded compatibility corpus and its runner
land with the `cmux-holder` crate (cx-t2sqm.15); this file is their source.

A holder is a small process that owns one PTY (`--pty`) or one agent
harness's pipes (`--pipes`) and an output log. Daemons of every later
version speak this protocol to every v1 holder, forever. A holder is never
updated.

## 1. Spawn

The daemon execs `cmux-holder --pty|--pipes --bootstrap-fd 3` with an empty
environment. Fd 3 is a pipe that carries one bootstrap struct (same framing
as section 3, kind 0 BOOTSTRAP, daemon to holder only):
`token raw[32], registry_dir string, socket_dir string, install string,
session string, argv string-list, env string-list ("K=V"), cwd string,
cols u16, rows u16, px_w u16, px_h u16, ring_bytes u32, log_bytes u64,
orphan_grace_secs u32 (0 = none)`.

The holder then, in this order:
1. calls `setsid()` and leaves the daemon's cgroup / launchd job / Job Object
   (a stop of the daemon's unit must not stop it); on Linux calls
   `prctl(PR_SET_DUMPABLE, 0)`;
2. takes the exclusive lease (section 8);
3. binds its socket;
4. spawns the child (pty: on a new PTY of the given size, as session leader
   with the PTY as controlling terminal; pipes: three pipes, own process
   group), with exactly `env` and `cwd`;
5. atomically renames its identity record into place (section 7);
6. writes one byte `0x01` to fd 3 and closes it. If step 4 fails it writes
   `0x02`, then `errno i32`, writes no record and exits.

## 2. Transport

- One Unix domain stream socket per holder (Windows: one named pipe), path in
  the holder's identity record (section 7). Socket mode 0600, directory 0700.
- Before reading a frame the holder checks the peer uid
  (`getpeereid` / `SO_PEERCRED`; Windows: the pipe client's user SID) equals
  its own. A different uid: close without a reply.
- At most 8 links that have not sent HELLO; each must send HELLO within 5 s
  or is closed. A frame other than HELLO before HELLO, or a second HELLO on
  one link, closes that link.
- At most one controller at a time (section 5.2); observers (HELLO with the
  observer flag) may read WELCOME and close.

## 3. Framing

Every frame, both directions:

| Offset | Size | Field | Notes |
| --- | --- | --- | --- |
| 0 | 4 | magic | ASCII `CMHL` |
| 4 | 2 | kind | u16 little endian (section 4) |
| 6 | 2 | flags | u16 LE; senders write 0 except the bits defined in section 4; receivers ignore unknown bits |
| 8 | 4 | len | u32 LE payload length, at most 1 MiB (1 048 576) |
| 12 | len | payload | kind-specific, little endian, no padding |

A bad magic or a `len` above 1 MiB closes the link (the stream is lost). An
unknown `kind` from the daemon gets ERROR `UNKNOWN_KIND` and the link stays
up. A daemon ignores an unknown kind from a holder. Strings and byte strings
never exceed the frame; a holder truncates argv/env in WELCOME's record to
fit (the full record stays on disk).

Strings are `u32 len + UTF-8 bytes`; byte strings are `u32 len + bytes`;
`u64` offsets count output bytes from the start of the holder's life.

## 4. Kinds

| Kind | Value | Dir | Payload |
| --- | --- | --- | --- |
| HELLO | 1 | d->h | `min u16, max u16, caps_wanted u64, token raw[32]`; flags bit 0 = observer (never becomes controller) |
| WELCOME | 2 | h->d | `version u16, caps_granted u64, state u8 (0 running, 1 exited), oldest u64, end u64, cols u16, rows u16, identity bytes` (the identity record, section 7) |
| ATTACH | 3 | d->h | `from_offset u64` (above `end`: ERROR `BAD_PAYLOAD`) |
| DATA | 4 | h->d | `offset u64, bytes` (at most 1 MiB - 16); flags bit 0 = stderr (pipes mode) |
| GAP | 5 | h->d | `requested u64, oldest u64` |
| DETACH | 6 | d->h | empty |
| WRITE | 7 | d->h | `bytes` (at most 1 MiB - 4) |
| RESIZE | 8 | d->h | `cols u16, rows u16, px_w u16, px_h u16`; 0 cols or rows: `BAD_PAYLOAD`; pipes mode: `NOT_SUPPORTED` |
| SIGNAL | 9 | d->h | `signal i32, target u8` (0 group, 1 leader) |
| ACK | 10 | d->h | `offset u64` |
| EXIT | 11 | h->d | `status_kind u8` (0 exited, 1 signaled), `code i64` (Unix exit status or signal; Windows u32 exit code), `end_offset u64, at_ms u64` |
| CLOSE | 12 | d->h | `grace_ms u32` |
| PING | 13 | both | `nonce u64` |
| PONG | 14 | both | `nonce u64` |
| ERROR | 15 | h->d | `request_kind u16, code u16, message string` |
| STATS | 16 | both | d->h empty; h->d `cpu_user_us u64, cpu_sys_us u64, max_rss_bytes u64` of the child's group as the kernel reports it to the holder without a scan (getrusage of reaped children, Linux cgroup, Windows job accounting); 0 when unknown |

Error codes: 1 `UNKNOWN_KIND`, 2 `BAD_TOKEN`, 3 `NO_COMMON_VERSION`,
4 `NOT_CONTROLLER`, 5 `NOT_SUPPORTED`, 6 `BAD_PAYLOAD`, 7 `EXITED`.

## 5. Session

### 5.1 Handshake

1. The daemon connects and sends HELLO first. The holder answers nothing
   before HELLO.
2. Token mismatch (constant-time compare): ERROR `BAD_TOKEN`, then close.
   (Only ERROR `BAD_TOKEN` and `NO_COMMON_VERSION` close the link; every
   other ERROR keeps it.)
3. No common version in `[min, max]` and `[1, 1]`: ERROR
   `NO_COMMON_VERSION` with the holder's range in the message, then close.
4. Otherwise WELCOME with `version = 1`, `caps_granted = caps_wanted &
   holder_caps`. v1 holders grant 0. Bits are assigned in this file only and
   never reused.

### 5.2 Controller

- The WELCOMEd non-observer link is the controller. A new valid HELLO on
  another link replaces it: the old link gets ERROR `NOT_CONTROLLER` and is
  closed; frames still queued on the old link are dropped. A daemon that
  restarts therefore always wins. A daemon that receives `NOT_CONTROLLER`
  does not reconnect by itself (another daemon owns the holder).
- Only the controller may send WRITE, RESIZE, SIGNAL, ACK and CLOSE.

### 5.3 Output

- The holder always reads the PTY (or both pipes) and appends to its log,
  with or without a controller (decided 2026-10-14: drop oldest, never
  block). It never blocks the child on the socket or
  on ACK. The log is an in-memory ring (`ring_bytes`, default 8 MiB)
  spilling to `<id>.log` beside its record (`log_bytes`, default 64 MiB);
  at the cap the oldest bytes are dropped and `oldest` moves up. ACK only
  allows earlier trimming (bytes below an acked offset may go first).
- ATTACH `from`: if `from < oldest`, GAP `{from, oldest}` then DATA from
  `oldest`; else DATA from `from`. Then live DATA in order until DETACH, a
  new controller or the end. A controller that falls behind `oldest` while
  streaming gets GAP in the stream, then DATA from the new `oldest`.
- pipes mode: stdout and stderr share one offset space in arrival order;
  DATA flags bit 0 marks stderr bytes (decided 2026-10-14: one offset space,
  not two offsets per frame).

### 5.4 Input and control

- WRITE bytes go to the PTY master (pty) or the harness stdin (pipes) in
  order. A full PTY blocks the holder's writer, not its reader.
- SIGNAL target 0: `killpg(child_pgid, signal)`; 1: `kill(child_pid,
  signal)`. The holder never signals any other process.
- CLOSE at t0: SIGHUP to the group (pty) or close stdin (pipes), and
  SIGTERM to the group; at t0 + `grace_ms`, SIGKILL to the group. CLOSE
  after the child exited acts as the final ACK (section 5.5).

### 5.5 Exit

When the child leader is reaped, the holder reads the PTY master until EIO
(pty) or both pipes until EOF or 2 s (pipes); the last byte read is
`end_offset`. It writes `<id>.exit` (atomic, fsync, 0600, JSON:
`{"schema":1,"id":...,"status_kind":...,"code":...,"end_offset":...,"at_ms":...}`)
and sends EXIT to the controller, if any. After every ATTACH to an exited
holder, EXIT follows the last DATA. The holder stays (no timer) until an ACK
of `end_offset` or a CLOSE, then removes its socket, record and log and
exits; with `orphan_grace_secs` set it also leaves after that long with no
controller. The daemon deletes `<id>.exit` after it has recorded the exit.

### 5.6 Survival rules

- The holder ignores SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1/2 and SIGPIPE,
  except a service-manager stop, which acts like CLOSE with grace 2 s: on
  macOS SIGTERM from PID 1 (launchd); on Linux SIGTERM from PID 1 or from
  the `systemd --user` manager of the holder's own uid, identified by the
  sender pid named in `$MANAGERPID` at spawn (no process read); on Windows
  `CTRL_SHUTDOWN_EVENT` / `WM_ENDSESSION`. In a container whose PID 1 is not
  a service manager, the daemon spawns with `--no-pid1-stop`.
- No orphan timer in normal installs. A DEV build may pass
  `--orphan-grace-secs N`, written in the identity record.
- The holder never reads another process's state and never lists processes.

## 6. Capabilities

v1 defines no capability bits. Rules for later bits:
- A daemon must work with `caps_granted = 0` forever.
- A bit adds frames or payload fields only on links that granted it.
- Payload growth: new fields only at the end of a payload, only under a
  granted bit; a v1 reader never sees them.

## 7. Identity record

`<registry>/<id>.json`, written by the holder after it holds its lease and
has bound its socket (atomic rename, 0600, O_NOFOLLOW). JSON, fields only
grow, readers ignore unknown fields. `<registry>` is
`~/Library/Application Support/cmux/holders/<install>/` on macOS (the daily
`/tmp` cleaner removes files idle for 3 days), `$XDG_STATE_HOME/cmux/holders/<install>/`
on Linux. Sockets go to `/tmp/cmux-<uid>/holders/<install>/` (macOS) or
`$XDG_RUNTIME_DIR/cmux/holders/<install>/` (Linux; `/tmp/cmux-<uid>/...`
when that path would exceed 103 bytes).

```json
{
  "schema": 1,
  "id": "<32 hex>",
  "mode": "pty",
  "install": "<12 hex hash of bundle id + tag>",
  "session": "<daemon session name>",
  "cwd": "/path",
  "argv": ["/bin/zsh", "-l"],
  "started_at_ms": 0,
  "protocol": {"min": 1, "max": 1},
  "caps": 0,
  "socket": "/tmp/cmux-501/holders/<install>/<id>.sock",
  "lease": "<id>.<nonce>.live",
  "orphan_grace_secs": null,
  "holder_build": "<content hash of the holder binary>"
}
```

The owner token is not in this record. The daemon keeps tokens in its own
store: macOS Keychain item `cmux holder tokens <install>`; Linux a 0600 file
`$XDG_STATE_HOME/cmux/holders/<install>/tokens` (protects against other
users only, and against same-uid processes only when Yama
`ptrace_scope >= 1`). A holder whose token is lost cannot be controlled
again; the daemon lists it as "running, not reachable" and the user may end
it with SIGKILL from the UI (the only pid use, from the user's action).
`pid` fields are absent on purpose: no daemon finds or signals a holder by
pid.

Threat model (decision D6, Lawrence 2026-10-14): the holder protects
against other users only. It checks the socket peer uid (section 2) and the
owner token, and nothing else: no code-identity, code-signature or audit
token check. A process of the same user is trusted the same way a shell of
that user is.

## 8. Liveness and discovery

- The holder holds an exclusive `flock` on `<lease>` (a path relative to the
  record's directory) for its life, from before its record exists. A daemon
  that gets the lock knows the holder is dead. Only a daemon that holds the
  lease deletes the record, socket, log and stale `.live` files.
- Discovery = list `<registry>/*.json`, probe each lease, connect to each
  live socket, HELLO. Never ps, `proc_listpids`, sysctl, `/proc` walks or pid
  probes (`scripts/cmux-next/check-no-process-scan.py`).

## 9. Compatibility corpus (with cx-t2sqm.15)

`cmux-tui/crates/cmux-holder/corpus/v1/*.json`, one file per exchange:
`{name, steps:[{dir:"d"|"h", frame_hex}], notes}`. Required exchanges:

1. handshake ok, caps 0; 2. bad token; 3. no common version (daemon offers
2..3); 4. unknown kind 999 -> ERROR, link kept; 5. attach from 0 then live
data; 6. attach below `oldest` -> GAP + data; 7. write + echo; 8. resize;
9. signal group SIGINT; 10. ack trims, re-attach below acked -> GAP; 11. close
-> EXIT; 12. controller replaced -> NOT_CONTROLLER; 13. pipes mode stderr
flag; 14. RESIZE in pipes mode -> NOT_SUPPORTED; 15. ping/pong; 16. observer HELLO
keeps the controller; 17. STATS; 18. attach to an exited holder -> DATA then
EXIT; 19. bootstrap with a failing exec -> 0x02 + errno, no record; 20. a
link silent past the 5 s HELLO deadline is closed.

The runner replays each file twice in CI: the current daemon client against
a holder built from the newest commit, and against a holder built from the
oldest supported holder commit (pinned in `corpus/v1/HOLDER_PINS`). A
daemon-side change that breaks any file is refused.
