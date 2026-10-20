//! Tabs within a pane: close focus, moves within and across panes, and session paths.

use super::*;

#[test]
fn structural_test_mux_can_create_many_surfaces_without_ptys() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((120, 40))).unwrap();
    let pane = mux.with_state(|s| s.pane_of(first.id).unwrap());

    for _ in 0..450 {
        mux.new_tab(Some(pane), None, None).unwrap();
    }

    assert_eq!(mux.surface_count(), 451);
    mux.with_state(|s| {
        let pane = &s.panes[&pane];
        assert_eq!(pane.tabs.len(), 451);
        for surface in pane.tabs.iter().filter_map(|id| s.surfaces.get(id)) {
            assert_eq!(surface.kind(), SurfaceKind::Pty);
            assert_eq!(surface.size(), (120, 40));
            assert!(!surface.is_dead());
        }
    });
}

#[test]
fn closing_active_pane_focuses_most_recent_remaining_pane() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
    let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
    let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

    assert!(mux.focus_pane(p1));
    assert!(mux.focus_pane(p3));
    let previous_p1_focus = mux.with_state(|state| state.panes[&p1].focused_at);
    let events = mux.subscribe();
    mux.close_pane(p3).unwrap();

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut saw_closed = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(remaining).expect("pane close events arrive before timeout") {
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::PaneClosed, pane, .. })
                if pane == Some(p3) =>
            {
                saw_closed = true;
            }
            MuxEvent::TreeSelectionChanged if saw_closed => break,
            MuxEvent::TreeSelectionChanged => {
                panic!("selection resync arrived before the pane-closed delta")
            }
            _ => {}
        }
    }
    mux.with_state(|s| {
        assert_eq!(s.workspaces[0].screens[0].active_pane, p1);
        assert!(s.panes.contains_key(&p2));
        assert!(s.panes[&p1].focused_at > previous_p1_focus);
    });
}

#[test]
fn tabs_within_pane() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.new_tab(Some(pane), None, None).unwrap();

    mux.with_state(|s| {
        let p = &s.panes[&pane];
        assert_eq!(p.tabs, vec![s1.id, s2.id]);
        assert_eq!(p.active_tab, 1);
    });

    // Closing the active tab activates the previous one; the pane stays.
    mux.close_surface(s2.id).unwrap();
    mux.with_state(|s| {
        let p = &s.panes[&pane];
        assert_eq!(p.tabs, vec![s1.id]);
        assert_eq!(p.active_tab, 0);
        assert_eq!(s.workspaces.len(), 1);
    });

    // Closing the last tab collapses the pane and screen and closes the
    // workspace in the same commit (LAST-TAB-CLOSES-WORKSPACE).
    mux.close_surface(s1.id).unwrap();
    mux.with_state(|s| {
        assert!(s.workspaces.is_empty());
        assert_eq!(s.workspace_revision, 2);
    });
}

/// F6 (pane-active-tab-DESIGN.md I6, close-focus.md): closing the active tab
/// activates the next tab, else the previous one, as the app's strip does;
/// closing a background tab keeps the active tab.
#[test]
fn closing_the_active_tab_activates_the_next_tab_else_the_previous() {
    let mux = test_mux();
    let a = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|s| s.pane_of(a.id).unwrap());
    let b = mux.new_tab(Some(pane), None, None).unwrap();
    let c = mux.new_tab(Some(pane), None, None).unwrap();
    let d = mux.new_tab(Some(pane), None, None).unwrap();
    let active = |mux: &Arc<Mux>| mux.with_state(|s| s.panes[&pane].active_surface());

    mux.select_tab(Some(pane), Some(1), None);
    assert_eq!(active(&mux), Some(b.id));
    mux.close_surface(b.id).unwrap();
    assert_eq!(active(&mux), Some(c.id), "the next tab, not the previous");

    // A background tab before the active one closes: the active tab stays.
    mux.close_surface(a.id).unwrap();
    assert_eq!(active(&mux), Some(c.id));

    // The last tab closes: no next tab, so the previous one.
    mux.select_tab(Some(pane), Some(1), None);
    assert_eq!(active(&mux), Some(d.id));
    mux.close_surface(d.id).unwrap();
    assert_eq!(active(&mux), Some(c.id));
}

/// F10: moving a tab that sits before the active tab out of its pane keeps
/// the source pane's active tab, in memory and in the durable record.
#[test]
fn moving_a_tab_out_keeps_the_source_active_tab_in_memory_and_durably() {
    let mux = test_mux();
    let a = mux.new_workspace(None, None).unwrap();
    let source = mux.with_state(|s| s.pane_of(a.id).unwrap());
    let b = mux.new_tab(Some(source), None, None).unwrap();
    let c = mux.new_tab(Some(source), None, None).unwrap();
    let other = mux.split(source, SplitDir::Right, None).unwrap();
    let target = mux.with_state(|s| s.pane_of(other.id).unwrap());
    mux.select_tab(Some(source), Some(2), None);
    assert_eq!(mux.with_state(|s| s.panes[&source].active_surface()), Some(c.id));

    assert!(mux.move_tab(a.id, target, 0));

    mux.with_state(|s| {
        assert_eq!(s.panes[&source].tabs, vec![b.id, c.id]);
        assert_eq!(s.panes[&source].active_surface(), Some(c.id));
    });
    let (pane_id, c_id) = mux.with_state(|s| {
        (s.resource_indexes.pane_ids[&source].clone(), s.resource_indexes.tab_ids[&c.id].clone())
    });
    let durable = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let record = durable.panes.iter().find(|pane| pane.public_id == pane_id).unwrap();
    assert_eq!(record.active_tab, Some(c_id), "the durable record names the same active tab");
}

#[test]
fn closing_an_ordinary_tab_does_not_rebuild_the_split_index() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.split(pane, SplitDir::Right, None).unwrap();
    let ordinary_tab = mux.new_tab(Some(pane), None, None).unwrap();
    let sentinel = SplitId::MAX;
    {
        let mut state = mux.state.lock().unwrap();
        state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
    }

    mux.close_surface(ordinary_tab.id).unwrap();

    mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
    mux.close_surface(first.id).unwrap();
    mux.with_state(|state| assert!(!state.split_screens.contains_key(&sentinel)));
}

#[test]
fn move_tab_within_pane_clamps_and_tracks_active_tab() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.new_tab(Some(pane), None, None).unwrap();
    let s3 = mux.new_tab(Some(pane), None, None).unwrap();
    let pane_revision = mux.with_state(|s| s.pane_revision);

    assert!(mux.move_tab(s3.id, pane, 0));
    mux.with_state(|s| {
        let pane = &s.panes[&pane];
        assert_eq!(pane.tabs, vec![s3.id, s1.id, s2.id]);
        assert_eq!(pane.active_tab, 0);
    });

    assert!(mux.move_tab(s3.id, pane, 99));
    mux.with_state(|s| {
        let pane = &s.panes[&pane];
        assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
        assert_eq!(pane.active_tab, 2);
        assert_eq!(s.pane_revision, pane_revision);
    });
}

#[test]
fn move_tab_same_position_preserves_active_tab_and_emits_no_event() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.new_tab(Some(pane), None, None).unwrap();
    let s3 = mux.new_tab(Some(pane), None, None).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let events = mux.subscribe();

    assert!(!mux.move_tab(s2.id, pane, 1));
    mux.with_state(|s| {
        let pane = &s.panes[&pane];
        assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
        assert_eq!(pane.active_tab, 0);
    });
    assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
}

#[test]
fn move_tab_across_panes_collapses_empty_source_and_preserves_surface() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
    let original_count = mux.surface_count();
    let pane_revision = mux.with_state(|s| s.pane_revision);

    assert!(mux.move_tab(s1.id, p2, 0));
    mux.with_state(|s| {
        assert!(!s.panes.contains_key(&p1));
        let target = &s.panes[&p2];
        assert_eq!(target.tabs, vec![s1.id, s2.id]);
        assert_eq!(target.active_tab, 0);
        assert!(s.surfaces.contains_key(&s1.id));
        let mut ids = Vec::new();
        s.workspaces[0].screens[0].root.pane_ids(&mut ids);
        assert_eq!(ids, vec![p2]);
        assert_eq!(s.pane_revision, pane_revision + 1);
    });
    assert_eq!(mux.surface_count(), original_count);
}

#[test]
fn surface_session_subscription_tracks_real_tab_moves_without_layout_churn() {
    let mux = test_mux();
    mux.create_empty_workspace(None, None, None).unwrap();
    let target = mux.new_browser_tab("about:blank#target".into(), None, Some((80, 24))).unwrap();
    mux.create_empty_workspace(None, None, None).unwrap();
    let destination =
        mux.new_browser_tab("about:blank#destination".into(), None, Some((80, 24))).unwrap();
    let (source_screen, destination_screen, destination_pane) = mux.with_state(|state| {
        let source_pane = state.pane_of(target.id).unwrap();
        let destination_pane = state.pane_of(destination.id).unwrap();
        let (source_workspace_index, source_screen_index) = state.screen_of(source_pane).unwrap();
        let (destination_workspace_index, destination_screen_index) =
            state.screen_of(destination_pane).unwrap();
        (
            state.workspaces[source_workspace_index].screens[source_screen_index].id,
            state.workspaces[destination_workspace_index].screens[destination_screen_index].id,
            destination_pane,
        )
    });
    let events = mux.subscribe_surface_session(target.id).unwrap();

    assert!(mux.move_tab(target.id, destination_pane, 0));
    mux.emit(MuxEvent::LayoutChanged(source_screen, None));
    mux.emit(MuxEvent::LayoutChanged(destination_screen, None));

    let received = events.try_iter().collect::<Vec<_>>();
    assert!(received.iter().any(|event| matches!(event, MuxEvent::TreeChanged)));
    let layouts = received
        .iter()
        .filter_map(|event| match event {
            MuxEvent::LayoutChanged(screen, _) => Some(*screen),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert!(layouts.is_empty());
    mux.shutdown();
}

#[test]
fn move_tab_does_not_emit_layout_for_a_removed_source_screen() {
    let mux = test_mux();
    let source = mux.new_workspace(None, None).unwrap();
    let (workspace, source_screen) =
        mux.with_state(|state| (state.workspaces[0].id, state.workspaces[0].screens[0].id));
    let target = mux.new_screen(Some(workspace), None).unwrap();
    let target_pane = mux.with_state(|state| state.pane_of(target.id).unwrap());
    let events = mux.subscribe();

    assert!(mux.move_tab(source.id, target_pane, 0));
    mux.with_state(|state| {
        assert!(state.workspaces[0].screens.iter().all(|screen| screen.id != source_screen));
    });
    assert!(matches!(events.recv().unwrap(), MuxEvent::TreeChanged));
    assert!(events.try_iter().all(
        |event| !matches!(event, MuxEvent::LayoutChanged(screen, _) if screen == source_screen)
    ));
}
