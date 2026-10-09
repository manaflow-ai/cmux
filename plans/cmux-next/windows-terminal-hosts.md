# Per-terminal hosts on Windows (GPUI lane)

Status: design for review (no code). Owner: GPUI lane (coordinator,
2026-10-09). Bead: to file (no bead tool on the lane's machine). Code needs
CORE (cmux-tui-core, cmux-pty, cmux-tui main); exact files below.

## Problem

On Windows a daemon restart ends every terminal. Measured in the gpuitest
session (GPUI `scripts/windows/daemon-terminal-test.ps1 -Scenarios restart`,
cmux-tui 165aa9a24ef): `server stop` under a running app, the app's views
get `Detached { reason: HostShutdown }`, the new daemon has no such
terminals, and the views fail to reattach (`attachment_generation_mismatch`).
On macOS and Linux the same scenario reattaches the same shells.

Cause: per-terminal hosts are Unix-only. On Windows
`serve_terminal_host_stdio` fails ("per-terminal hosts are not implemented on
this platform", `terminal_host_runtime.rs` not(unix) stubs), the host
branches in `mux.rs` (`use_host_runtime`, `adopt_terminal_hosts`) and
`surface.rs` (`SessionOwned && terminal_host_root`) are `#[cfg(unix)]`, so
`surface.rs` opens the ConPTY in the daemon process (`cmux_pty::open` +
`pty.spawn`). The terminal lives and dies with the daemon.

## What the Unix host does (the contract to keep)

- Spawn: `cmux-tui __terminal-host --bootstrap-stdio` with stdin/stdout
  pipes, `setsid`, inherited fds closed (`isolate_terminal_host_process_fds`).
  Over the pipes: `Bootstrap` (versions, terminal id, 32-byte owner token) ->
  `Ready` (incarnation) -> `Launch` (endpoint, record path, size, cwd,
  command, env, colors, limits) -> `Ready`/`LaunchFailed`; then the pipes are
  dropped. Standby hosts are pre-spawned and wait on the pipe.
- The host owns the PTY, the child, the Ghostty parser, the replay snapshot
  and viewer-size arbitration; it listens on its own socket
  (`/tmp/cmux-th-<uid>/<terminal_hex>.sock`, 0600, private directory).
- Record `<state_root>/terminal-hosts-<stable_token(session)>/<id>.json`
  (v4: terminal id, incarnation, endpoint, owner token, host pid, start
  nonce, workspace key, capability flags), written by the host after it
  binds; a `.live` lease (held `flock`), an `.exit` record (fsynced before
  the Exit frame, removed by the mux after SQLite is durable), a
  `.publication.lock` (hosts hold it shared; reset takes it exclusive).
- Adoption after a daemon restart (`Mux::adopt_terminal_hosts`): scan and
  validate records (canonical name, endpoint path, owner uid, mode), liveness
  (`flock` probe on `.live`, else `kill(pid, 0)`), connect, check the
  listener's uid, authenticate with the owner token; take PTY custody
  (`SCM_RIGHTS`) so a crashed host can be replaced (`--adopt-pty-fd 3`).

## Windows design

One host process per terminal, as on Unix: the same binary, protocol,
records and adoption flow. Only the system layer differs.

| Piece | Unix | Windows |
| --- | --- | --- |
| Spawn | `pre_exec(setsid)`, pipes | `CreateProcessW`: `CREATE_NO_WINDOW`, `CREATE_NEW_PROCESS_GROUP`, `CREATE_BREAKAWAY_FROM_JOB` (see Risks), `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` = only the two bootstrap pipe ends (the handle-isolation analog of `isolate_terminal_host_process_fds`) |
| PTY | openpty | ConPTY in the host (`cmux_pty` already has it), child started by the host |
| Endpoint | 0600 Unix socket in `/tmp/cmux-th-<uid>` | `cmux::local_socket::listen` at `%TEMP%\cmux-th-<USERNAME>\<terminal_hex>.sock`: owner-only protected directory, socket file owner = our token user (measured at Medium and High integrity) |
| Daemon -> host check | listener uid | `connect_same_user` (socket file owner SID = ours) |
| Host -> client check | none (socket mode) | `accept` refuses another user, below Medium integrity, AppContainer (same `peer_allowed` policy as the daemon); then the owner token as on Unix |
| Liveness lease | `flock` on `.live` | `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)` held by the host for its life (released by the kernel when it dies); the probe tries `LOCKFILE_EXCLUSIVE_LOCK \| LOCKFILE_FAIL_IMMEDIATELY`: success = Dead. Fallback: `OpenProcess` + `GetProcessTimes` creation time equal to the record's (new field `host_created_100ns`; pid reuse guard) |
| Publication / reset locks | `flock` shared / exclusive | `LockFileEx` shared / exclusive on `.publication.lock` |
| No-replace rename | `renameat2` / `renamex_np` | `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING` |
| Record ownership check | uid, mode `& 077 == 0` | owner SID = ours and the directory owner-only (`win::owner_of`, `directory_is_owner_only`) |
| Terminate | `killpg` | the host ends the child tree with `TerminateJobObject` on the terminal's job, then exits |
| PTY custody / replacement host | `SCM_RIGHTS`, `--adopt-pty-fd` | not in v1 (`pty_custody: false`): an `HPCON` cannot move between processes (no documented API), so a crashed host ends its terminal with an exit cause `host_lost` (cmux-next shows the host-loss banner; the GPUI view ends, see GPUI 1e25086) |

### Job Objects

Today the daemon creates one unnamed job per terminal child
(`cmux-pty/src/windows_jobs.rs`, no `KILL_ON_JOB_CLOSE`) and gates cwd, name
and usage reads on `IsProcessInJob` (`windows_processes.rs`). With hosts,
the host spawns the child, so the host creates the job. A restarted daemon
must still prove "started by the daemon" without holding the handle:

- The host names the job `Local\cmux-tui-<USERNAME>-<stable_token(session)>-<terminal_hex>-<incarnation>`
  with an owner-only security descriptor (our token user full access,
  nothing else), records the name in the host record (`job_name`), and
  keeps the handle open for its life (the job object lives while the host
  does).
- The daemon opens it with `OpenJobObjectW(JOB_OBJECT_QUERY)`, checks the
  job's owner SID is ours (`GetSecurityInfo`; a squatted name fails), then
  `IsProcessInJob(process, job)` on the one process handle it reads, as
  today. Same user and same session checks stay.
- Race to fix on the way: `AssignProcessToJobObject` right after spawn
  leaves a window. Start the child suspended (`CREATE_SUSPENDED`) or with
  `PROC_THREAD_ATTRIBUTE_JOB_LIST`, assign, then resume.

Alternative (rejected for v1): the host answers `terminal-resources` for its
own tree. It moves the process reads into every host and changes the
daemon's sampler; the named job keeps today's reader.

### Records and paths

- `terminal_host_root` uses the Unix naming on Windows too
  (`terminal-hosts-<stable_token(session)>`; the not(unix) stub's
  `<session>.terminal-hosts` goes; no Windows record exists yet).
- Record v5 adds `job_name` and `host_created_100ns` (optional; Unix leaves
  them out). Validation: canonical name, endpoint equals the per-user path,
  file owner SID ours, directory owner-only.
- Exit record: `FlushFileBuffers` before the Exit frame (the fsync analog).

### Breakaway and the app's process tree

The GPUI app starts `cmux-tui server ensure`; the daemon starts hosts. A
host must not die with the app or the daemon. Windows kills a job's
processes when the job is closed with `KILL_ON_JOB_CLOSE` (Task Scheduler,
some terminals and IDEs put their children in such jobs). Hosts spawn with
`CREATE_BREAKAWAY_FROM_JOB`; when the enclosing job forbids breakaway
(`JOB_OBJECT_LIMIT_BREAKAWAY_OK` unset) `CreateProcessW` fails with
`ERROR_ACCESS_DENIED`, and the daemon then logs it once and falls back to
an in-process ConPTY for that terminal (today's behavior), so a terminal
always opens. The daemon itself is started detached by the launcher (the
same breakaway rule).

## Code (CORE; exact files)

- `crates/cmux-tui-core/src/terminal_host_runtime.rs`: the not(unix) stubs
  go; the platform-neutral record, protocol and adoption code moves out of
  `mod unix` where it has no syscalls; `mod windows` beside it.
- New `crates/cmux-tui-core/src/terminal_host_runtime/windows/`:
  `standby.rs` (spawn, handle list, breakaway), `endpoint.rs`
  (local_socket listen/connect, record checks), `liveness.rs` (`LockFileEx`
  lease and probes, publication and reset locks), `jobs.rs` (named job,
  owner check).
- `crates/cmux-tui-core/src/mux.rs`: `use_host_runtime` and
  `adopt_terminal_hosts` on Windows.
- `crates/cmux-tui-core/src/surface.rs`: the host branch on Windows;
  `surface/rehost.rs` stays Unix-only (no custody).
- `crates/cmux-tui-core/src/windows_processes.rs`: the job by name.
- `crates/cmux-pty/src/windows_jobs.rs`: named job, owner-only descriptor,
  suspended start (no race).
- `crates/cmux-tui/src/main.rs`: the `__terminal-host` entry on Windows.
- `bindings/rust/src/local_socket/windows.rs`: nothing new expected
  (`listen`, `connect_same_user`, `accept_with_peer` exist).

## Tests

- Unit (cmux-tui-core, hosted `test-windows`): record v5 round trip and
  validation refusals (other owner SID, wide directory DACL, wrong endpoint
  path); liveness lease (a child holds the lock: Live; after it exits:
  Dead; a reused pid with another creation time: Dead); named job (owner
  check refuses a job created with another descriptor; `IsProcessInJob`
  for a host's child, refused for the test runner); handle list (the host
  inherits only the two pipes: a probe for a known handle fails in the
  child).
- Integration (hosted `test-windows`): start a daemon, open a terminal,
  `server stop` (keeps hosts), start a daemon, `list-workspaces` shows the
  same terminal id and a `read-screen` shows output from before; input
  after the restart reaches the same shell; `server stop --end-terminals`
  leaves no process.
- GPUI, gpuitest session: `daemon-terminal-test.ps1 -Scenarios restart`
  passes (reattached, `dt-after-42`, scrollback), and `quit`, `resources`
  (now through the named job after a restart), `owner` still pass. A host
  killed by PID: the view ends ("terminal ended") and the tab shows the
  terminal as dead with `host_lost`.

## Risks and open decisions

1. Breakaway denied by an enclosing job: fall back to in-process ConPTY
   (terminal opens, does not survive a daemon restart) and log once.
   Alternative: refuse to start the terminal. Proposed: fall back.
2. No PTY custody on Windows (v1): a host crash ends its terminal. Unix
   replaces the host. Proposed: accept for v1.
3. Job ownership after a restart: named job with owner check (proposed) or
   host-reported resources.
4. Process count: one `cmux-tui.exe` per terminal (~10-20 MB private each,
   to measure); standby hosts as on Unix.

## Handoff (2026-10-10, GPUI lane agent at its context limit)

State of branch `gpui-windows-terminal-hosts` (side branch; force-pushed only by
this lane after rebases), head c42d00e53ae, rebased on feat-cmux-next with B1
(70bb57f3e77c):

- Decisions taken: no PTY custody in v1 (host crash -> `host_lost`); named
  owner-only Job Object; breakaway forbidden -> in-process ConPTY, logged AND
  shown to the user (new string on the host-loss banner pattern, en + ja; a
  persistent terminal state field in the protocol, CORE spec change).
- Split (crate-split lane, only writer of `terminal_host_runtime.rs`): item list
  and its FINAL NAMES section in cmuxterm-hq
  `.cmux-scratch/cx-ko2e-split-items.md` (A1-A3 and B1 landed so far). Build
  against the names there; B1 `sys::HostStream` = `uds_windows::UnixStream`.
- Red test: `cmux-tui/crates/cmux-tui/tests/windows_terminal_hosts.rs`
  (`a_terminal_survives_a_fenced_daemon_restart_on_windows`), red on hosted
  test (windows): runs 37905235782, 37930026163 ("did not adopt ... exit code 1").
- Windows layer done, 13 unit tests green on hosted test (windows) (run
  37930026163): `terminal_host_runtime/windows/{liveness,endpoint,jobs}.rs`
  (LockFileEx leases; per-user endpoint path, `bind`, `connect_record` on
  `sys::HostStream`; named job create / `open_checked` with
  JOB_OBJECT_QUERY | READ_CONTROL / `contains`). Wiring: one
  `#[cfg(windows)] pub mod windows;` in `terminal_host_runtime.rs`, five
  windows-sys features in cmux-tui-core `Cargo.toml` (no Cargo.lock change).
- Branch-only CI line: `test (windows)` in `.github/workflows/cmux-tui.yml`
  runs `terminal_host_runtime::windows::` and `--test windows_terminal_hosts`;
  it lands with the CORE request. Hosted checks: `gh workflow run
  cmux-tui.yml --ref gpui-windows-terminal-hosts -f commit=<sha> -f mode=full
  -f request_id=<token>` (full mode is the only path that runs these on
  Windows); read the job log with `gh api --allow-escape-sequences
  repos/manaflow-ai/cmux/actions/jobs/<id>/logs`.

Next steps (in order):

1. Breakaway notice, independent of the split (coordinator, 2026-10-10):
   a. Spec + daemon + bindings: a persistent terminal state field saying the
      terminal runs in-process and will not survive a daemon restart (name it
      with the spec owner; a reconnecting client must see it, so it is
      terminal state, not an event). Red test first; then
      `cmux-tui/bindings/codegen/generate.py --write`,
      `cmux-tui/scripts/check-spec-inventory.py`,
      `cmux-tui/scripts/check-sdk-schema.py`; old clients must decode it
      (optional field, ignored when unknown).
   b. A new string key on cmux-next's host-loss banner pattern
      (`TerminalLinkWatch.forwardHostLoss` / `session.hostLoss`), en + ja, in
      cmux-next's catalog.
   c. GPUI shows the banner from that field (shared client code; only Windows
      sets it).
2. After the split moves the remaining B rows: `windows/standby.rs`
   (`CreateProcessW` with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` = the two
   bootstrap pipes, `CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP |
   CREATE_BREAKAWAY_FROM_JOB`, child started suspended and assigned to the
   named job before resume; `ERROR_ACCESS_DENIED` on breakaway -> in-process
   fallback + the state field), Lease/PrivateFs seams on Windows (records,
   `MoveFileExW` no-replace, owner checks), the few-line hooks in `mux.rs`
   (`use_host_runtime`, `adopt_terminal_hosts`) and `surface.rs`.
3. Green the red test on hosted test (windows), then the GPUI gpuitest restart
   scenario (`scripts/windows/daemon-terminal-test.ps1 -Scenarios restart`).
4. CORE request via the coordinator with the exact files; push to
   feat-cmux-next only through `gate-run.sh` with a receipt in /tmp/gates/
   (SAFE_PUSH_GATED_HEAD + SAFE_PUSH_GATE_RECEIPT; lane-rules.md "Gate
   receipts").

Windows VM leftovers for these tests: `C:\build-wb\wd-dist` (release dist with
the tree's cmux-tui.exe), `wd-dist-nobin`, `wd-tui` (test script).
