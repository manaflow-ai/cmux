//! Tests: viewport resize drags and animation, pane layout in the viewport,
//! and clear history.

use super::*;

#[test]
fn viewport_resize_drag_keeps_its_mouse_down_coordinate_origin() {
    let mux = Mux::new("viewport-resize-origin-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let base = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.new_pane_right(base, cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config.viewport.animation = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));
    app.viewport_offset = 40;
    let target = PaneResizeDragTarget::ViewportColumn {
        pane: base,
        edge: PaneEdge::Right,
        column_x: 0,
        viewport_x: 0,
        viewport_width: 80,
        viewport_offset: 40,
    };

    app.resize_drag_target(target, 20, 5);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let first_width = mux.with_state(|state| {
        state.workspaces[state.active_workspace].screens[0].viewport_base_width.unwrap()
    });

    app.viewport_offset = 10;
    app.resize_drag_target(target, 20, 5);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let second_width = mux.with_state(|state| {
        state.workspaces[state.active_workspace].screens[0].viewport_base_width.unwrap()
    });
    assert!(
        (second_width - first_width).abs() < f32::EPSILON,
        "live viewport motion must not change a drag's pointer mapping"
    );

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn layout_undo_action_confirms_before_closing_a_created_pane() {
    let mux = Mux::new("layout-undo-action-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let base = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    let right = mux
        .new_pane_right(base, cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22)))
        .unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let moved = mux.new_tab(Some(base), None, None).unwrap();
    assert!(mux.move_tab(moved.id, right_pane, 1));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));
    let closing_pane = app.tree.pane(right_pane).unwrap().short_id.clone();
    let closing_tabs = app
        .tree
        .pane(right_pane)
        .unwrap()
        .tabs
        .iter()
        .map(|tab| tab.short_id.clone())
        .collect::<Vec<_>>();

    app.run_action(Action::UndoLayout).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ConfirmLayoutUndo { pane, .. }) if pane == right_pane
    ));
    let prompt = app.prompt.as_ref().unwrap();
    assert!(prompt.label.contains(&closing_pane));
    assert!(closing_tabs.iter().all(|tab| prompt.label.contains(tab)));
    assert!(mux.surface(right.id).is_some());
    assert!(mux.surface(moved.id).is_some());

    app.prompt.as_mut().unwrap().input.insert_str("confirm");
    app.commit_prompt();
    assert!(app.prompt.is_some());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.confirmation_mismatch)
    );

    app.prompt.as_mut().unwrap().input.clear();
    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    app.commit_prompt();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(app.prompt.is_none());
    assert!(mux.surface(right.id).is_some());
    assert!(mux.surface(moved.id).is_some());
    mux.with_state(|state| {
        assert!(!state.surfaces.contains_key(&right.id));
        assert!(!state.surfaces.contains_key(&moved.id));
    });
    assert_eq!(app.tree.active_screen().unwrap().layout.pane_ids_vec(), vec![base]);

    app.run_action(Action::UndoLayout).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.layout_nothing_to_undo)
    );
}

#[test]
fn stale_layout_undo_confirmation_keeps_the_created_pane() {
    let mux = Mux::new("stale-layout-undo-action-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let base = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    let right = mux
        .new_pane_right(base, cmux_tui_core::DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22)))
        .unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));

    app.run_action(Action::UndoLayout).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(app.prompt.is_some());
    assert!(mux.set_viewport_pane_width(right_pane, 0.5));

    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    app.commit_prompt();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert!(mux.surface(right.id).is_some());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().sidebar.layout_undo_stale)
    );

    mux.close_pane(right_pane).unwrap();
}

#[test]
fn viewport_motion_eases_and_can_jump_without_animation() {
    let now = Instant::now();
    let mut motion = ViewportMotion::new(now);
    motion.retarget(60, true, now);

    assert_eq!(motion.offset(), 0);
    assert!(motion.update(now + VIEWPORT_ANIMATION_DURATION / 2));
    assert!(motion.offset() > 0);
    assert!(motion.offset() < 60);
    assert!(motion.animating());

    motion.update(now + VIEWPORT_ANIMATION_DURATION);
    assert_eq!(motion.offset(), 60);
    assert!(!motion.animating());

    motion.retarget(10, false, now + VIEWPORT_ANIMATION_DURATION);
    assert_eq!(motion.offset(), 10);
    assert!(!motion.animating());
}

#[test]
fn first_pane_index_preserves_screen_pane_lookup_semantics() {
    let pane = |name: &str| PaneView {
        id: 7,
        resource_id: None,
        short_id: name.to_string(),
        name: Some(name.to_string()),
        tabs: Vec::new(),
        active_tab: 0,
        focused_at: 0,
    };
    let panes = vec![pane("first"), pane("duplicate")];

    let indexed = first_pane_by_id(&panes);

    assert_eq!(indexed.get(&7).and_then(|pane| pane.name.as_deref()), Some("first"));
}

#[test]
fn first_pane_index_is_empty_for_empty_input() {
    assert!(first_pane_by_id(&[]).is_empty());
}

#[test]
fn viewport_animation_leases_every_column_in_its_swept_range() {
    let pane = |id, surface| PaneView {
        id,
        resource_id: None,
        short_id: format!("p{id}"),
        name: None,
        tabs: vec![TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{surface}"),
            name: None,
            title: format!("pane {id}"),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            notification: None,
            supports_clear_history_key_fallback: false,
        }],
        active_tab: 0,
        focused_at: id,
    };
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: 3,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: vec![pane(1, 11), pane(2, 12), pane(3, 13)],
    };
    let layout = vec![
        (1, VirtualRect { x: 0, y: 0, width: 80, height: 24 }),
        (2, VirtualRect { x: 80, y: 0, width: 80, height: 24 }),
        (3, VirtualRect { x: 160, y: 0, width: 80, height: 24 }),
    ];

    let leases = swept_viewport_size_leases(
        PaneAreaProjection {
            screen: &screen,
            layout: &layout,
            stacked_headers: &HashSet::new(),
            area: Rect { x: 0, y: 0, width: 80, height: 24 },
            scrollbar_position: ScrollbarPosition::Column,
            pane_padding: 0,
            surface_only: None,
            viewport_offset: Some(0),
        },
        160,
    )
    .expect("a short animation sweep should stay within the synchronization budget");

    assert_eq!(leases.iter().map(|lease| lease.surface).collect::<Vec<_>>(), vec![11, 12, 13]);
}

#[test]
fn viewport_animation_rejects_an_unbounded_synchronization_sweep() {
    let pane = |id, surface| PaneView {
        id,
        resource_id: None,
        short_id: format!("p{id}"),
        name: None,
        tabs: vec![TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{surface}"),
            name: None,
            title: format!("pane {id}"),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            notification: None,
            supports_clear_history_key_fallback: false,
        }],
        active_tab: 0,
        focused_at: id,
    };
    let pane_count = 80;
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: pane_count,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: (1..=pane_count).map(|id| pane(id, 100 + id)).collect(),
    };
    let layout = (1..=pane_count)
        .map(|id| (id, VirtualRect { x: (id - 1) * 80, y: 0, width: 80, height: 24 }))
        .collect::<Vec<_>>();

    let leases = swept_viewport_size_leases(
        PaneAreaProjection {
            screen: &screen,
            layout: &layout,
            stacked_headers: &HashSet::new(),
            area: Rect { x: 0, y: 0, width: 80, height: 24 },
            scrollbar_position: ScrollbarPosition::Column,
            pane_padding: 0,
            surface_only: None,
            viewport_offset: Some(0),
        },
        (pane_count - 1) * 80,
    );

    assert!(
        leases.is_none(),
        "a distant jump must not enqueue synchronization for every crossed pane"
    );
}

#[test]
fn viewport_reclip_work_is_bounded_by_visible_panes() {
    let pane_count = 128u64;
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: 1,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: (1..=pane_count)
            .map(|id| PaneView {
                id,
                resource_id: None,
                short_id: format!("p{id}"),
                name: None,
                tabs: vec![TabView {
                    surface: 100 + id,
                    public_id: None,
                    content_id: None,
                    terminal_id: None,
                    short_id: format!("t{id}"),
                    name: None,
                    title: format!("pane {id}"),
                    kind: SurfaceKind::Pty,
                    browser_source: None,
                    browser_frames_stalled: false,
                    supports_clear_history_key_fallback: false,
                    notification: None,
                }],
                active_tab: 0,
                focused_at: id,
            })
            .collect(),
    };
    let layout = (1..=pane_count)
        .map(|id| (id, VirtualRect { x: (id - 1) * 80, y: 0, width: 80, height: 24 }))
        .collect::<Vec<_>>();
    let mux = Mux::new("viewport-reclip-work-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.content_area = Rect { x: 0, y: 0, width: 80, height: 24 };
    app.viewport_layout = layout;
    app.viewport_virtual_width = pane_count * 80;
    app.tree = TreeView::from_parts(
        vec![WorkspaceView {
            id: 3,
            resource_id: None,
            key: "workspace".to_string(),
            short_id: "w".to_string(),
            name: "workspace".to_string(),
            screens: vec![screen],
            active_screen: 0,
        }],
        1,
        Some(1),
        0,
    );

    app.reclip_viewport_panes();
    app.viewport_offset = (pane_count - 1) * 80;
    reset_pane_area_projection_work();
    app.reclip_viewport_panes();

    assert_eq!(app.pane_areas.len(), 1);
    assert!(
        pane_area_projection_work() <= 2,
        "one animation frame performed {} projection operations for one visible pane",
        pane_area_projection_work()
    );
}

#[test]
fn viewport_projection_cache_matches_full_projection_for_overlapping_ranges() {
    let pane = |id| PaneView {
        id,
        resource_id: None,
        short_id: format!("p{id}"),
        name: None,
        tabs: vec![TabView {
            surface: 100 + id,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{id}"),
            name: None,
            title: format!("pane {id}"),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            supports_clear_history_key_fallback: false,
            notification: None,
        }],
        active_tab: 0,
        focused_at: id,
    };
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: 4,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: (1..=4).map(pane).collect(),
    };
    // A down split can return to an earlier x after visiting the upper
    // branch, so the source traversal is intentionally not x-sorted.
    let layout = vec![
        (1, VirtualRect { x: 0, y: 0, width: 80, height: 12 }),
        (2, VirtualRect { x: 40, y: 12, width: 40, height: 12 }),
        (3, VirtualRect { x: 0, y: 12, width: 40, height: 12 }),
        (4, VirtualRect { x: 80, y: 0, width: 53, height: 24 }),
    ];
    let area = Rect { x: 0, y: 0, width: 80, height: 24 };
    let stacked_headers = HashSet::new();
    let mut cache = ViewportPaneAreaProjection::default();
    cache.rebuild(PaneAreaProjection {
        screen: &screen,
        layout: &layout,
        stacked_headers: &stacked_headers,
        area,
        scrollbar_position: ScrollbarPosition::Column,
        pane_padding: 0,
        surface_only: None,
        viewport_offset: Some(0),
    });
    let snapshot = |areas: &[PaneArea]| {
        let mut snapshot = areas
            .iter()
            .map(|area| {
                (
                    area.pane,
                    area.surface,
                    area.rect,
                    area.bar,
                    area.omnibar,
                    area.content,
                    area.track,
                    area.viewport.map(|clip| {
                        (
                            clip.rect_source_x,
                            clip.full_rect_width,
                            clip.omnibar_source_x,
                            clip.full_omnibar_width,
                            clip.content_source_x,
                            clip.full_content_width,
                        )
                    }),
                )
            })
            .collect::<Vec<_>>();
        snapshot.sort_unstable_by_key(|area| area.0);
        snapshot
    };

    for offset in [0, 39, 53] {
        let mut expected = Vec::new();
        rebuild_pane_areas(
            &mut expected,
            PaneAreaProjection {
                screen: &screen,
                layout: &layout,
                stacked_headers: &stacked_headers,
                area,
                scrollbar_position: ScrollbarPosition::Column,
                pane_padding: 0,
                surface_only: None,
                viewport_offset: Some(offset),
            },
        );
        let mut actual = Vec::new();
        cache.project_into(&mut actual, area, offset);
        assert_eq!(snapshot(&actual), snapshot(&expected), "projection mismatch at {offset}");
    }
}

#[test]
fn viewport_animation_tick_reclips_without_authoritative_layout_draw() {
    let mux = Mux::new("viewport-animation-paint-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.content_area = Rect { x: 0, y: 0, width: 80, height: 24 };
    app.viewport_layout = vec![
        (1, VirtualRect { x: 0, y: 0, width: 80, height: 24 }),
        (2, VirtualRect { x: 80, y: 0, width: 53, height: 24 }),
    ];
    app.viewport_virtual_width = 133;
    app.tree = TreeView::from_parts(
        vec![WorkspaceView {
            id: 3,
            resource_id: None,
            key: "workspace".to_string(),
            short_id: "w".to_string(),
            name: "workspace".to_string(),
            screens: vec![ScreenView {
                id: 4,
                resource_id: None,
                short_id: "s".to_string(),
                name: None,
                layout: Node::Leaf(1),
                active_pane: 2,
                zoomed_pane: None,
                viewport_base_width: Some(1.0),
                viewport_splits: BTreeMap::new(),
                panes: vec![
                    PaneView {
                        id: 1,
                        resource_id: None,
                        short_id: "p1".to_string(),
                        name: None,
                        tabs: vec![TabView {
                            surface: 11,
                            public_id: None,
                            content_id: None,
                            terminal_id: None,
                            short_id: "t1".to_string(),
                            name: None,
                            title: "left".to_string(),
                            kind: SurfaceKind::Pty,
                            browser_source: None,
                            browser_frames_stalled: false,
                            notification: None,
                            supports_clear_history_key_fallback: false,
                        }],
                        active_tab: 0,
                        focused_at: 0,
                    },
                    PaneView {
                        id: 2,
                        resource_id: None,
                        short_id: "p2".to_string(),
                        name: None,
                        tabs: vec![TabView {
                            surface: 12,
                            public_id: None,
                            content_id: None,
                            terminal_id: None,
                            short_id: "t2".to_string(),
                            name: None,
                            title: "right".to_string(),
                            kind: SurfaceKind::Pty,
                            browser_source: None,
                            browser_frames_stalled: false,
                            notification: None,
                            supports_clear_history_key_fallback: false,
                        }],
                        active_tab: 0,
                        focused_at: 1,
                    },
                ],
            }],
            active_screen: 0,
        }],
        1,
        Some(1),
        0,
    );
    let started_at = Instant::now();
    let mut motion = ViewportMotion::new(started_at);
    motion.retarget(53, true, started_at);
    app.viewport_states.insert(4, motion);
    app.reclip_viewport_panes();

    assert!(app.viewport_animation_active());
    assert_eq!(app.viewport_offset, 0);
    assert_eq!(app.pane_areas.iter().find(|area| area.pane == 1).unwrap().rect.width, 80);
    app.tree.workspace_revision = u64::MAX;

    assert_eq!(
        app.advance_viewport_animation(started_at + VIEWPORT_ANIMATION_DURATION / 2),
        RenderAction::Paint
    );
    assert!(app.viewport_offset > 0);
    assert!(
        app.pane_areas.iter().find(|area| area.pane == 1).unwrap().rect.width < 80,
        "paint-only animation ticks must reclip cached pane geometry"
    );
    assert_eq!(
        app.tree.workspace_revision,
        u64::MAX,
        "animation paint must preserve the cached authoritative tree"
    );
    assert_eq!(
        app.advance_viewport_animation(started_at + VIEWPORT_ANIMATION_DURATION),
        RenderAction::Draw,
        "the settling tick must release swept-range leases through one authoritative draw"
    );
}

#[test]
fn viewport_geometry_changes_reveal_the_active_pane_without_canceling_manual_scroll() {
    let mux = Mux::new("viewport-geometry-reveal-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.config.viewport.animation = false;
    app.replace_tree(app.session.tree());
    let screen = app.tree.active_screen().unwrap();
    let screen_id = screen.id;
    let active_pane = screen.active_pane;
    let now = Instant::now();
    let original_area = Rect { x: 0, y: 0, width: 80, height: 24 };
    let original_active = Rect { x: 80, y: 0, width: 53, height: 24 };

    assert_eq!(
        app.sync_viewport_motion(
            screen_id,
            active_pane,
            Some(original_active.into()),
            original_area,
            133,
            now,
        ),
        53
    );
    assert!(app.set_viewport_target(0, false));
    assert_eq!(
        app.sync_viewport_motion(
            screen_id,
            active_pane,
            Some(original_active.into()),
            original_area,
            133,
            now,
        ),
        0,
        "unchanged geometry must preserve an intentional manual scroll"
    );
    assert_eq!(
        app.sync_viewport_motion(
            screen_id,
            active_pane,
            Some(Rect { y: 1, height: 20, ..original_active }.into()),
            Rect { y: 1, height: 20, ..original_area },
            133,
            now,
        ),
        0,
        "vertical-only geometry changes must preserve manual horizontal scroll"
    );

    assert_eq!(
        app.sync_viewport_motion(
            screen_id,
            active_pane,
            Some(Rect { x: 120, y: 0, width: 80, height: 24 }.into()),
            Rect { x: 0, y: 0, width: 120, height: 24 },
            200,
            now,
        ),
        80,
        "host resize must reveal the unchanged active pane in its new geometry"
    );
}

#[test]
fn remote_screen_switch_records_the_new_active_pane() {
    let mux = Mux::new("remote-screen-focus-memory-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 30))).unwrap();
    let workspace = Session::Local(mux.clone()).tree().active_workspace().unwrap().id;
    mux.new_screen(Some(workspace), Some((80, 30))).unwrap();
    let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
    let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
    let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.select_screen(Some(0), None);

    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.session.remote = true;
    app.select_screen_for_client(Some(1), None);
    app.sync_layout((80, 31));
    // Client navigation is optimistic and client-local; it records the
    // session's focus memory for later attaches without moving the live
    // shared focus.
    assert_eq!(mux.with_state(|state| state.workspaces[0].active_screen), 0);
    assert_eq!(mux.session_focus().map(|(pane, _)| pane), Some(bottom_right));

    app.move_focus(Direction::Left);
    assert_eq!(app.active_pane(), Some(left));
    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(bottom_right));

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn remote_workspace_switch_records_the_new_active_pane() {
    let mux = Mux::new("remote-workspace-focus-memory-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 30))).unwrap();
    mux.new_workspace(None, Some((80, 30))).unwrap();
    let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
    let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
    let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.select_workspace(Some(0), None);

    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.session.remote = true;
    app.select_workspace_for_client(Some(1), None);
    app.sync_layout((80, 31));
    // Client navigation is optimistic and client-local; it records the
    // session's focus memory for later attaches without moving the live
    // shared focus.
    assert_eq!(mux.with_state(|state| state.active_workspace), 0);
    assert_eq!(mux.session_focus().map(|(pane, _)| pane), Some(bottom_right));

    app.move_focus(Direction::Left);
    assert_eq!(app.active_pane(), Some(left));
    app.move_focus(Direction::Right);
    assert_eq!(app.active_pane(), Some(bottom_right));

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn client_navigation_records_the_session_focus_without_moving_the_mux() {
    let mux = Mux::new("client-focus-report-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 30))).unwrap();
    mux.new_workspace(None, Some((80, 30))).unwrap();
    mux.select_workspace(Some(0), None);

    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    // Adopting a tree records the baseline without reporting.
    assert_eq!(mux.session_focus(), None);

    app.select_workspace_for_client(Some(1), None);
    // The report records the session's last focus for later attaches and
    // leaves the live shared focus alone, so attached clients stay put.
    let second_pane = app.tree.workspaces()[1].screens[0].active_pane;
    assert_eq!(mux.with_state(|state| state.active_workspace), 0);
    assert_eq!(mux.session_focus(), Some((second_pane, Some(0))));

    // A client with no memory of its own adopts the session's last
    // reported focus on first attach.
    let mut second = test_app(Session::Local(mux.clone()));
    second.sidebar_visible = false;
    second.client_focus_id = Some("bob".to_string());
    second.replace_tree(second.session.tree());
    assert_eq!(second.tree.active_workspace, 1);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn reconnecting_client_restores_its_own_focus() {
    let mux = Mux::new("client-focus-reconnect-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 30))).unwrap();
    mux.new_workspace(None, Some((80, 30))).unwrap();
    mux.select_workspace(Some(0), None);

    let mut first = test_app(Session::Local(mux.clone()));
    first.sidebar_visible = false;
    first.client_focus_id = Some("alice".to_string());
    first.replace_tree(first.session.tree());
    first.select_workspace_for_client(Some(1), None);
    drop(first);

    // Another client later reports focus elsewhere, moving the session's
    // last reported focus (the cross-client adoption default).
    let mut other = test_app(Session::Local(mux.clone()));
    other.sidebar_visible = false;
    other.client_focus_id = Some("bob".to_string());
    other.replace_tree(other.session.tree());
    other.select_workspace_for_client(Some(0), None);
    drop(other);

    let mut second = test_app(Session::Local(mux.clone()));
    second.sidebar_visible = false;
    second.client_focus_id = Some("alice".to_string());
    second.replace_tree(second.session.tree());
    // Reconnection restores this client's own remembered focus, not the
    // session focus another client reported afterwards.
    assert_eq!(second.tree.active_workspace, 1);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn alt_n_uses_zellij_default_vertical_distribution() {
    let (mux, _) = test_mux("alt-n-zellij-layout-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());

    for _ in 0..4 {
        app.sync_layout((200, 40));
        app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
            app.handle(event).unwrap();
        }
    }

    let screen = app.tree.active_screen().unwrap();
    let mut panes = Vec::new();
    screen.layout.pane_ids(&mut panes);
    panes.sort_unstable();
    assert_eq!(panes.len(), 5);

    let layout = layout_screen(
        &screen.layout,
        Rect { x: 0, y: 0, width: 200, height: 40 },
        Some(screen.active_pane),
    );
    assert_eq!(
        layout.panes,
        vec![
            (panes[0], Rect { x: 0, y: 0, width: 100, height: 40 }),
            (panes[1], Rect { x: 100, y: 0, width: 100, height: 10 }),
            (panes[2], Rect { x: 100, y: 10, width: 100, height: 10 }),
            (panes[3], Rect { x: 100, y: 20, width: 100, height: 10 }),
            (panes[4], Rect { x: 100, y: 30, width: 100, height: 10 }),
        ]
    );

    for _ in 0..8 {
        app.sync_layout((200, 40));
        app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
            app.handle(event).unwrap();
        }
    }

    let screen = app.tree.active_screen().unwrap();
    let mut panes = Vec::new();
    screen.layout.pane_ids(&mut panes);
    panes.sort_unstable();
    assert_eq!(panes.len(), 13);

    let layout = layout_screen(
        &screen.layout,
        Rect { x: 0, y: 0, width: 200, height: 40 },
        Some(screen.active_pane),
    );
    assert_eq!(layout.panes[0], (panes[0], Rect { x: 0, y: 0, width: 100, height: 40 }));
    for (index, (pane, rect)) in layout.panes[1..12].iter().enumerate() {
        assert_eq!(*pane, panes[index + 1]);
        assert_eq!(*rect, Rect { x: 100, y: index as u16, width: 100, height: 1 });
    }
    assert_eq!(layout.panes[12], (panes[12], Rect { x: 100, y: 11, width: 100, height: 29 }));

    app.sync_layout((200, 41));
    let leading = app.pane_areas.iter().find(|area| area.pane == panes[0]).unwrap();
    assert_eq!(leading.rect, Rect { x: 0, y: 0, width: 100, height: 40 });
    assert_eq!(leading.bar, Some(Rect { x: 0, y: 0, width: 100, height: 1 }));
    assert_eq!(leading.content.height, 38);
    for pane in &panes[1..12] {
        let area = app.pane_areas.iter().find(|area| area.pane == *pane).unwrap();
        assert_eq!(area.bar, Some(area.rect));
        assert_eq!(area.content.height, 0);
    }
    let expanded = app.pane_areas.iter().find(|area| area.pane == panes[12]).unwrap();
    assert_eq!(expanded.rect.height, 29);
    assert_eq!(expanded.content.height, 27);

    let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
    for surface in surfaces {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn command_k_clears_prior_output_without_a_session_mutation() {
    let (mux, surface) = test_mux("command-k-clear-history-test", None);
    surface.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07visible-content");
    });
    assert!(surface.with_terminal(|term| term.history_rows()).unwrap() > 0);

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.selection = Some(Selection { surface: surface.id, anchor: (1, 1), head: (2, 1) });
    let action = app.handle_key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)).unwrap();
    assert_eq!(action, RenderAction::None);
    assert!(app.selection.is_some());
    assert!(!app.session.has_pending_mutations());
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    let completion = loop {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if matches!(
            &event,
            AppEvent::ClearHistorySucceeded { surface: completed, .. }
                if *completed == surface.id
        ) {
            break event;
        }
    };
    app.handle(completion).unwrap();
    assert!(app.selection.is_none());

    surface.with_terminal(|term| {
        assert_eq!(term.history_rows(), 0);
        let viewport = term.viewport_text().unwrap();
        let compact =
            viewport.chars().filter(|character| !character.is_whitespace()).collect::<String>();
        assert!(!viewport.contains("history-"));
        assert!(compact.contains("prompt>visible-content"));
    });
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn delayed_clear_history_completion_preserves_newer_viewport_and_selection() {
    let (mux, surface) = test_mux("delayed-command-k-ui-test", None);
    surface.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
    });

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER))))
        .unwrap();
    let completion = loop {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if matches!(
            &event,
            AppEvent::ClearHistorySucceeded { surface: completed, .. }
                if *completed == surface.id
        ) {
            break event;
        }
    };

    app.handle(AppEvent::Input(Event::FocusGained)).unwrap();
    surface.with_terminal(|term| {
        for line in 0..40 {
            term.vt_write(format!("new-output-{line}\r\n").as_bytes());
        }
    });
    surface.scroll_delta(-5).unwrap();
    let offset = surface.with_terminal(|term| term.scrollbar().unwrap().offset).unwrap();
    assert!(offset > 0);
    let selection = Selection { surface: surface.id, anchor: (1, 1), head: (2, 2) };
    app.selection = Some(selection);

    app.handle(completion).unwrap();

    assert_eq!(surface.with_terminal(|term| term.scrollbar().unwrap().offset).unwrap(), offset);
    assert!(app.selection.is_some_and(|current| {
        current.surface == selection.surface
            && current.anchor == selection.anchor
            && current.head == selection.head
    }));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn delayed_clear_history_completion_preserves_recreated_selection() {
    let (mux, surface) = test_mux("delayed-command-k-selection-aba-test", None);
    surface.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
    });

    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let selection = Selection { surface: surface.id, anchor: (1, 1), head: (1, 1) };
    app.replace_selection(Some(selection));

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER))))
        .unwrap();
    let completion = loop {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if matches!(
            &event,
            AppEvent::ClearHistorySucceeded { surface: completed, .. }
                if *completed == surface.id
        ) {
            break event;
        }
    };

    app.replace_selection(None);
    app.replace_selection(Some(selection));
    assert_eq!(app.selection, Some(selection));

    app.handle(completion).unwrap();

    assert_eq!(app.selection, Some(selection));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn failed_command_k_preserves_viewport_and_selection() {
    let (mux, surface) = test_mux("command-k-failure-view-test", None);
    surface.with_terminal(|term| {
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> \x1b[31");
    });
    surface.scroll_delta(-5).unwrap();
    let offset_before = surface.with_terminal(|term| term.scrollbar().unwrap().offset).unwrap();
    assert!(offset_before > 0);
    let selection = Selection { surface: surface.id, anchor: (1, 1), head: (2, 2) };

    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.selection = Some(selection);

    assert_eq!(
        app.run_clear_history_shortcut(
            KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER).into()
        ),
        RenderAction::None
    );
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    app.apply_pty_failures();

    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "Could not clear terminal history: terminal output did not reach a safe clear-history boundary"
        )
    );
    assert_eq!(
        surface.with_terminal(|term| term.scrollbar().unwrap().offset).unwrap(),
        offset_before
    );
    assert!(app.selection.is_some_and(|current| {
        current.surface == selection.surface
            && current.anchor == selection.anchor
            && current.head == selection.head
    }));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn clear_history_fallback_operations_remain_ordered() {
    let (mux, surface) = test_mux("clear-history-fallback-budget-test", None);
    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block input lane", false, move || {
        started_tx.send(()).unwrap();
        let _ = unblock_rx.recv();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let fallback_key = KeyInput { utf8: "x".repeat(1024), ..Default::default() };
    let retained_bytes = fallback_key.utf8.capacity();
    for _ in 0..8 {
        app.session.clear_history_or_send_key(
            surface.id,
            fallback_key.clone(),
            app.input_revision,
            app.selection,
            app.selection_generation,
        );
    }

    assert_eq!(app.session.operations.queued_bytes_for_test(), retained_bytes * 8);
    unblock_tx.send(()).unwrap();
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn command_k_matches_the_reported_physical_key_across_layouts() {
    let (mux, surface) = test_mux("command-k-layout-test", None);
    surface.with_terminal(|term| {
        for line in 0..24 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
    });
    assert!(surface.with_terminal(|term| term.history_rows()).unwrap() > 0);

    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let action = app
        .handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('л'), KeyModifiers::SUPER),
            shifted_key: None,
            base_layout_key: Some('k'),
            text: String::new(),
        })))
        .unwrap();

    assert_eq!(action, RenderAction::None);
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    assert_eq!(surface.with_terminal(|term| term.history_rows()), Some(0));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn ctrl_l_reaches_foreground_primary_screen_app() {
    let mux = Mux::new(
        "ctrl-l-primary-screen-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; printf ready; exec cat".to_string(),
            ]),
            cols: 20,
            rows: 8,
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let attach = surface.attach_stream().unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut output = attach.replay.to_vec();
    while !output.windows(5).any(|window| window == b"ready") {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => panic!("foreground helper did not become ready: {error}"),
        }
    }

    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let action = app.handle_key(KeyEvent::new(KeyCode::Char('l'), KeyModifiers::CONTROL)).unwrap();
    assert_eq!(action, RenderAction::None);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));

    let deadline = Instant::now() + Duration::from_secs(1);
    output.clear();
    while !output.contains(&b'\x0c') {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => panic!("foreground app did not receive Ctrl-L: {error}"),
        }
    }

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn command_k_reaches_a_kitty_app_on_the_alternate_screen() {
    let mux = Mux::new(
        "command-k-alternate-screen-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; printf ready; exec cat".to_string(),
            ]),
            cols: 20,
            rows: 8,
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let attach = surface.attach_stream().unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut output = attach.replay.to_vec();
    while !output.windows(5).any(|window| window == b"ready") {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => panic!("alternate-screen helper did not become ready: {error}"),
        }
    }
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));

    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    let action = app.handle_key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)).unwrap();
    assert_eq!(action, RenderAction::None);
    assert!(!app.session.has_pending_mutations());

    let expected = b"\x1b[107;9u";
    let deadline = Instant::now() + Duration::from_secs(1);
    output.clear();
    while !output.windows(expected.len()).any(|window| window == expected) {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => panic!("alternate-screen app did not receive Command-K: {error}"),
        }
    }

    let action = app.handle_key(KeyEvent::new(KeyCode::Char('l'), KeyModifiers::CONTROL)).unwrap();
    assert_eq!(action, RenderAction::None);
    assert!(!app.prefix_armed);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));

    let expected = b"\x1b[108;5u";
    let deadline = Instant::now() + Duration::from_secs(1);
    output.clear();
    while !output.windows(expected.len()).any(|window| window == expected) {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => {
                panic!("alternate-screen app did not receive child-owned Ctrl-L: {error}")
            }
        }
    }

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn clear_history_shortcut_requires_atomic_fallback_support() {
    assert!(!should_claim_clear_history_shortcut(SurfaceKind::Pty, false));
    assert!(should_claim_clear_history_shortcut(SurfaceKind::Pty, true));
    assert!(!should_claim_clear_history_shortcut(SurfaceKind::Browser, true));
}

#[test]
fn prefixed_clear_history_never_forwards_only_the_suffix_key() {
    let mux = Mux::new(
        "prefixed-clear-history-fallback-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "stty raw -echo; printf ready; exec cat".to_string(),
            ]),
            cols: 20,
            rows: 8,
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let attach = surface.attach_stream().unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut output = attach.replay.to_vec();
    while !output.windows(5).any(|window| window == b"ready") {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_)) => {}
            Err(_) if Instant::now() < deadline => {}
            Err(error) => panic!("alternate-screen helper did not become ready: {error}"),
        }
    }
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));

    let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.config.keys.apply_for_test(&HashMap::from([(
        "clear-history".to_string(),
        Value::String("q".to_string()),
    )]));

    app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();
    assert!(app.prefix_armed);
    app.handle_key(KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)).unwrap();
    assert!(!app.prefix_armed);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));

    output.clear();
    let deadline = Instant::now() + Duration::from_millis(250);
    while Instant::now() < deadline {
        match attach.stream.recv_timeout(Duration::from_millis(20)) {
            Ok(cmux_tui_core::AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(cmux_tui_core::AttachFrame::OutputWithColors { output: bytes, .. }) => {
                output.extend_from_slice(&bytes);
            }
            Ok(cmux_tui_core::AttachFrame::Resized { .. })
            | Ok(cmux_tui_core::AttachFrame::ResizedWithColors { .. })
            | Ok(cmux_tui_core::AttachFrame::ColorsChanged(_))
            | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    assert!(
        !output.contains(&b'q'),
        "prefixed clear-history forwarded its suffix key to the alternate-screen child"
    );
    mux.close_surface(surface.id).unwrap();
}
