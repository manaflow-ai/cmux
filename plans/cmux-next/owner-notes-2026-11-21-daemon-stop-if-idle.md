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

### Known gaps (not changed)

- On macOS, uninstall leaves running terminal hosts alive (launchd ends only the job's own
  process group); a later install adopts them. On Linux, uninstall ends them.
- A daemon that `cmux server install` starts opens a default workspace with a shell, so
  `--if-idle` refuses it until that terminal ends.

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
