//! Layout application, directional focus, pane swap and zoom, and split collapse.

use super::*;

fn leaf_spec() -> LayoutSpec {
    LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None })
}

fn node_shape(node: &Node) -> String {
    match node {
        Node::Leaf(_) => "leaf".to_string(),
        Node::Split { dir, ratio, a, b, .. } => {
            let dir = match dir {
                SplitDir::Right => "right",
                SplitDir::Down => "down",
            };
            format!("{dir}:{ratio:.2}({}, {})", node_shape(a), node_shape(b))
        }
        Node::Stack { panes, expanded } => format!("stack:{panes:?}:{expanded}"),
    }
}

fn spec_shape(spec: &LayoutSpec) -> String {
    match spec {
        LayoutSpec::Leaf(_) => "leaf".to_string(),
        LayoutSpec::Split { dir, ratio, a, b } => {
            let dir = match dir {
                SplitDir::Right => "right",
                SplitDir::Down => "down",
            };
            format!("{dir}:{:.2}({}, {})", clamp_split_ratio(*ratio), spec_shape(a), spec_shape(b))
        }
        LayoutSpec::Stack { pane_count, expanded_index } => {
            format!("stack:{pane_count}:{expanded_index}")
        }
    }
}

fn leaf_order(node: &Node) -> Vec<PaneId> {
    let mut ids = Vec::new();
    node.pane_ids(&mut ids);
    ids
}

fn screen_root(mux: &Mux, screen: ScreenId) -> Node {
    mux.with_state(|s| {
        s.workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .find(|candidate| candidate.id == screen)
            .unwrap()
            .root
            .clone()
    })
}

#[test]
fn apply_layout_round_trip_reproduces_tree_shape_and_ratios() {
    let mux = test_mux();
    let spec = split_spec(
        SplitDir::Right,
        0.33,
        leaf_spec(),
        split_spec(SplitDir::Down, 0.67, leaf_spec(), leaf_spec()),
    );
    let first = mux.apply_layout(None, Some("round-trip".into()), &spec, None).unwrap();
    let exported_shape = node_shape(&screen_root(&mux, first.screen));
    mux.with_state(|state| assert_eq!(state.workspaces[0].name, "workspace-1"));

    let round_trip_spec = mux.with_state(|s| {
        fn from_node(node: &Node) -> LayoutSpec {
            match node {
                Node::Leaf(_) => leaf_spec(),
                Node::Split { dir, ratio, a, b, .. } => {
                    split_spec(*dir, *ratio, from_node(a), from_node(b))
                }
                Node::Stack { panes, expanded } => LayoutSpec::Stack {
                    pane_count: panes.len(),
                    expanded_index: panes
                        .iter()
                        .position(|pane| pane == expanded)
                        .expect("valid stack expansion"),
                },
            }
        }
        from_node(&s.workspaces[0].screens[0].root)
    });
    let second =
        mux.apply_layout(None, Some("round-trip-2".into()), &round_trip_spec, None).unwrap();
    let applied_shape = node_shape(&screen_root(&mux, second.screen));

    assert_eq!(exported_shape, spec_shape(&spec));
    assert_eq!(applied_shape, exported_shape);
    assert_eq!(first.panes.len(), 3);
    assert_eq!(second.panes.len(), 3);
}

#[test]
fn apply_layout_holds_target_workspace_lifecycle_through_commit() {
    let mux = test_mux();
    let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
    let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Arc::new(Mutex::new(release_rx));
    *mux.layout_apply_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
        move || {
            reserved_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
        }
    }));
    let apply = std::thread::spawn({
        let mux = mux.clone();
        move || mux.apply_layout(Some(target.workspace), None, &leaf_spec(), None)
    });
    reserved_rx.recv().unwrap();

    let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
    let close = std::thread::spawn({
        let mux = mux.clone();
        move || {
            close_done_tx.send(mux.close_workspace_at_revision(target.workspace, Some(1))).unwrap();
        }
    });
    let premature_close = close_done_rx.recv_timeout(Duration::from_millis(250));
    let closed_early = premature_close.is_ok();
    release_tx.send(()).unwrap();
    let applied = apply.join();
    let close_result = match premature_close {
        Ok(result) => result,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => close_done_rx.recv().unwrap(),
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            panic!("workspace close result channel disconnected")
        }
    };
    close.join().unwrap();
    *mux.layout_apply_after_workspace_reservation.lock().unwrap() = None;

    assert!(!closed_early, "workspace closed before layout commit");
    assert!(applied.unwrap().is_ok());
    assert_eq!(close_result.unwrap(), Some(2));
    mux.shutdown();
}

#[test]
fn apply_layout_constructs_stack_with_requested_expansion() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(
            None,
            Some("stack".into()),
            &LayoutSpec::Stack { pane_count: 3, expanded_index: 1 },
            None,
        )
        .unwrap();
    let root = screen_root(&mux, applied.screen);

    assert!(matches!(
        root,
        Node::Stack { ref panes, expanded }
            if panes.len() == 3 && expanded == applied.panes[1].pane
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].active_pane, applied.panes[1].pane);
    });
}

#[test]
fn pane_neighbor_returns_directional_adjacency() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(
            None,
            None,
            &split_spec(
                SplitDir::Right,
                0.5,
                leaf_spec(),
                split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
            ),
            None,
        )
        .unwrap();
    let p1 = applied.panes[0].pane;
    let p2 = applied.panes[1].pane;
    let p3 = applied.panes[2].pane;

    assert_eq!(mux.pane_neighbor(p1, Direction::Right).unwrap(), Some(p2));
    assert_eq!(mux.pane_neighbor(p2, Direction::Down).unwrap(), Some(p3));
    assert_eq!(mux.pane_neighbor(p1, Direction::Left).unwrap(), None);
}

#[test]
fn focus_direction_moves_active_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
    assert!(mux.focus_pane(p1));

    assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), p2);
    mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].active_pane, p2));
    assert!(mux.focus_direction(None, Direction::Right).is_err());
}

#[test]
fn focus_direction_returns_to_most_recently_focused_adjacent_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.split(left, SplitDir::Right, None).unwrap();
    let top_right = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let bottom = mux.split(top_right, SplitDir::Down, None).unwrap();
    let bottom_right = mux.with_state(|state| state.pane_of(bottom.id).unwrap());

    assert!(mux.focus_pane(top_right));
    assert!(mux.focus_pane(bottom_right));
    assert_eq!(mux.focus_direction(None, Direction::Left).unwrap(), left);
    assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), bottom_right);
}

#[test]
fn fresh_layout_focus_uses_layout_order_for_unfocused_candidates() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(
            None,
            None,
            &split_spec(
                SplitDir::Right,
                0.5,
                leaf_spec(),
                split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
            ),
            None,
        )
        .unwrap();

    assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), applied.panes[1].pane);
}

#[test]
fn selecting_a_tab_in_an_inactive_pane_does_not_change_focus_recency() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
    let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
    assert!(mux.focus_pane(left));
    mux.new_tab(Some(right), None, None).unwrap();
    let before = mux.with_state(|state| state.panes[&right].focused_at);

    mux.select_tab(Some(right), Some(0), None);

    assert_eq!(mux.with_state(|state| state.panes[&right].focused_at), before);
}

#[test]
fn moving_a_tab_to_another_pane_stamps_the_new_focus() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let extra = mux.new_tab(Some(left), None, None).unwrap();
    let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
    let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
    assert!(mux.focus_pane(left));
    let before = mux.with_state(|state| state.panes[&right].focused_at);

    assert!(mux.move_tab(extra.id, right, 0));

    mux.with_state(|state| {
        assert_eq!(state.active_pane(), Some(right));
        assert!(state.panes[&right].focused_at > before);
    });
}

#[test]
fn swap_pane_exchanges_leaf_positions_and_preserves_surfaces() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(None, None, &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()), None)
        .unwrap();
    let p1 = applied.panes[0].pane;
    let s1 = applied.panes[0].surface;
    let p2 = applied.panes[1].pane;
    let s2 = applied.panes[1].surface;
    assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p1, p2]);

    assert!(mux.swap_panes(p1, p2));
    assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p2, p1]);
    mux.with_state(|s| {
        assert_eq!(s.panes[&p1].tabs, vec![s1]);
        assert_eq!(s.panes[&p2].tabs, vec![s2]);
    });
}

#[test]
fn zoom_pane_toggles_screen_zoom_state() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(None, None, &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()), None)
        .unwrap();
    let p2 = applied.panes[1].pane;

    let zoomed = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
    assert_eq!(zoomed.zoomed_pane, Some(p2));
    mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, Some(p2)));

    let restored = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
    assert_eq!(restored.zoomed_pane, None);
    mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, None));
}

#[test]
fn process_info_metadata_is_recorded_for_spawned_surface() {
    let mux = test_mux();
    let cwd = std::env::temp_dir().to_string_lossy().into_owned();
    let applied = mux
        .apply_layout(
            None,
            None,
            &LayoutSpec::Leaf(LayoutLeafSpec {
                cwd: Some(cwd.clone()),
                command: Some(vec!["echo".into(), "ok".into()]),
            }),
            None,
        )
        .unwrap();
    let surface = mux.surface(applied.panes[0].surface).unwrap();

    assert_eq!(surface.process_id(), Some(surface.id as u32));
    assert_eq!(surface.spawn_command().as_deref(), Some("echo ok"));
    assert_eq!(surface.spawn_cwd().as_deref(), Some(cwd.as_str()));
}

#[test]
fn split_and_close_collapses_tree() {
    let mux = test_mux();
    let s1 = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
    let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
    let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
    let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

    mux.with_state(|s| {
        let mut ids = Vec::new();
        s.workspaces[0].screens[0].root.pane_ids(&mut ids);
        assert_eq!(ids, vec![p1, p2, p3]);
    });

    mux.close_pane(p2).unwrap();
    mux.with_state(|s| {
        let mut ids = Vec::new();
        s.workspaces[0].screens[0].root.pane_ids(&mut ids);
        assert_eq!(ids, vec![p1, p3]);
    });

    mux.close_pane(p1).unwrap();
    mux.close_pane(p3).unwrap();
    assert_eq!(mux.surface_count(), 0);
    // The last pane's close closes the emptied workspace in its commit.
    mux.with_state(|s| {
        assert!(s.workspaces.is_empty());
        assert_eq!(s.workspace_revision, 2);
    });
}
