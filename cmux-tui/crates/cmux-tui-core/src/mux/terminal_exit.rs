//! Terminal exits (invariant 3 of plans/cmux-next/OWNERSHIP-PRINCIPLES.md):
//! the live exit path, the durable exit receipt, the session shutdown
//! classification (`session-shutdown`) and the reconciling detach. Only a
//! process end detaches a terminal's tabs; a host loss keeps them, dead.

use anyhow::Context;
use serde_json::{Value, json};

use super::*;
use crate::terminal_end::TerminalEnd;

impl Mux {
    #[cfg(test)]
    pub(crate) fn persist_terminal_exit_for_test(
        &self,
        terminal_id: &TerminalPublicId,
        exit: &TerminalExit,
    ) -> anyhow::Result<bool> {
        let (host_id, incarnation) = {
            let registry = self.workspace_registry.lock().unwrap();
            let host_id = registry
                .live_terminal_host_id(terminal_id)?
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
            let incarnation =
                registry.terminal_record(&host_id)?.and_then(|terminal| terminal.incarnation);
            (host_id, incarnation)
        };
        self.persist_terminal_exit(
            &host_id,
            incarnation.as_deref(),
            &TerminalEnd::ProcessEnded(exit.clone()),
        )
    }

    /// Test seam: the session shutdown clock reads `now_ms` from now on.
    #[cfg(test)]
    pub(crate) fn set_session_clock_now_for_test(&self, now_ms: u64) {
        self.session_shutdown.set_now_for_test(now_ms);
    }

    /// Test seam: run the deferred exit detaches whose shutdown lead passed.
    #[cfg(test)]
    pub(crate) fn run_due_exit_settles_for_test(&self) {
        self.run_due_exit_settles();
    }

    /// Record, once and durably, when this owner's session began shutting
    /// down, so the next owner classifies signal exits from then on as host
    /// losses (`session-shutdown`). The owner's loop calls it as soon as a
    /// termination signal wakes it, before any teardown.
    pub fn begin_session_shutdown(&self) {
        self.session_shutdown.begin();
    }

    /// Log that this owner got termination signal `signal` from `sender_pid`
    /// (cx-0tgl LA): `"event":"daemon_signal"` in `terminal-losses.jsonl`,
    /// with the sender's name and parent. Best effort.
    #[cfg(unix)]
    pub fn record_daemon_signal(&self, signal: i32, sender_pid: i32, sender_uid: Option<u32>) {
        let root = self
            .surface_options
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_host_root
            .clone();
        if let Some(root) = root {
            crate::terminal_loss_log::record_daemon_signal(
                &root,
                signal,
                (sender_pid, sender_uid),
                self.started_at.elapsed().as_millis(),
            );
        }
    }

    /// Called by a surface's reader thread when its child exits. Hosted
    /// terminals preserve a durable exit receipt while all views detach;
    /// local surfaces are removed immediately.
    pub fn surface_exited(self: &Arc<Self>, id: SurfaceId) {
        if self.sidebar_surface_exited(id) {
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        if let Some(surface) = self.surface(id)
            && let Some(identity) = self.resource_terminal_host_identity(&surface)
        {
            if let Err(error) = self.mark_hosted_surface_exited(&surface, "host-exited") {
                self.emit(MuxEvent::Status(format!(
                    "could not persist terminal {id} exit: {error}"
                )));
                self.schedule_exited_terminal_detach(identity.terminal_id, &surface, "host-exited");
                return;
            }
            return;
        }
        self.remove_surface_after_registry(id);
        self.emit(MuxEvent::SurfaceExited(id));
    }

    /// Exit persistence is first-writer-wins. A transient SQLite failure
    /// leaves the old topology intact and retries through a weak owner until
    /// the atomic lifecycle-and-detach commit succeeds or shutdown begins.
    pub(super) fn schedule_exited_terminal_detach(
        self: &Arc<Self>,
        terminal_id: String,
        surface: &Arc<Surface>,
        reason: &'static str,
    ) {
        let Some(detach_lease) = self.terminal_exit_detaches.acquire(terminal_id.clone()) else {
            return;
        };
        let cleanup_id = terminal_id.clone();
        let mux = Arc::downgrade(self);
        let surface = Arc::downgrade(surface);
        let spawn_result = std::thread::Builder::new()
            .name(format!("terminal-exit-detach-{terminal_id}"))
            .spawn(move || {
                let _detach_lease = detach_lease;
                let mut delay = Duration::from_millis(25);
                loop {
                    std::thread::sleep(delay);
                    let Some(mux) = mux.upgrade() else { break };
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    let reconciled = surface
                        .upgrade()
                        .map(|surface| mux.mark_hosted_surface_exited(&surface, reason))
                        .unwrap_or_else(|| {
                            mux.detach_exited_terminal_topology(&terminal_id).map(drop)
                        });
                    match reconciled {
                        Ok(()) => break,
                        Err(error) => {
                            eprintln!(
                                "cmux-tui: could not detach exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                        }
                    }
                }
            });
        if let Err(error) = spawn_result {
            eprintln!(
                "cmux-tui: could not schedule exited terminal {cleanup_id} detach: {error:#}"
            );
        }
    }

    pub(super) fn mark_hosted_surface_exited(
        &self,
        surface: &Arc<Surface>,
        reason: &str,
    ) -> anyhow::Result<()> {
        let Some(identity) = self.resource_terminal_host_identity(surface) else {
            return Ok(());
        };
        // Output stays on the bounded asynchronous ingress path. Exit is the
        // one terminal transition that fences it, preserving byte order and
        // full topology subjects before the atomic detach transaction.
        self.flush_terminal_journal()?;
        let end = surface.terminal_end().unwrap_or_else(|| TerminalEnd::host_lost(reason));
        self.persist_terminal_exit(&identity.terminal_id, Some(&identity.incarnation), &end)?;
        self.detach_exited_terminal_topology(&identity.terminal_id)?;
        #[cfg(unix)]
        if let Some((path, expected)) = surface.terminal_host_exit_sidecar() {
            crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(&path, &expected)?;
        }
        Ok(())
    }

    /// Commit terminal lifecycle, topology detach, and exactly one public
    /// event in one registry transaction. Callers may observe the same exit
    /// through the live frame, sidecar recovery, and dead-host reconciliation;
    /// the first commit is the latch and all later observations are no-ops.
    pub(super) fn persist_terminal_exit(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        end: &TerminalEnd,
    ) -> anyhow::Result<bool> {
        // A signal exit during a session shutdown is a host loss. A live
        // signal exit within the shutdown lead is not final yet: it commits
        // without a detach, which waits out the lead (logout race).
        let settled = self.session_shutdown.settle(end.clone());
        let settle_until_ms = settled.pending_until_ms();
        let end = settled.end();
        let exit = end.exit();
        // Best-effort exit snapshot: capture the terminal's final state as
        // one bounded, compressed vt-replay blob while the runtime VT is
        // still alive, so terminal.output_read stays answerable after its
        // output records become prunable. Capture and store live AROUND the
        // first-writer-wins latch below and never affect its outcome: any
        // failure leaves the exit commit untouched and readers fall back to
        // the retained terminal.output records.
        let exit_replay = incarnation
            .and_then(|generation| self.capture_terminal_exit_replay(terminal_id, generation));
        let mut registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
        let public_terminal_id = registry.terminal_resource_id(terminal_id)?;
        if !matches!(terminal.lifecycle, TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned)
            && public_terminal_id.is_none()
        {
            // One-release compatibility for pre-resource terminal rows. They
            // have no public identity to emit, but still retain the exact
            // outcome in the terminal timeline and remain first-writer wins.
            let resource_revision = registry.resource_revision()?;
            let (_, terminal_revision) = commit_terminal_lifecycle(
                &mut registry,
                "terminal-exited",
                "terminal-host-exited",
                terminal_id,
                TerminalLifecycle::Exited,
                incarnation,
                Some(serde_json::json!({
                    "outcome": &exit.outcome,
                    "exited_at": exit.exited_at_ms.to_string(),
                    "revision": resource_revision.to_string(),
                })),
            )?;
            self.emit_terminal_registry_changed(&registry, terminal_revision);
            return Ok(true);
        }
        let mut state = self.state.lock().unwrap();
        let terminal_snapshot = if matches!(
            terminal.lifecycle,
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
        ) {
            Value::Null
        } else {
            terminal_exit_snapshot_in_state(&registry, &state, terminal_id)?
        };
        // The keep policy commits the identical exit latch but leaves the
        // views and the live screen surface in place. This only holds while
        // the runtime terminal emulator is alive: after a daemon restart the
        // in-memory VT is gone, so reconciliation degrades a kept-exited
        // terminal to the normal detach below.
        // Tabs the workspace store keeps (`kept_tabs`, keep-layout) stay
        // regardless of the runtime: a host's exit never removes them.
        let kept_by_store = match public_terminal_id.as_ref() {
            Some(public_id) => Self::terminal_tabs_kept_locked(&registry, &state, public_id)?,
            None => false,
        };
        let keep_live_views = kept_by_store
            || (terminal.on_exit == TerminalOnExit::Keep
                && public_terminal_id
                    .as_ref()
                    .is_some_and(|public_id| state.terminal_catalog.contains_key(public_id)));
        // Invariant 3: only a process end detaches views. A host loss or a
        // failed launch commits the same exit latch and leaves every tab in
        // place, dead until a respawn (L2, `terminal_respawn.rs`) replaces
        // the shell.
        let detach_proof = end.detach_proof();
        let detach_projection = match (detach_proof, public_terminal_id.as_ref()) {
            _ if matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            ) || keep_live_views
                || settle_until_ms.is_some() =>
            {
                None
            }
            (Some(proof), Some(public_terminal_id)) => self
                .terminal_exit_detach_projection_locked(
                    proof,
                    &registry,
                    &state,
                    terminal_id,
                    public_terminal_id,
                )?,
            _ => None,
        };
        let mut terminal_snapshot = terminal_snapshot;
        if detach_projection.is_some() {
            // The same revision deletes every view of this terminal, so the
            // exited row must carry the detached tab edge. A full snapshot at
            // this revision derives `tab_id: null, tab_ids: []` from topology;
            // a delta that disagrees leaves clients with a graph that no
            // snapshot at the same cursor can confirm.
            terminal_snapshot["tab_id"] = Value::Null;
            terminal_snapshot["tab_ids"] = serde_json::json!([]);
        }
        let topology = detach_projection.as_ref().map(|projection| {
            (&projection.patch, &projection.changes, projection.workspace_close.as_ref())
        });
        let (_, terminal_revision, resource_revision, replayed, workspace_revision) = registry
            .commit_terminal_exit(terminal_id, incarnation, exit, terminal_snapshot, topology)?;
        let mut detach_effects = None;
        if !replayed {
            if let Some(projection) = detach_projection {
                detach_effects =
                    Some(projection.install(&mut state, resource_revision, workspace_revision));
            } else {
                state.resource_revision = resource_revision;
            }
            self.emit_terminal_registry_changed(&registry, terminal_revision);
        }
        drop(state);
        drop(registry);
        #[cfg(unix)]
        if let Some(terminal_id) = &public_terminal_id {
            // Replay is a recovery path: the durable exit may have committed
            // before the previous cleanup attempt completed.
            self.image_pastes.close_terminal(terminal_id.as_str());
        }
        if !replayed {
            if let Some((snapshot_terminal_id, generation, blob)) = exit_replay {
                // Best-effort: a snapshot store failure must not disturb the
                // exit latch that already committed above.
                if let Err(error) = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .put_terminal_exit_snapshot(snapshot_terminal_id.as_str(), &generation, &blob)
                {
                    eprintln!(
                        "cmux-tui: could not store the exit snapshot for terminal \
                         {snapshot_terminal_id}: {error:#}"
                    );
                }
            }
            // A host loss is logged once, with the signals its host recorded
            // (cx-6so.49); best effort, after the exit latch.
            #[cfg(unix)]
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            if let Some(root) = root
                && let Some(cause) = crate::terminal_loss_log::record_host_loss(
                    &root.join(format!("{terminal_id}.json")),
                    terminal_id,
                    incarnation,
                    end,
                )
                && let Some(public_id) = public_terminal_id.as_ref()
            {
                self.record_terminal_loss_cause(public_id.as_str(), cause);
            }
            // cx-6so.49 L2: a placed terminal whose shell was lost with its
            // host gets a new shell under the same id (it decides and marks
            // the tabs respawning before the tree push below).
            if settle_until_ms.is_none() {
                self.schedule_terminal_respawn(terminal_id, incarnation, end);
            }
            if let Some(public_terminal_id) = public_terminal_id.as_ref() {
                self.terminal_exit_waiters.notify(public_terminal_id);
            }
            self.publish_resource_event();
            if let Some(effects) = detach_effects {
                self.finish_terminal_exit_detach(effects);
            } else if detach_proof.is_none() || settle_until_ms.is_some() {
                // The tabs stay and now show the terminal dead.
                self.emit(MuxEvent::TreeChanged);
            }
        }
        if let Some(until_ms) = settle_until_ms {
            self.schedule_exit_settle(terminal_id, until_ms);
        }
        Ok(!replayed)
    }

    /// Reconcile a lifecycle row that was committed before topology detach was
    /// introduced, or whose daemon stopped between those two older commits.
    /// The durable terminal receipt remains queryable after every view leaves.
    pub(super) fn detach_exited_terminal_topology(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<bool> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .with_context(|| format!("unknown terminal {terminal_id}"))?;
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            return Ok(false);
        }
        if terminal.lifecycle != TerminalLifecycle::Exited {
            // Nothing to detach: a respawn (L2) already reopened the row the
            // caller saw exited.
            return Ok(false);
        }
        // Invariant 3: a receipt of a host loss (outcome unknown) keeps the
        // tabs, dead; only a recorded exit status or signal detaches them,
        // and a signal during a session shutdown counts as a host loss. A
        // signal exit within the shutdown lead waits until the lead passed
        // (logout race) and is classified again then.
        let recorded = TerminalEnd::from_receipt(terminal.exit.as_ref());
        let settled = self.session_shutdown.settle(recorded.clone());
        if let Some(until_ms) = settled.pending_until_ms() {
            self.schedule_exit_settle(terminal_id, until_ms);
            return Ok(false);
        }
        if let (TerminalEnd::ProcessEnded(recorded), TerminalEnd::HostLost(lost)) =
            (&recorded, settled.end())
        {
            // The receipt still records the signal (its exit committed within
            // the shutdown lead). Record the host loss in the receipt, so an
            // owner that no longer knows this shutdown window agrees. Best
            // effort: on failure the tab stays dead now and a later owner
            // that still knows the window settles it again.
            let mut state = self.state.lock().unwrap();
            let settled = terminal_exit_snapshot_in_state(&registry, &state, terminal_id).and_then(
                |snapshot| registry.settle_terminal_exit(terminal_id, recorded, lost, snapshot),
            );
            match settled {
                Ok((_, terminal_revision, resource_revision, false)) => {
                    state.resource_revision = resource_revision;
                    self.emit_terminal_registry_changed(&registry, terminal_revision);
                    drop(state);
                    drop(registry);
                    self.publish_resource_event();
                }
                Ok(_) => {}
                Err(error) => eprintln!(
                    "cmux-tui: could not record the session shutdown host loss of terminal \
                     {terminal_id}: {error:#}"
                ),
            }
            return Ok(false);
        }
        let Some(proof) = settled.end().detach_proof() else {
            return Ok(false);
        };
        let Some(terminal_public_id) = registry.terminal_resource_id(terminal_id)? else {
            return Ok(false);
        };
        let mut state = self.state.lock().unwrap();
        // Tabs the workspace store keeps (`kept_tabs`, keep-layout) survive
        // the terminal's exit and owner restarts; a frontend relaunches them.
        if Self::terminal_tabs_kept_locked(&registry, &state, &terminal_public_id)? {
            return Ok(false);
        }
        // A keep-policy terminal retains its views while the runtime screen
        // surface is alive; reconciliation must not force-detach it out from
        // under a live daemon. Without a runtime (a daemon restart dropped
        // the in-memory VT) the kept terminal degrades to the normal detach.
        if terminal.on_exit == TerminalOnExit::Keep
            && state.terminal_catalog.contains_key(&terminal_public_id)
        {
            return Ok(false);
        }
        let Some(projection) = self.terminal_exit_detach_projection_locked(
            proof,
            &registry,
            &state,
            terminal_id,
            &terminal_public_id,
        )?
        else {
            return Ok(false);
        };
        let mutation = WorkspaceMutation::daemon_local("cmux-tui-runtime");
        let fingerprint = json!({
            "operation":"terminal.exit.detach",
            "terminal_id":terminal_id,
            "terminal":terminal_public_id,
            "tabs":projection.tab_ids,
        });
        // A detach that empties a workspace closes it in the same commit
        // (LAST-TAB-CLOSES-WORKSPACE); the topology close commits both.
        let (revision, workspace_revision) = match projection.workspace_close.as_ref() {
            Some(close) => {
                let commit = registry.commit_topology_close(
                    &mutation,
                    "terminal.exit.detach",
                    &fingerprint,
                    None,
                    None,
                    &projection.patch,
                    &json!({}),
                    &projection.changes,
                    &[],
                    Some(close),
                    None,
                    false,
                    None,
                )?;
                (commit.resource.revision, commit.workspace_revision)
            }
            None => {
                let commit = registry.commit_resource_patch(
                    &mutation,
                    "terminal.exit.detach",
                    &fingerprint,
                    None,
                    Some(state.resource_revision),
                    &projection.patch,
                    &json!({}),
                    &projection.changes,
                )?;
                (commit.revision, None)
            }
        };
        let effects = projection.install(&mut state, revision, workspace_revision);
        drop(state);
        drop(registry);
        self.publish_resource_event();
        self.finish_terminal_exit_detach(effects);
        Ok(true)
    }
}
