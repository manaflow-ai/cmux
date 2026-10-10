//! In-state tree edits: focus identity, focus stamps, auto-layout append, pane and surface removal, tab moves, close deltas, and layout undo confirmation details.

use super::*;

pub(super) type FocusIdentity = (WorkspaceId, ScreenId, PaneId);

pub(super) fn current_focus_identity(state: &State) -> Option<FocusIdentity> {
    let workspace = state.workspaces.get(state.active_workspace)?;
    let screen = workspace.active_screen_ref()?;
    Some((workspace.id, screen.id, screen.active_pane))
}

pub(super) fn restore_focus_identity(state: &mut State, focus: Option<FocusIdentity>) {
    let Some((workspace_id, screen_id, pane_id)) = focus else { return };
    let Some(workspace_index) = state.workspace_index(workspace_id) else { return };
    state.active_workspace = workspace_index;
    let Some(screen_index) =
        state.workspaces[workspace_index].screens.iter().position(|screen| screen.id == screen_id)
    else {
        return;
    };
    state.workspaces[workspace_index].active_screen = screen_index;
    if state.workspaces[workspace_index].screens[screen_index].root.contains(pane_id) {
        state.workspaces[workspace_index].screens[screen_index].active_pane = pane_id;
    }
}

/// Every surface in a screen (all panes, all tabs).
pub(super) fn screen_tabs(state: &State, screen: &Screen) -> Vec<SurfaceId> {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    pane_ids
        .iter()
        .filter_map(|id| state.panes.get(id))
        .flat_map(|pane| pane.tabs.iter().copied())
        .collect()
}

pub(super) fn stamp_pane_focus(mux: &Mux, state: &mut State, pane: PaneId) {
    let focused_at = state.next_focus_sequence();
    let active_at = mux.next_active_at();
    if let Some(pane) = state.panes.get_mut(&pane) {
        pane.active_at = active_at;
        pane.focused_at = focused_at;
    }
}

pub(super) fn stamp_changed_active_pane(mux: &Mux, state: &mut State, previous: Option<PaneId>) {
    let current = state.active_pane();
    if current != previous
        && let Some(pane) = current
    {
        stamp_pane_focus(mux, state, pane);
    }
}

pub(super) fn most_recent_pane(state: &State, panes: &[PaneId]) -> Option<PaneId> {
    panes
        .iter()
        .filter_map(|id| state.panes.get(id).map(|pane| (*id, pane.active_at)))
        .max_by_key(|(_, active_at)| *active_at)
        .map(|(id, _)| id)
}

pub(super) fn clamp_split_ratio(ratio: f32) -> f32 {
    ratio.clamp(0.05, 0.95)
}

pub(super) fn append_to_auto_layout(
    root: &mut Node,
    auto_layout: &mut Option<Vec<PaneId>>,
    pane: PaneId,
    mut next_id: impl FnMut() -> SplitId,
) {
    let mut panes = auto_layout.clone().unwrap_or_else(|| {
        let mut panes = Vec::new();
        root.pane_ids(&mut panes);
        panes.sort_unstable();
        panes
    });
    let current_panes = root.pane_ids_vec().into_iter().collect::<HashSet<_>>();
    panes.retain(|pane| current_panes.contains(pane));
    panes.push(pane);
    *root = crate::layout::zellij_default_pane_layout_with_ids(&panes, &mut next_id)
        .expect("new pane layout always has at least one pane");
    *auto_layout = Some(panes);
}

pub(super) fn remove_pane_from_screen_layout(mux: &Mux, screen: &mut Screen, pane: PaneId) -> bool {
    screen.invalidate_layout_undo();
    if screen.layout_columns_active() {
        let Some(index) =
            screen.layout_columns.iter().position(|column| column.root.contains(pane))
        else {
            return true;
        };
        let column = &mut screen.layout_columns[index];
        let root = std::mem::replace(&mut column.root, Node::Leaf(0));
        let stack_expanded = root.stack_expanded_pane();
        match root.remove_leaf(pane) {
            Some(mut root) => {
                if let Some(panes) = column.creation_order_auto_layout.as_mut() {
                    panes.retain(|candidate| *candidate != pane);
                    if let Some(layout) =
                        crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || {
                            mux.next_id()
                        })
                    {
                        root = layout;
                        if let Some(expanded) = stack_expanded {
                            root.expand_stack_pane(expanded);
                        }
                    } else {
                        column.creation_order_auto_layout = None;
                    }
                }
                column.root = root;
            }
            None => {
                screen.layout_columns.remove(index);
            }
        }
        if screen.layout_columns.is_empty() {
            return false;
        }
        screen.collapse_single_layout_column();
        return true;
    }

    let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
    let stack_expanded = root.stack_expanded_pane();
    let Some(mut root) = root.remove_leaf(pane) else {
        return false;
    };
    if let Some(panes) = screen.creation_order_auto_layout.as_mut() {
        panes.retain(|candidate| *candidate != pane);
        if let Some(layout) =
            crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || mux.next_id())
        {
            root = layout;
            if let Some(expanded) = stack_expanded {
                root.expand_stack_pane(expanded);
            }
        } else {
            screen.creation_order_auto_layout = None;
        }
    }
    screen.root = root;
    true
}

pub(super) fn unique_screen_ids(ids: impl IntoIterator<Item = ScreenId>) -> Vec<ScreenId> {
    let mut unique = Vec::new();
    for id in ids {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    unique
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct ActiveTreeSelection {
    pub(super) workspace: Option<WorkspaceId>,
    pub(super) screen: Option<ScreenId>,
    pub(super) pane: Option<PaneId>,
    pub(super) surface: Option<SurfaceId>,
}

pub(super) fn active_tree_selection(state: &State) -> ActiveTreeSelection {
    let workspace = state.workspaces.get(state.active_workspace);
    let screen = workspace.and_then(|workspace| workspace.screens.get(workspace.active_screen));
    let pane = screen.and_then(|screen| state.panes.get(&screen.active_pane));
    ActiveTreeSelection {
        workspace: workspace.map(|workspace| workspace.id),
        screen: screen.map(|screen| screen.id),
        pane: screen.map(|screen| screen.active_pane),
        surface: pane.and_then(|pane| pane.tabs.get(pane.active_tab)).copied(),
    }
}

pub(super) fn surface_screen_id(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    let pane = state.pane_of(surface)?;
    let (wi, si) = state.screen_of(pane)?;
    Some(state.workspaces[wi].screens[si].id)
}

pub(super) fn resolve_workspace_index(
    state: &State,
    id: Option<WorkspaceId>,
    key: Option<&str>,
) -> anyhow::Result<usize> {
    if id.is_none() && key.is_none() {
        anyhow::bail!("workspace or key is required");
    }
    let by_id = id.and_then(|id| state.workspaces.iter().position(|workspace| workspace.id == id));
    let by_key =
        key.and_then(|key| state.workspaces.iter().position(|workspace| workspace.key == key));
    match (id, key, by_id, by_key) {
        (Some(id), _, None, _) => anyhow::bail!("unknown workspace {id}"),
        (_, Some(key), _, None) => anyhow::bail!("unknown workspace key {key}"),
        (Some(_), Some(_), Some(left), Some(right)) if left != right => {
            anyhow::bail!("workspace and key identify different workspaces")
        }
        (_, _, Some(index), _) | (_, _, _, Some(index)) => Ok(index),
        _ => anyhow::bail!("unknown workspace"),
    }
}

pub(super) fn workspace_mutation_result(
    commit: &RegistryCommit,
) -> anyhow::Result<WorkspaceMutationResult> {
    let workspace = commit.result["workspace"].as_u64();
    let key = commit.result["key"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("stored workspace mutation result is missing key"))?
        .to_string();
    let index = commit.result["index"]
        .as_u64()
        .map(usize::try_from)
        .transpose()
        .context("stored workspace mutation index is invalid")?;
    let changed = commit.result["changed"].as_bool().unwrap_or(true);
    Ok(WorkspaceMutationResult {
        workspace,
        key,
        index,
        revision: commit.revision,
        replayed: commit.replayed,
        changed,
    })
}

pub(super) fn close_surface_delta(
    state: &State,
    notifications: &TreeDecorations,
    surface: SurfaceId,
) -> Option<TreeDelta> {
    let pane_id = state.pane_of(surface)?;
    let pane = state.panes.get(&pane_id)?;
    let tab_index = pane.tabs.iter().position(|candidate| *candidate == surface)?;
    let (wi, si) = state.screen_of(pane_id)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    if pane.tabs.len() > 1 {
        let entity = crate::server::tree_entity_json(
            state,
            notifications,
            TreeDeltaKind::TabClosed,
            surface,
        )?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::TabClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane_id),
            surface: Some(surface),
            index: Some(tab_index),
            entity,
            workspace_revision: None,
            transaction: None,
        });
    }
    close_pane_delta(state, notifications, pane_id)
}

pub(super) fn close_pane_delta(
    state: &State,
    notifications: &TreeDecorations,
    pane: PaneId,
) -> Option<TreeDelta> {
    let (wi, si) = state.screen_of(pane)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    let mut panes = Vec::new();
    screen.root.pane_ids(&mut panes);
    if panes.len() > 1 {
        let entity =
            crate::server::tree_entity_json(state, notifications, TreeDeltaKind::PaneClosed, pane)?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::PaneClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane),
            surface: None,
            index: Some(panes.iter().position(|candidate| *candidate == pane)?),
            entity,
            workspace_revision: None,
            transaction: None,
        });
    }
    close_screen_delta(state, notifications, screen.id)
}

pub(super) fn close_screen_delta(
    state: &State,
    notifications: &TreeDecorations,
    screen: ScreenId,
) -> Option<TreeDelta> {
    let (wi, si) = state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
        workspace.screens.iter().position(|candidate| candidate.id == screen).map(|si| (wi, si))
    })?;
    let workspace = &state.workspaces[wi];
    let entity =
        crate::server::tree_entity_json(state, notifications, TreeDeltaKind::ScreenClosed, screen)?;
    Some(TreeDelta {
        kind: TreeDeltaKind::ScreenClosed,
        workspace: workspace.id,
        screen: Some(screen),
        pane: None,
        surface: None,
        index: Some(si),
        entity,
        workspace_revision: None,
        transaction: None,
    })
}

pub(super) fn close_workspace_delta(
    state: &State,
    notifications: &TreeDecorations,
    workspace: WorkspaceId,
) -> Option<TreeDelta> {
    let index = state.workspace_index(workspace)?;
    let entity = crate::server::tree_entity_json(
        state,
        notifications,
        TreeDeltaKind::WorkspaceClosed,
        workspace,
    )?;
    Some(TreeDelta {
        kind: TreeDeltaKind::WorkspaceClosed,
        workspace,
        screen: None,
        pane: None,
        surface: None,
        index: Some(index),
        entity,
        workspace_revision: None,
        transaction: None,
    })
}

pub(super) fn update_layout_undo_token_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    hasher.update(value);
}

pub(super) fn layout_undo_confirmation_details(
    state: &State,
    registry: &WorkspaceRegistry,
    workspace_index: usize,
    screen_index: usize,
) -> anyhow::Result<Value> {
    let screen = state
        .workspaces
        .get(workspace_index)
        .and_then(|workspace| workspace.screens.get(screen_index))
        .context("layout undo screen disappeared")?;
    let entry = screen.layout_undo.back().ok_or(LayoutUndoError::Unavailable)?;
    if entry.after_revision != screen.layout_revision {
        return Err(LayoutUndoError::Stale(
            "layout changed since the last undoable action".to_string(),
        )
        .into());
    }
    anyhow::ensure!(!entry.created_panes.is_empty(), "layout undo does not require confirmation");

    let mut hasher = Sha256::new();
    update_layout_undo_token_part(&mut hasher, b"cmux.layout-undo.confirmation.v1");
    update_layout_undo_token_part(&mut hasher, registry.generation().as_bytes());
    update_layout_undo_token_part(&mut hasher, screen.public_id.to_string().as_bytes());
    update_layout_undo_token_part(&mut hasher, &screen.layout_revision.to_be_bytes());
    hasher.update(u64::try_from(entry.created_panes.len()).unwrap_or(u64::MAX).to_be_bytes());

    let mut closes_panes = Vec::with_capacity(entry.created_panes.len());
    for created in &entry.created_panes {
        let pane_id = state
            .resource_indexes
            .pane_ids
            .get(created)
            .with_context(|| format!("pane {created} has no public identity"))?;
        let pane = state
            .panes
            .get(created)
            .with_context(|| format!("created pane {created} disappeared before undo preview"))?;
        closes_panes.push(pane_id.clone());
        update_layout_undo_token_part(&mut hasher, pane_id.to_string().as_bytes());
        hasher.update(u64::try_from(pane.tabs.len()).unwrap_or(u64::MAX).to_be_bytes());
        for surface in &pane.tabs {
            let tab_id = state
                .resource_indexes
                .tab_ids
                .get(surface)
                .cloned()
                .with_context(|| format!("tab {surface} has no public identity"))?;
            update_layout_undo_token_part(&mut hasher, tab_id.to_string().as_bytes());
        }
    }
    let confirmation_token =
        hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let revision = registry.resource_topology_snapshot()?.revision;
    Ok(serde_json::json!({
        "revision":revision.to_string(),
        "confirmation_token":confirmation_token,
        "closes_panes":closes_panes,
    }))
}

/// Advance the confirmation fence when a tab membership mutation touches a
/// pane that the latest undo would close. This runs in the same state-lock
/// critical section as the tab mutation, so a confirmed undo observes either
/// the old membership and revision or the new membership and revision.
pub(super) fn fence_layout_undo_for_tab_membership(state: &mut State, panes: &[PaneId]) {
    let screens = panes
        .iter()
        .filter_map(|pane| state.screen_of(*pane))
        .map(|(workspace, screen)| state.workspaces[workspace].screens[screen].id)
        .collect::<HashSet<_>>();
    for screen_id in screens {
        let Some(screen) = state
            .workspaces
            .iter_mut()
            .flat_map(|workspace| workspace.screens.iter_mut())
            .find(|screen| screen.id == screen_id)
        else {
            continue;
        };
        let affects_created_pane = screen.layout_undo.back().is_some_and(|entry| {
            entry.after_revision == screen.layout_revision
                && entry.created_panes.iter().any(|created| panes.contains(created))
        });
        if !affects_created_pane {
            continue;
        }
        let revision = screen.layout_revision.saturating_add(1);
        screen.layout_revision = revision;
        let entry = screen.layout_undo.back_mut().expect("validated undo entry remains present");
        entry.after_revision = revision;
        entry.coalesce = None;
    }
}

/// Remove one surface from the state: detach it from its
/// pane, and collapse emptied panes/screens. An emptied workspace stays
/// here; the close plan closes it (`close_emptied_workspaces_locked`). Returns the removed surface and whether
/// split ownership or positional indexes changed. Runs under the state lock.
pub(super) fn remove_surface(
    mux: &Mux,
    state: &mut State,
    target: SurfaceId,
) -> (Option<Arc<Surface>>, bool) {
    let previous_active = state.active_pane();
    // Capture the placement and its screen before removing reverse indexes.
    // Teardown often removes many last-tab panes in a row, so resolving these
    // relationships from the topology after index deletion would repeatedly
    // scan every pane and split tree.
    let pane_id = state
        .resource_indexes
        .tab_pane
        .get(&target)
        .copied()
        .filter(|pane| state.panes.get(pane).is_some_and(|pane| pane.tabs.contains(&target)))
        .or_else(|| {
            state.panes.values().find(|pane| pane.tabs.contains(&target)).map(|pane| pane.id)
        });
    let screen_location = pane_id.and_then(|pane| state.screen_of(pane));
    let removed = state.surfaces.remove(&target);
    if let Some(tab_id) = state.resource_indexes.tab_ids.remove(&target) {
        state.resource_indexes.tabs.remove(&tab_id);
    }
    if let Some(content_id) = state.resource_indexes.content_ids.remove(&target) {
        let remove_content = if let Some(placements) =
            state.resource_indexes.content_placements.get_mut(&content_id)
        {
            placements.retain(|placement| *placement != target);
            placements.is_empty()
        } else {
            false
        };
        if remove_content {
            state.resource_indexes.content_placements.remove(&content_id);
        }
    }
    state.resource_indexes.tab_pane.remove(&target);
    let Some(pane_id) = pane_id else {
        return (removed, false);
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        fence_layout_undo_for_tab_membership(state, &[pane_id]);
        return (removed, false);
    }

    // Last tab gone: the pane collapses out of its screen.
    state.remove_pane(pane_id);
    let Some((wi, si)) = screen_location else {
        return (removed, false);
    };
    let (was_active, screen_remains) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let screen_remains = remove_pane_from_screen_layout(mux, screen, pane_id);
        (was_active, screen_remains)
    };
    if screen_remains {
        let next_active = if was_active {
            let mut ids = Vec::new();
            state.workspaces[wi].screens[si].root.pane_ids(&mut ids);
            most_recent_pane(state, &ids)
        } else {
            None
        };
        if let Some(next) = next_active {
            state.workspaces[wi].screens[si].active_pane = next;
        }
        stamp_changed_active_pane(mux, state, previous_active);
        return (removed, true);
    }

    // Screen emptied: drop it from the workspace.
    let ws = &mut state.workspaces[wi];
    ws.screens.remove(si);
    ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
    if !ws.screens.is_empty() {
        stamp_changed_active_pane(mux, state, previous_active);
        return (removed, true);
    }

    // The screen emptied, but the workspace remains as a canonical registry
    // entry. Record the resulting loss of active pane without discarding its
    // stable workspace identity.
    stamp_changed_active_pane(mux, state, previous_active);
    (removed, true)
}

pub(super) fn collapse_empty_pane(mux: &Mux, state: &mut State, pane_id: PaneId) {
    state.remove_pane(pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return;
    };
    let (was_active, screen_remains) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let screen_remains = remove_pane_from_screen_layout(mux, screen, pane_id);
        (was_active, screen_remains)
    };
    if screen_remains {
        let next_active = if was_active {
            let mut ids = Vec::new();
            state.workspaces[wi].screens[si].root.pane_ids(&mut ids);
            most_recent_pane(state, &ids)
        } else {
            None
        };
        if let Some(next) = next_active {
            state.workspaces[wi].screens[si].active_pane = next;
        }
    } else {
        let ws = &mut state.workspaces[wi];
        ws.screens.remove(si);
        ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
    }
}

pub(super) fn move_tab_in_state(
    mux: &Mux,
    state: &mut State,
    surface: SurfaceId,
    target_pane: PaneId,
    index: usize,
) -> (bool, bool) {
    if !state.surfaces.contains_key(&surface) || !state.panes.contains_key(&target_pane) {
        return (false, false);
    }
    let Some(source_pane) = state.pane_of(surface) else { return (false, false) };
    if source_pane == target_pane {
        let Some(pane) = state.panes.get_mut(&target_pane) else {
            return (false, false);
        };
        let Some(old_idx) = pane.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
        let new_idx = new_idx.min(pane.tabs.len().saturating_sub(1));
        if new_idx == old_idx {
            return (false, false);
        }
        let tab = pane.tabs.remove(old_idx);
        pane.tabs.insert(new_idx, tab);
        pane.active_tab = new_idx;
        fence_layout_undo_for_tab_membership(state, &[target_pane]);
        return (true, false);
    }

    fence_layout_undo_for_tab_membership(state, &[source_pane, target_pane]);
    {
        let Some(source) = state.panes.get_mut(&source_pane) else {
            return (false, false);
        };
        let Some(old_idx) = source.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        source.tabs.remove(old_idx);
        if !source.tabs.is_empty() && source.active_tab >= old_idx && source.active_tab > 0 {
            source.active_tab -= 1;
        }
    }

    let topology_changed = state.panes.get(&source_pane).is_some_and(|pane| pane.tabs.is_empty());
    if topology_changed {
        collapse_empty_pane(mux, state, source_pane);
    }

    let Some(target) = state.panes.get_mut(&target_pane) else {
        return (false, topology_changed);
    };
    let new_idx = index.min(target.tabs.len());
    target.tabs.insert(new_idx, surface);
    target.active_tab = new_idx;
    state.resource_indexes.tab_pane.insert(surface, target_pane);
    let destination_path = if let Some((wi, si)) = state.screen_of(target_pane) {
        state.active_workspace = wi;
        let ws = &mut state.workspaces[wi];
        ws.active_screen = si;
        let screen = &mut ws.screens[si];
        screen.active_pane = target_pane;
        Some((ws.id, screen.id))
    } else {
        None
    };
    if let Some((workspace, screen)) = destination_path {
        mux.subscribers.update_surface_session_path(surface, workspace, screen, target_pane);
    }
    (true, topology_changed)
}
