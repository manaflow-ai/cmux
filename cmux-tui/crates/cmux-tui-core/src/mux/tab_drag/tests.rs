use super::*;

fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone())).unwrap_or_default()
}

fn pane_of(mux: &Mux, surface: SurfaceId) -> PaneId {
    mux.with_state(|state| state.pane_of(surface)).unwrap()
}

fn screen_panes(mux: &Mux, pane: PaneId) -> Vec<PaneId> {
    mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].screens[screen].root.pane_ids_vec()
    })
}

fn transaction_of(events: &MuxEventReceiver, surface: SurfaceId) -> Option<String> {
    std::iter::from_fn(|| events.try_recv().ok()).find_map(|event| match event {
        MuxEvent::TreeDelta(delta)
            if delta.kind == TreeDeltaKind::TabChanged && delta.surface == Some(surface) =>
        {
            delta.transaction.map(|transaction| transaction.to_string())
        }
        _ => None,
    })
}

#[test]
fn cmux_next_tab_to_split_is_atomic_undoable_and_durable() {
    let mux = Mux::new_for_test("tab-drag-split", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, first);
    let second = mux.new_tab(Some(origin), None, None).unwrap().id;
    // A pane's only tab cannot be split out of it.
    let lone = mux.new_workspace(None, None).unwrap().id;
    assert!(
        mux.move_tab_to_split(lone, pane_of(&mux, lone), TabDropEdge::Right, None, None).is_err()
    );

    let events = mux.subscribe();
    let outcome = mux
        .move_tab_to_split(second, origin, TabDropEdge::Left, Some(0.3), Some("drag-1".into()))
        .unwrap();
    assert!(outcome.undoable);
    assert_eq!(pane_of(&mux, second), outcome.pane);
    assert_eq!(tabs(&mux, origin), vec![first]);
    assert_eq!(tabs(&mux, outcome.pane), vec![second]);
    // Left edge: the new pane comes first in the split.
    assert_eq!(screen_panes(&mux, origin), vec![outcome.pane, origin]);
    assert_eq!(transaction_of(&events, second).as_deref(), Some("drag-1"));
    drop(events);

    match mux.undo_layout(origin, None, false).unwrap() {
        LayoutUndoResult::Undone { .. } => {}
        other => panic!("tab drag undo required confirmation: {other:?}"),
    }
    assert_eq!(tabs(&mux, origin), vec![first, second]);
    assert_eq!(screen_panes(&mux, origin), vec![origin]);
    assert!(mux.with_state(|state| !state.panes.contains_key(&outcome.pane)));

    // Redo the drag: the split and the moved tab are durable topology.
    let outcome = mux.move_tab_to_split(second, origin, TabDropEdge::Bottom, None, None).unwrap();
    let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&second].clone());
    let pane_id = mux.with_state(|state| state.resource_indexes.pane_ids[&outcome.pane].clone());
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let durable_tab = topology.tabs.iter().find(|tab| tab.public_id == tab_id).unwrap();
    assert_eq!(durable_tab.pane_id, pane_id);
    assert!(topology.panes.iter().any(|pane| pane.public_id == pane_id));
}

/// User requirement 2026-10-02: a pane's only tab dropped on its own
/// pane's edge splits the pane, and a fresh terminal stays in the old
/// pane (`respawn`). The moved tab keeps its terminal; the echo carries
/// the transaction; without a respawn the same drop is still refused.
/// Review finding 2026-10-02: the respawn split runs in two commits,
/// so the split checks that the pane still holds exactly the fresh and
/// the dragged tab. A pane another client changed in between refuses
/// the split before anything moves.
#[test]
fn cmux_next_respawn_split_refuses_a_pane_that_changed_since_the_fresh_tab() {
    let mux = Mux::new_for_test("tab-drag-respawn-guard", SurfaceOptions::default());
    let dragged = mux.new_workspace(None, None).unwrap().id;
    let pane = pane_of(&mux, dragged);
    let fresh = mux.new_tab(Some(pane), None, None).unwrap().id;
    let other = mux.new_tab(Some(pane), None, None).unwrap().id;
    let before = tabs(&mux, pane);
    let split = TabDragDestination::Split { pane, edge: TabDropEdge::Right, ratio: None };
    let guard = SourceGuard { pane, tabs: [fresh, dragged] };
    let error = mux.commit_tab_drag_guarded(dragged, split, None, Some(guard)).unwrap_err();
    assert!(error.to_string().contains("stale"), "{error:#}");
    assert_eq!(tabs(&mux, pane), before);
    assert_eq!(screen_panes(&mux, pane), vec![pane]);
    // With the expected pane the same split commits.
    mux.close_surface(other).unwrap();
    let guard = SourceGuard { pane, tabs: [fresh, dragged] };
    let outcome = mux.commit_tab_drag_guarded(dragged, split, None, Some(guard)).unwrap();
    assert_eq!(tabs(&mux, outcome.pane), vec![dragged]);
    assert_eq!(tabs(&mux, pane), vec![fresh]);
}

#[test]
fn cmux_next_only_tab_splits_its_own_pane_with_a_respawned_terminal() {
    let mux = Mux::new_for_test("tab-drag-respawn", SurfaceOptions::default());
    let lone = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, lone);
    let terminal = mux.surface(lone).unwrap().terminal_public_id().map(ToString::to_string);
    assert!(mux.move_tab_to_split(lone, origin, TabDropEdge::Right, None, None).is_err());

    let events = mux.subscribe();
    let outcome = mux
        .move_tab_to_split_respawning(
            lone,
            origin,
            TabDropEdge::Right,
            None,
            SplitRespawn::Terminal(TerminalSpawnOptions::default()),
            Some("drag-respawn".into()),
        )
        .unwrap();
    assert_eq!(tabs(&mux, outcome.pane), vec![lone]);
    let fresh = tabs(&mux, origin);
    assert_eq!(fresh.len(), 1);
    assert_ne!(fresh[0], lone);
    assert_eq!(screen_panes(&mux, origin), vec![origin, outcome.pane]);
    // The moved tab keeps its terminal; the fresh tab is a new one.
    assert_eq!(mux.surface(lone).unwrap().terminal_public_id().map(ToString::to_string), terminal);
    assert_ne!(
        mux.surface(fresh[0]).unwrap().terminal_public_id().map(ToString::to_string),
        terminal
    );
    assert_eq!(transaction_of(&events, lone).as_deref(), Some("drag-respawn"));
    drop(events);
    // The tree is durable: both tabs are in the resource topology.
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    for surface in [lone, fresh[0]] {
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&surface].clone());
        assert!(topology.tabs.iter().any(|tab| tab.public_id == tab_id));
    }

    // A respawn is only for the pane's only tab: with two tabs it is refused
    // and nothing is created.
    let before = tabs(&mux, outcome.pane);
    let second = mux.new_tab(Some(outcome.pane), None, None).unwrap().id;
    let count = mux.with_state(|state| state.surfaces.len());
    assert!(
        mux.move_tab_to_split_respawning(
            second,
            outcome.pane,
            TabDropEdge::Left,
            None,
            SplitRespawn::Terminal(TerminalSpawnOptions::default()),
            None,
        )
        .is_err()
    );
    assert_eq!(mux.with_state(|state| state.surfaces.len()), count);
    assert_eq!(tabs(&mux, outcome.pane), [before, vec![second]].concat());
}

#[test]
fn cmux_next_tab_to_column_and_cross_pane_moves() {
    let mux = Mux::new_for_test("tab-drag-column", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, first);
    let second = mux.new_tab(Some(origin), None, None).unwrap().id;
    let third = mux.new_tab(Some(origin), None, None).unwrap().id;

    let column = mux.move_tab_to_column(third, origin, None, None, None, None).unwrap();
    assert!(column.undoable);
    let columns = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(origin).unwrap();
        state.workspaces[workspace].screens[screen].layout_columns.len()
    });
    assert_eq!(columns, 2);
    assert_eq!(tabs(&mux, column.pane), vec![third]);
    assert!(mux.move_tab_to_column(second, origin, None, Some(3.0), None, None).is_err());

    // A cross-pane move on one screen is undoable too.
    let (moved, undoable) = mux.move_tab_with_undo(second, column.pane, 1, Some("drag-2".into()));
    assert!(moved && undoable);
    assert_eq!(tabs(&mux, column.pane), vec![third, second]);
    mux.undo_layout(origin, None, false).unwrap();
    assert_eq!(tabs(&mux, origin), vec![first, second]);
    mux.undo_layout(origin, None, false).unwrap();
    assert_eq!(tabs(&mux, origin), vec![first, second, third]);

    // Moving a pane's last tab into a split elsewhere removes the pane
    // and is not undoable.
    let split = mux.move_tab_to_split(third, origin, TabDropEdge::Right, None, None).unwrap();
    let moved = mux.move_tab_to_split(third, origin, TabDropEdge::Top, None, None).unwrap();
    assert!(!moved.undoable);
    assert!(mux.with_state(|state| !state.panes.contains_key(&split.pane)));
    assert_eq!(tabs(&mux, moved.pane), vec![third]);
}

#[test]
fn cmux_next_tab_to_new_workspace_places_it_in_a_group() {
    let mux = Mux::new_for_test("tab-drag-workspace", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, first);
    let second = mux.new_tab(Some(origin), None, None).unwrap().id;
    let member = mux.create_empty_workspace(Some("member".into()), None, None).unwrap();
    mux.create_workspace_group(Some("g".into()), "G".into(), None, false, None).unwrap();
    mux.move_workspace_to_group(
        None,
        Some(&member.key),
        Some("g".into()),
        None,
        None,
        None,
        &WorkspaceMutation::daemon_local("tab-drag-test"),
    )
    .unwrap();
    assert!(mux.move_tab_to_new_workspace(second, Some("missing".into()), None, None).is_err());
    let workspace = mux.move_tab_to_new_workspace(second, Some("g".into()), Some(0), None).unwrap();
    let (order, key) = mux.with_state(|state| {
        (
            state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
            state.workspace_by_id(workspace).unwrap().key.clone(),
        )
    });
    // In-group index 0 places the new workspace before the member.
    let new_index = order.iter().position(|id| *id == workspace).unwrap();
    let member_index = order.iter().position(|id| *id == member.workspace).unwrap();
    assert_eq!(new_index + 1, member_index);
    assert_eq!(
        mux.presentation_snapshot().workspace(&key).and_then(|record| record.group.clone()),
        Some("g".to_string())
    );
    assert_eq!(tabs(&mux, pane_of(&mux, second)), vec![second]);
}
