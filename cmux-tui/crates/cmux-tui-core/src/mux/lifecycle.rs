//! Mux lifecycle: side-table purges on close, shutdown and journal finalization, server readiness, daemon handoff and shutdown requests, surface options and machine usage.

use super::*;

impl Mux {
    /// Drop per-surface metadata for a surface that has left the tree.
    /// `SurfaceId` is monotonic, so without this every closed tab would
    /// leak an entry forever and `list-agents` would keep reporting dead
    /// surfaces as live agents.
    pub(super) fn purge_surface_side_tables(&self, surface: SurfaceId) {
        let lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        sizing.surfaces.remove(&surface);
        sizing.report_order.retain(|(reported_surface, _), _| *reported_surface != surface);
        sizing.policies.remove(&surface);
        sizing.terminal_runtime_by_placement.remove(&surface);
        // Views of a closed placement leave their runtime's engine; the
        // engine itself lives while another placement still shows it.
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        for runtime in runtimes {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            if !entry.placements.remove(&surface) {
                continue;
            }
            let departed = entry
                .members
                .iter()
                .filter(|(_, member)| member.placement == surface)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let mut changed = false;
            for id in departed {
                entry.members.remove(&id);
                changed |= entry.engine.detach(&id);
            }
            if entry.placements.is_empty() {
                sizing.terminal_sizing.remove(&runtime);
                sizing.terminal_size_policies.remove(&runtime);
            } else {
                sizing.note_size_state(runtime, changed);
                self.refresh_host_policy_locked(&mut sizing, runtime);
                self.apply_terminal_grid(&sizing, runtime);
            }
        }
        drop(sizing);
        self.publish_size_states();
        self.control_clients.forget_surface_attach_epoch(surface);
        drop(lifecycle);
        // After the sizing lifecycle lock: the feed lock comes before the
        // registry and state locks, never after another lock.
        self.close_placement_feed_items(surface);
    }

    pub(super) fn purge_terminal_side_tables(&self, terminal_id: &TerminalPublicId) {
        let pending_cleanup = {
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.purge_agent_hook_pending_for_terminal(terminal_id)
        };
        if pending_cleanup.is_err() {
            self.report_internal_diagnostic("terminal agent hook cleanup deferred");
        }
        // The registry guard is dropped before acquiring the fence guard.
        self.agent_hook_fences.lock().unwrap().remove(terminal_id);
        self.agent_hook_children.lock().unwrap_or_else(|e| e.into_inner()).remove(terminal_id);
        self.agent_records.lock().unwrap().remove(terminal_id);
        self.agent_presence.lock().unwrap().remove(terminal_id);
        self.agent_prompts.lock().unwrap().forget(terminal_id);
        self.output_store.forget(terminal_id);
        // Terminal lifecycle does not flow through `agent.*` journal events
        // yet, so a closed terminal retires its roster entry explicitly.
        // The snapshot persists so a restart does not resurrect the entry.
        // The fold lock orders this save with `fold_agent_roster`'s, so
        // neither writes an older snapshot over the other's. The write takes
        // the registry connection alone, never the workspace registry lock,
        // so state commits do not wait behind it (issue 23038).
        let fold = self.agent_roster_fold.lock().unwrap();
        let retired = {
            let mut host = self.agent_roster.lock().unwrap();
            let retired = host.roster.retire_terminal(terminal_id.as_str());
            retired.then(|| (host.cursor, host.roster.snapshot().to_string()))
        };
        if let Some((cursor, snapshot)) = retired
            && let Err(error) = self.registry_connection.put_journal_reducer_state(
                crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
                crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
                cursor,
                &snapshot,
            )
        {
            eprintln!("cmux-tui: persisting the agent roster snapshot failed: {error}");
        }
        drop(fold);
        // Read the terminal's open local items and drop its ring together.
        self.close_terminal_feed_items(terminal_id);
    }

    pub(super) fn purge_terminal_runtime_side_tables(&self, runtime: &Surface) {
        if let Some(runtime_id) = runtime.terminal_runtime_id() {
            self.reserved_in_process_terminals.lock().unwrap().remove(&runtime_id);
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let mut pending = self.pending_cell_pixels.lock().unwrap();
            if let Some(update) = pending.as_mut() {
                update.failures.remove(&runtime_id);
                if update.failures.is_empty() {
                    let target = update.target;
                    *self.cell_pixels.lock().unwrap() = target;
                    *pending = None;
                }
            }
        }
        if let Some(terminal_id) = runtime.terminal_public_id() {
            #[cfg(unix)]
            self.image_pastes.close_terminal(terminal_id.as_str());
            self.purge_terminal_side_tables(terminal_id);
        }
    }

    pub fn shutdown(&self) {
        let screen_checkpoint = self.wants_shutdown_checkpoint();
        self.shutting_down.store(true, Ordering::Release);
        // An in-flight maintenance tick must not delay the rest of shutdown.
        self.stop_journal_maintenance();
        self.stop_output_cleanup();
        #[cfg(unix)]
        self.stop_agent_chat_notices();
        self.begin_session_shutdown();
        self.terminal_respawns.wake_all();
        self.startup_adoption_gate.wake_all();
        // Hosts of closed terminals were already asked to exit; give them
        // their close deadline so this owner acknowledges their exits.
        if !self.wait_for_terminal_host_closes(
            TERMINAL_HOST_CLOSE_WAIT,
            Instant::now() + TERMINAL_HOST_CLOSE_WAIT,
        ) {
            eprintln!("cmux-tui: closed terminal hosts did not exit before shutdown");
        }
        self.config_reload_changed.notify_all();
        self.journal_plugin.shutdown();
        self.journal_kernel.wake_waiters();
        let hook_deadline = Instant::now() + crate::journal_hooks::SHUTDOWN_WAIT;
        if !self.journal_hook_runtime.shutdown_until(hook_deadline) {
            eprintln!("cmux-tui: journal hook workers did not stop before the shutdown deadline");
        }
        self.finalize_terminal_journal("shutdown", screen_checkpoint);
        self.journal_kernel.shutdown();
        if let Some(runtime) = self.browser_runtime.lock().unwrap().take() {
            runtime.shutdown();
        }
    }

    /// The owner's last step after `shutdown`: free the session for the
    /// next owner, the writer lease and then the session guard a new owner
    /// takes first, then remove the control socket. `server stop` reports a
    /// stop when this owner's connection closes, which is the process exit;
    /// the kernel could close that socket before these lock files, so an
    /// owner started right after the stop found the session still owned
    /// (feed_local, "detached session owner did not become ready"). The
    /// leases go first: this owner keeps listening until it exits, so no new
    /// owner binds the socket before it is removed here.
    pub fn release_ownership(&self, socket_path: &Path) {
        {
            let mut registry = self.workspace_registry.lock().unwrap_or_else(|e| e.into_inner());
            drop(registry.lease.take());
            drop(registry.session_guard.take());
        }
        crate::server::cleanup(socket_path);
    }

    /// Stop the terminal readers and the journal writer; with
    /// `screen_checkpoint`, checkpoint the terminal screens in between.
    pub(super) fn finalize_terminal_journal(&self, context: &str, screen_checkpoint: bool) {
        if self.journal_ingress.is_closed() {
            self.output_store.shutdown(self);
            if let Err(error) = self.journal_ingress.close_and_join() {
                eprintln!("cmux-tui: await session journal writer during {context}: {error:#}");
            }
            return;
        }
        // Finalization can run while unwinding from a failed operation. A
        // panic while holding the state lock poisons it, but cleanup must not
        // panic again (for example, when a test simulates a daemon crash).
        let surfaces =
            unique_surface_runtimes(&self.state.lock().unwrap_or_else(PoisonError::into_inner));
        let terminal_reader_deadline = Instant::now() + TERMINAL_READER_SHUTDOWN_TIMEOUT;
        let mut terminal_gaps = surfaces
            .iter()
            .filter_map(|surface| surface.shutdown_for_daemon(terminal_reader_deadline))
            .collect::<Vec<_>>();
        for surface in surfaces {
            terminal_gaps.extend(surface.finish_terminal_reader(terminal_reader_deadline));
        }
        if self.journal_ingress.is_current_writer_thread() {
            // The readers stopped: the store's last write is safe here too.
            self.output_store.shutdown(self);
            if !terminal_gaps.is_empty() {
                eprintln!(
                    "cmux-tui: {context} on the session journal writer could not durably record \
                     {} terminal output gap(s)",
                    terminal_gaps.len()
                );
            }
            if let Err(error) = self.journal_ingress.close_and_join() {
                eprintln!("cmux-tui: stop session journal writer during {context}: {error:#}");
            }
            return;
        }
        // Output is not journaled (output_store.rs): a reader that missed
        // the shutdown grace only costs the output store its last bytes.
        for gap in &terminal_gaps {
            eprintln!(
                "cmux-tui: terminal {} ({}) reader did not drain during {context}: {}",
                gap.terminal_id, gap.generation, gap.reason
            );
        }
        // Readers are stopped and every terminal is still alive: write the
        // output store's last snapshots and segment frames.
        self.output_store.shutdown(self);
        // Each terminal reader has drained or its journal capture gate has
        // closed. An update that exceeded the extra active-update grace has a
        // durable gap above. Fence the terminal ingress lane while this Mux
        // still owns the registry; the closed gate prevents a timed-out reader
        // from inserting output after the barrier.
        if let Err(error) = self.flush_terminal_journal() {
            eprintln!("cmux-tui: flush terminal journal during {context}: {error:#}");
        }
        if screen_checkpoint {
            self.capture_shutdown_checkpoint();
        }
        if let Err(error) = self.journal_ingress.close_and_join() {
            eprintln!("cmux-tui: stop session journal writer during {context}: {error:#}");
        }
    }

    /// Publish that every owner needed by canonical server lifecycle commands
    /// is installed. Ordinary control clients may connect before this point.
    pub fn mark_server_lifecycle_ready(&self) {
        self.server_lifecycle_ready.store(true, Ordering::Release);
        // The first terminal must not pay for the host executable's install
        // (cx-b4sjc); unit tests start no daemon and install nothing.
        #[cfg(all(unix, not(test)))]
        crate::host_exe::prepare_in_background();
        #[cfg(all(unix, not(test)))]
        crate::holder_runtime::prepare_in_background();
    }

    pub fn server_lifecycle_ready(&self) -> bool {
        self.server_lifecycle_ready.load(Ordering::Acquire)
    }

    /// Validate the target daemon and atomically reserve its handoff. Unless
    /// forced, this proves no other native browser owns the mux. New control
    /// clients and native-browser ownership changes are rejected until the
    /// reservation is cancelled or shutdown completes.
    pub(crate) fn begin_daemon_handoff(
        &self,
        requesting_client: u64,
        request: DaemonHandoffRequest,
    ) -> anyhow::Result<DaemonIdentity> {
        let (_, generation) = self.registry_identity();
        let actual_identity = DaemonIdentity { pid: std::process::id(), generation };
        if let Some(expected_identity) = &request.expected_identity {
            if expected_identity.pid != actual_identity.pid {
                anyhow::bail!("daemon pid changed; identify again");
            }
            if expected_identity.generation != actual_identity.generation {
                anyhow::bail!("daemon generation changed; identify again");
            }
        }
        self.control_clients.begin_daemon_handoff(requesting_client, request.force)?;
        Ok(actual_identity)
    }

    pub(crate) fn commit_daemon_handoff_after_ack(
        &self,
        requesting_client: u64,
        acknowledge: impl FnOnce() -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        self.control_clients.commit_daemon_handoff_after_ack(requesting_client, acknowledge)
    }

    pub(crate) fn daemon_handoff_in_progress(&self) -> bool {
        self.control_clients.daemon_handoff_in_progress()
    }

    /// The handoff was acknowledged to its requester; it can no longer be
    /// cancelled.
    pub(crate) fn daemon_handoff_committed(&self) -> bool {
        self.control_clients.daemon_handoff_committed()
    }

    pub fn cancel_daemon_handoff(&self, requesting_client: u64) {
        self.control_clients.cancel_daemon_handoff(requesting_client);
    }

    /// Ask the owning frontend loop to leave through the normal daemon
    /// shutdown path. Durable terminal hosts are disconnected by `shutdown`
    /// and remain available for the replacement daemon to adopt.
    pub fn request_daemon_shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        #[cfg(unix)]
        self.stop_agent_chat_notices();
        self.begin_session_shutdown();
        self.terminal_respawns.wake_all();
        self.startup_adoption_gate.wake_all();
        // The journal hook dispatcher waits on the shared journal.
        self.journal_kernel.wake_waiters();
        if let Some(waker) = self.daemon_shutdown_waker.lock().unwrap().as_ref() {
            waker();
        }
    }

    /// Install the callback that `request_daemon_shutdown` runs after it
    /// sets the flag (the headless owner loop's wake).
    pub fn set_daemon_shutdown_waker(&self, waker: impl Fn() + Send + Sync + 'static) {
        *self.daemon_shutdown_waker.lock().unwrap() = Some(Box::new(waker));
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        self.shutting_down.load(Ordering::Acquire)
    }

    /// Update options used for future surface/browser launches.
    pub fn update_surface_options(&self, update: impl FnOnce(&mut SurfaceOptions)) {
        let mut options = self.surface_options.lock().unwrap();
        update(&mut options);
    }

    /// The latest machine-level model spend readout, or `None` when the
    /// daemon has no usable readout.
    pub fn machine_usage(&self) -> Option<MachineUsage> {
        self.machine_usage.lock().unwrap().clone()
    }

    /// Replace the machine-level spend readout. Subscribers are told only
    /// when the readout actually changed, so a steady poll stays silent.
    pub fn set_machine_usage(&self, usage: Option<MachineUsage>) {
        {
            let mut current = self.machine_usage.lock().unwrap();
            if *current == usage {
                return;
            }
            *current = usage.clone();
        }
        self.emit(MuxEvent::MachineUsageChanged(usage));
    }
}
