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

    #[cfg(unix)]
    fn terminal_hex(prefix: &str, index: usize) -> String {
        format!("{prefix}000000000040008000{index:012x}")
    }

    #[cfg(unix)]
    fn tab_count(mux: &Arc<Mux>) -> usize {
        mux.with_state(|state| state.panes.values().map(|pane| pane.tabs.len()).sum())
    }

    /// The full stop (`shutdown-daemon end_terminals`) of a restored session
    /// of `terminals` workspaces, each with one terminal that ended before
    /// this daemon started: its tab is dead and it has no runtime here. That
    /// is every terminal of the person's session after an app update (826
    /// workspaces, 798 terminals: 628 parked, 170 dead, 0 live). Eight of
    /// them hold a kept tab (parked); the others lost their host.
    ///
    /// Counts with no clock: the stop is one resource revision and each
    /// terminal is tombstoned, each dead tab is gone, each workspace stays.
    /// It prints the time for the record; the time is not asserted.
    #[cfg(unix)]
    fn stop_of_a_restored_session(terminals: usize) {
        use crate::state::kept_tab_store::KeptTab;
        use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

        const PARKED: usize = 8;
        let root = std::env::temp_dir().join(format!(
            "cmux-stop-restored-{terminals}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let session = "stop-restored";
        let options = SurfaceOptions {
            terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
                &root, session,
            )),
            ..SurfaceOptions::default()
        };
        let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
        let mut terminal_ids = Vec::new();
        let mut parked = Vec::new();
        for index in 0..terminals {
            let workspace = mux.create_empty_workspace(None, None, None).unwrap();
            let (id, incarnation) = (terminal_hex("00", index), terminal_hex("10", index));
            let surface = mux
                .seed_running_terminal_with_on_exit_for_test(
                    &id,
                    &incarnation,
                    &workspace.key,
                    TerminalOnExit::Close,
                )
                .unwrap();
            if index < PARKED {
                parked.push(surface);
            }
            terminal_ids.push(id);
        }
        let kept = mux.with_state(|state| {
            parked
                .iter()
                .map(|surface| KeptTab {
                    tab_id: state.resource_indexes.tab_ids[surface].to_string(),
                    ..Default::default()
                })
                .collect::<Vec<_>>()
        });
        mux.commit_kept_tabs(&kept).unwrap();
        for surface in &parked {
            mux.surface(*surface).unwrap().record_process_end_for_test(TerminalExit::now(
                TerminalExitOutcome::Signal { signal: libc::SIGTERM, core_dumped: false },
            ));
            mux.surface_exited(*surface);
        }
        mux.shutdown();
        drop(mux);

        let mux = Mux::open_persistent(session, options, &root).unwrap();
        for terminal_id in &terminal_ids {
            assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Exited, "{terminal_id}");
        }
        mux.with_state(|state| {
            assert!(state.terminal_catalog.is_empty(), "a restored ended terminal has no runtime");
            assert_eq!(state.workspaces.len(), terminals);
        });
        assert_eq!(tab_count(&mux), terminals, "each ended terminal keeps its dead tab");
        terminal_ids.sort();
        let revision = || mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
        let before = revision();

        let began = Instant::now();
        let mut ended = mux.end_all_terminals().unwrap();
        let stop_ms = began.elapsed().as_secs_f64() * 1000.0;

        let revisions = revision() - before;
        eprintln!(
            "stop-restored terminals={terminals} revisions={revisions} stop_ms={stop_ms:.1} \
             ms_per_terminal={:.3}",
            stop_ms / terminals as f64
        );
        ended.sort();
        assert_eq!(ended, terminal_ids);
        assert_eq!(
            revisions, 1,
            "the stop of {terminals} ended terminals must commit one resource revision, got \
             {revisions}"
        );
        for terminal_id in &terminal_ids {
            assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Tombstoned);
        }
        assert_eq!(tab_count(&mux), 0, "each dead tab is gone");
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), terminals, "emptied workspaces stay");
            assert!(state.surfaces.is_empty());
        });
        assert_eq!(mux.terminal_host_closes.pending(), 0);
        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(root);
    }

    /// The per-terminal close rebuilt and committed the whole session once
    /// for each ended terminal with no runtime: 66.5 s to stop the person's
    /// session (DAEMON LISTS STOP 800, 2026-11-10), 2.1 s at 60 workspaces.
    #[cfg(unix)]
    #[test]
    fn stop_of_a_restored_session_is_one_commit() {
        stop_of_a_restored_session(60);
    }

    /// The same at the person's session size.
    #[cfg(unix)]
    #[test]
    #[ignore = "826 terminals take minutes to make; run with --include-ignored"]
    fn stop_of_a_restored_session_is_one_commit_at_826() {
        stop_of_a_restored_session(826);
    }
}
