use super::*;
use crate::resource_api::public_terminal_snapshot;

impl Mux {
    /// Commit terminal cwd under the same registry -> state fence as topology.
    /// A late reader from a replaced runtime cannot update its successor.
    pub(crate) fn publish_terminal_directory(
        &self,
        source: &Surface,
        observed: &Option<String>,
        directory: Option<String>,
    ) -> anyhow::Result<bool> {
        let Some(id) = source.terminal_public_id() else { return Ok(true) };
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let Some(current) = state.terminal_catalog.get(id).cloned() else { return Ok(false) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(true);
        }
        // A snapshot flush may race the reader. Only the latest serialized OSC state wins.
        if current.pwd() != *observed { return Ok(false); }
        if current.published_directory() == directory {
            return Ok(true);
        }
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(true) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(true) };
        if durable.lifecycle != TerminalLifecycle::Running {
            return Ok(true);
        }
        let topology = registry.resource_topology_snapshot()?;
        let content_id = ContentPublicId::Terminal(id.clone());
        let tabs = topology.tabs.iter().filter(|tab| tab.content_id == content_id)
            .map(|tab| tab.public_id.clone()).collect();
        let mut value = public_terminal_snapshot(id, &durable, Some(&current), tabs)?;
        value["cwd"] = serde_json::json!(directory);
        let deltas = serde_json::json!([{
            "kind": "upsert", "resource": "terminal", "id": id, "value": value,
        }]);
        let mutation = WorkspaceMutation::local("terminal.cwd");
        let commit = registry.commit_resource_patch(
            &mutation, "terminal.cwd", &value, None, None,
            &ResourcePatch { changes: Vec::new() }, &value, &deltas,
        )?;
        current.commit_published_directory(directory);
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        self.publish_resource_event();
        Ok(true)
    }

    /// Close the startup race where the first prompt preceded runtime registration.
    pub(crate) fn publish_pending_terminal_directories(&self) {
        let terminals = self.state.lock().unwrap().terminal_catalog.values().cloned().collect::<Vec<_>>();
        for surface in terminals { surface.publish_pending_directory(); }
    }
}
