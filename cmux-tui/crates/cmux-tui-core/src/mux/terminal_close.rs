//! Terminal resolution and close: resolve by public id or host id, guarded terminal close, failed hosted attachments, and discovered host termination.

use super::*;

impl Mux {
    /// Resolve a terminal identity to its durable record and one live view
    /// placement. A catalog-owned terminal with zero views resolves
    /// successfully with a null surface. This is lookup-only and never creates
    /// a replacement shell.
    ///
    /// Either identity a client can hold is accepted: the process-stable
    /// terminal host UUID, or the public `term_…` resource id every resource
    /// command reports (with or without its prefix). A public id maps through
    /// the registry, including after close, so a tombstone still answers.
    /// Clients such as the Mac app only ever hold public ids; validating them
    /// as host ids answered `invalid_terminal_id` and left a detached
    /// terminal unresolvable by construction (#12362).
    pub fn resolve_terminal(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalResolution>> {
        let (terminal, terminal_revision) = {
            let registry = self.workspace_registry.lock().unwrap();
            let Some(host_id) = Self::resolve_terminal_host_id(&registry, terminal_id)? else {
                return Ok(None);
            };
            (registry.terminal_record(&host_id)?, registry.terminal_revision()?)
        };
        let Some(terminal) = terminal else {
            return Ok(None);
        };
        let state = self.state.lock().unwrap();
        let surface = self
            .catalog_terminal_by_host(&state, &terminal.terminal_id)?
            .and_then(|runtime| terminal_placement_for_runtime(&state, &runtime));
        Ok(Some(TerminalResolution { surface, terminal, terminal_revision }))
    }

    /// The host id behind a resolver input, or `None` when no registered
    /// terminal carries that identity. A UUIDv4-shaped value is tried as a host
    /// id first; about one public id in 64 has that shape by chance, so on a
    /// miss it is retried as a public id before being reported unknown.
    pub(super) fn resolve_terminal_host_id(
        registry: &WorkspaceRegistry,
        terminal_id: &str,
    ) -> anyhow::Result<Option<String>> {
        let payload = terminal_id.strip_prefix("term_").unwrap_or(terminal_id);
        let is_hex = payload.len() == crate::terminal_host::TERMINAL_ID_LEN * 2
            && payload.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'));
        anyhow::ensure!(is_hex, "invalid_terminal_id");
        if !terminal_id.starts_with("term_")
            && TerminalId::from_hex(payload).is_some()
            && registry.terminal_record(payload)?.is_some()
        {
            return Ok(Some(payload.to_string()));
        }
        let public_id = TerminalPublicId::parse(format!("term_{payload}"))?;
        registry.terminal_host_id(&public_id)
    }

    /// Atomically resolve, incarnation-check, and remove a hosted terminal by
    /// process-stable identity. The host is terminated only after the state
    /// lock has made the removal authoritative for this daemon generation.
    /// Tests only: production closes name their mutation (and actor) with
    /// [`Self::close_terminal_with_mutation`] (P8 landing 3b).
    #[cfg(test)]
    pub(crate) fn close_terminal(
        &self,
        terminal_id: &str,
        terminal_incarnation: &str,
    ) -> anyhow::Result<TerminalCloseResult> {
        self.close_terminal_with_mutation(
            terminal_id,
            Some(terminal_incarnation),
            None,
            None,
            &WorkspaceMutation::daemon_local("cmux-tui"),
        )
    }

    pub fn close_terminal_with_mutation(
        &self,
        terminal_id: &str,
        terminal_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<TerminalCloseResult> {
        self.close_terminal_guarded(
            terminal_id,
            terminal_incarnation,
            expected_generation,
            expected_revision,
            mutation,
            TerminalCloseGuard::None,
        )
    }

    /// Close a hosted terminal after checking `guard` under the registry
    /// lock, which serializes every placement commit. A failed guard returns
    /// [`TerminalCloseGuardFailed`] and changes nothing.
    pub(crate) fn close_terminal_guarded(
        &self,
        terminal_id: &str,
        terminal_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        guard: TerminalCloseGuard,
    ) -> anyhow::Result<TerminalCloseResult> {
        validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        if let Some(incarnation) = terminal_incarnation {
            validate_terminal_hex(incarnation, "invalid_terminal_incarnation")?;
        }
        if let Some(result) = self.commit_legacy_terminal_close(
            terminal_id,
            terminal_incarnation,
            expected_generation,
            expected_revision,
            mutation,
            guard,
        )? {
            return Ok(result);
        }
        let (commit, terminal_incarnation, public_id, notify_public_id) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            if guard == TerminalCloseGuard::UnplacedAndNotKept {
                let placed = {
                    let state = self.state.lock().unwrap();
                    state.surfaces.values().any(|surface| {
                        self.resource_terminal_host_identity(surface)
                            .is_some_and(|identity| identity.terminal_id == terminal_id)
                    })
                };
                if placed || registry.terminal_keep(terminal_id)? {
                    return Err(TerminalCloseGuardFailed.into());
                }
            }
            let public_id = registry.terminal_resource_id(terminal_id)?;
            let commit = registry.close_terminal(
                mutation,
                expected_generation,
                expected_revision,
                terminal_id,
                terminal_incarnation,
            )?;
            let newly_closed =
                !commit.replayed && !commit.result["already_closed"].as_bool().unwrap_or(false);
            if newly_closed {
                self.emit_terminal_registry_changed(&registry, commit.revision);
            }
            let incarnation =
                registry.terminal_record(terminal_id)?.and_then(|terminal| terminal.incarnation);
            (commit, incarnation, public_id.clone(), newly_closed.then_some(public_id).flatten())
        };
        self.notify_terminal_exit_waiters(notify_public_id);
        let (target, removed, runtime, changed_screens, empty_revision) = {
            let mut state = self.state.lock().unwrap();
            let catalog_public_id = public_id.or_else(|| {
                state.terminal_catalog.iter().find_map(|(public_id, surface)| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                        .then(|| public_id.clone())
                })
            });
            let runtime = catalog_public_id
                .as_ref()
                .and_then(|public_id| state.terminal_catalog.get(public_id))
                .cloned();
            // The durable close has committed. From this point cleanup must
            // finish even if an in-memory host incarnation was stale; leaving
            // a live runtime behind would contradict the terminal tombstone.
            let content_id = catalog_public_id.map(ContentPublicId::Terminal);
            let mut targets = content_id
                .as_ref()
                .map(|content_id| state.placements_of_content(content_id).to_vec())
                .unwrap_or_default();
            if targets.is_empty() {
                targets.extend(state.surfaces.iter().filter_map(|(surface_id, surface)| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                        .then_some(*surface_id)
                }));
            }
            let target = targets.first().copied();
            let changed_screens = unique_screen_ids(
                targets.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
            );
            let removed = if let Some(runtime) = runtime.as_ref() {
                remove_terminal_runtime_from_state(self, &mut state, runtime).0
            } else {
                let mut removed = Vec::with_capacity(targets.len());
                let mut split_index_dirty = false;
                for target in targets {
                    let (surface, topology_changed) = remove_surface(self, &mut state, target);
                    split_index_dirty |= topology_changed;
                    if let Some(surface) = surface {
                        removed.push(surface);
                    }
                }
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                removed
            };
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            (target, removed, runtime, changed_screens, empty_revision)
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
        }
        let had_runtime = runtime.is_some();
        if let Some(runtime) = runtime {
            self.purge_terminal_runtime_side_tables(&runtime);
            self.terminate_terminal_runtime(&runtime);
        }
        if target.is_some() {
            self.emit(MuxEvent::TreeChanged);
        }
        for screen in changed_screens {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        if !had_runtime {
            self.terminate_discovered_terminal_host(terminal_id, terminal_incarnation.as_deref());
        }
        self.emit_empty_if_current(empty_revision);
        Ok(TerminalCloseResult {
            surface: target,
            terminal_id: terminal_id.to_string(),
            terminal_incarnation,
            already_closed: commit.result["already_closed"].as_bool().unwrap_or(commit.replayed),
            terminal_revision: commit.revision,
        })
    }

    /// A host can become Running before its topology binding is built. Keep
    /// the durable lifecycle transition ahead of in-memory removal so a crash
    /// at any point cannot resurrect an unbound Running terminal on restart.
    pub(super) fn fail_hosted_terminal_attachment(
        &self,
        surface: &Arc<Surface>,
        _operation: &str,
        reason: &str,
    ) -> anyhow::Result<()> {
        let Some(identity) = self.resource_terminal_host_identity(surface) else {
            let removed = {
                let mut state = self.state.lock().unwrap();
                remove_terminal_runtime_from_state(self, &mut state, surface).0
            };
            for placement in removed {
                self.purge_surface_side_tables(placement.id);
            }
            self.purge_terminal_runtime_side_tables(surface);
            if !surface.is_dead() {
                surface.kill();
            }
            return Ok(());
        };
        self.persist_terminal_exit(
            &identity.terminal_id,
            Some(&identity.incarnation),
            &TerminalEnd::launch_failed(reason),
        )?;
        let removed = {
            let mut state = self.state.lock().unwrap();
            remove_terminal_runtime_from_state(self, &mut state, surface).0
        };
        for placement in removed {
            self.purge_surface_side_tables(placement.id);
        }
        self.purge_terminal_runtime_side_tables(surface);
        if !surface.is_dead() {
            surface.kill();
        }
        Ok(())
    }

    pub(crate) fn terminate_discovered_terminal_host(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
    ) {
        #[cfg(unix)]
        {
            self.clear_pending_terminal(terminal_id);
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            let Some(root) = root else { return };
            terminate_discovered_terminal_host_in(&root, terminal_id, incarnation);
        }
        #[cfg(not(unix))]
        let _ = (terminal_id, incarnation);
    }
}
