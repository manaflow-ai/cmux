# Windows daemon mode for the GPUI app (bead cx-stg)

Status: design, no code yet. Owner: GPUI lane. Base: feat-cmux-next
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

## 1. SDK and daemon client: one transport

Unix-only code in the clients (feat-cmux-next e98b689d646):

| File | What is Unix-only |
| --- | --- |
| `bindings/rust/src/codec.rs` | `UnixStream` everywhere; `connect_unix_with_poll_checks`: `libc::socket(AF_UNIX)`, `FD_CLOEXEC`, `O_NONBLOCK`, `connect` with `EINPROGRESS`, poll, then blocking again |
| `bindings/rust/src/client.rs` | `socket: UnixStream`, `handler: FnOnce(UnixStream)` |
| `bindings/rust/src/raw/byte_attachment/mod.rs` | `socket: UnixStream` |
| `bindings/rust/src/resource/stream.rs` | `writer: UnixStream` |
| `bindings/rust/src/socket_hash.rs`, `resource/client.rs` | `UnixListener` in tests |
| `bindings/rust-daemon-client/src/launcher.rs` | `kill` (SIGKILL), `user_temp_dir` (macOS confstr), `is_executable` (mode bits) |

Design:

- One `LocalStream` trait in cmux-sdk (`bindings/rust/src/transport.rs`):
  Read + Write + Send + Sync, `try_clone`, `set_read_timeout`,
  `set_write_timeout`, `shutdown`, `set_nonblocking`. The client, codec,
  byte attachment and resource streams hold `transport::Stream` (a concrete
  enum or `Box<dyn LocalStream>`; an enum keeps the hot write path free of
  dynamic dispatch). Unix: `std::os::unix::net::UnixStream`, the existing
  connect code moved behind `transport::connect` unchanged. Windows:
  `uds_windows::UnixStream` (the crate the daemon already uses; std has no
  stable AF_UNIX on Windows). No second client: everything above the
  transport is the same code on every platform.
- Connect with deadline and poll checks on Windows: `uds_windows` connect
  blocks. Implement the same contract (`connect_with_poll_checks`: deadline,
  poll interval, the caller's check between polls) with a non-blocking
  socket (`set_nonblocking`, `connect` returning `WSAEWOULDBLOCK`, then
  `WSAPoll` on the raw socket); fall back to a connect thread with a
  deadline only if `WSAPoll` cannot see AF_UNIX completion (verify first).
  Close-on-exec: the socket must not be inherited by processes the client
  starts. Check whether `uds_windows` creates it with
  `WSA_FLAG_NO_HANDLE_INHERIT` (not verified yet); else clear
  `HANDLE_FLAG_INHERIT` after creation. A test asserts it.
- Same-user check: Windows AF_UNIX gives no peer credentials. The socket
  lives in the user's `%TEMP%`, whose ACL admits only that user, SYSTEM and
  Administrators; the client additionally checks the socket file's owner
  SID equals its own token user before the first write (GetNamedSecurityInfoW
  on the socket path; not verified yet on AF_UNIX socket files, which are
  reparse points), as the Unix client refuses a listener of another user. Same check on the daemon side is out of scope (unchanged).
- Shared code with the daemon: the daemon's `platform/transport.rs` and the
  SDK's `transport.rs` implement the same trait shape. Decision for the
  coordinator: move both into one small crate (`cmux-local-socket`) that the
  daemon and cmux-sdk depend on (one source of truth; cmux-sdk is published,
  so that crate must be published too), or keep the trait in cmux-sdk only
  and leave the daemon's copy (no new published crate; two copies of about
  60 lines).
- Launcher (`rust-daemon-client`): `kill` -> `TerminateProcess` on a handle
  from the spawned `Child`; `user_temp_dir` -> `std::env::temp_dir()` (what
  the daemon uses), and the `TMPDIR` pinning is skipped; `is_executable` ->
  `is_file()` plus `.exe` lookup in `resolve_binary`. Socket path from
  `server ensure`'s JSON as today.
- Tests: the SDK's unit tests that use `UnixStream::pair()` get a
  `transport::pair()` (Windows: a listener on a temp path, accept + connect).
  Conformance and the socket tests run in a new `test-windows` job in
  `cmux-tui-sdks.yml` (hosted Windows runner, `x86_64-pc-windows-gnu`, like
  `cmux-tui.yml`), against a daemon built in the same job.

## 2. Daemon: Windows process tree, usage, foreground and cwd

From the same calls GPUI's `hovercard/resources.rs` already makes on
Windows (windows-sys, already a cmux-tui-core dependency):

- Tree: `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)` -> (pid, parent pid,
  exe name). A parent pid can be reused: accept a child only when its
  creation time (`GetProcessTimes`) is after the parent's.
- Usage: `GetProcessTimes` (kernel + user, 100 ns units) and
  `K32GetProcessMemoryInfo` (`PrivateWorkingSetSize`, else `PrivateUsage`),
  with `PROCESS_QUERY_LIMITED_INFORMATION`.
- Foreground: ConPTY has no foreground process group. Rule: the newest live
  descendant of the terminal's shell by creation time, skipping
  `conhost.exe` / `OpenConsole.exe`; the shell itself when it has none.
  (cmux-next's macOS/Linux use `tcgetpgrp`; the GPUI Ghostty fork reports
  the shell's pid on Windows.) Name: `QueryFullProcessImageNameW`.
- Cwd: the process's PEB: `NtQueryInformationProcess(ProcessBasicInformation)`,
  then `ReadProcessMemory` of `ProcessParameters` (PEB + 0x20) and
  `CurrentDirectory.DosPath` (+0x38 length, +0x40 buffer; 64-bit layout).
  WOW64 (32-bit) processes: `ProcessWow64Information` and the 32-bit layout
  (PEB32 + 0x10, +0x24 / +0x28), or report no cwd (first version: no cwd).
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

## Decisions for the coordinator

1. One shared transport crate for daemon and SDK (`cmux-local-socket`,
   published), or the trait in cmux-sdk only with the daemon's copy kept.
2. WOW64 cwd: implement the 32-bit PEB layout now, or no cwd for 32-bit
   processes in the first version.
3. Windows foreground rule: newest live descendant of the shell (this note),
   or the shell only (what the GPUI Ghostty fork reports).
