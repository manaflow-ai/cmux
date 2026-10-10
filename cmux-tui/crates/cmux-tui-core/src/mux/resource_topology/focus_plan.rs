//! Focus plans for resource topology: focus deltas, pane focus plans, applying a focus path, and tab position reindexing.

use super::*;

pub(super) fn focus_deltas(
    state: &State,
    before: &ResourceTopologySnapshot,
    after: &ResourceTopologySnapshot,
    previous_workspace: Option<WorkspacePublicId>,
    next_workspace: Option<WorkspacePublicId>,
) -> anyhow::Result<Value> {
    let mut changes = Vec::new();
    let mut workspaces =
        [previous_workspace, next_workspace].into_iter().flatten().collect::<Vec<_>>();
    workspaces.sort();
    workspaces.dedup();
    for id in &workspaces {
        changes.push(("workspace", id.to_string(), workspace_value(state, after, id)?));
    }
    let mut screens = Vec::new();
    for topology in [before, after] {
        if let Some(workspace) = topology.active_workspace.as_ref()
            && let Some(screen) = active_screen(topology, workspace)
        {
            screens.push(screen.clone());
        }
    }
    screens.sort();
    screens.dedup();
    for id in &screens {
        let screen = topology_screen(after, id).or_else(|_| topology_screen(before, id))?;
        changes.push((
            "screen",
            id.to_string(),
            screen_value(
                screen,
                after,
                after.active_workspace.as_ref(),
                active_screen(after, &screen.workspace_id),
            )?,
        ));
    }
    let mut panes = Vec::new();
    for topology in [before, after] {
        for screen in &screens {
            if let Ok(screen) = topology_screen(topology, screen) {
                panes.push(screen.active_pane.clone());
            }
        }
    }
    panes.sort();
    panes.dedup();
    for id in &panes {
        let pane = topology_pane(after, id).or_else(|_| topology_pane(before, id))?;
        changes.push(("pane", id.to_string(), pane_value(state, pane, after)?));
    }
    Ok(Value::Array(
        changes
            .into_iter()
            .enumerate()
            .map(|(sequence, (resource, id, value))| upsert(sequence, resource, &id, value))
            .collect(),
    ))
}

pub(super) fn focus_pane_plan(
    mux: &Arc<Mux>,
    state: &mut State,
    registry: &WorkspaceRegistry,
    pane: PaneId,
) -> anyhow::Result<ResourceMutationPlan> {
    let (workspace_index, screen_index) =
        state.screen_of(pane).context("resolved pane has no screen")?;
    let workspace_id = state.workspaces[workspace_index].public_id.clone();
    let screen_id = state.workspaces[workspace_index].screens[screen_index].public_id.clone();
    let pane_id = state.resource_indexes.pane_ids[&pane].clone();
    let topology = registry.resource_topology_snapshot()?;
    let previous = topology.active_workspace.clone();
    let mut after = topology.clone();
    after.active_workspace = Some(workspace_id.clone());
    set_active_screen(&mut after, &workspace_id, Some(screen_id.clone()));
    let current = &state.workspaces[workspace_index].screens[screen_index];
    let mut focused_layout = current.layout_snapshot();
    let previous_pane = focused_layout.active_pane;
    if focused_layout.layout_columns.is_empty() {
        focused_layout.root.expand_stack_pane(previous_pane);
        focused_layout.root.expand_stack_pane(pane);
    } else {
        for column in &mut focused_layout.layout_columns {
            column.root.expand_stack_pane(previous_pane);
            column.root.expand_stack_pane(pane);
        }
        sync_layout_column_projection(&mut focused_layout);
    }
    focused_layout.active_pane = pane;
    let durable_screen = registry_screen_from_layout(
        state,
        workspace_index,
        screen_index,
        &focused_layout,
        &topology,
        current.name.clone(),
    )?;
    *after
        .screens
        .iter_mut()
        .find(|screen| screen.public_id == screen_id)
        .context("pane screen is absent from durable topology")? = durable_screen.clone();
    let deltas = focus_deltas(state, &topology, &after, previous, Some(workspace_id.clone()))?;
    let workspace_record =
        registry_workspace(state, workspace_index, registry.session_id().as_str());
    let result = json!({"pane":pane_id,"screen":screen_id});
    let mux = Arc::clone(mux);
    Ok(ResourceMutationPlan::new(
        ResourcePatch {
            changes: vec![
                ResourceChange::UpsertWorkspace {
                    workspace: workspace_record,
                    position: workspace_index,
                    active_screen: Some(screen_id),
                },
                ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace_id) },
                ResourceChange::UpsertScreen(durable_screen),
            ],
        },
        result,
        deltas,
        move |state| apply_focus_path(&mux, state, pane),
    ))
}

pub(super) fn apply_focus_path(mux: &Mux, state: &mut State, pane: PaneId) {
    let (workspace, screen) = state.screen_of(pane).expect("planned pane remains in its screen");
    state.active_workspace = workspace;
    state.workspaces[workspace].active_screen = screen;
    let current = &mut state.workspaces[workspace].screens[screen];
    let previous = current.active_pane;
    if current.layout_columns_active() {
        let mut expanded = false;
        for column in &mut current.layout_columns {
            expanded |= column.root.expand_stack_pane(previous);
            expanded |= column.root.expand_stack_pane(pane);
        }
        if expanded {
            current.sync_layout_column_projection();
        }
    } else {
        current.root.expand_stack_pane(previous);
        current.root.expand_stack_pane(pane);
    }
    current.active_pane = pane;
    stamp_pane_focus(mux, state, pane);
}

/// Assign target-pane positions in one pass over the topology tabs.
///
/// `target_order` is authoritative for both the moved tab and existing target
/// tabs. Keeping the first map entry preserves the previous `position` lookup
/// behavior if malformed input contains a duplicate public id.
pub(super) fn reindex_target_tab_positions(
    tabs: &mut [RegistryTab],
    target_pane_id: &PanePublicId,
    target_order: &[TabPublicId],
) {
    let mut positions = HashMap::with_capacity(target_order.len());
    for (position, tab_id) in target_order.iter().enumerate() {
        positions.entry(tab_id).or_insert(position);
    }
    for tab in tabs {
        if let Some(&position) = positions.get(&tab.public_id) {
            tab.pane_id = target_pane_id.clone();
            tab.position = position;
        }
    }
}
