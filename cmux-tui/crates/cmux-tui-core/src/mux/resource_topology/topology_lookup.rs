//! Resource topology lookups and change values: screen, pane and tab lookups, active screen, registry workspace, upsert and delete deltas, and workspace placement.

use super::*;

/// Registry position for a workspace created into `group` (`None` =
/// ungrouped) at final index `index` among that section's members. Groups
/// partition the workspace order, so the position sits among the members,
/// and after the last member when `index` is past the end. Without an index
/// the workspace goes after the section's last member, or last overall.
pub(in crate::mux) fn new_workspace_position(
    state: &State,
    presentation: &crate::workspace_registry::PresentationSnapshot,
    group: Option<&str>,
    index: Option<usize>,
) -> usize {
    let members = state
        .workspaces
        .iter()
        .enumerate()
        .filter(|(_, workspace)| {
            presentation.workspace(&workspace.key).and_then(|record| record.group.as_deref())
                == group
        })
        .map(|(position, _)| position)
        .collect::<Vec<_>>();
    match (index, members.last()) {
        (Some(index), Some(_)) if index < members.len() => members[index],
        (_, Some(last)) if group.is_some() || index.is_some() => last + 1,
        _ => state.workspaces.len(),
    }
}

pub(super) fn find_screen(state: &State, target: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
        item.screens.iter().position(|screen| screen.id == target).map(|screen| (workspace, screen))
    })
}

pub(super) fn topology_screen<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &ScreenPublicId,
) -> anyhow::Result<&'a RegistryScreen> {
    topology
        .screens
        .iter()
        .find(|screen| &screen.public_id == id)
        .with_context(|| format!("screen {id} is absent from durable topology"))
}

pub(super) fn topology_pane<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &PanePublicId,
) -> anyhow::Result<&'a RegistryPane> {
    topology
        .panes
        .iter()
        .find(|pane| &pane.public_id == id)
        .with_context(|| format!("pane {id} is absent from durable topology"))
}

pub(super) fn topology_pane_mut<'a>(
    topology: &'a mut ResourceTopologySnapshot,
    id: &PanePublicId,
) -> anyhow::Result<&'a mut RegistryPane> {
    topology
        .panes
        .iter_mut()
        .find(|pane| &pane.public_id == id)
        .with_context(|| format!("pane {id} is absent from durable topology"))
}

pub(super) fn topology_tab<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &TabPublicId,
) -> anyhow::Result<&'a RegistryTab> {
    topology
        .tabs
        .iter()
        .find(|tab| &tab.public_id == id)
        .with_context(|| format!("tab {id} is absent from durable topology"))
}

pub(super) fn topology_tab_mut<'a>(
    topology: &'a mut ResourceTopologySnapshot,
    id: &TabPublicId,
) -> anyhow::Result<&'a mut RegistryTab> {
    topology
        .tabs
        .iter_mut()
        .find(|tab| &tab.public_id == id)
        .with_context(|| format!("tab {id} is absent from durable topology"))
}

pub(super) fn active_screen<'a>(
    topology: &'a ResourceTopologySnapshot,
    workspace: &WorkspacePublicId,
) -> Option<&'a ScreenPublicId> {
    topology
        .active_screens
        .iter()
        .find(|(candidate, _)| candidate == workspace)
        .and_then(|(_, screen)| screen.as_ref())
}

pub(super) fn set_active_screen(
    topology: &mut ResourceTopologySnapshot,
    workspace: &WorkspacePublicId,
    screen: Option<ScreenPublicId>,
) {
    if let Some((_, active)) =
        topology.active_screens.iter_mut().find(|(candidate, _)| candidate == workspace)
    {
        *active = screen;
    }
}

pub(super) fn registry_workspace(state: &State, index: usize, session: &str) -> RegistryWorkspace {
    let workspace = &state.workspaces[index];
    RegistryWorkspace {
        id: workspace.id,
        public_id: workspace.public_id.clone(),
        key: workspace.key.clone(),
        name: workspace.name.clone(),
        group_key: session.to_string(),
    }
}

pub(super) fn upsert(sequence: usize, resource: &str, id: &str, value: Value) -> Value {
    json!({
        "kind":"upsert",
        "sequence":u32::try_from(sequence).unwrap_or(u32::MAX),
        "resource":resource,
        "id":id,
        "value":value,
    })
}

pub(super) fn upserts<'a>(values: impl IntoIterator<Item = (&'a str, &'a str, Value)>) -> Value {
    Value::Array(
        values
            .into_iter()
            .enumerate()
            .map(|(sequence, (resource, id, value))| upsert(sequence, resource, id, value))
            .collect(),
    )
}

pub(super) fn workspace_value(
    state: &State,
    topology: &ResourceTopologySnapshot,
    id: &WorkspacePublicId,
) -> anyhow::Result<Value> {
    let index = state
        .workspaces
        .iter()
        .position(|workspace| &workspace.public_id == id)
        .with_context(|| format!("workspace {id} is not live"))?;
    let workspace = &state.workspaces[index];
    Ok(json!({
        "id":id,
        "session_id":topology.session_id,
        "name":workspace.name,
        "index":u32::try_from(index).context("workspace index exceeds uint32")?,
        "focused":topology.active_workspace.as_ref() == Some(id),
    }))
}

pub(super) fn pane_value(
    state: &State,
    pane: &RegistryPane,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let screen = topology_screen(topology, &pane.screen_id)?;
    let focused = topology.active_workspace.as_ref() == Some(&screen.workspace_id)
        && active_screen(topology, &screen.workspace_id) == Some(&screen.public_id)
        && screen.active_pane == pane.public_id;
    pane_value_with_flags(pane, focused, screen.zoomed_pane.as_ref() == Some(&pane.public_id))
        .inspect(|_value| {
            debug_assert!(state.resource_indexes.panes.contains_key(&pane.public_id));
        })
}

pub(super) fn pane_value_with_zoom(
    state: &State,
    pane: &RegistryPane,
    topology: &ResourceTopologySnapshot,
    zoomed: bool,
) -> anyhow::Result<Value> {
    let mut value = pane_value(state, pane, topology)?;
    value["zoomed"] = json!(zoomed);
    Ok(value)
}

pub(super) fn pane_value_with_flags(
    pane: &RegistryPane,
    focused: bool,
    zoomed: bool,
) -> anyhow::Result<Value> {
    Ok(json!({
        "id":pane.public_id,
        "screen_id":pane.screen_id,
        "name":pane.name,
        "focused":focused,
        "zoomed":zoomed,
    }))
}

pub(super) fn tab_value(
    tab: &RegistryTab,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let pane = topology_pane(topology, &tab.pane_id)?;
    u32::try_from(tab.position).context("tab index exceeds uint32")?;
    Ok(tab.public_value(pane.active_tab.as_ref() == Some(&tab.public_id)))
}

pub(super) fn target_location_screen(state: &State, location: (usize, usize)) -> ScreenId {
    state.workspaces[location.0].screens[location.1].id
}

pub(super) fn delete_delta(sequence: usize, resource: &str, id: &str) -> Value {
    json!({
        "kind":"delete",
        "sequence":u32::try_from(sequence).unwrap_or(u32::MAX),
        "resource":resource,
        "id":id,
    })
}
