//! Auto-layout new panes and stacked panes: expansion, focus, swaps, and splits.

use super::*;

#[test]
fn zellij_new_pane_uses_creation_order_after_manual_split() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_pane(p1, None).unwrap();
    let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let third = mux.split(p1, SplitDir::Down, None).unwrap();
    let p3 = mux.with_state(|state| state.pane_of(third.id).unwrap());
    let fourth = mux.new_pane(p3, None).unwrap();
    let p4 = mux.with_state(|state| state.pane_of(fourth.id).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let mut order = Vec::new();
        screen.root.pane_ids(&mut order);
        assert_eq!(order, vec![p1, p2, p3, p4]);
        assert_eq!(screen.creation_order_auto_layout.as_deref(), Some(order.as_slice()));
    });
}

#[test]
fn zellij_new_pane_exits_zoom_before_focusing_the_new_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();

    let new_surface = mux.new_pane(first_pane, None).unwrap();
    let new_pane = mux.with_state(|state| state.pane_of(new_surface.id).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, new_pane);
        assert_eq!(screen.zoomed_pane, None);
    });
}

#[test]
fn zellij_new_pane_emits_pane_added_delta_and_layout_change() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let (workspace, screen, first_pane) = mux.with_state(|state| {
        let workspace = &state.workspaces[0];
        let screen = &workspace.screens[0];
        (workspace.id, screen.id, state.pane_of(first.id).unwrap())
    });
    let events = mux.subscribe();

    let added = mux.new_pane(first_pane, None).unwrap();
    let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut saw_added = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(remaining).expect("pane creation events arrive") {
            MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::PaneAdded,
                workspace: event_workspace,
                screen: Some(event_screen),
                pane: Some(event_pane),
                surface: None,
                index: Some(1),
                ..
            }) if event_workspace == workspace
                && event_screen == screen
                && event_pane == added_pane =>
            {
                saw_added = true;
            }
            MuxEvent::LayoutChanged(event_screen) if saw_added && event_screen == screen => {
                break;
            }
            MuxEvent::LayoutChanged(_) if !saw_added => {
                panic!("layout invalidation arrived before the pane-added delta")
            }
            _ => {}
        }
    }
    assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
}

#[test]
fn closing_zellij_pane_reapplies_layout_for_remaining_count() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let mut surfaces = vec![first];
    let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    for _ in 0..4 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        surfaces.push(surface);
    }

    mux.close_surface(surfaces[0].id).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let order = screen.creation_order_auto_layout.as_ref().unwrap();
        assert_eq!(order.len(), 4);
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 200, height: 40 },
            Some(screen.active_pane),
        );
        assert_eq!(layout.rect_of(order[0]).unwrap().height, 40);
        let right_heights =
            order[1..].iter().map(|pane| layout.rect_of(*pane).unwrap().height).collect::<Vec<_>>();
        assert_eq!(right_heights, vec![13, 14, 13]);
    });
}

#[test]
fn closing_zellij_stack_pane_keeps_active_pane_expanded() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let mut surfaces = vec![first];
    let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    for _ in 1..14 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        surfaces.push(surface);
    }
    let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    let active_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
    assert!(mux.focus_pane(active_stack_pane));

    mux.close_surface(surfaces[1].id).unwrap();
    mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, active_stack_pane);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                        && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&active_stack_pane))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&active_stack_pane));
            assert!(layout.rect_of(active_stack_pane).unwrap().height > 1);
        });
}

#[test]
fn rebuilding_zellij_layout_preserves_stack_expansion_while_focus_is_elsewhere() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let mut surfaces = vec![first];
    let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    for _ in 1..14 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        surfaces.push(surface);
    }
    let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    let expanded_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
    assert!(mux.focus_pane(expanded_stack_pane));
    assert!(mux.focus_pane(leading_pane));

    mux.close_surface(surfaces[1].id).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&expanded_stack_pane));
        assert!(layout.rect_of(expanded_stack_pane).unwrap().height > 1);
    });
}

#[test]
fn moving_zellij_stack_pane_keeps_target_pane_expanded() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let mut surfaces = vec![first];
    let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    for _ in 1..14 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        surfaces.push(surface);
    }
    let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
    let target = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
    let events = mux.subscribe();

    assert!(mux.move_tab(surfaces[1].id, target, 0));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, target);
        assert!(matches!(
            &screen.root,
            Node::Split { dir: SplitDir::Right, a, b, .. }
                if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                    && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&target))
        ));
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&target));
        assert!(layout.rect_of(target).unwrap().height > 1);
    });
    assert!(events.try_iter().any(|event| matches!(event, MuxEvent::LayoutChanged(_))));
}

#[test]
fn swapping_zellij_stack_panes_keeps_active_pane_expanded() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut active = first_pane;
    for _ in 1..13 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    }

    assert!(mux.swap_panes(active, first_pane));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, active);
        assert!(screen.creation_order_auto_layout.is_none());
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&active));
        assert!(layout.rect_of(active).unwrap().height > 1);
    });
}

#[test]
fn closing_active_pane_in_damaged_stack_expands_replacement() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut active_surface = first;
    let mut active = first_pane;
    for _ in 1..14 {
        active_surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(active_surface.id).unwrap());
    }
    assert!(mux.swap_panes(active, first_pane));

    mux.close_surface(active_surface.id).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.creation_order_auto_layout.is_none());
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&screen.active_pane));
        assert!(layout.rect_of(screen.active_pane).unwrap().height > 1);
    });
}

#[test]
fn focusing_zellij_stack_header_expands_that_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let mut active = mux.with_state(|state| state.pane_of(first.id).unwrap());
    for _ in 1..13 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    }
    let stack_pane = mux.with_state(|state| {
        state.workspaces[0].screens[0].creation_order_auto_layout.as_ref().unwrap()[1]
    });

    assert!(mux.focus_pane(stack_pane));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, stack_pane);
        assert!(matches!(
            &screen.root,
            Node::Split { dir: SplitDir::Right, b, .. }
                if matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&stack_pane))
        ));
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&stack_pane));
        assert!(layout.rect_of(stack_pane).unwrap().height > 1);
    });
}

#[test]
fn focusing_outside_a_stack_emits_layout_changed() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut active = first_pane;
    for _ in 1..13 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    }
    let stack_pane = mux.with_state(|state| {
        state.workspaces[0].screens[0].creation_order_auto_layout.as_ref().unwrap()[1]
    });
    let outside = mux.split(active, SplitDir::Right, None).unwrap();
    let outside_pane = mux.with_state(|state| state.pane_of(outside.id).unwrap());
    assert!(mux.focus_pane(stack_pane));
    let events = mux.subscribe();

    assert!(mux.focus_pane(outside_pane));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let layout = layout_screen(
            &screen.root,
            Rect { x: 0, y: 0, width: 80, height: 40 },
            Some(screen.active_pane),
        );
        assert!(!layout.stacked_headers.contains(&stack_pane));
        assert!(layout.rect_of(stack_pane).unwrap().height > 1);
    });
    let invalidations = events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::TreeChanged | MuxEvent::LayoutChanged(_)))
        .collect::<Vec<_>>();
    assert_eq!(invalidations.len(), 1);
    assert!(matches!(invalidations[0], MuxEvent::LayoutChanged(_)));
}

#[test]
fn directional_split_of_zellij_stack_preserves_requested_direction() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut active = first_pane;
    for _ in 1..13 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    }

    let split = mux.split(active, SplitDir::Right, None).unwrap();
    let split_pane = mux.with_state(|state| state.pane_of(split.id).unwrap());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(matches!(
            &screen.root,
            Node::Split { dir: SplitDir::Right, a, b, .. }
                if matches!(a.as_ref(), Node::Leaf(pane) if *pane == first_pane)
                    && matches!(
                        b.as_ref(),
                        Node::Split { dir: SplitDir::Right, a, b, .. }
                            if matches!(a.as_ref(), Node::Stack { .. })
                                && matches!(b.as_ref(), Node::Leaf(pane) if *pane == split_pane)
                    )
        ));
        assert!(screen.creation_order_auto_layout.is_none());
    });
}

#[test]
fn splitting_a_collapsed_stack_member_expands_the_target_side() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut active = first_pane;
    for _ in 1..13 {
        let surface = mux.new_pane(active, None).unwrap();
        active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    }
    let target = mux.with_state(|state| {
        state.workspaces[0].screens[0].creation_order_auto_layout.as_ref().unwrap()[1]
    });

    mux.split(target, SplitDir::Right, None).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(matches!(
            &screen.root,
            Node::Split { b, .. }
                if matches!(
                    b.as_ref(),
                    Node::Split { a, .. }
                        if matches!(a.as_ref(), Node::Stack { expanded, .. } if *expanded == target)
                )
        ));
    });
}
