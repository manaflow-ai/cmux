//! Terminal creation in a workspace: host ids and run results for created terminals, replayed placements, the create implementation, and binding a running terminal to its canonical workspace.

use super::*;

impl Mux {
    pub(super) fn created_terminal_host_id(&self, created_path: &Value) -> anyhow::Result<String> {
        let terminal_id = TerminalPublicId::parse(
            created_path["terminal_id"]
                .as_str()
                .context("created terminal result omitted its public terminal id")?
                .to_string(),
        )?;
        self.workspace_registry
            .lock()
            .unwrap()
            .terminal_host_id(&terminal_id)?
            .context("created terminal result has no durable host id")
    }

    pub(crate) fn created_terminal_run_result(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<RunCommandResult> {
        for _ in 0..2 {
            let resolution = self
                .resolve_terminal(terminal_id)?
                .context("created terminal result has no durable terminal row")?;
            let placement = resolution.surface.and_then(|surface| {
                self.with_state(|state| run_placement_for_surface(state, surface))
            });
            match resolution.terminal.lifecycle {
                TerminalLifecycle::Exited => {
                    anyhow::ensure!(
                        resolution.terminal.exit.is_some(),
                        "exited terminal omitted durable exit metadata"
                    );
                    return Ok(RunCommandResult {
                        placement: None,
                        terminal: resolution.terminal,
                        terminal_revision: resolution.terminal_revision,
                    });
                }
                TerminalLifecycle::Running => {
                    if let Some(placement) = placement {
                        return Ok(RunCommandResult {
                            placement: Some(placement),
                            terminal: resolution.terminal,
                            terminal_revision: resolution.terminal_revision,
                        });
                    }
                    // Exit commits lifecycle before installing the detached
                    // state. Re-read once if that transition landed between
                    // resolve_terminal's registry and state snapshots.
                }
                lifecycle => anyhow::bail!(
                    "created terminal is {} before its run result could be returned",
                    terminal_lifecycle_name(lifecycle)
                ),
            }
        }
        anyhow::bail!("created running terminal has no placement")
    }

    pub(crate) fn reap_created_terminal_surface(self: &Arc<Self>, surface: Option<SurfaceId>) {
        if let Some(surface) = surface.and_then(|surface| self.surface(surface)) {
            self.reap_if_dead(&surface);
        }
    }

    pub(crate) fn activate_created_terminal_surface(
        &self,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<()> {
        if let Some(surface) = surface.and_then(|surface| self.surface(surface)) {
            surface.activate_hosted_launch_stream()?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_terminal_in_workspace_with_mutation(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        requested_terminal_id: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        on_exit: Option<TerminalOnExit>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        self.create_terminal_in_workspace_with_mutation_env(
            workspace,
            argv,
            cwd,
            name,
            size,
            requested_terminal_id,
            expected_generation,
            expected_revision,
            mutation,
            on_exit,
            Vec::new(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn create_terminal_in_workspace_with_mutation_env(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        requested_terminal_id: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        on_exit: Option<TerminalOnExit>,
        env: Vec<(String, String)>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let workspace_key = self
            .state
            .lock()
            .unwrap()
            .workspace_by_id(workspace)
            .map(|workspace| workspace.key.clone())
            .ok_or_else(|| anyhow::anyhow!("unknown workspace {workspace}"))?;
        if let Some(terminal_id) = requested_terminal_id {
            validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        }
        let fingerprint = terminal_create_fingerprint(
            &workspace_key,
            requested_terminal_id,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            on_exit,
        )?;
        let replay =
            { self.workspace_registry.lock().unwrap().replay_terminal(mutation, &fingerprint)? };
        if let Some(replay) = replay {
            let terminal_id = replay.result["terminal_id"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored terminal create result is missing id"))?;
            return self.replayed_terminal_placement(terminal_id);
        }
        let terminal_id = match requested_terminal_id {
            Some(value) => TerminalId::from_hex(value).expect("validated terminal UUID"),
            None => TerminalId::random()?,
        };
        let reservation = TerminalReservationRequest {
            terminal_id,
            mutation: mutation.clone(),
            fingerprint,
            expected_generation: expected_generation.map(str::to_string),
            expected_revision,
            on_exit: on_exit.unwrap_or_default(),
            tab_id: None,
            env,
        };
        let (placement, surface, created_path) = self.create_terminal_in_workspace_impl(
            workspace,
            argv,
            cwd,
            name,
            size,
            Some(reservation),
        )?;
        let identity = self
            .resource_terminal_host_identity(&surface)
            .ok_or_else(|| anyhow::anyhow!("created terminal has no host identity"))?;
        let terminal_revision = self.workspace_registry.lock().unwrap().terminal_revision()?;
        Ok(TerminalPlacementResult {
            placement: Some(placement),
            terminal_id: identity.terminal_id,
            terminal_incarnation: Some(identity.incarnation),
            terminal_revision,
            replayed: false,
            created_path: Some(created_path),
            created_surface: Some(surface.id),
        })
    }

    pub(super) fn replayed_terminal_placement(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let resolved = self.created_terminal_run_result(terminal_id)?;
        let placement = resolved.placement;
        let surface = placement.map(|placement| placement.surface);
        let created_path =
            surface.map(|surface| self.created_resource_path(surface)).transpose()?;
        Ok(TerminalPlacementResult {
            placement,
            terminal_id: resolved.terminal.terminal_id,
            terminal_incarnation: resolved.terminal.incarnation,
            terminal_revision: resolved.terminal_revision,
            replayed: true,
            created_path,
            created_surface: surface,
        })
    }

    pub(super) fn create_terminal_in_workspace_impl(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<(RunPlacement, Arc<Surface>, Value)> {
        {
            let state = self.state.lock().unwrap();
            if state.workspace_by_id(workspace).is_none() {
                anyhow::bail!("unknown workspace {workspace}");
            }
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_empty_check.lock().unwrap().clone() {
            hook();
        }
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_materialization_lock.lock().unwrap().clone()
        {
            hook();
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_workspace_reservation.lock().unwrap().clone()
        {
            hook();
        }
        let (workspace_key, inherited_pane) = {
            let state = self.state.lock().unwrap();
            let Some(workspace) = state.workspace_by_id(workspace) else {
                anyhow::bail!("unknown workspace {workspace}");
            };
            (workspace.key.clone(), workspace.active_screen_ref().map(|screen| screen.active_pane))
        };
        let inherited_cwd = inherited_pane.and_then(|pane| self.pane_cwd(pane));
        let surface = match reservation {
            Some(reservation) => self.spawn_surface_in_workspace_reserved(
                &workspace_key,
                cwd.or(inherited_cwd),
                size,
                argv,
                reservation,
            )?,
            None => {
                self.spawn_surface_in_workspace(&workspace_key, cwd.or(inherited_cwd), size, argv)?
            }
        };
        self.pending_workspace_surfaces.lock().unwrap().insert(surface.id, workspace);
        let pending_surface = self.pending_workspace_surface(surface.id);
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        if surface.terminal_host_identity().is_some() {
            // Launch/Ready intentionally releases the registry lock around
            // process startup. Re-read canonical placement after Ready and
            // hold registry -> state through the binding so a move committed
            // during launch is projected instead of the stale request target.
            let projected = self.bind_running_terminal_to_canonical_workspace(&surface);
            let (placement, canonical_workspace, changed, created_path) = match projected {
                Ok(projected) => projected,
                Err(error) => {
                    self.fail_hosted_terminal_attachment(
                        &surface,
                        "terminal-topology-attach-failed",
                        "topology-attach-failed",
                    )?;
                    return Err(error);
                }
            };
            let _ = surface.persist_host_workspace(&canonical_workspace);
            if changed {
                self.emit(MuxEvent::TreeChanged);
            }
            drop(pending_surface);
            drop(workspace_lifecycle);
            return Ok((placement, surface, created_path));
        }
        let notifications = self.tree_decorations();
        let active_at = self.next_active_at();
        let mut rollback_removed = Vec::new();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let result = (|| -> anyhow::Result<_> {
                anyhow::ensure!(
                    state.surfaces.contains_key(&surface.id),
                    "terminal closed while its topology binding was being created"
                );
                let wi = state
                    .workspace_index(workspace)
                    .context("workspace disappeared while creating terminal")?;
                let target =
                    state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
                if let Some(target) = target {
                    let (_, si) = state
                        .screen_of(target)
                        .context("workspace active pane disappeared while creating terminal")?;
                    let pane = state
                        .panes
                        .get_mut(&target)
                        .context("workspace active pane disappeared while creating terminal")?;
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    let index = pane.tabs.len() - 1;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    let screen = state.workspaces[wi].screens[si].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new terminal tab is present in tree snapshot");
                    let placement =
                        RunPlacement { surface: surface.id, pane: target, screen, workspace };
                    let created_path = self.created_resource_path_in_state(&state, surface.id)?;
                    Ok((
                        placement,
                        TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace,
                            screen: Some(screen),
                            pane: Some(target),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                            workspace_revision: None,
                            transaction: None,
                        },
                        true,
                        created_path,
                    ))
                } else {
                    let (pane_id, pane) = self.make_pane(surface.id)?;
                    let screen_id = self.next_id();
                    let screen_public_id = ScreenPublicId::random()?;
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
                    state.workspaces[wi].screens.push(Screen {
                        id: screen_id,
                        public_id: screen_public_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        creation_order_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    });
                    state.workspaces[wi].active_screen = 0;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::ScreenAdded,
                        screen_id,
                    )
                    .expect("first workspace screen is present in tree snapshot");
                    let placement = RunPlacement {
                        surface: surface.id,
                        pane: pane_id,
                        screen: screen_id,
                        workspace,
                    };
                    let created_path = self.created_resource_path_in_state(&state, surface.id)?;
                    Ok((
                        placement,
                        TreeDelta {
                            kind: TreeDeltaKind::ScreenAdded,
                            workspace,
                            screen: Some(screen_id),
                            pane: None,
                            surface: None,
                            index: Some(0),
                            entity,
                            workspace_revision: None,
                            transaction: None,
                        },
                        false,
                        created_path,
                    ))
                }
            })();
            if result.is_err() {
                rollback_removed = remove_terminal_runtime_from_state(self, &mut state, &surface).0;
            }
            result
        };
        let attached = match attached {
            Ok(attached) => attached,
            Err(error) => {
                drop(pending_surface);
                for placement in rollback_removed {
                    self.purge_surface_side_tables(placement.id);
                }
                self.purge_terminal_runtime_side_tables(&surface);
                if !surface.is_dead() {
                    surface.kill();
                }
                return Err(error);
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(attached.1, attached.2);
        drop(workspace_lifecycle);
        Ok((attached.0, surface, attached.3))
    }

    /// Bind a just-launched hosted surface using the latest durable row, not
    /// the workspace requested before process launch. Holding registry ->
    /// state through projection is the create/move serialization fence.
    pub(super) fn bind_running_terminal_to_canonical_workspace(
        &self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<(RunPlacement, String, bool, Value)> {
        let identity = surface
            .terminal_host_identity()
            .ok_or_else(|| anyhow::anyhow!("created terminal has no host identity"))?;
        let registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(&identity.terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("created terminal has no registry row"))?;
        if terminal.lifecycle != TerminalLifecycle::Running {
            anyhow::bail!(
                "created terminal is {} before topology binding",
                terminal_lifecycle_name(terminal.lifecycle)
            );
        }
        let mut state = self.lock_state_pinned(&registry).unwrap();
        if !state.surfaces.contains_key(&surface.id) {
            anyhow::bail!("terminal closed while its topology binding was being created");
        }
        let (placement, changed) = self.project_terminal_to_workspace_in_state(
            &mut state,
            &identity.terminal_id,
            &terminal.workspace_key,
        )?;
        let placement =
            placement.ok_or_else(|| anyhow::anyhow!("created terminal has no live surface"))?;
        let created_path = self.created_resource_path_in_state(&state, surface.id)?;
        Ok((placement, terminal.workspace_key, changed, created_path))
    }
}
