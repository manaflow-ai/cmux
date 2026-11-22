# Owner notes, 2026-11-21: `daemon stop --if-idle` and the launchd uninstall wait

The pre-push guardrail names PL-daemon (session cmux-b6) for the cmux-tui files below. That
session was not live (acpmux on mac has no session cmux-b6), so the note is here. No action is
needed unless you disagree with a change.

## PL-daemon (cmux-tui-core, cmux-server, session cmux-b6)

Range on feat-cmux-next: 33dbf5d73136..88507c515693 (launchd fix 7912a1fa3c51, `--if-idle`
88507c515693). Rex parity item `server stop --if-idle`.

### cmux-tui-core: `shutdown-daemon` with `if_idle`

- New optional field `if_idle` on `shutdown-daemon` and capability `daemon-stop-if-idle-v1`
  (`server.rs` `DAEMON_STOP_IF_IDLE_CAPABILITY`, listed in `server/capabilities.rs`; spec:
  `cmux-tui/spec/commands.md`, `cmux-tui/spec/sdk-schema.json`, `docs/protocol.md`). An older
  daemon ignores the field; the CLI checks the capability first and exits 4.
- `server/stop_if_idle.rs` `check` runs inside the handoff reservation (`cmd_server.rs`
  `shutdown_daemon`, after `begin_daemon_handoff`). Busy means another control client is
  connected (owner-plugin clients excluded, as `user_client_count` does) or a terminal row is
  `launching`, `adopting` or `running`. Busy answers `error_code` `daemon_busy` with
  `error_details` `{clients, terminals}` and releases the reservation.
- The idle-stop fence. When the check passes, under the workspace registry lock it read the
  terminals with, it raises `WorkspaceRegistry::set_idle_stop_fence(Some(requester))`: two TEMP
  triggers on the registry's one SQLite connection. `BEFORE INSERT ON terminal_hosts` refuses a
  live lifecycle. `BEFORE UPDATE OF lifecycle` refuses a change from not live to live. Every
  terminal write path is covered (commit, respawn, resource projection, restore), because all of
  them write through that connection. If you add a second connection that writes
  `terminal_hosts`, it does not have these triggers: route it through the fence.
- The fence has an owner. `check` raises it only while `daemon_handoff_pending_for(requester)`
  holds. `Mux::settle_idle_stop_fence` (`mux/lifecycle.rs`) lowers it unless
  `daemon_handoff_held_by(owner)` holds. It runs after `Mux::cancel_daemon_handoff` releases a
  reservation and after a disconnect that released one. `ClientRegistry::remove`
  (`server/client_registry_views.rs`) now returns `(record, released_handoff)`;
  `server/disconnect.rs` calls the settle when that is true. Lock order: workspace registry, then
  client registry state (in `check` and in the settle).
- A creation refused by the fence fails at the write of its `launching` row, before its host
  starts. Its caller gets `mutation.indeterminate` (the creation records its outcome only after
  the effect). No other client is connected while the fence is up, so only the requester's own
  requests or daemon-internal paths can see this.
- Tests: `server/tests/stop_if_idle.rs` (10 tests) and `mux/tests/idle_stop_fence.rs` (respawn
  and raw write refused while raised). Red runs: 44957954880, 44961043182, 44961683729. Codex
  review r27..r27d, APPROVE on r27d.

### cmux-server: launchd uninstall waits for the bootout

- `service/launchd.rs` `uninstall`: `launchctl bootout` returns before launchd drops the job (on
  macOS 27.0.1, `launchctl print` exited 0 right after it and 113 two seconds later). Uninstall
  now asks again every 100 ms for up to 5 s (`BOOTOUT_WAIT_POLLS`), as the systemd path waits.
  After that it still refuses and removes nothing.
- Test: `tests/service_ownership.rs`
  `uninstall_waits_for_launchd_to_drop_the_job_after_its_bootout` (red run 44960533335). Real
  launchd install and uninstall twice on cmux15: no plist, no job, no hold folder left.

### Known gaps (closed below, in "Follow-up: the two known gaps")

- On macOS, uninstall left running terminal hosts alive.
- "A daemon that `cmux server install` starts opens a default workspace with a shell": wrong. See
  the follow-up: a fresh service daemon has no terminal.

## Follow-up: the service lock and new unit files (cmux-server)

Two gaps left open by R-002/R-004/R-005 are now closed at their root.

- **Old write handles and ACL entries on a unit file.** Install kept an unchanged unit or plist file
  in place (only a `chmod`), so a write descriptor another account opened earlier (while a mode bit
  or an ACL entry allowed it) and the file's own macOS ACL entries stayed live. Now
  `fsx::write_fresh` writes every unit as a new inode (same modification time when the bytes are
  the same, so systemd does not set `NeedDaemonReload`). Right before uninstall stops anything,
  `Services::renew_unit_files` checks every unit file, then writes the text cmux renders now into
  a new inode at each one: never the old bytes, since an old descriptor on the ownership record
  could forge a matching hash. The record is refused when an ACL entry lets another account write it.
- **Two service commands at once.** systemd and launchd stop by name only, so a gap of one command
  stays between cmux's last check and the stop. Another account cannot use it (private folders, new
  inodes, only root or this account can load another unit or job). Another cmux command could:
  `Services::lock` now holds an exclusive `flock` on `<unit folder>/.cmux-server.lock` (0600, this
  account's, checked to still be the file at that name after the lock; removed when the last unit
  is) for install, uninstall, start, stop and restart, and for the CLI `install` and `uninstall`
  verbs for their whole run (`--purge` included). The same thread may take it again. A second
  command refuses at once. Service managers load no file of that name. On macOS a lock file with
  any ACL allow entry (a folder that passes `allow read,file_inherit` on) is removed and the command
  refuses, naming `chmod -N` for the folder: another account could have opened it.
- Tests: `tests/service_ownership.rs` (10 new). Red on the code before the fix: Linux runs
  44972866606 and 44974778143; macOS on cmux15 (5 of 5 red, the two macOS ACL tests included).
  Codex r28 (BLOCK, 3 findings, fixed), r28b, r28c and r28d (BLOCK, 1 finding each, fixed).

## Follow-up: the two known gaps (cmux-server, cmux-server-core, cmux-tui-core, cmux-tui)

Real runs on cmux15 (launchd, macOS 27) and Linux fleet runners (systemd 255) found the causes.

- **Uninstall left the shells, on macOS and on Linux.** A terminal host (`cmux-tui __terminal-host`)
  runs in a session of its own and ignores a SIGTERM that does not come from PID 1
  (cx-t2sqm.17). `launchctl bootout` ends only the job's process group, and `systemctl --user kill
  --kill-whom=all` comes from the user manager, which is not PID 1: on Linux the uninstall then
  refused ("9 processes of cmux-server.service still run") and left the unit. Only a cmux daemon can
  end the hosts. Now uninstall of the session service (`service/mod.rs` `sweep`) has a daemon
  end them, before it removes the unit files:
  - While the service's daemon runs (launchd `pid` in `launchctl print`, systemd `MainPID`), it
    ends its own terminals before the manager stops it (`end_running_daemon_terminals`):
    `<binary> daemon status --session S --json` must answer on the session's socket with status
    `running`, session S and that same pid, then `<binary> daemon stop --session S
    --end-terminals --json` must answer `stopped` with that pid. The daemon knows its own state,
    so uninstall reads nothing of its process: no environment, no arguments (cmux-next does not
    scan processes, `plans/cmux-next/pty-holder.md` section 4; an earlier version of this change
    read `/proc/PID/environ` and `KERN_PROCARGS2`, and the push gate refused it). The daemon exits
    0. launchd starts a new one at once (the session plist has `KeepAlive=true`; a probe on cmux15
    showed that `launchctl disable` does not stop that for a loaded job); the bootout ends it, and
    the sweep below ends any terminal it started. The `disable --now` that follows cancels
    systemd's restart (`RestartSec=3`). Another pid, another session, or no answer (a
    daemon the app started for the session, the service's daemon behind a socket of its own, a
    shell whose socket folder is not the service's) refuses before anything changes: the command
    says to run it in a login shell where `daemon status` answers with that pid. Both commands run
    without `CMUX_TUI_SOCKET` and `CMUX_MUX_SOCKET`, so a terminal's socket never stands in for
    the session's.
  - Then, in both cases, once the manager stopped the service (launchd: bootout, then the wait
    until launchd dropped the job; systemd: `disable --now`), `end_terminal_hosts` ends the hosts
    left: those of a daemon that did not run (a crash, an earlier stop) and those of a daemon
    launchd restarted meanwhile. It runs `<binary> daemon ensure --session S` (that daemon adopts
    every host still running) and `<binary> daemon stop --session S --end-terminals`, with HOME
    from the user database (what launchd and systemd give a service) and the two state variables
    (`CMUX_TUI_STATE_DIR`, `XDG_STATE_HOME`) as the manager now gives them (`launchctl getenv`,
    kept byte for byte; `systemctl --user show-environment`, its `$'...'` quoting decoded). A
    variable the manager does not set is removed, never taken from the shell. A daemon launchd
    restarted got exactly these values. A relative state path refuses: the daemon resolves it
    against its own working directory. Only a daemon this `ensure` started (`started`,
    `restarted`) is stopped: one that already runs (`running`: a daemon of the session the app
    started outside the service; `replaced`: a wedged one replaced) holds those terminals as its
    own and keeps them.
  - Then the old systemd kill and checks, then the unit files go.
  - A pid query launchd cannot answer refuses; it never reads as "no daemon runs".
  - Read before anything changes (the unit renewal included), so a refusal changes nothing: the
    daemon's answer or the manager's environment, the binary
    (`$HOME/.local/bin/cmux-tui`; gone: refused, `cmux server install` puts it back), and the binary
    and its `.local/bin` and `.local` folders being this account's and writable by no other; so must
    a build staged beside it (`cmux-tui.staged`), which `daemon ensure` swaps in and runs first.
  - systemd: after `disable --now`, the unit must be inactive before the sweep (its hosts may stay,
    `KillMode=process`; a daemon still running could start terminals after the sweep).
  - Known limit: with no daemon running, the manager's environment now is the best answer. A state
    variable changed in the manager (or a drop-in) after the daemon stopped points the sweep at other
    state; on macOS its hosts then stay, as all of them did before this change (Linux refuses: its
    cgroup still holds them). A drop-in that gives the daemon a state or socket of its own, with no
    daemon running, has the same limit.
  - A failure after the stop keeps the unit files ("removed nothing"); the next uninstall tries again.
  - An uninstall run in a terminal of the session refuses before it changes anything
    (`cli/lifecycle.rs`, `service::terminal_session`): the sweep would end that terminal, and the
    uninstall with it, before the unit files go. A terminal's `CMUX_TUI_SOCKET` names its session
    only when it is a default socket path (`cmux-tui-UID/<session>.sock`, or the SHA-256 leaf in
    `cmux-tui-hashed-UID` or `cmux-tui-invalid-UID`); any other socket (a daemon run with
    `--socket` of its own) refuses too, since cmux cannot tell its session. Only a default socket of
    another session lets uninstall run in a cmux terminal.
- **The CLI uninstall renewed a session unit as the store unit.** `cli/lifecycle.rs` built
  `Services` with no session, so `renew_unit_files` (0412ec9b) wrote the store unit's text over the
  session unit right before the stop; a failed uninstall would have left a unit that starts another
  program. The CLI now passes the installed session (`session_service::installed_host`), with the
  binary that install places (`$HOME/.local/bin/cmux-tui`), never the path the file names.
- **`--if-idle` and "the default shell".** There is none: a service daemon right after install
  stops with `--if-idle` (exit 0), under launchd and systemd, in both cycles. Two things kept it busy:
  - hosts that an uninstall left (above), adopted by the next install's daemon;
  - terminals of closed tabs that never ended. Closing a workspace leaves its terminals live for the
    reap grace (Reopen Closed attaches to them until then), but the service daemon had no reaper:
    `daemon start` runs `--headless`, and a headless owner reaps only with
    `--terminal-reap-grace-seconds` (`daemon ensure` passes 30). Now the session unit passes it too
    (`cmux-server-core` `units/session.rs` `SESSION_REAP_GRACE_SECONDS`, in the plist and in
    `ExecStart`; a unit without it still parses as cmux's). Seen on cmux15: refused at +13 s, stopped
    at +32 s.
  - The refusal also says which live terminals belong to closed tabs and will be reaped
    (`error_details.closed_tabs`, message "... of closed tabs, which end after the reap grace unless
    reopened"; 0 when the daemon runs no reaper), since "1 live terminal" with no workspace left read
    like a hidden shell. `Mux::unplaced_and_placed_terminals`
    takes and drops the state lock before `stop_if_idle::check` takes the registry lock; the idle
    decision does not change.
- Tests: `cmux-server/tests/service_ownership.rs`
  `uninstall_ends_the_sessions_terminals_after_the_service_stopped`,
  `uninstall_removes_nothing_when_the_terminals_did_not_end`,
  `uninstall_changes_nothing_when_the_session_binary_is_gone`,
  `uninstall_changes_nothing_when_the_session_binary_folder_is_shared`,
  `uninstall_ends_the_terminals_with_the_state_env_of_the_service_manager`,
  `uninstall_has_the_running_daemon_end_its_terminals_before_the_service_stops`,
  `uninstall_changes_nothing_when_the_running_daemon_does_not_answer_as_the_services`,
  `uninstall_removes_nothing_when_the_running_daemon_did_not_end_its_terminals` (each on both
  platforms), `uninstall_leaves_a_daemon_of_the_session_it_did_not_start`,
  `uninstall_ends_no_terminals_while_systemd_still_runs_the_daemon`,
  `uninstall_changes_nothing_when_launchd_cannot_say_whether_the_daemon_runs`,
  `uninstall_changes_nothing_when_a_staged_build_is_shared`,
  `uninstall_ends_no_terminals_with_a_relative_state_path`; `service/systemd.rs`
  `show_environment_values_are_read_as_systemd_quotes_them`;
  `tests/session_service.rs` `uninstall_stops_the_session_unit_as_cmux_wrote_it` and
  `uninstall_refuses_to_run_in_a_terminal_of_the_session`;
  `cmux-server-core/tests/session_units.rs` `the_session_daemon_reaps_closed_terminals` and
  `session_units_without_the_reap_grace_still_parse`; core `server/tests/stop_if_idle.rs`
  `stop_if_idle_names_the_terminals_of_closed_tabs`. Red on the code before: Linux runs
  [44979754368](https://github.com/manaflow-ai/cmux/actions/runs/44979754368) (cmux-server),
  [44980379978](https://github.com/manaflow-ai/cmux/actions/runs/44980379978) (session units) and
  [44979421154](https://github.com/manaflow-ai/cmux/actions/runs/44979421154) (core). The Codex r29 tests: [44981334728](https://github.com/manaflow-ai/cmux/actions/runs/44981334728) (3 of 3 red with the old behavior put back at each fix site) and
  [44982048782](https://github.com/manaflow-ai/cmux/actions/runs/44982048782) (Codex r29b: 4 of 4) [44983540492](https://github.com/manaflow-ai/cmux/actions/runs/44983540492) (r29c: 2 of 2),
  [44984272152](https://github.com/manaflow-ai/cmux/actions/runs/44984272152) (r29d: 1 of 1) [44985064328](https://github.com/manaflow-ai/cmux/actions/runs/44985064328) (r29e: 2 of 2) and [44986840757](https://github.com/manaflow-ai/cmux/actions/runs/44986840757) (r29f and r29g: 3 of 3); the running-daemon tests on the version that read the daemon's
  process: [44990299053](https://github.com/manaflow-ai/cmux/actions/runs/44990299053) (2 of 3; the third refused there for another reason) and, with the answer check taken out, [44990595285](https://github.com/manaflow-ai/cmux/actions/runs/44990595285) (the third).
- Green on the final code: Linux [44995117604](https://github.com/manaflow-ai/cmux/actions/runs/44995117604) (fmt, clippy
  `-D warnings` on cmux-server and cmux-server-core, clippy on cmux-tui-core and cmux-tui with `-A
  unused_qualifications` because `language_packs.rs` fails it at the base, the cmux-server and
  cmux-server-core tests, the core idle-stop and reaper tests, the cmux-tui `local_owner` tests);
  macOS on cmux15 (the same tests).
- Real runs, two cycles of install, `daemon stop --if-idle` and uninstall each, lock file included:
  - launchd on cmux15. Before the fix (0412ec9b): hosts left after uninstall, and the next install's
    daemon refused `--if-idle` with "1 live terminal". After: no daemon, host, shell, plist or lock
    file left in either cycle; the lock file is 0600 while installed and gone after uninstall.
    In two of the later runs, under load average 9 to 10 (another build on cmux15), `workspace
    create` answered `mutation.outcome_unknown` (exit 3) though it made the workspace and its
    terminal; the checks after it passed. Not looked into here: it is outside this change.
  - systemd on Linux (systemd 255): [44981182362](https://github.com/manaflow-ai/cmux/actions/runs/44981182362) and, with the
    daemon environment read (the version the push gate refused), [44982032501](https://github.com/manaflow-ai/cmux/actions/runs/44982032501) [44983535780](https://github.com/manaflow-ai/cmux/actions/runs/44983535780) and [44986950002](https://github.com/manaflow-ai/cmux/actions/runs/44986950002), then (final code, the daemon ends its own terminals) [44994053605](https://github.com/manaflow-ai/cmux/actions/runs/44994053605), FAIL=0, the same checks; the daemon runs with `--terminal-reap-grace-seconds 30`. Before the fix:
    [44978909184](https://github.com/manaflow-ai/cmux/actions/runs/44978909184) (uninstall refused
    with the hosts still running).
- Test setup trap: a LaunchAgent gets the account's real HOME, not the HOME of the shell that ran
  `cmux server install`. An e2e with a private HOME must use a session name of its own, or its
  daemon shares the account's `main` session state.
- Codex: r29 (BLOCK: 5 findings; 4 fixed, the lock-order one rejected: no lock is held while the
  other is taken); r29b (BLOCK: 6 findings; 5 fixed; rejected: checking HOME and its parents, since
  the service manager runs that same path at every start unchecked, and a group-writable HOME of a
  user-private group is common); r29c (BLOCK: 3 findings; the forged session and the sweep read
  after the renewal fixed; the stopped-daemon fallback kept as the known limit above); r29d (BLOCK:
  1 finding, fixed: a failed pid query read as no daemon); r29e (BLOCK: 2 findings, fixed: a daemon
  with its own state or socket, a shared staged build); r29f (BLOCK: 1 finding, fixed: a relative
  state path); r29g (BLOCK: 2 findings, both fixed: an uninstall run in a terminal of the session
  ended itself; an empty state value in the daemon's environment read as a relative path); r29h, on
  those fixes only (BLOCK: 1 finding, fixed: a terminal of a daemon with a socket of its own was
  read as another session's, red on the code before in [44987742727](https://github.com/manaflow-ai/cmux/actions/runs/44987742727)). The r29g and r29h briefs asked
  for findings at medium severity or above in this change. Then the push gate (`check-no-process-scan`)
  refused the reads of the daemon's process; the redesign above (the daemon ends its own
  terminals) drops them, and with them the checks of its arguments and environment. r30 on the
  redesign (BLOCK: 2 findings, both fixed: launchd restarts the daemon at once after its clean
  exit, so a terminal started on the new one before the bootout stayed, now the sweep after the
  bootout ends it; the sweep's `ensure` could find a daemon the app started for the session and
  end its terminals, now only a daemon it started is stopped; red with each fix taken out:
  [44991198478](https://github.com/manaflow-ai/cmux/actions/runs/44991198478)); r30b on those fixes (BLOCK: 2 findings). Fixed: `daemon
  ensure` reported `started` when the owner it spawned lost the bind to a racing ensure's owner
  (the app reconnecting after the daemon-first stop dropped its connection is such a race), so the
  sweep would stop the app's new daemon; now `cmux-tui` `local_owner.rs` `wait_for_spawned_owner`
  says whether the owner that answers announced itself on this call's ready pipe, and ensure
  reports the winner as `running` (spec: `cmux-tui/spec/cli.md`; red with the fix taken out:
  [44992697078](https://github.com/manaflow-ai/cmux/actions/runs/44992697078)). r30c on that fix
  (BLOCK: 3 findings, all fixed): a successor that replaced the owner after its announcement was
  still taken as this call's; an owner whose first probe found it still starting was reported as
  `running`, so the sweep would leave its terminals; off Unix (no ready pipe) any owner that
  answered was taken as this call's. Now the owner is this call's only when it announced itself
  (Unix) and answers with the pid this call spawned (`is_spawned_owner`; a DEV build that runs the
  owner under the "cmux Files (dev)" launcher never sees the owner's pid, so there the
  announcement alone counts). Test: `local_owner/recovery_tests.rs`
  `an_owner_this_call_did_not_spawn_is_not_the_one_it_started` (six cases), red with each part
  taken out: [44995114998](https://github.com/manaflow-ai/cmux/actions/runs/44995114998) (no pid check: "replaced by a successor" fails; the r30b fallback: "its own owner, first probe starting" fails). r30d on that (BLOCK: 1 finding, fixed: a test constructor of `SpawnedOwner`
  lacked the new field, so the test target did not compile); r30e: APPROVE. Kept as a known limit: a daemon that replaces the one
  this uninstall identified between two of its commands (status, then stop; ensure, then stop).
  The stop checks the pid it answers, but only after it stopped; closing that needs a stop that
  names the daemon it may stop, a daemon CLI change. It needs the daemon this command just
  identified to exit by itself within those milliseconds and another to take the socket.
