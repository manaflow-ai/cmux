//! Terminal OSC 9;4 progress and OSC 7501 program status on the public
//! graph. The daemon parses both for every terminal (mounted or not) and
//! publishes a terminal upsert whenever the parsed state changes.

use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};

impl Mux {
    /// Publish `source`'s current terminal snapshot (with its progress and
    /// program status) as one resource revision named `mutation`. A replaced
    /// runtime or a terminal that is not running publishes nothing.
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
        let current = {
            let state = self.lock_state_pinned(&registry).unwrap();
            state.terminal_catalog.get(id).cloned()
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
        drop(registry);
        self.publish_resource_event();
        Ok(())
    }
}
