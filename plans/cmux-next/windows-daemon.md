# Windows daemon mode for the GPUI app (bead cx-stg)

Status: design reviewed (GO with changes, 2026-10-07); experiments done; no code yet. Owner: GPUI lane. Base: feat-cmux-next
e98b689d646 (2026-10-07). Order (coordinator): this note, then the SDK
transport, then the daemon's Windows process data, then the Windows tree
artifact (with hq-ed). CORE/bindings pushes go through the CORE queue;
Cargo.lock changes need the LOCK.

## Goal

The GPUI app on Windows is a client of the cmux-tui daemon, as on macOS and
Linux: terminals live in the daemon, survive app restarts and daemon
restarts, other clients see them, and the hover card's CPU, memory and
folder come from the daemon. Today GPUI builds `daemon_off.rs` on Windows
(local shells only) because cmux-sdk is Unix-only.

## What exists

- Daemon transport: `cmux-tui-core/src/platform/transport.rs` has a
  `Stream` trait (Read + Write + try_clone_box + timeouts + shutdown) and a
  Windows implementation on `uds_windows` 1.2 (AF_UNIX, Windows 10 1803+).
  `connect_same_user` is a plain connect there (no peer credentials).
- Socket base on Windows: `std::env::temp_dir()` (per-user `%TEMP%`),
  user component `%USERNAME%` (`platform.rs runtime_base_dir`,
  `user_id_component`).
- Owner start on Windows: `local_owner.rs` probes the socket (no readiness
  pipe, no `waitid`, no install-key pipe: `install_key_from_fd` is a no-op
  there).
- PTYs: portable-pty's ConPTY backend (`cmux-pty`).
- CI: `cmux-tui.yml` `test-windows` runs `cargo test -p cmux-tui-core --lib`
  for `x86_64-pc-windows-gnu` on a hosted Windows runner.
- Not on Windows: process trees, usage, foreground process, its name and cwd
  (`process_resources.rs` Sampler and `platform.rs foreground_*` return
  nothing; `reads_process_trees()` is false).
- Artifacts: `cmux-tui-build-package.yml` can build `x86_64-pc-windows-gnu`;
  the tree publication forbids the Windows binaries today
  (`cmux-tui-artifacts.yml --forbid-artifact cmux-tui-x86_64-pc-windows-gnu.exe`).

## 1. One local-socket transport: crate `cmux-local-socket`

Decision (coordinator, 2026-10-07): a shared crate, used by the daemon
(cmux-tui-core) and cmux-sdk, so the same-user checks exist once (two
copies would drift: a security bug). Its version moves in lockstep with
cmux-sdk and it is published by the same release workflow and trusted
publisher (no new token or account). If crates.io trusted publishing needs
a web-UI step for the new name, that is reported to the coordinator and
cmux-sdk keeps a path dependency until then. The new crate and Cargo.lock
need CORE + LOCK.

Unix-only code in the clients (feat-cmux-next e98b689d646):

| File | What is Unix-only |
| --- | --- |
| `bindings/rust/src/codec.rs` | `UnixStream` everywhere; `connect_unix_with_poll_checks`: `libc::socket(AF_UNIX)`, `FD_CLOEXEC`, `O_NONBLOCK`, `connect` with `EINPROGRESS`, poll, then blocking again |
| `bindings/rust/src/client.rs` | `socket: UnixStream`, `handler: FnOnce(UnixStream)` |
| `bindings/rust/src/raw/byte_attachment/mod.rs` | `socket: UnixStream` |
| `bindings/rust/src/resource/stream.rs` | `writer: UnixStream` |
| `bindings/rust/src/socket_hash.rs`, `resource/client.rs` | `UnixListener` in tests |
| `bindings/rust-daemon-client/src/launcher.rs` | `kill` (SIGKILL), `user_temp_dir` (macOS confstr), `is_executable` (mode bits) |

Crate API (Unix and Windows behind cfg):

- `Stream`: Read + Write + Send + Sync, `try_clone`, `set_read_timeout`,
  `set_write_timeout`, `shutdown`, `set_nonblocking`, `peer_pid`. Unix:
  `std::os::unix::net::UnixStream`; Windows: `uds_windows::UnixStream` (std
  has no stable AF_UNIX on Windows). One concrete type per platform (no
  dynamic dispatch on the write path).
- `connect(path, deadline, poll_interval, check)`: the client contract that
  `codec.rs connect_unix_with_poll_checks` has today (the Unix code moves
  here unchanged). Windows: non-blocking connect (`WSAEWOULDBLOCK`) and
  `WSAPoll`; a connect thread with a deadline only if `WSAPoll` does not
  report AF_UNIX completion (to verify in the first red test).
- `connect_same_user(path, ...)`: before connecting, the socket file's
  owner SID must equal the caller's token user (Windows); Unix keeps its
  current listener check. Refusal is an error, never a fallback.
- `listen(path)`: creates the socket directory with an owner-only DACL
  (protected, no inheritance: the token user full control; nothing else)
  and the token user as owner, refuses an existing directory whose DACL or
  owner is wider, binds, then sets the socket file's owner to the token
  user (see experiment 2).
- `Listener::accept()` checks the peer: Windows `WSAIoctl
  SIO_AF_UNIX_GETPEERPID`, then `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
  and the process token's `TokenUser` SID must equal ours; otherwise the
  connection is closed and refused (the rule Unix applies with
  `getpeereid`/`SO_PEERCRED`, `peer_may_connect`: owner, or root/SYSTEM is not
  admitted on Windows unless the coordinator decides so).
- Sockets are not inherited by child processes (experiment 1).

Users of the crate:

- cmux-sdk: `codec.rs`, `client.rs`, the byte attachment and the resource
  streams hold `cmux_local_socket::Stream`; nothing above the transport
  changes (no second client). The `UnixStream::pair()` tests use
  `cmux_local_socket::pair()`.
- cmux-tui-core: `platform/transport.rs` becomes a thin wrapper of the crate
  (its `Stream` trait object stays for the server's existing users).
- cmux-daemon-client launcher: `kill` -> `TerminateProcess`; `user_temp_dir`
  -> `std::env::temp_dir()` (the daemon's base) and no `TMPDIR` pinning;
  `is_executable` -> `is_file()` and `.exe` in `resolve_binary`.

Experiments (Windows VM `cmux2-gpui-windows`, Server 2022, admin SSH, a
console program, no windows; 2026-10-07; source: manaflow-ai/cmux-gpui branch
windows-daemon-design, `scripts/windows/uds-experiment/`):

1. Inheritance: listener, connected and accepted `uds_windows` sockets have
   `HANDLE_FLAG_INHERIT` clear; a child started with handle inheritance
   (`std::process::Command`) gets `WSAENOTSOCK` (10038) for each. So
   `uds_windows` sockets are not inherited; a crate test keeps it so.
2. Socket file owner: `GetNamedSecurityInfoW(SE_FILE_OBJECT, OWNER)` reads
   the owner of an AF_UNIX socket file (std sees it as a plain file). For an
   elevated process (High integrity) the owner is BUILTIN\Administrators
   (`S-1-5-32-544`, the token's default owner `TokenOwner`), not the token
   user, so "owner == token user" would refuse an elevated daemon's socket.
   `SetNamedSecurityInfoW(OWNER = token user)` on the socket file works
   (returns 0, the owner reads back as the user), and connects still work
   after it. Hence `listen` sets the owner of the directory and the socket
   file to the token user explicitly, and the client compares with its own
   token user. Not measured yet: a non-elevated (Medium) process, whose
   default owner is normally the user itself (to check in the gpuitest
   session).
3. Peer pid: `WSAIoctl(SIO_AF_UNIX_GETPEERPID)` (0x58000100) works on
   `uds_windows` sockets, on the accepted and the connecting side, and
   returns the peer's process id.

Tests (crate, hosted `test-windows` in `cmux-tui-sdks.yml` and
`cmux-tui.yml`; red first):

- Not inherited (experiment 1 as a test); peer pid; deadline and poll checks.
- The peer SID check as a pure function (`peer_allowed(peer_sid, our_sid)`)
  with fake SIDs: other user refused, same user admitted, SYSTEM and
  Administrators refused.
- A directory with a wider ACL (Everyone read, or an inherited ACE) and a
  directory owned by another SID: `listen` refuses both; a socket file whose
  owner is not the token user: `connect_same_user` refuses.
- A real peer of another user: no second account (coordinator: creating one
  is a host-access change). Options, in order: the pure-function test above
  (always); on the hosted Windows runner (an ephemeral admin VM) a peer
  started as LocalService or SYSTEM through a short-lived scheduled task or
  service, which are other SIDs without a new account; a restricted or
  low-integrity token does not change the user SID, so it cannot stand in
  for another user. If the coordinator wants it on the Windows VM too, a
  SYSTEM scheduled task is the same method there (a decision: it is not an
  account, but it runs code as SYSTEM).

## 2. Daemon: Windows process tree, usage, foreground and cwd

From the same calls GPUI's `hovercard/resources.rs` already makes on
Windows (windows-sys, already a cmux-tui-core dependency):

- Tree: `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)` -> (pid, parent pid,
  exe name). A parent pid can be reused: accept a child only when its
  creation time (`GetProcessTimes`) is after the parent's.
- Usage: `GetProcessTimes` (kernel + user, 100 ns units) and
  `K32GetProcessMemoryInfo` (`PrivateWorkingSetSize`, else `PrivateUsage`),
  with `PROCESS_QUERY_LIMITED_INFORMATION`.
- Foreground: ConPTY has no foreground process group. Heuristic (coordinator
  decision, documented as one): the newest live descendant of the
  terminal's shell by creation time, skipping `conhost.exe` /
  `OpenConsole.exe`; the shell itself when it has none.
  (cmux-next's macOS/Linux use `tcgetpgrp`; the GPUI Ghostty fork reports
  the shell's pid on Windows.) Name: `QueryFullProcessImageNameW`.
- Cwd: the process's PEB: `NtQueryInformationProcess(ProcessBasicInformation)`,
  then `ReadProcessMemory` of `ProcessParameters` (PEB + 0x20) and
  `CurrentDirectory.DosPath` (+0x38 length, +0x40 buffer; 64-bit layout).
  WOW64 (32-bit) processes: no cwd in v1 (coordinator decision); detected
  with `IsWow64Process2` and reported as unknown, documented.
- Access rule (coordinator): read another process's PEB only for processes
  the daemon started, same user, same session; refuse all others. Checks, on
  one handle opened once (no pid reuse between check and read):
  1. Started by the daemon: every terminal's child tree runs in a Job Object
     the daemon creates per terminal (CreateJobObjectW +
     AssignProcessToJobObject right after spawn, before the shell runs
     user code; children inherit the job). `IsProcessInJob(handle, job)`
     must be true. (Job Objects are the reliable "started by" proof;
     parent pids are not.)
  2. Same user: the process token's `TokenUser` SID equals the daemon's.
  3. Same session: `ProcessIdToSessionId` equals the daemon's session.
  Any failed check: no cwd, no name, no usage for that process, logged once
  per pid at debug level. `terminal-resources` sums only processes that
  pass 1-3.
- Then `reads_process_trees()` is true on Windows and `terminal-resources`,
  the snapshot cwd and the foreground name work as on Linux.
- Tests (cmux-tui-core, `test-windows`): tree order (root then breadth
  first, as `cmux_next_process_tree_lists_root_then_descendants_breadth_first`),
  pid-reuse guard, PEB cwd of a spawned child in a known directory, and the
  refusals: a same-user process outside the job (the test runner itself),
  a process in the job whose token differs (skipped when the runner cannot
  create one), and a different session (the predicate with a fake session
  id). Each refusal returns no cwd and no usage.

## 3. Windows tree artifact (with hq-ed)

Windows binaries publish only when signed, or when the coordinator decides
unsigned is OK: raised with the coordinator before any publish.

- Publish `cmux-tui-x86_64-pc-windows-gnu.exe` (+ `cmux-app-host` if built)
  and `.sha256` in every new tree, the same publish path as Linux; remove the
  `--forbid-artifact` lines for it and add `--require-artifact`.
- `pin-cmux-tui.sh host_tree_target`: `MINGW*/MSYS*/CYGWIN*` and Windows
  x86_64 -> `x86_64-pc-windows-gnu`.
- GPUI: `scripts/fetch-cmux-tui.sh` already uses `pin-cmux-tui.sh fetch` and
  `path` for non-macOS targets and checks the published `.sha256`;
  `scripts/build-windows.ps1` bundles the binary beside `cmux2.exe`
  (fetched on the build host, or from a Mac with
  `CMUX_TUI_TREE_TARGET=x86_64-pc-windows-gnu`).

## 4. GPUI app changes (after 1-3)

- `apps/cmux2/Cargo.toml`: cmux-daemon-client and cmux-daemon-layout for all
  targets; `daemon_off.rs` goes; `daemon_binary.rs` looks for
  `cmux-tui.exe`.
- Terminals: the Linux mirror (`native/offscreen/mirror.rs`, the shared
  `daemon/terminal_mirror.rs` and `daemon/output_queue.rs`) serves Windows
  unchanged (same offscreen surfaces); `native/mod.rs` routes Windows daemon
  tabs to it.
- Client identity `device_kind`: as Linux (decision pending: a desktop kind).

## 5. Test plan

- No test runs on Lawrence's laptop.
- SDK: `cmux-tui-sdks.yml` `test-windows` (unit, socket, conformance against
  a daemon built in the job). Daemon: `cmux-tui.yml` `test-windows` gains
  the process tests above. Freestyle has no Windows VMs today.
- GPUI on the Windows VM, only in the `gpuitest` session (scheduled task,
  principal gpuitest, Interactive, Limited; RDP from the Linux VM's private
  display; logoff only with `scripts/windows/logoff-gpuitest.sh` after an
  exact name and id match):
  1. `scripts/windows/daemon-terminal-test.ps1` (port of
     `scripts/daemon-terminal-test.sh`): private session
     (`CMUX2_DAEMON=1`, `CMUX2_DAEMON_SESSION=dt-<pid>`), scratch data dir and
     settings file; scenario quit (type, quit, the CLI reads the screen, a
     second launch reattaches the same terminal with its scrollback);
     scenario restart (`server stop` under the running app, new daemon pid,
     every terminal reattaches, later input reaches the same terminal);
     `server stop --end-terminals` at the end and no process of the session
     left (by exact pid).
  2. Hover card: CPU, memory and folder from `terminal-resources` for a
     terminal running `ping -t` in a known folder.
  3. A window capture by HWND (PrintWindow) of a daemon terminal.
- Gates: `scripts/check.sh --target windows`, GPUI unit tests on the VM.

## Decisions

Taken (coordinator, 2026-10-07): shared crate `cmux-local-socket`; no cwd
for 32-bit processes in v1; foreground = newest live descendant (a
heuristic); Job Object per terminal with `IsProcessInJob` on one handle;
`test-windows` jobs; no new Windows account.

Open:

1. A real other-user peer test: on the hosted Windows runner only (a
   LocalService/SYSTEM peer through a scheduled task), or also on the
   Windows VM (the same method, code running as SYSTEM there).
2. Elevated clients: admit an Administrators-owned socket for an elevated
   client, or always require the token user as owner (this note: always the
   token user; `listen` sets it).
3. Signed or unsigned Windows binaries for the tree publication.
