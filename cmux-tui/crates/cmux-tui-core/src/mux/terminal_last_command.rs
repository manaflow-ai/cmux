use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};

impl Mux {
    /// Publish a terminal's changed `extra.last_command`
    /// (`terminal-exit-status-v1`) as a terminal upsert, under the same
    /// registry -> state fence as topology. A late reader from a replaced
    /// runtime cannot publish for its successor. `Ok(false)` means the
    /// terminal is not in the public graph yet; the change stays pending.
    pub(crate) fn publish_terminal_last_command(&self, source: &Surface) -> anyhow::Result<bool> {
        let Some(id) = source.terminal_public_id() else { return Ok(true) };
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let Some(current) = state.terminal_catalog.get(id).cloned() else { return Ok(false) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(true);
        }
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(false) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(false) };
        if durable.lifecycle != TerminalLifecycle::Running {
            // Only running records carry the field.
            return Ok(true);
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
        let deltas = serde_json::json!([{
            "kind": "upsert", "sequence": 0, "resource": "terminal", "id": id, "value": value,
        }]);
        let mutation = WorkspaceMutation::local("terminal.last_command");
        let commit = registry.commit_resource_patch(
            &mutation,
            "terminal.last_command",
            &value,
            None,
            None,
            &ResourcePatch { changes: Vec::new() },
            &value,
            &deltas,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        // Notify directly, as the cwd publisher does: publish_resource_event
        // would retry pending publications from inside this one.
        self.publish_journal_event();
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn published_last_commands(mux: &Mux) -> Vec<Value> {
        mux.resource_events_after(0)
            .unwrap()
            .batches
            .iter()
            .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
            .filter(|change| change["resource"] == "terminal")
            .filter_map(|change| change.get("value")?.get("extra")?.get("last_command").cloned())
            .collect()
    }

    #[test]
    fn read_run_a_finished_command_publishes_one_terminal_upsert() {
        let mux = Mux::new_for_test("last-command-upsert", SurfaceOptions::default());
        let request = serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"create",
            "operation":"workspace.create",
            "idempotency_key":"last-command-upsert",
            "params":{
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            },
        });
        let created =
            crate::resource_router::handle_resource_message(&mux, &request.to_string()).unwrap();
        assert_eq!(created["ok"], true, "{created}");
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux
            .resource_surface_for_terminal(&terminal_id)
            .and_then(|surface| mux.surface(surface))
            .expect("created terminal surface");

        surface.apply_stream_output_for_test(b"$ sh -c 'exit 7'\r\n$ ").unwrap();
        surface.publish_pending_last_command();
        assert!(published_last_commands(&mux).is_empty(), "no marks, no record");

        surface
            .apply_stream_output_for_test(b"\x1b]133;C\x07\x1b]133;D;7\x07\x1b]133;A\x07$ ")
            .unwrap();
        // The output reader publishes after releasing the parser lock.
        surface.publish_pending_last_command();
        surface.publish_pending_last_command();
        let published = published_last_commands(&mux);
        assert_eq!(published.len(), 1, "one upsert per new record: {published:?}");
        assert_eq!(published[0].get("exit_code"), Some(&serde_json::json!(7)));
        mux.shutdown();
    }
}
