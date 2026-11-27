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
| Spawn | `pre_exec(setsid)`, pipes | `CreateProcessW`: `CREATE_NO_WINDOW`, `CREATE_NEW_PROCESS_GROUP`, `CREATE_BREAKAWAY_FROM_JOB` (see Risks), `bInheritHandles` FALSE; the bootstrap streams are two named pipes (random 128-bit name, first instance, one instance, local only, owner-only DACL) that the host opens by name, accepted only from the host's pid. No handle is ever inheritable for the host (std `Command` spawns elsewhere in the daemon inherit every inheritable handle, so a handle list with inheritable pipes would leak them) |
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
  runs `terminal_host_runtime::sys::windows::` and `--test windows_terminal_hosts`;
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

## Progress (2026-10-09, continuation agent, branch `gpui-windows-terminal-hosts-2`)

Rebased on feat-cmux-next with B2b (bcb887e23aa5). New commits:

- Breakaway notice, wire: tab JSON `terminal_host_fallback` (null, or
  `"breakaway_denied"`). It is set on the surface before publication
  (`Surface::mark_terminal_host_fallback`), so every tree and every later
  client shows it. A string in sdk-schema (not an enum), so old SDKs read new
  reasons; no capability (the field is informative and nullable).
  `surface/host_state.rs` holds it (with `TerminalHostConnectionState`, moved
  out of surface.rs for the god-file ratchet); `server/raw_tab.rs`
  `merge_surface_fields` emits it (server.rs net 0 lines).
- Red tests: `server/tests/wire_commands.rs`
  `tab_json_reports_why_a_terminal_has_no_host_of_its_own` (portable);
  `tests/windows_terminal_hosts.rs`
  `a_terminal_without_breakaway_runs_in_process_and_says_so` (daemon started
  suspended in a Job Object without BREAKAWAY_OK; red until the host spawn
  lands) and `a_hosted_terminal_reports_no_fallback`.
- String: `terminal.link.inProcess` in CmuxNextTerminal Localizable.xcstrings
  (en translated, 20 languages needs_review; check-l10n passes). macOS does
  not show it (only Windows sets the field).
- `windows/standby.rs`: `spawn_host_process` (CreateProcessW, handle list,
  no window, own group, breakaway), `HostSpawnError::BreakawayDenied`,
  `in_job`, `breakaway_allowed`; tests (pipes, drop ends the process, a
  helper test process in a job without breakaway gets BreakawayDenied).

Open:

- God-file ratchet: `terminal_host_runtime.rs` is +4 lines over its baseline
  because of our `pub mod windows;`. Only the split lane writes that file:
  request R1 in cmuxterm-hq `.cmux-scratch/cx-ko2e-split-items.md`.
- Wiring the fallback (mark the surface when the spawn says BreakawayDenied)
  waits for the host runtime on Windows (`serve_terminal_host_stdio`, the
  B rows of the split). Until then Windows hosts are off and nothing sets it.
- GPUI banner: after the cmux change lands and cmux-shared.pin includes the
  string.
- Finding (run 37935857605, job 113837661734): the hosted `test (windows)`
  runner runs the tests in a Job Object that forbids breakaway
  (`spawn_host_process` gave BreakawayDenied; `in_job` true). With the
  decided fallback, every terminal on that runner runs in-process, so
  `a_terminal_survives_a_fenced_daemon_restart_on_windows` cannot go green
  there. Decision needed: run the hosted test in a job that allows breakaway
  (a wrapper job with BREAKAWAY_OK), or on breakaway denial start the host
  in the daemon's job (it survives a daemon restart, ends only when that
  job closes) and keep the in-process fallback only for a spawn failure.
  The standby unit tests use `Breakaway::Stay` on such a runner.

## Progress (2026-10-09 evening, rebased on feat-cmux-next with B3 216c72866348)

- The Windows layer is now `terminal_host_runtime/sys/windows/` (declared in
  `sys.rs`), so `terminal_host_runtime.rs` needs no line from us (god-file
  check passes; request R1 withdrawn).
- `sys/windows/seams.rs` replaces most `windows_stubs`: FileOwner (proof of an
  owner-only directory of ours), record file checks and opens (links
  refused), leases (LockFileEx), HostLivenessLease, process_definitely_gone,
  rename_no_replace (MoveFileExW), sync, private and endpoint directories,
  connect_with_retry (same-user owner check), AcceptWaker (event).
  Still stubs: PTY custody (none in v1), StandbyTerminalHost and
  launch_terminal_host_from (wait for the host entry and
  serve_terminal_host_stdio on Windows, still in `mod unix`), SessionId,
  process-group signals and kill (Job Object), PTY lock and loss-signal
  cleanup.
- Host bootstrap streams are named pipes, not inherited handles (see the
  Spawn row); `open_bootstrap_pipes` is the host-side call.
- Hosted run 37979232196 at be8c39ee4eb: lint (linux, clippy) green; test
  (windows) 28 Windows-layer tests green, the 2 red integration tests still
  red as expected; macOS lint fails on an upstream unused import
  (server.rs `machine_listening_tcp_json`, not ours); the Linux package
  entrypoint jobs fail with "npm package archive exceeds expanded size
  limit" (not traced).

## Coordinator decisions (2026-10-09) and their code

- Breakaway denied: the host starts inside the daemon's job
  (`spawn_host_process` retries with `Breakaway::Stay`). Notice
  `terminal_host_fallback: "breakaway_denied"` only when that job kills on
  close (`HostProcess::ends_with_daemon_job`, from
  `job_kills_on_close`, innermost job only). In-process fallback only when
  the start fails: `"host_start_failed"`. Strings: `terminal.link.endsWithStarter`
  (breakaway_denied) and `terminal.link.inProcess` (host_start_failed).
- Field name `terminal_host_fallback` kept.
- `pub mod windows;`: the coordinator asked the split lane to add it. This
  branch already moved the layer to `sys/windows/` (declared in `sys.rs`),
  which needs no line in `terminal_host_runtime.rs`; open point for the
  coordinator.

## State after the split finished (2026-10-10, B3-B18 on feat-cmux-next)

- New rule (Lawrence via chief): no unit tests. The branch's new unit tests
  (sys/windows liveness, endpoint, jobs, standby, seams; cmux-pty
  windows_jobs; server wire_commands tab test) are dropped. Behavior tests
  stay: `tests/windows_terminal_hosts.rs` (restart survival, kill-on-close
  notice, no notice for a normal terminal), through the daemon socket.
- `adopt_pty_fd` returns Ok(None) on Windows (`--bootstrap-stdio` starts a
  new terminal); `max_payload` is MAX_LAUNCH_PAYLOAD.
- `signal_terminal_process_groups` (seams.rs) ends the terminal's Job Object
  on Kill (`cmux_pty::windows_jobs::terminate_every_job`).
- Still stubs (the Windows host runtime): StandbyTerminalHost::spawn (wire to
  `standby::spawn_host_process`; note the struct expects std pipes and a
  `SpawnedHostProcess` over `std::process::Child`, while the spawn returns a
  raw process handle and named-pipe Files: the struct must change on
  Windows), HostListener (local_socket listen, WSAEventSelect + the waker
  event for `wait`), publication lock (LockFileEx shared on
  `.publication.lock`), adopt_launch decode/start (ConPTY child through
  cmux-pty, HostShared), HostChild, PtyPollHandle and the readiness wait
  (PeekNamedPipe on the ConPTY output), the `__terminal-host` entry in
  main.rs (open_bootstrap_pipes), and the mux/surface hooks.

## Handoff (2026-10-10, continuation agent at its context limit)

Branch `gpui-windows-terminal-hosts-2` (only this lane pushes it; rebased on
feat-cmux-next after the split finished). Bead cx-ko2e (in_progress). No push
to feat-cmux-next without a relayed token (CORE) and a gate receipt
(`/Users/lawrence/fun/cmuxterm-hq/.cmux-scratch/nx-worker/gate-run.sh`,
SAFE_PUSH_GATED_HEAD + SAFE_PUSH_GATE_RECEIPT). Rule: no unit tests; behavior
tests only (daemon socket / CLI / hosted e2e), red commit first.

Seam list (every signature sys/windows must provide): cmuxterm-hq
`.cmux-scratch/cx-ko2e-split-items.md`, section FINAL NAMES (split B1-B18
done). Windows code: `cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime/sys/windows/`
(`seams.rs` real seams, `standby.rs` host spawn with named-pipe bootstrap and
breakaway/job logic, `endpoint.rs`, `jobs.rs`, `liveness.rs`); the remaining
fail-closed placeholders are `mod windows_stubs` in
`terminal_host_runtime/sys.rs`. Declared in `sys.rs`; the split lane adds no
`mod windows` line (coordinator, final).

Done on the branch: tab JSON `terminal_host_fallback` (`breakaway_denied` =
host inside the daemon's kill-on-close job; `host_start_failed` = in-process),
spec + sdk-schema + bindings, strings `terminal.link.endsWithStarter` and
`terminal.link.inProcess`; host spawn (no inherited handle; breakaway, else
inside the daemon's job, `HostProcess::ends_with_daemon_job`); seams (owner-only
dir proof, record opens, LockFileEx leases, liveness lease, rename, connect,
accept waker, endpoint_dir); Job Object stop (`signal_terminal_process_groups`
-> `cmux_pty::windows_jobs::terminate_every_job`), `kill_process_group`;
`adopt_pty_fd` -> Ok(None).

Remaining, in order:
1. `StandbyTerminalHost` on Windows (`sys.rs` stub -> `sys/windows`): wrap
   `standby::spawn_host_process(current_exe, ["__terminal-host",
   "--bootstrap-stdio"])`. The shared struct expects `io::PipeWriter`/
   `io::PipeReader` and `SpawnedHostProcess` (std `Child`); the spawn returns
   a raw process handle and named-pipe `File`s, so give Windows its own struct
   and check every shared use in `shared/attachment/launch.rs`.
2. Host entry `__terminal-host` in `cmux-tui/crates/cmux-tui/src/main.rs` on
   Windows: `standby::open_bootstrap_pipes(last arg)` in place of stdio, then
   the shared serve path.
3. `HostListener` (bind via `endpoint::bind` / `cmux::local_socket::listen`,
   nonblocking accept, `wait(waker, timeout)`: WSAEventSelect(FD_ACCEPT) on
   the listener socket + WaitForMultipleObjects with the AcceptWaker event).
4. Publication lock (`reserve_terminal_host_publication`,
   `acquire_terminal_host_publication_lock`): LockFileEx shared on
   `<root>/.publication.lock` (`liveness::lock_file`), reset exclusive; mirror
   `sys/unix/lease.rs`.
5. `adopt_launch::decode` / `start`: decode the launch frame (no adopt), spawn
   the ConPTY child through cmux-pty, build `HostShared`; `HostChild`
   (process_id, clone_killer, adopted_session None, wait_exit_observed via
   WaitForSingleObject, wait_and_disarm -> TerminalExit).
6. `PtyPollHandle` / `wait_for_pty_readable_or_forced_drain`: PeekNamedPipe
   on the ConPTY output pipe with a short sleep, plus the drain waker.
7. Mux hooks: `mux/surface_spawn.rs` `use_host_runtime` and
   `adopt_terminal_hosts` on Windows; on `spawn_host_process` success with
   `ends_with_daemon_job()` call `Surface::mark_terminal_host_fallback(
   BreakawayDenied)`; on spawn error run in-process and mark
   `HostStartFailed` (before publication).
8. Named terminal job for a restarted daemon (`cmux-pty/src/windows_jobs.rs`,
   `jobs::job_name`, record field `job_name`) and `windows_processes.rs`
   reading by name.
9. Behavior proof of the breakaway job through a real child: extend
   `cmux-tui/crates/cmux-tui/tests/windows_terminal_hosts.rs` (daemon in a
   kill-on-close job: close the job, the terminal ends; daemon in a plain
   no-breakaway job: stop the daemon, the terminal survives and is adopted).
10. GPUI banner (cmux2-gpui) after the cmux change lands and the pin moves.

Decision needed: the host's terminal job sets no kill-on-close today. If the
daemon kills an unadoptable host (`kill_process_group`), or the host crashes,
its shell tree survives orphaned. Kill-on-close on the host's terminal job
fixes that for hosts, but changes the in-process daemon too unless it is set
only in host processes.

Shortcuts taken: (1) the new Windows code has a temporary `#[allow(dead_code)]`
on `mod windows` in `sys.rs` until the shared runtime calls it; (2) the host's
terminal job has no kill-on-close (above). Also: `sync_dir` is a no-op on
Windows, `has_single_link` is true (owner-only DACL), `is_endpoint_file`
accepts any non-directory reparse point, a failed job-limit query counts as
kill-on-close (shows the notice).

CI (hosted `cmux-tui.yml` full mode: `gh workflow run cmux-tui.yml --ref
gpui-windows-terminal-hosts-2 -f commit=<sha> -f mode=full -f
request_id=<token>`; wait with `glaeda-gh wait run manaflow-ai/cmux/<id>`):
last run 38022719138 at b61b7bbd8b2: lint (linux, clippy) green; test
(windows) builds; expected reds: `a_terminal_survives_a_fenced_daemon_restart_on_windows`
and `a_terminal_in_a_kill_on_close_job_without_breakaway_says_so` (no Windows
host runtime yet); not ours: test (linux)
`cli::mcp::tests::every_tool_is_reachable_from_the_cmux_cli_and_no_excluded_operation_is`,
macOS lint (unused import in `chatmux-relay/src/pty.rs`), and earlier the
Linux package jobs ("npm package archive exceeds expanded size limit").
Earlier runs: 37938711110 (runner job forbids breakaway), 37975463447,
37979232196, 38006094082, 38008073080.

Windows VM check (gpuitest session only; log off only with
`scripts/windows/logoff-gpuitest.sh`; never the demo session), in
~/fun/cmux2-gpui: `scripts/windows/daemon-terminal-test.ps1 -Scenarios restart`
(then `quit`, `resources`, `owner`). Leftovers on the VM: `C:\build-wb\wd-dist`,
`wd-dist-nobin`, `wd-tui`.

## The Windows host runtime (2026-10-10, branch `gpui-windows-terminal-hosts-2`)

Wired on Windows (sys/windows): `StandbyTerminalHost` (this executable as
`__terminal-host --bootstrap-stdio <pipe base>`, `standby::spawn_host_process`)
and `SpawnedHostProcess` (a sys seam now: Unix keeps the std child, Windows
the exact process handle; `commit` detaches), `HostListener`
(`cmux::local_socket::listen`, `WSAEventSelect(FD_ACCEPT)` and
`WaitForMultipleObjects` with the waker event; accepted sockets get their
event selection cleared and block), publication and reset locks
(`LockFileEx` on `.publication.lock`), `adopt_launch` (Launch only; ConPTY
child through cmux-pty), `HostChild` (the child watcher closes the
pseudoconsole when the child exits, so the reader drains and gets EOF; the
reader blocks in `ReadFile`, so the readiness wait only ends a forced
drain), `sys::host_bootstrap_streams` (the entry
`serve_terminal_host_process`: stdio on Unix, the named pipes on Windows),
`SUPPORTS_PTY_CUSTODY` false. The hosted path of surface and mux is built on
Windows (`cfg(any(unix, windows))`); PTY custody and rehosting stay Unix
(a dead Windows host is a host loss).

Fallback marking: `HostAttachment::launch_ends_with_daemon_job` ->
`terminal_host_fallback: "breakaway_denied"` (set when the surface is built);
`HostProcessStartFailed` from the spawn -> the daemon runs the terminal in
its own process and marks `"host_start_failed"` (the mux gives it an
incarnation as for a terminal without hosts).

Decision (kill-on-close of the host's terminal job, open in the handoff):
no kill-on-close, as on Unix. A Unix host is a session leader of its own;
its shell runs in another session on the PTY. `kill_process_group(host)`
or a host crash ends only the host's group; the shell then gets a hangup
when the PTY master closes, and a process that ignores the hangup or left
the terminal (nohup, a daemonized job) survives. On Windows the host owns
the pseudoconsole: when the host ends, every handle it had closes, the
pseudoconsole host ends and the processes attached to that console get the
console close (Windows' hangup); a process that detached from the console
survives. A kill-on-close terminal job would end those too, which Unix does
not do, and it would change the in-process daemon (the job code is shared).
So `windows_jobs` keeps grouping only; an explicit terminate still ends the
whole job (`signal_terminal_process_groups(Kill)` -> `TerminateJobObject`).

Behavior proof (tests/windows_terminal_hosts.rs): restart survival; a
daemon in a kill-on-close job without breakaway says `breakaway_denied`, and
closing that job ends the shell; a daemon in a plain job without breakaway
shows no notice, its terminal survives a fenced restart, and the shell
survives the job closing; a hosted terminal reports no fallback.

Not done on Windows yet: the session reset of a host root
(`workspace_registry` `prepare_terminal_host_root_for_reset` still refuses
on non-Unix), named terminal jobs for a restarted daemon's process reads
(handoff item 8), and the GPUI banner (cmux2-gpui, after the pin moves).

## Handoff (2026-10-10, after the rebase on feat-cmux-next 8cdf94c1ce0)

State: the Windows host runtime is done for v1. Hosted CI (`cmux-tui.yml`
full) is green on Windows for every behavior test in
`tests/windows_terminal_hosts.rs`: restart survival, `breakaway_denied` in
a kill-on-close job without breakaway (closing that job ends the shell), a
plain job without breakaway (no notice, survives a fenced restart, the shell
survives the job closing), and a hosted terminal without fallback.

- Run 38027999303 at 1c212543be7 (before the rebase): test (windows) green,
  4/4 host tests pass.
- Rebase on 8cdf94c1ce0 (859 commits): conflicts in the workflow (kept the
  new acpmux check and the host test step), spec/commands.md (kept the
  remote-terminal paragraph), the generated bindings (regenerated with
  `bindings/codegen/generate.py --write`, `--check` clean), tree_json.rs
  (`merge_surface_fields` on the new remote-terminal code), the respawn
  rework (`RespawnDecision`, `plan_terminal_respawn_locked`,
  `start_terminal_respawn`: built on Windows as before), surface/input.rs
  (`send_hosted_input` built on Windows), terminal_loss_log.rs (upstream
  removed the test module). Run 38071367009 at 3175a26cbe8: four Windows
  build errors (detached-terminal helpers, record-removal wait) and rustfmt.
- 308c5df647d fixes them. Run 38072195088 at 308c5df647d: test (windows)
  green, 4/4 host tests pass; lint (linux) green; Windows release build
  green. Reds not from this branch (its diff touches none of them): test
  (linux) `transport_path_coverage_tests::every_safe_transport_operation_has_a_noun_first_path`
  (the new `settings.*` operations), macOS clippy `tests/cli/chief.rs:264`
  (E0308), and the hosted verification job that sums them.

Next: a gate receipt (`gate-run.sh`) at the head and a push to
feat-cmux-next with a relayed token (CORE). Still not done on Windows: the
session reset of a host root, named terminal jobs for a restarted daemon's
process reads (handoff item 8), the GPUI banner (cmux2-gpui, after the pin
moves).
