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
        program_status_change: Option<serde_json::Value>,
    ) -> anyhow::Result<()> {
        let Some(id) = source.terminal_public_id() else { return Ok(()) };
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let Some(current) = state.terminal_catalog.get(id).cloned() else { return Ok(()) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(());
        }
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(()) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(()) };
        if durable.lifecycle != TerminalLifecycle::Running {
            return Ok(());
        }
        let topology = registry.resource_topology_snapshot()?;
        let content_id = ContentPublicId::Terminal(id.clone());
        let tabs =
            terminal_tab_ids_in_canonical_order(
                topology.tabs.iter().filter(|tab| tab.content_id == content_id).map(|tab| {
                    (id.clone(), tab.pane_id.clone(), tab.position, tab.public_id.clone())
                }),
            )
            .remove(id)
            .unwrap_or_default();
        let value = public_terminal_snapshot(id, &durable, Some(&current), tabs)?;
        let mut result = value.clone();
        if let Some(change) = program_status_change {
            result["program_status_change"] = change;
        }
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
            &result,
            &deltas,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        self.publish_resource_event();
        Ok(())
    }
}
