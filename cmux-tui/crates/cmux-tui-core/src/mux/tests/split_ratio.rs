//! Split ratio commands: clamping, undo metadata, and stable split ids.

use super::*;

#[test]
fn set_ratio_updates_deepest_split_and_clamps() {
    let mux = test_mux();
    let (p1, p2, p3, _, _) = seed_split_ratio_tree(&mux);

    assert!(mux.set_ratio_checked(p1, SplitDir::Right, 0.8).is_ok());
    mux.with_state(|s| {
        let root = &s.workspaces[0].screens[0].root;
        let Node::Split { ratio: root_ratio, a, .. } = root else {
            panic!("root should be split");
        };
        assert_eq!(*root_ratio, 0.5);
        let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
            panic!("first child should be split");
        };
        assert_eq!(*inner_ratio, 0.8);
    });

    assert!(mux.set_ratio_checked(p2, SplitDir::Right, -1.0).is_ok());
    mux.with_state(|s| {
        let Node::Split { ratio, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        assert_eq!(*ratio, 0.05);
    });

    assert!(mux.set_ratio_checked(p3, SplitDir::Right, 2.0).is_ok());
    mux.with_state(|s| {
        let Node::Split { a, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        let Node::Split { ratio, .. } = a.as_ref() else {
            panic!("first child should be split");
        };
        assert_eq!(*ratio, 0.95);
    });

    assert!(matches!(
        mux.set_ratio_checked(9999, SplitDir::Right, 0.4),
        Err(LayoutRatioError::UnknownPaneSplit { pane: 9999 })
    ));
}

#[test]
fn unchanged_ratio_commands_preserve_undo_metadata_revision_and_events() {
    let mux = test_mux();
    let (p1, _, _, root_split, inner_split) = seed_split_ratio_tree(&mux);
    mux.state.lock().unwrap().workspaces[0].screens[0].creation_order_auto_layout =
        Some(vec![1, 2, 3]);
    let before = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (
            screen.layout_revision,
            screen.layout_undo.len(),
            screen.creation_order_auto_layout.clone(),
        )
    });
    let events = mux.subscribe();

    assert!(mux.set_split_ratio_checked(root_split, 0.5).is_ok());
    assert!(mux.set_ratio_checked(p1, SplitDir::Right, 0.5).is_ok());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(
            (
                screen.layout_revision,
                screen.layout_undo.len(),
                screen.creation_order_auto_layout.clone(),
            ),
            before
        );
        assert!(state.split_screens.contains_key(&root_split));
        assert!(state.split_screens.contains_key(&inner_split));
    });
    assert!(events.try_iter().next().is_none());
}

#[test]
fn set_split_ratio_updates_only_the_exact_split_and_clamps() {
    let mux = test_mux();
    let (_, _, _, root_split, inner_split) = seed_split_ratio_tree(&mux);
    mux.state.lock().unwrap().workspaces[0].screens[0].creation_order_auto_layout =
        Some(vec![1, 2, 3]);
    let events = mux.subscribe();

    assert!(mux.set_split_ratio_checked(root_split, 2.0).is_ok());
    mux.with_state(|s| {
        let Node::Split { id, ratio: root_ratio, a, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        assert_eq!(*id, root_split);
        assert_eq!(*root_ratio, 0.95);
        let Node::Split { id, ratio: inner_ratio, .. } = a.as_ref() else {
            panic!("first child should be split");
        };
        assert_eq!(*id, inner_split);
        assert_eq!(*inner_ratio, 0.5);
        assert!(s.workspaces[0].screens[0].creation_order_auto_layout.is_none());
    });
    assert!(matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(_)));
    assert!(events.try_recv().is_err());
    assert!(matches!(
        mux.set_split_ratio_checked(9999, 0.4),
        Err(LayoutRatioError::UnknownSplit { split: 9999 })
    ));
}

#[test]
fn dynamically_created_split_ids_remain_stable_across_tree_edits() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|s| s.pane_of(first.id).unwrap());
    let second = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|s| s.pane_of(second.id).unwrap());
    let original = mux.with_state(|s| {
        let Node::Split { id, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        *id
    });

    let third = mux.split(p2, SplitDir::Down, None).unwrap();
    let p3 = mux.with_state(|s| s.pane_of(third.id).unwrap());
    let nested = mux.with_state(|s| {
        let Node::Split { b, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should remain split");
        };
        let Node::Split { id, .. } = b.as_ref() else {
            panic!("second child should be split");
        };
        *id
    });
    let screen = mux.with_state(|state| state.workspaces[0].screens[0].id);
    mux.with_state(|state| {
        assert_eq!(state.split_screens.get(&original).map(|location| location.2), Some(screen));
        assert_eq!(state.split_screens.get(&nested).map(|location| location.2), Some(screen));
    });
    assert!(mux.swap_panes(p1, p3));
    assert!(mux.set_split_ratio_checked(original, 0.7).is_ok());

    mux.with_state(|s| {
        let Node::Split { id, ratio, .. } = &s.workspaces[0].screens[0].root else {
            panic!("root should remain split");
        };
        assert_eq!(*id, original);
        assert_eq!(*ratio, 0.7);
    });

    mux.close_surface(third.id).unwrap();
    mux.with_state(|state| {
        assert!(!state.split_screens.contains_key(&original));
        assert!(state.split_screens.contains_key(&nested));
    });
}
