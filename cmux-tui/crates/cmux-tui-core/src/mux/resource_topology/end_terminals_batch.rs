//! `shutdown-daemon end_terminals`: end every live terminal in one durable
//! commit (nx-scale step 1b).
//!
//! Closing terminals one at a time rebuilt the whole session projection and
//! committed it once per terminal, so a teardown of N terminals cost O(N^2)
//! (1,000 terminals: 147 s, 2,000: 557 s). This plans every removal on one
//! clone of the live state, projects it once, and commits the resource
//! tombstones and the terminal host tombstones in one SQLite transaction,
//! like a batch tab close. Hosts are signaled after the commit through the
//! parallel host-close pool.
//!
//! A terminal without a catalog runtime is in the same commit when the
//! per-terminal close would take it: it ended (its tabs are dead, or it has
//! none) or it is pending. After an app update that is every terminal of the
//! session (826 workspaces: 628 parked, 170 dead, 0 live), and one close each
//! made the stop 66 s. The per-terminal close keeps only what it must refuse
//! or repair: no resource row, a changed host, a live row with no owner.
//!
//! Chromium's fast shutdown is the model: at quit the browser ends each
//! renderer process with no cleanup pass and no wait for each one. Here the
//! durable record of the end is one transaction for the session, and the
//! hosts are told to go together with one bounded wait for all of them.

use super::*;

/// What one batched end committed.
pub(crate) struct EndedTerminalBatch {
    /// Host ids the commit ended.
    pub ended: Vec<String>,
    /// Host ids the batch did not take (no resource row, a changed host, a
    /// live row with no owner); the caller closes them one by one.
    pub remaining: Vec<String>,
}

impl Mux {
    /// End `terminal_ids` (host ids) in one commit: each with a runtime, and
    /// each ended or pending one with none. Emptied workspaces stay, as with
    /// a per-terminal close from `end_terminals`. Nothing changes unless the
    /// whole batch commits.
    pub(crate) fn end_terminals_in_one_commit(
        &self,
        terminal_ids: &[String],
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<EndedTerminalBatch> {
        let _creation_handoff =
            self.resource_creation_handoff.write().unwrap_or_else(PoisonError::into_inner);
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
        // Pending terminals of the batch: a host may run with no runtime here.
        let mut pending_hosts = Vec::new();
        for terminal_id in terminal_ids {
            let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
                remaining.push(terminal_id.clone());
                continue;
            };
            let runtime = projected.terminal_catalog.get(&public_id).cloned();
            if let Some(runtime) = runtime.as_ref() {
                if self
                    .resource_terminal_host_identity(runtime)
                    .is_none_or(|host| &host.terminal_id != terminal_id)
                {
                    remaining.push(terminal_id.clone());
                    continue;
                }
            } else if registry.terminal_host_id(&public_id)?.as_ref() != Some(terminal_id) {
                remaining.push(terminal_id.clone());
                continue;
            }
            let Some(record) = registry.terminal_record(terminal_id)? else {
                remaining.push(terminal_id.clone());
                continue;
            };
            if runtime.is_none() {
                // The rule of the per-terminal close (`commit_legacy_terminal_close`):
                // with no runtime, only an ended or a pending terminal closes
                // here. A tombstoned row with a live resource and a live row
                // with no owner stay with that close, which repairs or refuses.
                if record.lifecycle != TerminalLifecycle::Exited
                    && !self.pending_terminal_closable(terminal_id)
                {
                    remaining.push(terminal_id.clone());
                    continue;
                }
                if self.terminal_is_pending(terminal_id) {
                    pending_hosts.push((
                        public_id.clone(),
                        terminal_id.clone(),
                        record.incarnation.clone(),
                    ));
                }
            } else if record.lifecycle == TerminalLifecycle::Tombstoned {
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
            runtimes.extend(removed_runtime.or(runtime));
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
            projection.restates_all,
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
        // A pending terminal has a host and no runtime: end the host by its
        // record, as the per-terminal close does.
        for (public_id, terminal_id, incarnation) in pending_hosts {
            self.after_terminal_close(
                &public_id,
                &terminal_id,
                &json!({ "incarnation": incarnation }),
                true,
            );
        }
        for runtime in &runtimes {
            self.purge_terminal_runtime_side_tables(runtime);
        }
        self.terminate_terminal_runtimes_deferred(runtimes);
        Ok(EndedTerminalBatch { ended, remaining })
    }
}

#[cfg(test)]
mod tests;
