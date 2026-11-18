# Owner notes, 2026-11-17: the daemon marks its Recovered terminals workspace

The pre-push guardrail names PL-daemon (session cmux-b6) for the cmux-tui files below. That
session was not live (acpmux on mac and its peers has no session cmux-b6), so the note is here.
No action is needed unless you disagree with a change.

## PL-daemon (cmux-tui-core, cmux-server, session cmux-b6)

Range on feat-cmux-next: b1b05cf4e16c..cfe06fbef8d5 (red test f46ceff7142e, fix 9b130dcc20d6,
runbook cfe06fbef8d5). Classic handoff B16
([classic-handoff-go-live-RUNBOOK.md](classic-handoff-go-live-RUNBOOK.md)).

- New capability `workspace-recovered-v1` (`state/home_store.rs` `WORKSPACE_RECOVERED_CAPABILITY`,
  listed in `server/capabilities.rs`; spec: `cmux-tui/spec/commands.md`, beside `workspace-kind-v1`).
- New field `recovered` (bool) on each workspace of the raw tree (`server/tree_json.rs`, from
  `server/home.rs` `raw_workspace_recovered`). It is true while the workspace has at least one tab
  and every tab is a recovered terminal host. A tab the person adds makes the workspace theirs.
- The source is the durable `recovered_terminal` launch spec that `mux/orphan_hosts.rs` already
  writes on the `terminal_hosts` row. No schema change. `PresentationSnapshot` gains
  `recovered_terminals` (terminal ids), read in `presentation_store/snapshot.rs`
  (`read_recovered_terminals`: live, non-tombstoned rows with that mark).
- `recover_orphan_terminal` now reloads the presentation snapshot after it adopts a host, so the
  first tree after the recovery already has the mark. A reload failure is logged, not fatal.
- Cost: when no recovered terminal exists, the set is empty and the tree does no walk.
- Consumer: cmux-next `FirstWorkspace.swift` `needsFirstWorkspace` reads `WorkspaceModel.recovered`;
  the two workspace names stay as the fallback for a daemon that sends no field. If you rename the
  recovery workspace or change what it holds, keep `recovered` true for it.
- Tests: `terminal_host_recovery` `a_live_host_of_a_lost_registry_is_recovered_not_terminated`
  (red at f46ceff7142e's tree: `recovered` was `Null`; green after), Swift suite
  `RecoveredWorkspaceMarkerTests`. Compile check 9fb72d09ce7a2160f9f1068c.
