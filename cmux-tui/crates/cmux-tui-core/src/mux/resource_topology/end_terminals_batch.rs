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
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
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

#[cfg(test)]
mod tests {
    use super::super::*;

    fn host_id(mux: &Arc<Mux>, surface: &Arc<Surface>) -> String {
        mux.resource_terminal_host_identity(surface).expect("test terminal is hosted").terminal_id
    }

    fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
        mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
    }

    /// Ending N terminals one close at a time rebuilt and committed the whole
    /// session projection N times: O(N^2) teardown (1,000 terminals took
    /// 147 s). The teardown is one projection and one commit.
    #[test]
    fn end_all_terminals_commits_one_resource_revision() {
        const TERMINALS: usize = 4;
        let mux = Mux::new_for_test("terminal-end-batch", SurfaceOptions::default());
        let mut terminal_ids = (0..TERMINALS)
            .map(|index| {
                let surface =
                    mux.new_workspace(Some(format!("batch-{index}")), Some((80, 24))).unwrap();
                host_id(&mux, &surface)
            })
            .collect::<Vec<_>>();
        terminal_ids.sort();
        let before = mux.with_state(|state| state.resource_revision);

        let mut ended = mux.end_all_terminals().unwrap();

        ended.sort();
        assert_eq!(ended, terminal_ids);
        let revisions = mux.with_state(|state| state.resource_revision) - before;
        assert_eq!(
            revisions, 1,
            "ending {TERMINALS} terminals must commit one resource revision, got {revisions}"
        );
        for terminal_id in &terminal_ids {
            assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Tombstoned);
        }
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), TERMINALS, "emptied workspaces stay");
            assert!(state.terminal_catalog.is_empty());
            assert!(state.surfaces.is_empty());
        });
        assert_eq!(mux.terminal_host_closes.pending(), 0);
    }
}
