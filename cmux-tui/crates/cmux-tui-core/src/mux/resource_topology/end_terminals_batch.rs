//! `shutdown-daemon end_terminals`: end every live terminal in one durable
//! commit (nx-scale step 1b).
//!
//! Closing terminals one at a time rebuilt the whole session projection and
//! committed it once per terminal, so a teardown of N terminals cost O(N^2)
//! (1,000 terminals: 147 s, 2,000: 557 s). This plans every removal on one
//! clone of the live state, projects it once, and commits the resource
//! tombstones and the terminal host tombstones in one SQLite transaction,
//! like a batch tab close. Hosts are signaled after the commit through the
//! parallel host-close pool. A terminal without a catalog runtime (pending,
//! or exited with dead views) is left to the per-terminal close, which owns
//! those cases.

use super::*;

/// What one batched end committed.
pub(crate) struct EndedTerminalBatch {
    /// Host ids the commit ended.
    pub ended: Vec<String>,
    /// Host ids the batch did not take; the caller closes them one by one.
    pub remaining: Vec<String>,
}

impl Mux {
    /// End `terminal_ids` (host ids) in one commit. Emptied workspaces stay,
    /// as with a per-terminal close from `end_terminals`. Nothing changes
    /// unless the whole batch commits.
    pub(crate) fn end_terminals_in_one_commit(
        &self,
        terminal_ids: &[String],
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<EndedTerminalBatch> {
        let _creation_handoff =
            self.resource_creation_handoff.lock().unwrap_or_else(PoisonError::into_inner);
        let _creation_fence =
            self.resource_creation_execution.lock().unwrap_or_else(PoisonError::into_inner);
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        let selection_before = active_tree_selection(&state);
        let mut projected = state.clone();
        let mut remaining = Vec::new();
        let mut ended = Vec::new();
        let mut ended_public_ids = Vec::new();
        let mut terminal_batch = Vec::new();
        let mut runtimes = Vec::new();
        let mut removed = Vec::new();
        let mut changed_screens = Vec::new();
        for terminal_id in terminal_ids {
            let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
                remaining.push(terminal_id.clone());
                continue;
            };
            let Some(runtime) = projected.terminal_catalog.get(&public_id).cloned() else {
                remaining.push(terminal_id.clone());
                continue;
            };
            if self
                .resource_terminal_host_identity(&runtime)
                .is_none_or(|host| &host.terminal_id != terminal_id)
            {
                remaining.push(terminal_id.clone());
                continue;
            }
            let Some(record) = registry.terminal_record(terminal_id)? else {
                remaining.push(terminal_id.clone());
                continue;
            };
            if record.lifecycle == TerminalLifecycle::Tombstoned {
                // Closed meanwhile: ended, as the per-terminal close reports.
                ended.push(terminal_id.clone());
                continue;
            }
            changed_screens.extend(
                projected
                    .placements_of_content(&ContentPublicId::Terminal(public_id.clone()))
                    .iter()
                    .filter_map(|surface| surface_screen_id(&projected, *surface)),
            );
            let (removed_runtime, views, _) =
                remove_terminal_content_from_state(self, &mut projected, &public_id);
            removed.extend(views);
            runtimes.push(removed_runtime.unwrap_or(runtime));
            terminal_batch.push((terminal_id.clone(), record.incarnation));
            ended.push(terminal_id.clone());
            ended_public_ids.push(public_id);
        }
        if terminal_batch.is_empty() {
            return Ok(EndedTerminalBatch { ended, remaining });
        }
        let selection_resync = selection_before != active_tree_selection(&projected);
        let result = json!({
            "closed": removed.iter().map(|surface| surface.id).collect::<Vec<_>>(),
            "terminals": terminal_batch.iter().map(|(terminal_id, incarnation)| json!({
                "terminal_id": terminal_id,
                "terminal_incarnation": incarnation,
            })).collect::<Vec<_>>(),
        });
        let fingerprint = json!({"op": "end-terminals", "terminals": ended});
        let mut plan = ResourceClosePlan {
            state: projected,
            removed,
            terminal_runtime: None,
            closed_terminal_public_id: None,
            terminal_batch,
            workspace_close: None,
            delta: None,
            changed_screens: unique_screen_ids(changed_screens),
            selection_resync,
        };
        let projection =
            self.resource_effect_projection_locked(&registry, &mut plan.state, json!({}))?;
        let committed = registry.commit_topology_close(
            mutation,
            "terminals.end",
            &fingerprint,
            None,
            None,
            &projection.patch,
            &result,
            &projection.changes,
            &plan.terminal_batch,
            None,
            None,
            true,
            None,
        )?;
        anyhow::ensure!(
            !committed.resource.replayed,
            "end_terminals replayed an earlier commit of the same mutation"
        );
        let mut effects =
            plan.install(&mut state, committed.resource.revision, committed.workspace_revision);
        drop(state);
        if committed.terminal_batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, committed.terminal_batch.revision);
        }
        self.publish_revisioned_workspace_delta(&registry, &mut effects);
        drop(registry);
        drop(_creation_fence);
        drop(_creation_handoff);
        self.finish_resource_close(CommittedResourceClose { commit: committed.resource, effects });
        for public_id in &ended_public_ids {
            self.forget_terminal_end(public_id.as_str());
        }
        self.notify_terminal_exit_waiters(ended_public_ids);
        for runtime in &runtimes {
            self.purge_terminal_runtime_side_tables(runtime);
        }
        self.terminate_terminal_runtimes_deferred(runtimes);
        Ok(EndedTerminalBatch { ended, remaining })
    }
}
