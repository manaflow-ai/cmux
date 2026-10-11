//! Resource rename, focus and tab selection: workspaces, screens, panes and tabs, including directional pane focus.

use super::*;

impl Mux {
    pub(super) fn resource_focus_workspace(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.focus",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let workspace = resolved
                    .workspace
                    .context("workspace selector resolved without a live workspace")?;
                let index =
                    state.workspace_index(workspace).context("resolved workspace has no index")?;
                let target = state.workspaces[index].public_id.clone();
                let topology = registry.resource_topology_snapshot()?;
                let previous = topology.active_workspace.clone();
                let mut after = topology.clone();
                after.active_workspace = Some(target.clone());
                let deltas =
                    focus_deltas(state, &topology, &after, previous, Some(target.clone()))?;
                let active_pane =
                    state.workspaces[index].active_screen_ref().map(|screen| screen.active_pane);
                let result = json!({"workspace":target});
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::SetActiveWorkspace {
                            workspace_id: Some(target),
                        }],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.active_workspace = index;
                        if let Some(pane) = active_pane {
                            stamp_pane_focus(&mux, state, pane);
                        }
                    },
                ))
            },
        )
    }

    pub(super) fn resource_rename_screen(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "screen.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Screen,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let screen = resolved.screen.context("screen selector has no live screen")?;
                let screen_id = resolved.path.screen.context("screen selector has no public id")?;
                let (workspace_index, screen_index) =
                    find_screen(state, screen).context("resolved screen disappeared")?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_screen(&topology, &screen_id)?.clone();
                durable.name = name.clone();
                let value = screen_value(
                    &durable,
                    &topology,
                    topology.active_workspace.as_ref(),
                    active_screen(&topology, &durable.workspace_id),
                )?;
                let result = json!({"screen":screen_id});
                let deltas = upserts([("screen", screen_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        state.workspaces[workspace_index].screens[screen_index].name = apply_name;
                    },
                ))
            },
        )
    }

    pub(super) fn resource_rename_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "pane.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_pane(&topology, &pane_id)?.clone();
                durable.name = name.clone();
                let value = pane_value(state, &durable, &topology)?;
                let result = json!({"pane":pane_id});
                let deltas = upserts([("pane", pane_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertPane(durable)] },
                    result,
                    deltas,
                    move |state| {
                        state.panes.get_mut(&pane).expect("planned pane remains live").name =
                            apply_name;
                    },
                ))
            },
        )
    }

    pub(super) fn resource_rename_tab(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        authority: crate::resource_name::TabNameUpdate,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let commit = self.commit_resource_mutation_plan(
            mutation,
            "tab.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let surface = resolved.tab.context("tab selector has no live surface")?;
                let tab_id = resolved.path.tab.context("tab selector has no public id")?;
                Self::ensure_tab_renamable(state, registry, surface, &tab_id)?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_tab(&topology, &tab_id)?.clone();
                authority.apply(
                    &mut durable,
                    name.clone(),
                    &topology.generation,
                    topology.revision,
                )?;
                let value = tab_value(&durable, &topology)?;
                let result = json!({"tab":tab_id});
                let deltas = upserts([("tab", tab_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertTab(durable)] },
                    result,
                    deltas,
                    move |state| {
                        if let Some(surface) = state.surfaces.get(&surface) {
                            surface.set_name(apply_name);
                        }
                    },
                ))
            },
        )?;
        self.reload_kept_tab_name(commit.result["tab"].as_str())?;
        Ok(commit)
    }

    pub(super) fn resource_focus_screen(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "screen.focus",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Screen,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let screen = resolved.screen.context("screen selector has no live screen")?;
                let screen_id = resolved.path.screen.context("screen selector has no public id")?;
                let workspace_id =
                    resolved.path.workspace.context("screen selector has no workspace id")?;
                let workspace =
                    resolved.workspace.context("screen selector has no live workspace")?;
                let (workspace_index, screen_index) =
                    find_screen(state, screen).context("resolved screen disappeared")?;
                let topology = registry.resource_topology_snapshot()?;
                let previous = topology.active_workspace.clone();
                let mut after = topology.clone();
                after.active_workspace = Some(workspace_id.clone());
                set_active_screen(&mut after, &workspace_id, Some(screen_id.clone()));
                let deltas =
                    focus_deltas(state, &topology, &after, previous, Some(workspace_id.clone()))?;
                let workspace_record =
                    registry_workspace(state, workspace_index, registry.session_id().as_str());
                let result = json!({"screen":screen_id});
                let active_pane =
                    state.workspaces[workspace_index].screens[screen_index].active_pane;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![
                            ResourceChange::UpsertWorkspace {
                                workspace: workspace_record,
                                position: workspace_index,
                                active_screen: Some(screen_id),
                            },
                            ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace_id) },
                        ],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.active_workspace = workspace_index;
                        state.workspaces[workspace_index].active_screen = screen_index;
                        debug_assert_eq!(state.workspaces[workspace_index].id, workspace);
                        stamp_pane_focus(&mux, state, active_pane);
                    },
                ))
            },
        )
    }

    pub(super) fn resource_focus_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_focus_pane_impl(
            "pane.focus",
            selectors,
            None,
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    pub(super) fn resource_focus_pane_direction(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        direction: &str,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_focus_pane_impl(
            "pane.focus_direction",
            selectors,
            Some(parse_direction(direction)?),
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn resource_focus_pane_impl(
        self: &Arc<Self>,
        operation: &'static str,
        selectors: ResourceSelectors,
        direction: Option<Direction>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let selected = resolved.pane.context("pane selector has no live pane")?;
                let pane = if let Some(direction) = direction {
                    let (workspace, screen) =
                        state.screen_of(selected).context("resolved pane has no screen")?;
                    let screen = &state.workspaces[workspace].screens[screen];
                    let (dx, dy) = direction.delta();
                    Self::pane_navigation_layout(screen, selected, direction)
                        .neighbor_by_recency(selected, dx, dy, |candidate| {
                            state
                                .panes
                                .get(&candidate)
                                .map(|pane| pane.focused_at)
                                .unwrap_or_default()
                        })
                        .context("pane has no neighbor in that direction")?
                } else {
                    selected
                };
                focus_pane_plan(&mux, state, registry, pane)
            },
        )
    }

    pub(super) fn resource_focus_tab(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_select_tab_impl(
            "tab.focus",
            selectors,
            true,
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    pub(in crate::mux) fn commit_ordinary_tab_selection(
        self: &Arc<Self>,
        actor: &Actor,
        selectors: ResourceSelectors,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = json!({
            "operation":"tab.select",
            "selectors":&selectors,
            "fields":{},
        });
        self.resource_select_tab_impl(
            "tab.select",
            selectors,
            false,
            None,
            &WorkspaceMutation::local("cmux-tui", actor.clone()),
            &fingerprint,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn resource_select_tab_impl(
        self: &Arc<Self>,
        operation: &'static str,
        selectors: ResourceSelectors,
        focus_target_pane: bool,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let surface = resolved.tab.context("tab selector has no live surface")?;
                let tab_id = resolved.path.tab.context("tab selector has no public id")?;
                let pane = state.pane_of(surface).context("resolved tab has no pane")?;
                let focus_path = focus_target_pane || state.active_pane() == Some(pane);
                let mut plan = if focus_path {
                    focus_pane_plan(&mux, state, registry, pane)?
                } else {
                    ResourceMutationPlan::new(
                        ResourcePatch { changes: Vec::new() },
                        json!({}),
                        json!([]),
                        |_| {},
                    )
                };
                let topology = registry.resource_topology_snapshot()?;
                let pane_id = state.resource_indexes.pane_ids[&pane].clone();
                let mut durable = topology_pane(&topology, &pane_id)?.clone();
                let previous_active = durable.active_tab.clone();
                durable.active_tab = Some(tab_id.clone());
                plan.patch.changes.push(ResourceChange::UpsertPane(durable.clone()));
                let index = state.panes[&pane]
                    .tabs
                    .iter()
                    .position(|candidate| *candidate == surface)
                    .context("resolved tab disappeared")?;
                let mut deltas = plan.deltas.as_array().cloned().unwrap_or_default();
                let mut after = topology;
                *topology_pane_mut(&mut after, &pane_id)? = durable;
                let mut changed_tabs = [previous_active, Some(tab_id.clone())]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
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
                plan.deltas = Value::Array(deltas);
                plan.result = json!({"tab":tab_id});
                let prior_apply = std::mem::replace(
                    &mut plan,
                    ResourceMutationPlan::new(
                        ResourcePatch { changes: Vec::new() },
                        json!({}),
                        json!([]),
                        |_| {},
                    ),
                );
                let ResourceMutationPlan { patch, result, deltas, metrics, .. } = prior_apply;
                let apply_mux = Arc::clone(&mux);
                Ok(ResourceMutationPlan::new(patch, result, deltas, move |state| {
                    if focus_path {
                        apply_focus_path(&apply_mux, state, pane);
                    } else {
                        state.panes.get_mut(&pane).expect("planned pane remains live").active_at =
                            apply_mux.next_active_at();
                    }
                    state.panes.get_mut(&pane).expect("planned pane remains live").active_tab =
                        index;
                })
                .with_metrics(metrics))
            },
        )
    }
}
