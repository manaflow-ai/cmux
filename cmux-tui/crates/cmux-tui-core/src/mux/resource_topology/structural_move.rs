//! The durable plan for moving a pane's only tab to another pane, which
//! removes the source pane from its layout.

use super::*;

#[allow(clippy::too_many_arguments)]
/// Build the durable mutation plan for moving a sole tab across panes.
#[track_caller]
pub(in crate::mux) fn structural_tab_move_plan(
    mux: &Arc<Mux>,
    state: &mut State,
    registry: &WorkspaceRegistry,
    surface: SurfaceId,
    tab_id: TabPublicId,
    source_pane: PaneId,
    target_pane: PaneId,
    index: usize,
    result: impl FnOnce(&ResourceTopologySnapshot) -> anyhow::Result<Value>,
) -> anyhow::Result<ResourceMutationPlan> {
    let previous_active = state.active_pane();
    let source_location = state.screen_of(source_pane).context("source pane has no screen")?;
    let target_location = state.screen_of(target_pane).context("target pane has no screen")?;
    let source_workspace = state.workspace_at(source_location.0)?;
    let source_screen = state.screen_at(source_location.0, source_location.1)?;
    let source_screen_slot = source_screen.id;
    let source_screen_id = source_screen.public_id.clone();
    let source_screen_name = source_screen.name.clone();
    let source_workspace_id = source_workspace.public_id.clone();
    let source_active_screen = source_workspace.active_screen;
    let source_screen_ids = source_workspace
        .screens
        .iter()
        .map(|screen| (screen.id, screen.public_id.clone()))
        .collect::<Vec<_>>();
    let target_screen_id = state.screen_at(target_location.0, target_location.1)?.public_id.clone();
    let target_workspace = state.workspace_at(target_location.0)?;
    let target_workspace_id = target_workspace.public_id.clone();
    let target_workspace_key = target_workspace.key.clone();
    let source_pane_id = state.live_pane_public_id(source_pane)?.clone();
    let target_pane_id = state.live_pane_public_id(target_pane)?.clone();
    let mut source_layout = source_screen.layout_snapshot();
    let source_screen_remains = remove_pane_from_layout(&mut source_layout, source_pane);
    if source_screen_remains && source_layout.active_pane == source_pane {
        source_layout.active_pane =
            if source_screen_slot == target_location_screen(state, target_location)? {
                target_pane
            } else {
                source_layout.root.first_visible_pane()
            };
    }
    if source_layout.zoomed_pane == Some(source_pane) {
        source_layout.zoomed_pane = None;
    }

    let topology = registry.resource_topology_snapshot()?;
    let before = topology.clone();
    let mut after = topology;
    after.panes.retain(|pane| pane.public_id != source_pane_id);
    let target_order = {
        let mut target_tabs = after
            .tabs
            .iter()
            .filter(|tab| tab.pane_id == target_pane_id)
            .map(|tab| tab.public_id.clone())
            .collect::<Vec<_>>();
        let moved_index = index.min(target_tabs.len());
        target_tabs.insert(moved_index, tab_id.clone());
        reindex_target_tab_positions(&mut after.tabs, &target_pane_id, &target_tabs);
        target_tabs
    };
    let moved_tab = topology_tab(&after, &tab_id)?.clone();
    let target_record = {
        let pane = topology_pane_mut(&mut after, &target_pane_id)?;
        pane.active_tab = Some(tab_id.clone());
        pane.clone()
    };
    if !source_screen_remains {
        after.screens.retain(|screen| screen.public_id != source_screen_id);
    }
    after.active_workspace = Some(target_workspace_id.clone());
    set_active_screen(&mut after, &target_workspace_id, Some(target_screen_id.clone()));

    let mut changes = vec![
        ResourceChange::UpsertTab(moved_tab.clone()),
        ResourceChange::UpsertPane(target_record.clone()),
        ResourceChange::SetTabOrder { pane_id: target_pane_id.clone(), tab_ids: target_order },
        ResourceChange::TombstonePane { pane_id: source_pane_id.clone() },
    ];

    let target_durable = if source_screen_slot == target_location_screen(state, target_location)? {
        source_layout.active_pane = target_pane;
        registry_screen_from_layout(
            state,
            source_location.0,
            source_location.1,
            &source_layout,
            &after,
            source_screen_name.clone(),
        )?
    } else {
        let mut durable = topology_screen(&after, &target_screen_id)?.clone();
        durable.active_pane = target_pane_id.clone();
        durable
    };
    if let Some(screen) =
        after.screens.iter_mut().find(|screen| screen.public_id == target_screen_id)
    {
        *screen = target_durable.clone();
    }
    changes.push(ResourceChange::UpsertScreen(target_durable));

    let source_durable = if source_screen_remains && source_screen_id != target_screen_id {
        let durable = registry_screen_from_layout(
            state,
            source_location.0,
            source_location.1,
            &source_layout,
            &after,
            source_screen_name,
        )?;
        if let Some(screen) =
            after.screens.iter_mut().find(|screen| screen.public_id == source_screen_id)
        {
            *screen = durable.clone();
        }
        changes.push(ResourceChange::UpsertScreen(durable.clone()));
        Some(durable)
    } else {
        None
    };
    if !source_screen_remains {
        changes.push(ResourceChange::TombstoneScreen { screen_id: source_screen_id.clone() });
        changes.push(ResourceChange::SetScreenOrder {
            workspace_id: source_workspace_id.clone(),
            screen_ids: source_screen_ids
                .iter()
                .filter(|(id, _)| *id != source_screen_slot)
                .map(|(_, public_id)| public_id.clone())
                .collect(),
        });
    }

    let target_workspace_index = target_location.0;
    changes.push(ResourceChange::UpsertWorkspace {
        workspace: registry_workspace(
            state,
            target_workspace_index,
            registry.session_id().as_str(),
        )?,
        position: target_workspace_index,
        active_screen: Some(target_screen_id.clone()),
    });
    if source_workspace_id != target_workspace_id {
        let active_screen = if source_screen_remains {
            source_screen_ids.get(source_active_screen).map(|(_, public_id)| public_id.clone())
        } else {
            source_screen_ids
                .iter()
                .filter(|(id, _)| *id != source_screen_slot)
                .nth(source_active_screen.min(source_screen_ids.len().saturating_sub(2)))
                .map(|(_, public_id)| public_id.clone())
        };
        changes.push(ResourceChange::UpsertWorkspace {
            workspace: registry_workspace(
                state,
                source_location.0,
                registry.session_id().as_str(),
            )?,
            position: source_location.0,
            active_screen,
        });
        if let ContentPublicId::Terminal(terminal_id) = &moved_tab.content_id {
            let host_id =
                moved_tab.terminal_id.as_deref().context("terminal tab omitted its host id")?;
            let mut terminal = registry
                .terminal_snapshot()?
                .terminals
                .into_iter()
                .find(|terminal| terminal.terminal_id == host_id)
                .context("terminal has no durable host placement")?;
            terminal.workspace_key = target_workspace_key;
            changes
                .push(ResourceChange::UpsertTerminal { public_id: terminal_id.clone(), terminal });
        }
    }
    changes.push(ResourceChange::SetActiveWorkspace {
        workspace_id: Some(target_workspace_id.clone()),
    });

    // The focus change of the one focus path first, with the target and the
    // surviving source screen, then the moved tab and its pane (cx-gzh.26).
    let mut restated = vec![target_screen_id.clone()];
    if source_durable.is_some() {
        restated.push(source_screen_id.clone());
    }
    let mut deltas = focus_change_deltas(state, &before, &after, &restated, &[&target_pane_id])?;
    deltas.push(upsert(0, "tab", tab_id.as_str(), tab_value(&moved_tab, &after)?));
    let pane = pane_value(state, &target_record, &after)?;
    deltas.push(upsert(0, "pane", target_pane_id.as_str(), pane));
    for (sequence, delta) in deltas.iter_mut().enumerate() {
        delta["sequence"] = json!(sequence);
    }
    deltas.push(delete_delta(deltas.len(), "pane", source_pane_id.as_str()));
    if !source_screen_remains {
        deltas.push(delete_delta(deltas.len(), "screen", source_screen_id.as_str()));
    }

    // The result describes the state after the move.
    let result = result(&after)?;
    let source_screen_public = source_screen_id.clone();
    let target_screen_public = target_screen_id;
    let mux = Arc::clone(mux);
    Ok(ResourceMutationPlan::new(
        ResourcePatch { changes },
        result,
        Value::Array(deltas),
        move |state| {
            let moved = move_tab_in_state(&mux, state, surface, target_pane, index);
            debug_assert!(moved.0 && moved.1);
            if source_screen_remains
                && let Some((workspace, screen)) =
                    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
                        item.screens
                            .iter()
                            .position(|screen| screen.public_id == source_screen_public)
                            .map(|screen| (workspace, screen))
                    })
                && let Ok(screen) = state.screen_at_mut(workspace, screen)
            {
                overwrite_layout_snapshot(screen, source_layout);
            }
            #[allow(
                clippy::expect_used,
                reason = "INVARIANT: the plan was built from this state under the same lock, and moving one tab keeps the target screen"
            )]
            let (target_workspace, target_screen) = state
                .workspaces
                .iter()
                .enumerate()
                .find_map(|(workspace, item)| {
                    item.screens
                        .iter()
                        .position(|screen| screen.public_id == target_screen_public)
                        .map(|screen| (workspace, screen))
                })
                .expect("INVARIANT: planned target screen remains live");
            state.active_workspace = target_workspace;
            if let Ok(workspace) = state.workspace_at_mut(target_workspace) {
                workspace.active_screen = target_screen;
                if let Some(screen) = workspace.screens.get_mut(target_screen) {
                    screen.active_pane = target_pane;
                }
            }
            if previous_active != Some(target_pane) {
                stamp_pane_focus(&mux, state, target_pane);
            } else if let Some(pane) = state.panes.get_mut(&target_pane) {
                pane.active_at = mux.next_active_at();
            }
            Mux::rebuild_split_screen_index(state);
        },
    )
    .moving_tab(surface, target_pane, index))
}
