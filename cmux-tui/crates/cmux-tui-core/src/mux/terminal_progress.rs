//! A terminal's durable edges on the public graph: a command or prompt
//! fact, and an OSC 7501 program status record that appears, goes away or
//! changes its state or kind. The daemon parses them for every terminal
//! (mounted or not) and commits one terminal upsert per edge. An OSC 9;4
//! progress, the last output time and a report that keeps its record's
//! state and kind are live facts: `terminal_live.rs` sends them to the open
//! streams with no commit, but while a journal stream follows their rows
//! (`Mux::follow_terminal_progress_rows`) or a journal hook is delivered
//! them, each is one commit here too.

use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};

impl Mux {
    /// Publish `source`'s current terminal snapshot (with its newest live
    /// facts) as one resource revision named `mutation`, for a durable
    /// edge. A replaced runtime or a terminal that is not running publishes
    /// nothing.
    pub(crate) fn publish_terminal_progress(
        &self,
        source: &Surface,
        mutation: &'static str,
    ) -> anyhow::Result<()> {
        let Some(id) = source.terminal_public_id() else { return Ok(()) };
        let mut registry = self.workspace_registry.lock().unwrap();
        // The session lock only to find the terminal's current runtime: the
        // registry reads and the commit below run with the registry alone
        // (TUL-F7: progress reports held the session lock 18 s of 187 s
        // under L6, max 198 ms, and a person's key lookups waited).
        // The registry connection stays pinned to the end, as before: the
        // journal writer takes only the connection, so without the pin a
        // writer commit could land between the reads below and this
        // publish's commit (#32326 review). The second hold is taken under
        // the session lock's own pin (re-entrant), after lock_state_pinned
        // settled earlier answers, so it outlives the session lock only. It is
        // released with the registry, before the publish below (#32408).
        let (current, connection) = {
            let state = self.lock_state_pinned(&registry).unwrap();
            let connection = registry.connection.pin();
            (state.terminal_catalog.get(id).cloned(), connection)
        };
        let Some(current) = current else { return Ok(()) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(());
        }
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(()) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(()) };
        if durable.lifecycle != TerminalLifecycle::Running {
            return Ok(());
        }
        // This terminal's own tab rows, not the whole session topology.
        let tabs = terminal_tab_ids_in_canonical_order(
            registry
                .resource_tabs_of_content(id.as_str())?
                .into_iter()
                .map(|tab| (id.clone(), tab.pane_id, tab.position, tab.public_id)),
        )
        .remove(id)
        .unwrap_or_default();
        let value = public_terminal_snapshot(id, &durable, Some(&current), tabs)?;
        self.run_state_commit_after_apply_hook();
        let deltas = serde_json::json!([{
            "kind": "upsert", "sequence": 0, "resource": "terminal", "id": id, "value": value,
        }]);
        let commit = registry.commit_resource_patch(
            &WorkspaceMutation::daemon_local(mutation),
            mutation,
            &value,
            None,
            None,
            &ResourcePatch { changes: Vec::new() },
            &value,
            &deltas,
        )?;
        self.state.lock().unwrap_or_else(PoisonError::into_inner).resource_revision =
            commit.revision;
        // Released in reverse order of acquisition, both before the publish: it publishes the
        // terminals' pending directories, which take the registry (registry -> connection -> state).
        drop(connection);
        drop(registry);
        self.publish_resource_event();
        Ok(())
    }
}

// A terminal program's own report that it waits on the person, or stopped
// waiting (OSC 7501 `blocked`, then `working` or `idle`), journaled as agent
// roster evidence. Claude Code fires no hook when the person dismisses its
// permission dialog with Esc, so without the screen-detection plugin only
// this report ends the hook's `blocked` row
// (`journal_reducers_program_status.rs`).

impl Mux {
    /// Journal that `source`'s program started (`Blocked`) or stopped
    /// (`Working`, `Idle`) waiting on the person. Called by the terminal's
    /// publication after its upsert, never under the session or registry
    /// lock.
    pub(crate) fn record_program_status_evidence(
        &self,
        source: &Surface,
        state: ghostty_vt::ProgramStatusState,
    ) {
        let Some(terminal) = source.terminal_public_id() else { return };
        let ingress = match program_status_evidence_ingress(terminal, state) {
            Ok(ingress) => ingress,
            Err(error) => {
                eprintln!("cmux-tui: program status evidence for {terminal} not built: {error}");
                return;
            }
        };
        let key = format!("program-status-{terminal}-{}", crate::workspace_registry::new_uuid_v4());
        if let Err(error) = self.append_journal_ingress(&ingress, "program-status", &key) {
            eprintln!("cmux-tui: program status evidence for {terminal} not journaled: {error}");
        }
    }
}

/// The core-owned `agent.state.changed` event for one program status edge:
/// the agent hook envelope with the `cmux` adapter, the terminal as its
/// subject, and the state and wall-clock observation time normalized.
fn program_status_evidence_ingress(
    terminal: &TerminalPublicId,
    state: ghostty_vt::ProgramStatusState,
) -> anyhow::Result<crate::JournalIngress> {
    Ok(crate::JournalIngress {
        producer_id: crate::agent_hooks::AGENT_HOOK_PRODUCER_ID.into(),
        manifest_version: crate::agent_hooks::AGENT_HOOK_MANIFEST_VERSION,
        kind: "agent.state.changed".into(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![crate::JournalSubject { kind: "terminal".into(), id: terminal.to_string() }],
        sensitivity: Some(crate::JournalSensitivity::Sensitive),
        payload: serde_json::json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter": {"id": "cmux", "version": 1},
            "native_event": crate::journal_reducers::PROGRAM_STATUS_NATIVE_EVENT,
            "normalized": {
                "state": state.as_str(),
                "observed_at_ms": crate::workspace_registry::unix_epoch_ms()?.to_string(),
            },
            "native": {},
        }),
        causation_id: None,
        correlation_id: None,
    })
}
