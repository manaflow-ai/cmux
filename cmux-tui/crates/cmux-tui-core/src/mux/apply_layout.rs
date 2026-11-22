//! Applying layouts: apply_layout, layout instantiation, and discarding spawned surfaces on failure.

use super::*;

impl Mux {
    pub fn apply_layout_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppliedLayout> {
        let target_workspace = {
            let state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|ws| ws.id == id)
            {
                anyhow::bail!("unknown workspace {id}");
            }
            workspace.or_else(|| state.workspaces.get(state.active_workspace).map(|ws| ws.id))
        };
        let (target_workspace, created_workspace) = match target_workspace {
            Some(workspace) => (workspace, false),
            None => (
                self.create_empty_workspace_for_resource_effect(
                    None,
                    None,
                    WorkspacePublicId::random()?,
                    &WorkspaceMutation::local("cmux-tui-layout-workspace", actor.clone()),
                    false,
                )?
                .workspace,
                true,
            ),
        };
        let workspace_lifecycle = self.workspace_lifecycle(target_workspace);
        let workspace_lifecycle_guard = workspace_lifecycle.lock().unwrap();
        let workspace_key = self
            .state
            .lock()
            .unwrap()
            .workspace_by_id(target_workspace)
            .map(|workspace| workspace.key.clone())
            .ok_or_else(|| anyhow::anyhow!("layout workspace disappeared"))?;
        #[cfg(test)]
        if let Some(hook) = self.layout_apply_after_workspace_reservation.lock().unwrap().clone() {
            hook();
        }

        let mut created = Vec::new();
        let mut panes = Vec::new();
        let mut spawned = Vec::new();
        let root = match self.instantiate_layout(
            actor,
            layout,
            size,
            &workspace_key,
            &mut panes,
            &mut created,
            &mut spawned,
        ) {
            Ok(root) => root,
            Err(err) => {
                self.discard_spawned(actor, spawned);
                if created_workspace {
                    drop(workspace_lifecycle_guard);
                    let _ = self
                        .close_workspace_at_revision_for_resource_effect(actor, target_workspace);
                }
                return Err(err);
            }
        };
        if created.is_empty() {
            self.discard_spawned(actor, spawned);
            if created_workspace {
                drop(workspace_lifecycle_guard);
                let _ =
                    self.close_workspace_at_revision_for_resource_effect(actor, target_workspace);
            }
            anyhow::bail!("layout must contain at least one leaf");
        }
        let active_pane = root.first_visible_pane();
        let screen_id = self.next_id();
        let notifications = self.tree_decorations();
        let delta = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(target_workspace) else {
                drop(state);
                self.discard_spawned(actor, spawned);
                anyhow::bail!("layout workspace disappeared");
            };
            for (_, pane) in panes {
                state.insert_pane(pane);
            }
            stamp_pane_focus(self, &mut state, active_pane);
            let screen = Screen {
                id: screen_id,
                public_id: ScreenPublicId::random()?,
                name,
                root,
                active_pane,
                zoomed_pane: None,
                creation_order_auto_layout: None,
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            };
            let ws = &mut state.workspaces[workspace_index];
            ws.screens.push(screen);
            ws.active_screen = ws.screens.len().saturating_sub(1);
            let index = ws.active_screen;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::ScreenAdded,
                screen_id,
            )
            .expect("applied screen is present in tree snapshot");
            Self::rebuild_split_screen_index(&mut state);
            TreeDelta {
                kind: TreeDeltaKind::ScreenAdded,
                workspace: target_workspace,
                screen: Some(screen_id),
                pane: None,
                surface: None,
                index: Some(index),
                entity,
                workspace_revision: None,
                transaction: None,
            }
        };
        let projection_result = self.with_state(|state| {
            let (workspace, screen) =
                state.screen_of(active_pane).expect("applied screen remains live");
            serde_json::json!({
                "workspace_id":state.workspaces[workspace].public_id,
                "screen_id":state.workspaces[workspace].screens[screen].public_id,
            })
        });
        if let Err(error) = self.commit_ordinary_full_resource_projection(
            actor,
            "screen.layout.create",
            projection_result,
        ) {
            drop(workspace_lifecycle_guard);
            let rollback = self.close_screen_for_resource_effect(screen_id);
            if created_workspace {
                let _ =
                    self.close_workspace_at_revision_for_resource_effect(actor, target_workspace);
            }
            return match rollback {
                Ok(true) => Err(error.context("could not persist applied layout")),
                Ok(false) => Err(error.context(
                    "could not persist applied layout and its screen disappeared during rollback",
                )),
                Err(rollback) => Err(error.context(format!(
                    "could not persist applied layout; rollback also failed: {rollback:#}"
                ))),
            };
        }
        for surface in &spawned {
            surface.activate_hosted_launch_stream()?;
        }
        self.emit(MuxEvent::TreeDelta(delta));
        self.emit(MuxEvent::LayoutChanged(screen_id));
        for surface in spawned {
            self.reap_if_dead(&surface);
        }
        Ok(AppliedLayout { screen: screen_id, panes: created })
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn instantiate_layout(
        self: &Arc<Self>,
        actor: &Actor,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
        workspace_key: &str,
        panes: &mut Vec<(PaneId, Pane)>,
        created: &mut Vec<AppliedPane>,
        spawned: &mut Vec<Arc<Surface>>,
    ) -> anyhow::Result<Node> {
        match layout {
            LayoutSpec::Leaf(spec) => {
                if spec.command.as_ref().is_some_and(|argv| argv.is_empty()) {
                    anyhow::bail!("leaf command must not be empty");
                }
                let terminal_id = TerminalId::random()?;
                let terminal_hex = terminal_id.to_hex();
                let mutation = WorkspaceMutation::local("cmux-tui-layout-terminal", actor.clone());
                let reservation = TerminalReservationRequest {
                    terminal_id,
                    mutation,
                    fingerprint: terminal_create_fingerprint(
                        workspace_key,
                        Some(&terminal_hex),
                        spec.command.as_deref(),
                        spec.cwd.as_deref(),
                        None,
                        size,
                        None,
                    )?,
                    expected_generation: None,
                    expected_revision: None,
                    on_exit: TerminalOnExit::Close,
                    env: Vec::new(),
                };
                let surface = self.spawn_surface_in_workspace_reserved(
                    workspace_key,
                    spec.cwd.clone(),
                    size,
                    spec.command.clone(),
                    reservation,
                )?;
                let (pane_id, pane) = self.make_pane(surface.id)?;
                created.push(AppliedPane { pane: pane_id, surface: surface.id });
                panes.push((pane_id, pane));
                spawned.push(surface);
                Ok(Node::Leaf(pane_id))
            }
            LayoutSpec::Split { dir, ratio, a, b } => Ok(Node::Split {
                id: self.next_id(),
                dir: *dir,
                ratio: clamp_split_ratio(*ratio),
                a: Box::new(self.instantiate_layout(
                    actor,
                    a,
                    size,
                    workspace_key,
                    panes,
                    created,
                    spawned,
                )?),
                b: Box::new(self.instantiate_layout(
                    actor,
                    b,
                    size,
                    workspace_key,
                    panes,
                    created,
                    spawned,
                )?),
            }),
            LayoutSpec::Stack { pane_count, expanded_index } => {
                if *pane_count == 0 {
                    anyhow::bail!("stack must contain at least one pane");
                }
                if *expanded_index >= *pane_count {
                    anyhow::bail!("stack expanded pane must be a member");
                }
                let mut pane_ids = Vec::with_capacity(*pane_count);
                for _ in 0..*pane_count {
                    let node = self.instantiate_layout(
                        actor,
                        &LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None }),
                        size,
                        workspace_key,
                        panes,
                        created,
                        spawned,
                    )?;
                    let Node::Leaf(pane_id) = node else { unreachable!() };
                    pane_ids.push(pane_id);
                }
                let expanded = pane_ids[*expanded_index];
                Ok(Node::stack_with_expanded(pane_ids, expanded).expect("validated stack"))
            }
        }
    }

    pub(super) fn discard_spawned(&self, actor: &Actor, spawned: Vec<Arc<Surface>>) {
        if spawned.is_empty() {
            return;
        }
        let hosted = spawned
            .iter()
            .filter_map(|surface| self.resource_terminal_host_identity(surface))
            .map(|identity| (identity.terminal_id, Some(identity.incarnation)))
            .collect::<Vec<_>>();
        let mut registry = self.workspace_registry.lock().unwrap();
        let close = Self::terminal_public_ids_for_hosted(&registry, &hosted).and_then(
            |closed_public_ids| {
                registry
                    .close_terminals_atomically(
                        &WorkspaceMutation::local("cmux-tui-layout-discard", actor.clone()),
                        &hosted,
                    )
                    .map(|batch| (batch, closed_public_ids))
            },
        );
        let (batch, closed_public_ids) = match close {
            Ok(result) => result,
            Err(error) => {
                // The transaction rolled back, so killing or dropping these
                // surfaces would leave durable Running rows unreachable. Put
                // every still-canonical terminal into its registry workspace
                // while the same registry -> state writer fence is held.
                let mut topology_changed = false;
                let mut projection_errors = Vec::new();
                {
                    let mut state = self.state.lock().unwrap();
                    for (terminal_id, _) in &hosted {
                        let terminal = match registry.terminal_record(terminal_id) {
                            Ok(Some(terminal))
                                if terminal.lifecycle != TerminalLifecycle::Tombstoned =>
                            {
                                terminal
                            }
                            Ok(_) => continue,
                            Err(projection_error) => {
                                projection_errors.push(format!(
                                    "{terminal_id}: could not read canonical placement: {projection_error}"
                                ));
                                continue;
                            }
                        };
                        match self.project_terminal_to_workspace_in_state(
                            &mut state,
                            terminal_id,
                            &terminal.workspace_key,
                        ) {
                            Ok((_, changed)) => topology_changed |= changed,
                            Err(projection_error) => projection_errors.push(format!(
                                "{terminal_id}: could not restore topology: {projection_error}"
                            )),
                        }
                    }
                }
                drop(registry);
                let projection_errors = if projection_errors.is_empty() {
                    String::new()
                } else {
                    format!("; {}", projection_errors.join("; "))
                };
                self.emit(MuxEvent::Status(format!(
                    "could not atomically close discarded terminals: {error}{projection_errors}"
                )));
                if topology_changed {
                    self.emit(MuxEvent::TreeChanged);
                }
                return;
            }
        };
        let removed = {
            let mut state = self.state.lock().unwrap();
            let mut removed = Vec::new();
            for surface in &spawned {
                removed.extend(remove_terminal_runtime_from_state(self, &mut state, surface).0);
            }
            removed
        };
        if batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, batch.revision);
        }
        drop(registry);
        self.notify_terminal_exit_waiters(closed_public_ids);
        for placement in removed {
            self.purge_surface_side_tables(placement.id);
        }
        for surface in spawned {
            self.purge_terminal_runtime_side_tables(&surface);
            if !surface.is_dead() {
                surface.kill();
            }
        }
    }
}
