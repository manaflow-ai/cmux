//! Surface spawning: terminal surfaces in a workspace, sidebar plugin surfaces, and browser surfaces with a resource identity.

use super::*;

impl Mux {
    pub(super) fn spawn_surface_in_workspace(
        self: &Arc<Self>,
        workspace_key: &str,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size, Some(workspace_key), None)
    }

    pub(super) fn spawn_surface_in_workspace_reserved(
        self: &Arc<Self>,
        workspace_key: &str,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
        reservation: TerminalReservationRequest,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size, Some(workspace_key), Some(reservation))
    }

    pub(super) fn persist_terminal_cell_pixel_reconcile_failure(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        error: &anyhow::Error,
    ) -> anyhow::Result<()> {
        let detail = format!("{error:#}");
        eprintln!(
            "cmux-tui: terminal {terminal_id} cell-pixel reconciliation failed before \
             publication: {}",
            detail.escape_debug()
        );
        self.persist_terminal_exit(
            terminal_id,
            incarnation,
            &TerminalEnd::launch_failed("cell-pixel-reconcile-failed"),
        )
        .context("could not persist terminal exit after cell-pixel reconciliation failed")?;
        Ok(())
    }

    pub(super) fn spawn_surface_with(
        self: &Arc<Self>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        workspace_key: Option<&str>,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = self.next_id();
        // `split-client-keys-v1`: the tab id fixed when the creation was prepared.
        let tab_id = reservation.as_ref().and_then(|reservation| reservation.tab_id.clone());
        let reservation_env =
            reservation.as_ref().map(|reservation| reservation.env.as_slice()).unwrap_or_default();
        let (opts, cell_pixels) = self.terminal_spawn_options(cwd, command, size, reservation_env);
        #[cfg(test)]
        if let Some(hook) = self.terminal_spawn_after_cell_pixel_snapshot.lock().unwrap().clone() {
            let unlocked = match self.cell_pixel_lifecycle.try_lock() {
                Ok(lifecycle) => {
                    drop(lifecycle);
                    true
                }
                Err(_) => false,
            };
            hook(unlocked);
        }
        #[cfg(all(test, unix))]
        let use_host_runtime = !self.test_surface_runtime;
        #[cfg(all(not(test), unix))]
        let use_host_runtime = true;
        #[cfg(unix)]
        if let (Some(_), Some(workspace_key), true) =
            (opts.terminal_host_root.as_ref(), workspace_key, use_host_runtime)
        {
            let terminal_id = reservation
                .as_ref()
                .map(|reservation| reservation.terminal_id)
                .map(Ok)
                .unwrap_or_else(TerminalId::random)?;
            let terminal_hex = terminal_id.to_hex();
            // A host launched ahead of this creation for the same reserved
            // id (`terminal_work`): adopt it instead of launching one.
            let prelaunched = self.take_prelaunched_terminal(&terminal_hex);
            let launch_spec = terminal_launch_spec(
                prelaunched.as_ref().map_or(&opts, |prelaunched| prelaunched.launch_opts()),
            );
            let terminal = RegistryTerminal {
                terminal_id: terminal_hex.clone(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec,
                exit: None,
                on_exit: reservation
                    .as_ref()
                    .map(|reservation| reservation.on_exit)
                    .unwrap_or_default(),
            };
            let reserve_replayed = {
                let mut registry = self.workspace_registry.lock().unwrap();
                let (replayed, revision) = if let Some(reservation) = reservation.as_ref() {
                    let commit = registry.commit_terminal(
                        &reservation.mutation,
                        &reservation.fingerprint,
                        reservation.expected_generation.as_deref(),
                        reservation.expected_revision,
                        "terminal-reserved",
                        &terminal,
                        &serde_json::json!({
                            "terminal_id":terminal_hex,
                            "workspace_key":workspace_key,
                            "state":"launching",
                        }),
                    )?;
                    (commit.replayed, commit.revision)
                } else {
                    let revision = commit_terminal_transition(
                        &mut registry,
                        "terminal-reserved",
                        "reserve-terminal",
                        &terminal,
                    )?;
                    (false, revision)
                };
                if !replayed {
                    self.emit_terminal_registry_changed(&registry, revision);
                }
                replayed
            };
            if reserve_replayed {
                anyhow::bail!("terminal_create_replayed");
            }
            let launched =
                prelaunched.as_ref().map_or(&opts, |prelaunched| prelaunched.launch_opts());
            self.record_terminal_relaunch(&terminal_hex, launched);
            let spawned = match prelaunched {
                Some(prelaunched) => Surface::spawn_prelaunched(
                    prelaunched.into_host().with_tab_id(tab_id),
                    Arc::downgrade(self),
                ),
                None => Surface::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
                    id,
                    opts,
                    Arc::downgrade(self),
                    (
                        Some(terminal_id),
                        // Reopen Closed of an archived terminal (ARCHIVE-1).
                        &self.terminal_respawns.take_seed(&terminal_hex).unwrap_or_default(),
                    ),
                    Some(terminal_identity(tab_id)?),
                    crate::surface::PtyLifetime::SessionOwned,
                    cell_pixels,
                ),
            };
            let surface = match spawned {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalEnd::launch_failed(format!("launch-failed: {error}")),
                    );
                    return Err(error);
                }
            };
            let _pending_host_release = PendingTerminalHostRelease(surface.clone());
            let identity = surface
                .terminal_host_identity()
                .ok_or_else(|| anyhow::anyhow!("reserved terminal did not return host identity"))?;
            if identity.terminal_id != terminal_hex {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    None,
                    &TerminalEnd::launch_failed("host-identity-mismatch"),
                );
                surface.kill();
                anyhow::bail!("terminal host changed registry-reserved identity");
            }
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let ready = commit_terminal_lifecycle(
                    &mut registry,
                    "terminal-ready",
                    "terminal-ready",
                    &terminal_hex,
                    TerminalLifecycle::Running,
                    Some(&identity.incarnation),
                    None,
                );
                let (_, ready_revision) = match ready {
                    Ok(ready) => ready,
                    Err(error) => {
                        surface.kill();
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, ready_revision);
            }
            let cell_pixel_lifecycle =
                match self.reconcile_surface_cell_pixels_for_publish(&surface) {
                    Ok(lifecycle) => lifecycle,
                    Err(error) => {
                        let persistence = self.persist_terminal_cell_pixel_reconcile_failure(
                            &terminal_hex,
                            Some(&identity.incarnation),
                            &error,
                        );
                        surface.kill();
                        persistence?;
                        return Err(error);
                    }
                };
            let insert_result =
                insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
            drop(cell_pixel_lifecycle);
            if let Err(error) = insert_result {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    Some(&identity.incarnation),
                    &TerminalEnd::launch_failed("surface-insert-failed"),
                );
                surface.kill();
                return Err(error);
            }
            // Deprecated recovery mirror only; SQLite is placement authority.
            let _ = surface.persist_host_workspace(workspace_key);
            return Ok(surface);
        }
        if let (Some(workspace_key), Some(reservation)) = (workspace_key, reservation.as_ref()) {
            let terminal_hex = reservation.terminal_id.to_hex();
            let launch_spec = terminal_launch_spec(&opts);
            let terminal = RegistryTerminal {
                terminal_id: terminal_hex.clone(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec,
                exit: None,
                on_exit: reservation.on_exit,
            };
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let commit = registry.commit_terminal(
                    &reservation.mutation,
                    &reservation.fingerprint,
                    reservation.expected_generation.as_deref(),
                    reservation.expected_revision,
                    "terminal-reserved",
                    &terminal,
                    &serde_json::json!({
                        "terminal_id":terminal_hex,
                        "workspace_key":workspace_key,
                        "state":"launching",
                    }),
                )?;
                if commit.replayed {
                    anyhow::bail!("terminal_create_replayed");
                }
                self.emit_terminal_registry_changed(&registry, commit.revision);
            }
            self.record_terminal_relaunch(&terminal_hex, &opts);
            #[cfg(test)]
            if let Some(hook) =
                self.terminal_create_after_terminal_reservation.lock().unwrap().clone()
            {
                hook(&terminal_hex);
            }
            #[cfg(test)]
            let surface_result = if self.test_surface_runtime {
                Surface::spawn_for_test_with_resource_identity_at_cell_pixels(
                    id,
                    opts,
                    Arc::downgrade(self),
                    Some(terminal_identity(tab_id)?),
                    cell_pixels,
                )
            } else {
                Surface::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
                    id,
                    opts,
                    Arc::downgrade(self),
                    (None, &[]),
                    Some(terminal_identity(tab_id)?),
                    crate::surface::PtyLifetime::SessionOwned,
                    cell_pixels,
                )
            };
            #[cfg(not(test))]
            let surface_result =
                Surface::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
                    id,
                    opts,
                    Arc::downgrade(self),
                    (None, &[]),
                    Some(terminal_identity(tab_id)?),
                    crate::surface::PtyLifetime::SessionOwned,
                    cell_pixels,
                );
            let surface = match surface_result {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalEnd::launch_failed(format!("launch-failed: {error}")),
                    );
                    return Err(error);
                }
            };
            let incarnation = TerminalId::random()?.to_hex();
            let identity = TerminalHostIdentity {
                terminal_id: terminal_hex.clone(),
                incarnation: incarnation.clone(),
            };
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let (_, revision) = match commit_terminal_lifecycle(
                    &mut registry,
                    "terminal-ready",
                    "terminal-ready",
                    &terminal_hex,
                    TerminalLifecycle::Running,
                    Some(&incarnation),
                    None,
                ) {
                    Ok(ready) => ready,
                    Err(error) => {
                        surface.kill();
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, revision);
            }
            #[cfg(test)]
            if let Some(hook) =
                self.terminal_spawn_before_cell_pixel_reconcile.lock().unwrap().clone()
            {
                hook(&surface);
            }
            let cell_pixel_lifecycle =
                match self.reconcile_surface_cell_pixels_for_publish(&surface) {
                    Ok(lifecycle) => lifecycle,
                    Err(error) => {
                        let persistence = self.persist_terminal_cell_pixel_reconcile_failure(
                            &terminal_hex,
                            Some(&incarnation),
                            &error,
                        );
                        surface.kill();
                        persistence?;
                        return Err(error);
                    }
                };
            let insert_result =
                insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
            drop(cell_pixel_lifecycle);
            if let Err(error) = insert_result {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    Some(&incarnation),
                    &TerminalEnd::launch_failed("surface-insert-failed"),
                );
                surface.kill();
                return Err(error);
            }
            self.reserved_in_process_terminals.lock().unwrap().insert(surface.id, identity);
            return Ok(surface);
        }
        #[cfg(test)]
        let surface_result = if self.test_surface_runtime {
            Surface::spawn_for_test_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
        } else {
            Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
        };
        #[cfg(not(test))]
        let surface_result =
            Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels);
        let surface = match surface_result {
            Ok(surface) => surface,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                return Err(error);
            }
        };
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            self.pending_workspace_surfaces.lock().unwrap().remove(&id);
            surface.kill();
            return Err(error);
        }
        Ok(surface)
    }

    pub(super) fn spawn_sidebar_plugin_surface(
        self: &Arc<Self>,
        options: &SidebarPluginOptions,
        size: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        if options.command.is_empty() {
            anyhow::bail!("sidebar plugin command is empty");
        }
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        opts.command = Some(options.command.clone());
        opts.cwd = options.cwd.clone();
        opts.cols = size.0.max(1);
        opts.rows = size.1.max(1);
        opts.extra_env.push(("CMUX_SIDEBAR".to_string(), "1".to_string()));
        let cell_pixels = {
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_auxiliary_for_test_at_cell_pixels(
                id,
                opts,
                Arc::downgrade(self),
                cell_pixels,
            )?
        } else {
            Surface::spawn_auxiliary_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)?
        };
        #[cfg(not(test))]
        let surface =
            Surface::spawn_auxiliary_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)?;
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            surface.kill();
            return Err(error);
        }
        Ok(surface)
    }

    pub(super) fn spawn_browser_surface_with_resource_identity(
        self: &Arc<Self>,
        url: String,
        size: Option<(u16, u16)>,
        pending_workspace: Option<WorkspaceId>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let id = self.next_id();
        if let Some(workspace) = pending_workspace {
            self.pending_workspace_surfaces.lock().unwrap().insert(id, workspace);
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let size = self.resolve_client_size(size, (opts.cols, opts.rows));
        let cell_pixels = self.cell_pixel_creation_size();
        let surface = match resource_identity {
            Some(identity) => browser::new_surface_with_resource_identity(
                id,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
                identity,
            )?,
            None => browser::new_surface(
                id,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
            )?,
        };
        insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone())?;
        let tab_id = surface
            .resource_identity()
            .context("browser surface omitted its public tab identity")?
            .tab_id
            .clone();
        self.start_browser_bootstrap(
            surface.clone(),
            BrowserBootstrap::Provider { tab_id, url },
            None,
        );
        Ok(surface)
    }
}
