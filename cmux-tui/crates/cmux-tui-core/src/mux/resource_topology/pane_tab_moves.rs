//! Resource pane swaps and tab moves within the topology selected by resource selectors.

use super::*;

impl Mux {
    pub(super) fn resource_swap_panes(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let other_workspace = required_str(fields, "other_workspace")?.to_string();
        let other_screen = required_str(fields, "other_screen")?.to_string();
        let other_pane = required_str(fields, "other_pane")?.to_string();
        self.commit_resource_mutation_plan(
            mutation,
            "pane.swap",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let first = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let other_selectors = ResourceSelectors {
                    machine: selectors.machine.clone(),
                    session: selectors.session.clone(),
                    workspace: Some(other_workspace),
                    screen: Some(other_screen),
                    pane: Some(other_pane),
                    ..Default::default()
                };
                let second = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &other_selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let first_pane = first.pane.context("pane selector has no live pane")?;
                let second_pane = second.pane.context("other pane selector has no live pane")?;
                anyhow::ensure!(first_pane != second_pane, "cannot swap a pane with itself");
                let first_id = first.path.pane.context("pane selector has no public id")?;
                let second_id = second.path.pane.context("other pane selector has no public id")?;
                let first_screen =
                    state.screen_of(first_pane).context("first pane has no screen")?;
                let second_screen =
                    state.screen_of(second_pane).context("second pane has no screen")?;
                let mut first_layout =
                    state.workspaces[first_screen.0].screens[first_screen.1].layout_snapshot();
                let mut second_layout = (first_screen != second_screen).then(|| {
                    state.workspaces[second_screen.0].screens[second_screen.1].layout_snapshot()
                });
                swap_layout_panes(
                    &mut first_layout,
                    first_pane,
                    second_pane,
                    first_screen == second_screen,
                )?;
                if let Some(layout) = second_layout.as_mut() {
                    swap_layout_panes(layout, first_pane, second_pane, false)?;
                }
                let mut topology = registry.resource_topology_snapshot()?;
                if first_screen != second_screen {
                    let first_screen_id =
                        state.workspaces[first_screen.0].screens[first_screen.1].public_id.clone();
                    let second_screen_id = state.workspaces[second_screen.0].screens
                        [second_screen.1]
                        .public_id
                        .clone();
                    topology_pane_mut(&mut topology, &first_id)?.screen_id = second_screen_id;
                    topology_pane_mut(&mut topology, &second_id)?.screen_id = first_screen_id;
                }
                let first_durable = registry_screen_from_layout(
                    state,
                    first_screen.0,
                    first_screen.1,
                    &first_layout,
                    &topology,
                    state.workspaces[first_screen.0].screens[first_screen.1].name.clone(),
                )?;
                let second_durable = second_layout
                    .as_ref()
                    .map(|layout| {
                        registry_screen_from_layout(
                            state,
                            second_screen.0,
                            second_screen.1,
                            layout,
                            &topology,
                            state.workspaces[second_screen.0].screens[second_screen.1].name.clone(),
                        )
                    })
                    .transpose()?;
                let first_pane_record = topology_pane(&topology, &first_id)?.clone();
                let second_pane_record = topology_pane(&topology, &second_id)?.clone();
                let mut changes = vec![
                    ResourceChange::UpsertScreen(first_durable.clone()),
                    ResourceChange::UpsertPane(first_pane_record.clone()),
                    ResourceChange::UpsertPane(second_pane_record.clone()),
                ];
                if let Some(screen) = second_durable.clone() {
                    changes.push(ResourceChange::UpsertScreen(screen));
                }
                let mut event_values = vec![
                    (
                        "screen",
                        first_durable.public_id.to_string(),
                        screen_value(
                            &first_durable,
                            &topology,
                            topology.active_workspace.as_ref(),
                            active_screen(&topology, &first_durable.workspace_id),
                        )?,
                    ),
                    (
                        "pane",
                        first_id.to_string(),
                        pane_value(state, &first_pane_record, &topology)?,
                    ),
                    (
                        "pane",
                        second_id.to_string(),
                        pane_value(state, &second_pane_record, &topology)?,
                    ),
                ];
                if let Some(screen) = &second_durable {
                    event_values.push((
                        "screen",
                        screen.public_id.to_string(),
                        screen_value(
                            screen,
                            &topology,
                            topology.active_workspace.as_ref(),
                            active_screen(&topology, &screen.workspace_id),
                        )?,
                    ));
                }
                let deltas = Value::Array(
                    event_values
                        .into_iter()
                        .enumerate()
                        .map(|(sequence, (resource, id, value))| {
                            upsert(sequence, resource, &id, value)
                        })
                        .collect(),
                );
                let result = json!({"pane":first_id,"screen":first_durable.public_id});
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    deltas,
                    move |state| {
                        apply_layout_snapshot(
                            &mut state.workspaces[first_screen.0].screens[first_screen.1],
                            first_layout,
                        );
                        if let Some(layout) = second_layout {
                            apply_layout_snapshot(
                                &mut state.workspaces[second_screen.0].screens[second_screen.1],
                                layout,
                            );
                        }
                        if first_screen != second_screen {
                            let first_screen_slot =
                                state.workspaces[first_screen.0].screens[first_screen.1].id;
                            let second_screen_slot =
                                state.workspaces[second_screen.0].screens[second_screen.1].id;
                            state
                                .resource_indexes
                                .pane_screen
                                .insert(first_pane, second_screen_slot);
                            state
                                .resource_indexes
                                .pane_screen
                                .insert(second_pane, first_screen_slot);
                        }
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }

    pub(super) fn resource_move_tab_selected(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let destination_workspace = required_str(fields, "destination_workspace")?.to_string();
        let destination_screen = required_str(fields, "destination_screen")?.to_string();
        let destination_pane = required_str(fields, "destination_pane")?.to_string();
        let index =
            usize::try_from(required_u64(fields, "index")?).context("tab index exceeds usize")?;
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "tab.move",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let source = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let destination_selectors = ResourceSelectors {
                    machine: selectors.machine.clone(),
                    session: selectors.session.clone(),
                    workspace: Some(destination_workspace),
                    screen: Some(destination_screen),
                    pane: Some(destination_pane),
                    ..Default::default()
                };
                let destination = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &destination_selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target_workspace_id = destination
                    .path
                    .workspace
                    .clone()
                    .context("destination omitted workspace id")?;
                let target_screen_id =
                    destination.path.screen.clone().context("destination omitted screen id")?;
                let target_workspace_slot =
                    destination.workspace.context("destination workspace is not live")?;
                let target_workspace_index = state
                    .workspace_index(target_workspace_slot)
                    .context("destination workspace disappeared")?;
                let surface = source.tab.context("tab selector has no live surface")?;
                let tab_id = source.path.tab.context("tab selector has no public id")?;
                let source_pane = state.pane_of(surface).context("resolved tab has no pane")?;
                let target_pane =
                    destination.pane.context("destination pane selector has no live pane")?;
                let source_tabs = state.panes[&source_pane].tabs.clone();
                let old_index = source_tabs
                    .iter()
                    .position(|candidate| *candidate == surface)
                    .context("resolved tab disappeared")?;
                let structural = source_pane != target_pane && source_tabs.len() == 1;
                if structural {
                    return structural_tab_move_plan(
                        &mux,
                        state,
                        registry,
                        surface,
                        tab_id.clone(),
                        source_pane,
                        target_pane,
                        index,
                        json!({"tab":tab_id}),
                    );
                }
                let topology = registry.resource_topology_snapshot()?;
                let source_pane_id = state.resource_indexes.pane_ids[&source_pane].clone();
                let target_pane_id = state.resource_indexes.pane_ids[&target_pane].clone();
                let mut moved_tab = topology_tab(&topology, &tab_id)?.clone();
                let mut source_order = topology
                    .tabs
                    .iter()
                    .filter(|tab| tab.pane_id == source_pane_id)
                    .map(|tab| tab.public_id.clone())
                    .collect::<Vec<_>>();
                let mut target_order = if source_pane == target_pane {
                    Vec::new()
                } else {
                    topology
                        .tabs
                        .iter()
                        .filter(|tab| tab.pane_id == target_pane_id)
                        .map(|tab| tab.public_id.clone())
                        .collect::<Vec<_>>()
                };
                source_order.remove(old_index);
                let final_index = if source_pane == target_pane {
                    let final_index =
                        if index > old_index { index.saturating_sub(1) } else { index }
                            .min(source_order.len());
                    source_order.insert(final_index, tab_id.clone());
                    final_index
                } else {
                    let final_index = index.min(target_order.len());
                    target_order.insert(final_index, tab_id.clone());
                    moved_tab.pane_id = target_pane_id.clone();
                    final_index
                };
                moved_tab.position = final_index;
                let mut source_record = topology_pane(&topology, &source_pane_id)?.clone();
                let mut target_record = topology_pane(&topology, &target_pane_id)?.clone();
                if source_pane == target_pane {
                    source_record.active_tab = Some(tab_id.clone());
                    target_record = source_record.clone();
                } else {
                    source_record.active_tab = source_order
                        .get(
                            state.panes[&source_pane]
                                .active_tab
                                .min(source_order.len().saturating_sub(1)),
                        )
                        .cloned();
                    target_record.active_tab = Some(tab_id.clone());
                }
                let mut changes = vec![
                    ResourceChange::UpsertTab(moved_tab.clone()),
                    ResourceChange::UpsertPane(source_record.clone()),
                    ResourceChange::SetTabOrder {
                        pane_id: source_pane_id.clone(),
                        tab_ids: source_order,
                    },
                ];
                if source_pane != target_pane {
                    changes.push(ResourceChange::UpsertPane(target_record.clone()));
                    changes.push(ResourceChange::SetTabOrder {
                        pane_id: target_pane_id.clone(),
                        tab_ids: target_order,
                    });
                }
                if source.path.workspace.as_ref() != Some(&target_workspace_id)
                    && let ContentPublicId::Terminal(public_id) = &moved_tab.content_id
                {
                    let host = moved_tab
                        .terminal_id
                        .as_deref()
                        .context("terminal tab omitted its host id")?;
                    let mut terminal = registry
                        .terminal_record(host)?
                        .context("terminal has no durable host placement")?;
                    terminal.workspace_key = state.workspaces[target_workspace_index].key.clone();
                    changes.push(ResourceChange::UpsertTerminal {
                        public_id: public_id.clone(),
                        terminal,
                    });
                }
                let mut after = topology.clone();
                *topology_tab_mut(&mut after, &tab_id)? = moved_tab;
                *topology_pane_mut(&mut after, &source_pane_id)? = source_record.clone();
                *topology_pane_mut(&mut after, &target_pane_id)? = target_record.clone();
                if source_pane != target_pane {
                    let target_screen = after
                        .screens
                        .iter_mut()
                        .find(|screen| screen.public_id == target_screen_id)
                        .context("destination screen is absent from durable topology")?;
                    target_screen.active_pane = target_pane_id.clone();
                    changes.push(ResourceChange::UpsertScreen(target_screen.clone()));
                    changes.push(ResourceChange::UpsertWorkspace {
                        workspace: registry_workspace(
                            state,
                            target_workspace_index,
                            registry.session_id().as_str(),
                        ),
                        position: target_workspace_index,
                        active_screen: Some(target_screen_id.clone()),
                    });
                    changes.push(ResourceChange::SetActiveWorkspace {
                        workspace_id: Some(target_workspace_id.clone()),
                    });
                    after.active_workspace = Some(target_workspace_id.clone());
                    set_active_screen(
                        &mut after,
                        &target_workspace_id,
                        Some(target_screen_id.clone()),
                    );
                }
                let mut deltas = if source_pane != target_pane {
                    focus_deltas(
                        state,
                        &topology,
                        &after,
                        topology.active_workspace.clone(),
                        Some(target_workspace_id),
                    )?
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                } else {
                    Vec::new()
                };
                let mut changed_tabs = vec![tab_id.clone()];
                changed_tabs.extend(
                    [
                        topology_pane(&topology, &source_pane_id)?.active_tab.clone(),
                        topology_pane(&topology, &target_pane_id)?.active_tab.clone(),
                        source_record.active_tab,
                        target_record.active_tab,
                    ]
                    .into_iter()
                    .flatten(),
                );
                changed_tabs.sort();
                changed_tabs.dedup();
                for changed in changed_tabs {
                    deltas.push(upsert(
                        deltas.len(),
                        "tab",
                        changed.as_str(),
                        tab_value(topology_tab(&after, &changed)?, &after)?,
                    ));
                }
                let result = json!({"tab":tab_id});
                let previous_active = state.active_pane();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    Value::Array(deltas),
                    move |state| {
                        let moved = move_tab_in_state(&mux, state, surface, target_pane, index).0;
                        debug_assert!(
                            moved || source_pane == target_pane && old_index == final_index
                        );
                        if moved {
                            if previous_active != Some(target_pane)
                                && state.active_pane() == Some(target_pane)
                            {
                                stamp_pane_focus(&mux, state, target_pane);
                            } else if let Some(pane) = state.panes.get_mut(&target_pane) {
                                pane.active_at = mux.next_active_at();
                            }
                        }
                    },
                )
                .moving_tab(surface, target_pane, index))
            },
        )
    }
}
