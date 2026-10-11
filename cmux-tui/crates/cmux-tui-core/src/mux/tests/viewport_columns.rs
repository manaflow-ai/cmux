//! Viewport columns: new pane right, neighbor navigation, and projected split ratios.

use super::*;

#[test]
fn new_pane_right_wraps_the_screen_in_a_viewport_split() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());

    let appended =
        mux.new_pane_right(second_pane, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
    let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, appended_pane);
        assert_eq!(screen.zoomed_pane, None);
        assert_eq!(screen.viewport_splits.len(), 1);
        let Node::Split { id, dir, ratio, a, b } = &screen.root else {
            panic!("viewport pane must wrap the screen root");
        };
        assert_eq!(*dir, SplitDir::Right);
        assert!((*ratio - 0.6).abs() < f32::EPSILON);
        assert!(a.contains(first_pane));
        assert!(a.contains(second_pane));
        assert!(matches!(b.as_ref(), Node::Leaf(pane) if *pane == appended_pane));
        assert_eq!(screen.viewport_splits[id], DEFAULT_VIEWPORT_PANE_WIDTH);

        let layout = layout_screen_with_viewport(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 24 },
            Some(screen.active_pane),
            screen.viewport_base_width.unwrap_or(1.0),
            &screen.viewport_splits,
        );
        assert_eq!(layout.virtual_width, 133);
        assert_eq!(layout.rect_of(first_pane).unwrap().width, 40);
        assert_eq!(layout.rect_of(second_pane).unwrap().width, 40);
        assert_eq!(
            layout.rect_of(appended_pane).unwrap(),
            VirtualRect { x: 80, y: 0, width: 53, height: 24 }
        );
    });
    assert_eq!(mux.pane_neighbor(second_pane, Direction::Right).unwrap(), Some(appended_pane));
    assert_eq!(mux.pane_neighbor(appended_pane, Direction::Left).unwrap(), Some(second_pane));
}

#[test]
fn viewport_neighbor_navigation_remains_adjacent_past_u16_layout_extent() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut panes = vec![first_pane];

    for _ in 0..12 {
        let previous = *panes.last().unwrap();
        let surface =
            mux.new_pane_right(previous, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
        panes.push(mux.with_state(|state| state.pane_of(surface.id).unwrap()));
    }

    for pair in panes.windows(2) {
        let [left, right] = pair else { unreachable!() };
        assert_eq!(mux.pane_neighbor(*left, Direction::Right).unwrap(), Some(*right));
        assert_eq!(mux.pane_neighbor(*right, Direction::Left).unwrap(), Some(*left));
        assert_eq!(mux.pane_focus_neighbor(*left, Direction::Right).unwrap(), Some(*right));
        assert_eq!(mux.pane_focus_neighbor(*right, Direction::Left).unwrap(), Some(*left));
    }
}

#[test]
fn new_pane_right_rejects_invalid_width_before_spawning() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let surfaces = mux.with_state(|state| state.surfaces.len());

    assert!(mux.new_pane_right(pane, 0.0, None).is_err());
    assert_eq!(mux.with_state(|state| state.surfaces.len()), surfaces);
}

#[test]
fn new_pane_right_discards_spawn_when_target_disappears_before_attachment() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let weak = Arc::downgrade(&mux);
    *mux.viewport_split_after_spawn.lock().unwrap() = Some(Arc::new(move || {
        weak.upgrade().unwrap().close_pane_for_resource_effect(first_pane).unwrap();
    }));

    let error = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap_err();

    assert_eq!(error.to_string(), "pane creation failed");
    mux.with_state(|state| {
        assert!(state.surfaces.is_empty());
        assert!(state.panes.is_empty());
        assert!(state.workspaces[0].screens.is_empty());
    });
}

#[test]
fn viewport_columns_resize_independently() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let appended =
        mux.new_pane_right(second_pane, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
    let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());

    assert!(mux.set_viewport_pane_width(first_pane, 0.75));
    assert!(mux.set_viewport_pane_width(appended_pane, 0.5));
    assert!(!mux.set_viewport_pane_width(appended_pane, 0.0));

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.viewport_base_width, Some(0.75));
        let appended_split = match screen
            .root
            .viewport_column_owner(appended_pane, &screen.viewport_splits)
            .unwrap()
        {
            ViewportColumn::Split(split) => split,
            ViewportColumn::Base => panic!("appended pane must own a viewport split"),
        };
        assert_eq!(screen.viewport_splits[&appended_split], 0.5);
        let Node::Split { ratio, .. } = &screen.root else {
            panic!("viewport layout must retain its root split");
        };
        assert!((*ratio - 0.6).abs() < f32::EPSILON);

        let layout = layout_screen_with_viewport(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 24 },
            Some(screen.active_pane),
            screen.viewport_base_width.unwrap(),
            &screen.viewport_splits,
        );
        assert_eq!(layout.virtual_width, 100);
        assert_eq!(layout.rect_of(first_pane).unwrap().width, 30);
        assert_eq!(layout.rect_of(second_pane).unwrap().width, 30);
        assert_eq!(
            layout.rect_of(appended_pane).unwrap(),
            VirtualRect { x: 60, y: 0, width: 40, height: 24 }
        );
    });
}

#[test]
fn projected_viewport_split_ratio_resizes_the_authoritative_column() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let appended = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());
    let split = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        match &screen.root {
            Node::Split { id, .. } => *id,
            _ => panic!("viewport layout must expose a compatibility split"),
        }
    });

    let events = mux.subscribe();
    assert!(mux.set_split_ratio_checked(split, 0.5).is_ok());
    assert!(matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(_)));
    let after_change = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.layout_revision, screen.layout_undo.len())
    });
    assert!(mux.set_split_ratio_checked(split, 0.5).is_ok());
    assert!(matches!(
        mux.set_split_ratio_checked(split, 0.25),
        Err(LayoutRatioError::UnrepresentableViewportWidth { split: rejected, .. })
            if rejected == split
    ));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!((screen.layout_revision, screen.layout_undo.len()), after_change);
        assert_eq!(screen.viewport_splits[&split], 1.0);
        assert_eq!(
            screen
                .layout_columns
                .iter()
                .find(|column| column.root.contains(appended_pane))
                .map(|column| column.width),
            Some(1.0)
        );
        assert!(matches!(
            &screen.root,
            Node::Split { id, ratio, .. }
                if *id == split && (*ratio - 0.5).abs() < f32::EPSILON
        ));
        assert!(state.split_screens.contains_key(&split));
    });
    assert!(events.try_iter().next().is_none());
}

fn seed_high_ratio_viewport_projection() -> (Arc<Mux>, PaneId, SplitId) {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let middle = mux.new_pane_right(first_pane, 1.0, Some((78, 22))).unwrap();
    let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
    let right = mux.new_pane_right(middle_pane, MIN_VIEWPORT_PANE_WIDTH, Some((6, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let split = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let Node::Split { id, ratio, .. } = &screen.root else {
            panic!("three columns should expose a projected root split");
        };
        assert!((*ratio - (2.0 / 2.1)).abs() < f32::EPSILON);
        *id
    });
    (mux, right_pane, split)
}

fn assert_high_ratio_projection_resize_applied(
    mux: &Mux,
    expected_width: f32,
    undo_count_before: usize,
) {
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(
            (screen.layout_columns[2].width - expected_width).abs() < 1e-6,
            "projected ratio should update authoritative width: {:?}",
            screen.layout_columns
        );
        assert_eq!(screen.layout_undo.len(), undo_count_before + 1);
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn maximum_projected_split_ratio_still_resizes_authoritative_column() {
    let (mux, _right_pane, split) = seed_high_ratio_viewport_projection();
    let expected_width = 2.0 * (1.0 - 0.95) / 0.95;
    let undo_count_before =
        mux.with_state(|state| state.workspaces[0].screens[0].layout_undo.len());
    let events = mux.subscribe();

    assert!(mux.set_split_ratio_checked(split, 0.95).is_ok());

    assert_high_ratio_projection_resize_applied(&mux, expected_width, undo_count_before);
    assert!(matches!(events.try_recv(), Ok(MuxEvent::LayoutChanged(_))));
}

#[test]
fn maximum_pane_addressed_ratio_still_resizes_authoritative_column() {
    let (mux, right_pane, _split) = seed_high_ratio_viewport_projection();
    let expected_width = 2.0 * (1.0 - 0.95) / 0.95;
    let undo_count_before =
        mux.with_state(|state| state.workspaces[0].screens[0].layout_undo.len());
    let events = mux.subscribe();

    assert!(mux.set_ratio_checked(right_pane, SplitDir::Right, 0.95).is_ok());

    assert_high_ratio_projection_resize_applied(&mux, expected_width, undo_count_before);
    assert!(matches!(events.try_recv(), Ok(MuxEvent::TreeChanged)));
    assert!(matches!(events.try_recv(), Ok(MuxEvent::LayoutChanged(_))));
}

#[test]
fn set_ratio_resizes_a_projected_viewport_split() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();

    assert!(mux.set_ratio_checked(first_pane, SplitDir::Right, 0.5).is_ok());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let Node::Split { id, ratio, .. } = &screen.root else {
            panic!("viewport layout must expose a compatibility split");
        };
        assert!((*ratio - 0.5).abs() < f32::EPSILON);
        assert_eq!(screen.viewport_splits[id], 1.0);
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn new_pane_right_inserts_after_the_target_viewport_column() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let layout = layout_screen_with_viewport(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 24 },
            Some(screen.active_pane),
            screen.viewport_base_width.unwrap(),
            &screen.viewport_splits,
        );
        assert_eq!(
            layout.panes.iter().map(|(pane, _)| *pane).collect::<Vec<_>>(),
            vec![first_pane, middle_pane, second_pane]
        );
        assert_eq!(layout.rect_of(first_pane).unwrap().x, 0);
        assert_eq!(layout.rect_of(middle_pane).unwrap().x, 80);
        assert_eq!(layout.rect_of(second_pane).unwrap().x, 120);
    });
}

#[test]
fn viewport_self_swap_is_a_noop_without_undo_history_or_events() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let before = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.layout_revision, screen.layout_undo.len(), format!("{:?}", screen.root))
    });
    let events = mux.subscribe();

    assert!(!mux.swap_panes(right_pane, right_pane));

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_revision, before.0);
        assert_eq!(screen.layout_undo.len(), before.1);
        assert_eq!(format!("{:?}", screen.root), before.2);
    });
    assert!(events.try_iter().next().is_none());
}
