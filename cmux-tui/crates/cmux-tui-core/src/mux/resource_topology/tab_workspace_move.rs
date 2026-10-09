//! Moving a tab to another workspace or to a new workspace, with explicit placement.

use super::*;

impl Mux {
    /// Move a live placement without spawning replacement content. New/empty
    /// workspace layout and source removal commit together before live state changes.
    pub fn move_tab_to_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<()> {
        self.move_tab_to_workspace_placed(actor, surface, workspace, None, None, None)
    }

    /// Move a tab into a new workspace created in the same transaction,
    /// optionally in a sidebar group and at a final index among that
    /// section's members (groups partition the workspace order), named `name`
    /// (else the default `workspace-N`). Returns the new workspace.
    pub fn move_tab_to_new_workspace_as(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        group: Option<String>,
        index: Option<usize>,
        name: Option<String>,
    ) -> anyhow::Result<WorkspaceId> {
        if let Some(group) = &group {
            anyhow::ensure!(
                self.presentation_snapshot().group(group).is_some(),
                "unknown workspace group {group}"
            );
        }
        self.move_tab_to_workspace_placed(actor, surface, None, group, index, name)?;
        self.with_state(|state| {
            state
                .pane_of(surface)
                .and_then(|pane| state.screen_of(pane))
                .map(|(workspace, _)| state.workspaces[workspace].id)
        })
        .context("moved tab has no workspace")
    }

    pub(super) fn move_tab_to_workspace_placed(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
        group: Option<String>,
        group_index: Option<usize>,
        name: Option<String>,
    ) -> anyhow::Result<()> {
        name.as_deref().map(Self::validate_workspace_name).transpose()?;
        if let Some(workspace) = workspace {
            if self.with_state(|state| {
                state
                    .pane_of(surface)
                    .and_then(|pane| state.screen_of(pane))
                    .is_some_and(|(wi, _)| state.workspaces[wi].id == workspace)
            }) {
                return Ok(());
            }
            let target = self.with_state(|state| -> anyhow::Result<_> {
                let ws = state
                    .workspace_by_id(workspace)
                    .context("destination workspace disappeared")?;
                Ok(ws
                    .active_screen_ref()
                    .and_then(|screen| state.panes.get(&screen.active_pane))
                    .map(|pane| (pane.id, pane.tabs.len())))
            })?;
            if let Some((pane, index)) = target {
                anyhow::ensure!(
                    self.move_tab_as(actor, surface, pane, index),
                    "tab could not be moved"
                );
                return Ok(());
            }
        }
        anyhow::ensure!(
            workspace.is_some() || !self.workspaces_are_provider_managed(),
            "managed workspace creation is not supported by tab moves"
        );
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let fingerprint = json!({ "surface":surface, "workspace":workspace, "group":group,
            "group_index":group_index, "name":name });
        let presentation = self.presentation_snapshot();
        let plan_group = group.clone();
        let mux = Arc::clone(self);
        let commit = self.commit_resource_mutation_plan(
            &mutation,
            "tab.move_workspace",
            &fingerprint,
            None,
            None,
            move |state, registry| {
                let source_pane = state.pane_of(surface).context("source tab disappeared")?;
                let (source_wi, source_si) =
                    state.screen_of(source_pane).context("source screen disappeared")?;
                let source_ws = &state.workspaces[source_wi];
                let source_screen = &source_ws.screens[source_si];
                let source_screen_slot = source_screen.id;
                let source_ws_id = source_ws.public_id.clone();
                let source_screen_id = source_screen.public_id.clone();
                let tab_id = state
                    .resource_indexes
                    .tab_ids
                    .get(&surface)
                    .cloned()
                    .context("source tab has no identity")?;
                let source_pane_id = state.resource_indexes.pane_ids[&source_pane].clone();
                let new_workspace = workspace.is_none();
                let (target_wi, mut target_ws) = if let Some(id) = workspace {
                    let index =
                        state.workspace_index(id).context("destination workspace disappeared")?;
                    anyhow::ensure!(
                        state.workspaces[index].screens.is_empty(),
                        "destination layout changed; retry the move"
                    );
                    (index, state.workspaces[index].clone())
                } else {
                    anyhow::ensure!(
                        state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                        "workspace limit reached"
                    );
                    (
                        new_workspace_position(
                            state,
                            &presentation,
                            plan_group.as_deref(),
                            group_index,
                        ),
                        Workspace {
                            id: mux.next_id(),
                            public_id: WorkspacePublicId::random()?,
                            key: Mux::new_workspace_key()?,
                            name: Mux::moved_tab_workspace_name(name.as_deref(), state),
                            screens: Vec::new(),
                            active_screen: 0,
                        },
                    )
                };
                let target_pane = mux.next_id();
                let target_screen = mux.next_id();
                let target_pane_id = PanePublicId::random()?;
                let target_screen_id = ScreenPublicId::random()?;
                let mut after = registry.resource_topology_snapshot()?;
                let mut moved_tab = topology_tab(&after, &tab_id)?.clone();
                moved_tab.pane_id = target_pane_id.clone();
                moved_tab.position = 0;
                let mut source_record = topology_pane(&after, &source_pane_id)?.clone();
                let mut source_tabs = state.panes[&source_pane].tabs.clone();
                let old_index = source_tabs
                    .iter()
                    .position(|id| *id == surface)
                    .context("source tab disappeared")?;
                source_tabs.remove(old_index);
                let source_empty = source_tabs.is_empty();
                let source_active = if state.panes[&source_pane].active_tab >= old_index {
                    state.panes[&source_pane].active_tab.saturating_sub(1)
                } else {
                    state.panes[&source_pane].active_tab
                };
                source_record.active_tab = source_tabs
                    .get(source_active)
                    .map(|id| state.resource_indexes.tab_ids[id].clone());
                let mut changes = Vec::new();
                let mut deltas = Vec::new();
                let mut source_layout = source_screen.layout_snapshot();
                let source_screen_remains =
                    !source_empty || remove_pane_from_layout(&mut source_layout, source_pane);
                if source_empty {
                    after.panes.retain(|pane| pane.public_id != source_pane_id);
                    changes.push(ResourceChange::TombstonePane { pane_id: source_pane_id.clone() });
                    deltas.push(delete_delta(deltas.len(), "pane", source_pane_id.as_str()));
                    if source_screen_remains {
                        if source_layout.active_pane == source_pane {
                            source_layout.active_pane = source_layout.root.first_visible_pane();
                        }
                        if source_layout.zoomed_pane == Some(source_pane) {
                            source_layout.zoomed_pane = None;
                        }
                        let durable = registry_screen_from_layout(
                            state,
                            source_wi,
                            source_si,
                            &source_layout,
                            &after,
                            source_screen.name.clone(),
                        )?;
                        *after
                            .screens
                            .iter_mut()
                            .find(|s| s.public_id == source_screen_id)
                            .expect("source screen") = durable.clone();
                        changes.push(ResourceChange::UpsertScreen(durable));
                    } else {
                        after.screens.retain(|s| s.public_id != source_screen_id);
                        changes.push(ResourceChange::TombstoneScreen {
                            screen_id: source_screen_id.clone(),
                        });
                        deltas.push(delete_delta(
                            deltas.len(),
                            "screen",
                            source_screen_id.as_str(),
                        ));
                        let remaining = source_ws
                            .screens
                            .iter()
                            .filter(|s| s.id != source_screen_slot)
                            .nth(
                                source_ws
                                    .active_screen
                                    .min(source_ws.screens.len().saturating_sub(2)),
                            )
                            .map(|s| s.public_id.clone());
                        changes.push(ResourceChange::UpsertWorkspace {
                            workspace: registry_workspace(
                                state,
                                source_wi,
                                registry.session_id().as_str(),
                            ),
                            position: source_wi,
                            active_screen: remaining.clone(),
                        });
                        set_active_screen(&mut after, &source_ws_id, remaining);
                        let order = after
                            .screens
                            .iter_mut()
                            .filter(|s| s.workspace_id == source_ws_id)
                            .enumerate()
                            .map(|(index, s)| {
                                s.position = index;
                                s.public_id.clone()
                            })
                            .collect();
                        changes.push(ResourceChange::SetScreenOrder {
                            workspace_id: source_ws_id.clone(),
                            screen_ids: order,
                        });
                    }
                } else {
                    *topology_pane_mut(&mut after, &source_pane_id)? = source_record.clone();
                    changes.push(ResourceChange::UpsertPane(source_record));
                    let order = source_tabs
                        .iter()
                        .map(|id| state.resource_indexes.tab_ids[id].clone())
                        .collect::<Vec<_>>();
                    reindex_target_tab_positions(&mut after.tabs, &source_pane_id, &order);
                    changes.push(ResourceChange::SetTabOrder {
                        pane_id: source_pane_id.clone(),
                        tab_ids: order,
                    });
                }
                let pane_record = RegistryPane {
                    public_id: target_pane_id.clone(),
                    screen_id: target_screen_id.clone(),
                    name: None,
                    active_tab: Some(tab_id.clone()),
                    creation_ordinal: target_pane,
                };
                let screen_record = RegistryScreen {
                    public_id: target_screen_id.clone(),
                    workspace_id: target_ws.public_id.clone(),
                    position: 0,
                    name: None,
                    layout: RegistryLayoutNode::Leaf { pane: target_pane_id.clone() },
                    active_pane: target_pane_id.clone(),
                    zoomed_pane: None,
                    auto_layout: Some(vec![target_pane_id.clone()]),
                    viewport: RegistryViewport { base_width: None, columns: Vec::new() },
                };
                after.panes.push(pane_record.clone());
                after.screens.push(screen_record.clone());
                *topology_tab_mut(&mut after, &tab_id)? = moved_tab.clone();
                after.active_workspace = Some(target_ws.public_id.clone());
                if new_workspace {
                    after
                        .active_screens
                        .push((target_ws.public_id.clone(), Some(target_screen_id.clone())));
                } else {
                    set_active_screen(
                        &mut after,
                        &target_ws.public_id,
                        Some(target_screen_id.clone()),
                    );
                }
                let durable_ws = RegistryWorkspace {
                    id: target_ws.id,
                    public_id: target_ws.public_id.clone(),
                    key: target_ws.key.clone(),
                    name: target_ws.name.clone(),
                    group_key: mux.session.clone(),
                };
                let source_changes = std::mem::take(&mut changes);
                changes.extend([
                    ResourceChange::UpsertWorkspace {
                        workspace: durable_ws.clone(),
                        position: target_wi,
                        active_screen: Some(target_screen_id.clone()),
                    },
                    ResourceChange::UpsertScreen(screen_record.clone()),
                    ResourceChange::UpsertPane(pane_record.clone()),
                    ResourceChange::UpsertTab(moved_tab.clone()),
                    ResourceChange::SetScreenOrder {
                        workspace_id: target_ws.public_id.clone(),
                        screen_ids: vec![target_screen_id.clone()],
                    },
                    ResourceChange::SetTabOrder {
                        pane_id: target_pane_id.clone(),
                        tab_ids: vec![tab_id.clone()],
                    },
                    ResourceChange::SetActiveWorkspace {
                        workspace_id: Some(target_ws.public_id.clone()),
                    },
                ]);
                changes.extend(source_changes);
                if new_workspace {
                    let mut order =
                        state.workspaces.iter().map(|w| w.public_id.clone()).collect::<Vec<_>>();
                    order.insert(target_wi, target_ws.public_id.clone());
                    changes.push(ResourceChange::SetWorkspaceOrder { workspace_ids: order });
                }
                if let ContentPublicId::Terminal(public_id) = &moved_tab.content_id {
                    let host =
                        moved_tab.terminal_id.as_deref().context("terminal has no host id")?;
                    let mut terminal =
                        registry.terminal_record(host)?.context("terminal has no durable host")?;
                    terminal.workspace_key = target_ws.key.clone();
                    changes.push(ResourceChange::UpsertTerminal {
                        public_id: public_id.clone(),
                        terminal,
                    });
                }
                deltas.push(upsert(
                    deltas.len(),
                    "tab",
                    tab_id.as_str(),
                    tab_value(&moved_tab, &after)?,
                ));
                deltas.push(upsert(
                    deltas.len(),
                    "pane",
                    target_pane_id.as_str(),
                    pane_value_with_flags(&pane_record, true, false)?,
                ));
                deltas.push(upsert(
                    deltas.len(),
                    "screen",
                    target_screen_id.as_str(),
                    screen_value(
                        &screen_record,
                        &after,
                        after.active_workspace.as_ref(),
                        Some(&target_screen_id),
                    )?,
                ));
                deltas.push(workspace_resource_upsert(
                    deltas.len(),
                    registry.session_id().as_str(),
                    &target_ws.public_id,
                    &target_ws.name,
                    target_wi,
                    true,
                ));
                if let Some(previous) = state.workspaces.get(state.active_workspace)
                    && previous.public_id != target_ws.public_id
                {
                    deltas.push(workspace_resource_upsert(
                        deltas.len(),
                        registry.session_id().as_str(),
                        &previous.public_id,
                        &previous.name,
                        state.active_workspace,
                        false,
                    ));
                }
                if !source_empty {
                    deltas.push(upsert(
                        deltas.len(),
                        "pane",
                        source_pane_id.as_str(),
                        pane_value(state, topology_pane(&after, &source_pane_id)?, &after)?,
                    ));
                    for id in &source_tabs {
                        let id = &state.resource_indexes.tab_ids[id];
                        deltas.push(upsert(
                            deltas.len(),
                            "tab",
                            id.as_str(),
                            tab_value(topology_tab(&after, id)?, &after)?,
                        ));
                    }
                }
                for screen in
                    after.screens.iter().filter(|screen| screen.workspace_id == source_ws_id)
                {
                    deltas.push(upsert(
                        deltas.len(),
                        "screen",
                        screen.public_id.as_str(),
                        screen_value(
                            screen,
                            &after,
                            after.active_workspace.as_ref(),
                            active_screen(&after, &source_ws_id),
                        )?,
                    ));
                }
                deltas.push(upsert(
                    deltas.len(),
                    "workspace",
                    source_ws_id.as_str(),
                    workspace_value(state, &after, &source_ws_id)?,
                ));
                // A sidebar move can start from an inactive workspace. Clear the
                // formerly focused pane/screen in public event streams as well.
                if let Some(previous) = state.workspaces.get(state.active_workspace)
                    && previous.public_id != source_ws_id
                    && previous.public_id != target_ws.public_id
                    && let Some(screen) = previous.active_screen_ref()
                {
                    let screen = topology_screen(&after, &screen.public_id)?;
                    deltas.push(upsert(
                        deltas.len(),
                        "screen",
                        screen.public_id.as_str(),
                        screen_value(
                            screen,
                            &after,
                            after.active_workspace.as_ref(),
                            active_screen(&after, &previous.public_id),
                        )?,
                    ));
                    let pane = topology_pane(&after, &screen.active_pane)?;
                    deltas.push(upsert(
                        deltas.len(),
                        "pane",
                        pane.public_id.as_str(),
                        pane_value(state, pane, &after)?,
                    ));
                }
                let result = json!({"tab":tab_id,"workspace":target_ws.public_id});
                let mut desired = mux.registry_projection(state);
                if new_workspace {
                    desired.insert(target_wi, durable_ws);
                    // Workspaces after the insertion point shift right; keep
                    // their public indexes current.
                    for (index, shifted) in state.workspaces.iter().enumerate().skip(target_wi) {
                        deltas.push(workspace_resource_upsert(
                            deltas.len(),
                            registry.session_id().as_str(),
                            &shifted.public_id,
                            &shifted.name,
                            index + 1,
                            false,
                        ));
                    }
                }
                let key = target_ws.key.clone();
                let target_ws_slot = target_ws.id;
                let layout_op = if new_workspace {
                    LayoutOpKind::MoveTabToNewWorkspace {
                        tab: surface,
                        // The in-group index places the workspace among its
                        // group's members; the model does not compare the workspace order.
                        index: None,
                        new_workspace: target_ws_slot,
                        new_screen: target_screen,
                        new_pane: target_pane,
                    }
                } else {
                    LayoutOpKind::MoveTabToWorkspace {
                        tab: surface,
                        workspace: target_ws_slot,
                        // The destination has no screen (checked above).
                        pane: None,
                        new_screen: target_screen,
                        new_pane: target_pane,
                    }
                };
                target_ws.screens.push(Screen {
                    id: target_screen,
                    public_id: target_screen_id,
                    name: None,
                    root: Node::Leaf(target_pane),
                    active_pane: target_pane,
                    zoomed_pane: None,
                    creation_order_auto_layout: Some(vec![target_pane]),
                    viewport_splits: Default::default(),
                    viewport_base_width: None,
                    layout_columns: Vec::new(),
                    layout_revision: 0,
                    layout_undo: Default::default(),
                });
                let pane = Pane {
                    id: target_pane,
                    public_id: target_pane_id,
                    name: None,
                    tabs: vec![surface],
                    active_tab: 0,
                    active_at: mux.next_active_at(),
                    focused_at: 0,
                };
                state.workspaces.reserve(usize::from(new_workspace));
                state.panes.reserve(1);
                let plan = ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result.clone(),
                    Value::Array(deltas),
                    move |state| {
                        fence_layout_undo_for_tab_membership(state, &[source_pane]);
                        state.panes.get_mut(&source_pane).expect("source pane").tabs = source_tabs;
                        state.panes.get_mut(&source_pane).expect("source pane").active_tab =
                            source_active;
                        if source_empty {
                            collapse_empty_pane(&mux, state, source_pane);
                            if source_screen_remains {
                                overwrite_layout_snapshot(
                                    &mut state.workspaces[source_wi].screens[source_si],
                                    source_layout,
                                );
                            }
                        }
                        if new_workspace {
                            state.push_workspace(target_ws);
                            let last = state.workspaces.len() - 1;
                            if target_wi < last {
                                state.move_workspace(last, target_wi);
                            }
                        } else {
                            state.workspaces[target_wi] = target_ws;
                        }
                        state.insert_pane(pane);
                        state.rebuild_resource_indexes();
                        state.active_workspace = target_wi;
                        stamp_pane_focus(&mux, state, target_pane);
                        Mux::rebuild_split_screen_index(state);
                        mux.subscribers.update_surface_session_path(
                            surface,
                            target_ws_slot,
                            target_screen,
                            target_pane,
                        );
                    },
                );
                let plan = plan.with_layout_op(layout_op);
                Ok(if new_workspace {
                    plan.with_workspace_ledger(ResourceWorkspaceLedger {
                        event_kind: "workspace-added",
                        workspace_key: key,
                        workspaces: desired,
                        legacy_result: result,
                        presentation: plan_group.map(|group| WorkspacePresentationUpdate {
                            group: Some(Some(group)),
                            ..WorkspacePresentationUpdate::default()
                        }),
                    })
                } else {
                    plan
                })
            },
        )?;
        if group.is_some() {
            let registry = self.workspace_registry.lock().unwrap();
            self.reload_presentation(&registry)?;
        }
        if let Some(surface_handle) = self.surface(surface) {
            let key = self.with_state(|state| {
                state
                    .pane_of(surface)
                    .and_then(|pane| state.screen_of(pane))
                    .map(|(wi, _)| state.workspaces[wi].key.clone())
            });
            if let Some(key) = key {
                let _ = surface_handle.persist_host_workspace(&key);
            }
        }
        self.emit_resource_topology_legacy_events(ResourceOperation::TabMove, &commit);
        Ok(())
    }
}
