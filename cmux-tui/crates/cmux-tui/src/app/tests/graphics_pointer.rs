//! Tests: committed pointer frames and menu routes, kitty graphics processing
//! and failures, and drags across frames.

use super::*;

#[test]
fn menu_pointer_routes_share_the_committed_snapshot() {
    let levels: Arc<[RenderedMenuLevel]> = vec![RenderedMenuLevel {
        rect: Rect { x: 2, y: 2, width: 20, height: 3 },
        scroll_offset: 0,
        items: vec![MenuItem::Submenu {
            label: "nested".to_string(),
            items: vec![MenuItem::Action(MenuAction::NewTab(7))],
        }]
        .into(),
        resources: vec![None].into(),
    }]
    .into();
    let frame = RenderedPointerFrame { menu: Some(levels.clone()), ..Default::default() };

    let route = frame.route_for_mouse(&MouseEvent {
        kind: MouseEventKind::Moved,
        column: 3,
        row: 3,
        modifiers: KeyModifiers::NONE,
    });

    let PointerRouteIdentity::Menu { levels: routed, .. } = route else {
        panic!("pointer should route through the committed menu");
    };
    assert!(
        Arc::ptr_eq(&levels, &routed),
        "motion routing must clone only the Arc, not menu items"
    );
}

#[test]
fn pointer_routes_projection_rail_padding_to_projection_rail() {
    let rect = Rect { x: 4, y: 0, width: 20, height: 10 };
    let pane = PaneArea {
        pane: 7,
        surface: 9,
        rect,
        bar: None,
        omnibar: None,
        content: Rect { x: 5, y: 1, width: 18, height: 8 },
        track: None,
        viewport: None,
    };
    let mux = Mux::new("projection-rail-pointer-frame-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.outer_size = (40, 10);
    app.sidebar_layout.ordered =
        vec![crate::app::RailPlacement { kind: RailKind::Projection(0), view_index: 0, rect }];
    app.pane_areas = vec![pane];
    app.commit_rendered_pointer_frame();

    let padding_route = app.rendered_pointer_frame.route_for_mouse(&MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: rect.x + rect.width - 1,
        row: rect.y + rect.height - 1,
        modifiers: KeyModifiers::NONE,
    });
    assert!(matches!(
        padding_route,
        PointerRouteIdentity::Rail { kind: RailKind::Projection(0), .. }
    ));

    let content_route = app.rendered_pointer_frame.route_for_mouse(&MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane.content.x,
        row: pane.content.y,
        modifiers: KeyModifiers::NONE,
    });
    assert!(
        matches!(content_route, PointerRouteIdentity::Pane { pane: routed, .. } if routed.pane == pane.pane)
    );
}

#[test]
fn graphics_only_repaint_is_a_pointer_replay_barrier() {
    assert_eq!(
        PointerRoutePhase::Fresh.with_action(RenderAction::Graphics),
        PointerRoutePhase::GraphicsRenderPending,
        "browser input must wait for a replacement bitmap on that surface"
    );
}

#[test]
fn browser_graphics_processing_does_not_block_terminal_pointer_input() {
    let (mux, surface) = test_mux("graphics-terminal-pointer-scope-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 2,
        row: content.y + 1,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(
        app.deferred_input.is_empty(),
        "an unrelated terminal click must not wait for a browser bitmap"
    );
    assert!(matches!(app.drag, Some(Drag::Select { .. })));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn browser_click_requires_a_processed_frame() {
    let mux = Mux::new("browser-processed-frame-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
    surface.kill();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    assert_eq!(
        app.session.surface(surface.id).and_then(|surface| surface.browser_frame_seq()),
        None
    );
    let content = app.pane_areas[0].content;
    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 2,
        row: content.y + 1,
        modifiers: KeyModifiers::NONE,
    };
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;

    app.handle(AppEvent::Input(Event::Mouse(click))).unwrap();

    assert!(
        blocked.drain_mouse_lifetimes().is_empty(),
        "a placeholder with no processed browser frame must not accept pointer input"
    );
    assert!(!matches!(app.drag, Some(Drag::Browser { .. })));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pending_graphics_deletion_blocks_pointer_through_processed_rect() {
    let mux = Mux::new("graphics-deletion-pointer-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.last_graphics_snapshot.push(GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect: Rect { x: 2, y: 2, width: 8, height: 4 },
        seq: 13,
        pointer_frame_seq: Some(13),
    });
    app.pending_graphics_submission = Some(7);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
    let covered = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 3,
        row: 3,
        modifiers: KeyModifiers::NONE,
    };

    assert!(
        app.pointer_route_is_stale_for_mouse(&covered),
        "the old browser image still owns this cell until deletion is processed"
    );
    let menu = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        modifiers: KeyModifiers::SHIFT,
        ..covered
    };
    assert!(
        !app.pointer_route_is_stale_for_mouse(&menu),
        "a cmux-owned menu press must not wait for a graphics image it never enters"
    );

    app.pending_graphics_snapshot = Some(vec![GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect: Rect { x: 12, y: 2, width: 8, height: 4 },
        seq: 13,
        pointer_frame_seq: Some(13),
    }]);
    let newly_covered = MouseEvent { column: 13, ..covered };
    let unchanged = MouseEvent { column: 25, ..covered };
    assert!(app.pointer_route_is_stale_for_mouse(&covered));
    assert!(app.pointer_route_is_stale_for_mouse(&newly_covered));
    assert!(!app.pointer_route_is_stale_for_mouse(&unchanged));
}

#[test]
fn graphics_changed_rect_bound_stays_within_linear_comparison_budget() {
    let mux = Mux::new("graphics-diff-complexity-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));
    let count = 512usize;
    let previous = (0..count)
        .map(|index| GraphicIdentity {
            session_generation: app.session_generation,
            surface: index as SurfaceId,
            rect: Rect { x: index as u16, y: 1, width: 1, height: 1 },
            seq: index as u64,
            pointer_frame_seq: None,
        })
        .collect::<Vec<_>>();
    let next = (0..count)
        .map(|index| GraphicIdentity {
            session_generation: app.session_generation,
            surface: (count + index) as SurfaceId,
            rect: Rect { x: (count + index) as u16, y: 1, width: 1, height: 1 },
            seq: (count + index) as u64,
            pointer_frame_seq: None,
        })
        .collect::<Vec<_>>();

    crate::app::GRAPHICS_ROUTE_COMPARISONS.with(|comparisons| comparisons.set(0));
    assert!(app.graphics_changed_rect_bound(&previous, &next).is_some());
    let comparisons = crate::app::GRAPHICS_ROUTE_COMPARISONS.with(std::cell::Cell::get);
    assert!(
        comparisons <= count.saturating_mul(8),
        "graphics diff compared {comparisons} pairs for {count} entries"
    );
}

#[test]
fn ordinary_browser_repaint_does_not_change_pointer_geometry() {
    let mux = Mux::new("graphics-repaint-pointer-authority-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let rect = Rect { x: 2, y: 2, width: 8, height: 4 };
    app.last_graphics_snapshot.push(GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect,
        seq: 13,
        pointer_frame_seq: Some(13),
    });
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    app.track_graphics_submission(
        7,
        vec![GraphicIdentity {
            session_generation: app.session_generation,
            surface: 11,
            rect,
            seq: 14,
            pointer_frame_seq: Some(13),
        }],
    );

    assert!(
        !app.pending_graphics_changes_cell(rect.x + 1, rect.y + 1),
        "a new bitmap with unchanged document and geometry must not starve pointer input"
    );
}

#[test]
fn superseded_graphics_processing_keeps_intermediate_cells_blocked() {
    let mux = Mux::new("graphics-processing-union-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let intermediate = GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect: Rect { x: 2, y: 2, width: 8, height: 4 },
        seq: 13,
        pointer_frame_seq: Some(13),
    };
    let covered = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 3,
        row: 3,
        modifiers: KeyModifiers::NONE,
    };
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    app.track_graphics_submission(2, vec![intermediate]);
    app.track_graphics_submission(3, Vec::new());

    assert!(
        app.pointer_route_is_stale_for_mouse(&covered),
        "A→B→A must block cells touched by the intermediate B processing"
    );

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 2,
        session_generation: intermediate.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: intermediate.surface,
            rect: intermediate.rect,
            seq: intermediate.seq,
            pointer_frame_seq: intermediate.pointer_frame_seq,
        }],
    });
    assert_eq!(app.last_graphics_snapshot, vec![intermediate]);
    assert_eq!(app.pending_graphics_submission, Some(3));
    assert!(
        app.pointer_route_is_stale_for_mouse(&covered),
        "the cell must stay blocked while replacement A processing is pending"
    );

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 3,
        session_generation: app.session_generation,
        graphics: Vec::new(),
    });
    assert!(app.last_graphics_snapshot.is_empty());
    assert_eq!(app.pending_graphics_submission, None);
    assert!(!app.pointer_route_is_stale_for_mouse(&covered));
}

#[test]
fn sustained_graphics_processing_advances_acknowledged_pointer_authority() {
    let mux = Mux::new("graphics-processing-liveness-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
    let surface_id = surface.id;
    surface.kill();
    let mut app = test_app(Session::Local(mux.clone()));
    app.pending_graphics_submission = Some(3);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 2,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: surface_id,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 13,
            pointer_frame_seq: Some(13),
        }],
    });

    assert_eq!(
        app.rendered_pointer_frame.pane_content_generations.get(&surface_id),
        Some(&PaneContentGeneration::Browser(13)),
        "every acknowledged presentation must advance pointer authority even when a successor is pending"
    );
    assert_eq!(app.pending_graphics_submission, Some(3));
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::GraphicsProcessingPending);
    mux.close_surface(surface_id).unwrap();
}

#[test]
fn graphics_completion_acknowledges_one_exact_remote_presentation() {
    let surface_id = 7;
    let mut app = test_app(crate::session::test_remote_session_with_browser_pointer_range(
        surface_id, 41, 42,
    ));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(4);
    app.browser_input = dispatcher;
    assert!(
        app.session
            .surface(surface_id)
            .is_some_and(|surface| surface.browser_accepts_pointer_frame(41))
    );

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 2,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: surface_id,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 42,
            pointer_frame_seq: Some(42),
        }],
    });

    let surface = app.session.surface(surface_id).expect("remote browser surface");
    assert!(!surface.browser_accepts_pointer_frame(41));
    assert!(surface.browser_accepts_pointer_frame(42));
    let published =
        blocked.recv_timeout(Duration::from_secs(1)).expect("presentation acknowledgement");
    assert!(matches!(published.kind, BrowserInputKind::Presented { frame_seq: 42 }));

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 3,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: surface_id,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 42,
            pointer_frame_seq: Some(42),
        }],
    });

    assert!(
        blocked.recv_timeout(Duration::from_millis(20)).is_none(),
        "an unchanged full graphics snapshot must not republish the same presentation"
    );
}

#[test]
fn graphics_acknowledgment_discards_obsolete_affected_cells() {
    let mux = Mux::new("graphics-processing-bounded-union-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let graphic = |surface, x| GraphicIdentity {
        session_generation: app.session_generation,
        surface,
        rect: Rect { x, y: 2, width: 2, height: 2 },
        seq: surface,
        pointer_frame_seq: Some(surface),
    };
    let first = graphic(11, 2);
    let second = graphic(12, 8);
    let latest = graphic(13, 14);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    app.track_graphics_submission(2, vec![first]);
    app.track_graphics_submission(3, vec![second]);
    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 2,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: first.surface,
            rect: first.rect,
            seq: first.seq,
            pointer_frame_seq: first.pointer_frame_seq,
        }],
    });
    app.track_graphics_submission(4, vec![latest]);
    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 3,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: second.surface,
            rect: second.rect,
            seq: second.seq,
            pointer_frame_seq: second.pointer_frame_seq,
        }],
    });

    assert!(
        !app.pending_graphics_changes_cell(first.rect.x, first.rect.y),
        "an acknowledged successor must discard cells absent from both it and the latest pending snapshot"
    );
    assert!(app.pending_graphics_changes_cell(second.rect.x, second.rect.y));
    assert!(app.pending_graphics_changes_cell(latest.rect.x, latest.rect.y));
}

#[test]
fn newer_browser_render_keeps_an_older_processing_acknowledgment_stale() {
    let mux = Mux::new("graphics-processing-order-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
    let surface_id = surface.id;
    surface.kill();
    let mut app = test_app(Session::Local(mux.clone()));
    app.pending_graphics_submission = Some(7);
    app.pointer_route_phase = PointerRoutePhase::GraphicsRenderPending;

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 7,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: surface_id,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 13,
            pointer_frame_seq: Some(13),
        }],
    });

    assert_eq!(app.pending_graphics_submission, None);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::GraphicsRenderPending);
    assert_eq!(
        app.rendered_pointer_frame.pane_content_generations.get(&surface_id),
        Some(&PaneContentGeneration::Browser(13))
    );

    app.pending_graphics_submission = Some(8);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 8,
        session_generation: app.session_generation,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: surface_id,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 14,
            pointer_frame_seq: Some(14),
        }],
    });
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
    assert_eq!(
        app.rendered_pointer_frame.pane_content_generations.get(&surface_id),
        Some(&PaneContentGeneration::Browser(14))
    );
    mux.close_surface(surface_id).unwrap();
}

#[test]
fn graphics_writer_failure_releases_the_pointer_processing_barrier() {
    let mux = Mux::new("graphics-failure-pointer-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    app.pending_graphics_submission = Some(9);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
    app.last_graphics_snapshot.push(GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect: Rect { x: 1, y: 2, width: 3, height: 4 },
        seq: 15,
        pointer_frame_seq: Some(15),
    });
    app.rendered_pane_content_generations.insert(11, PaneContentGeneration::Browser(15));

    assert_eq!(app.disable_graphics_after_failure(), RenderAction::Draw);

    assert!(!app.graphics_supported);
    assert_eq!(app.pending_graphics_submission, None);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    assert!(app.last_graphics_snapshot.is_empty());
    assert!(
        !app.rendered_pane_content_generations
            .values()
            .any(|generation| matches!(generation, PaneContentGeneration::Browser(_)))
    );
}

#[test]
fn graphics_writer_timeout_retries_without_disabling_graphics() {
    let mux = Mux::new("graphics-timeout-pointer-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    app.pending_graphics_submission = Some(9);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
    app.last_graphics_snapshot.push(GraphicIdentity {
        session_generation: app.session_generation,
        surface: 11,
        rect: Rect { x: 1, y: 2, width: 3, height: 4 },
        seq: 15,
        pointer_frame_seq: Some(15),
    });
    app.rendered_pane_content_generations.insert(11, PaneContentGeneration::Browser(15));

    assert_eq!(app.retry_graphics_after_timeout(9, app.session_generation), RenderAction::Draw);

    assert!(app.graphics_supported);
    assert_eq!(app.pending_graphics_submission, None);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    assert!(app.last_graphics_snapshot.is_empty());
    assert!(
        !app.rendered_pane_content_generations
            .values()
            .any(|generation| matches!(generation, PaneContentGeneration::Browser(_)))
    );
}

#[test]
fn stale_graphics_timeout_preserves_a_newer_submission() {
    let mux = Mux::new("stale-graphics-timeout-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    app.pending_graphics_submission = Some(10);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;

    assert_eq!(app.retry_graphics_after_timeout(9, app.session_generation), RenderAction::None);
    assert!(app.graphics_supported);
    assert_eq!(app.pending_graphics_submission, Some(10));
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::GraphicsProcessingPending);
}

#[test]
fn graphics_identity_is_scoped_to_the_machine_session() {
    let mux = Mux::new("graphics-session-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let placement = |session_generation| {
        GraphicPlacement::browser_frame(
            session_generation,
            11,
            Rect { x: 1, y: 2, width: 3, height: 4 },
            Arc::new(BrowserFrame {
                session_id: "test".to_string(),
                data_b64: "AAAA".to_string(),
                css_width: 3,
                css_height: 4,
                image_width: 3,
                image_height: 4,
                seq: 15,
            }),
            Some(15),
            None,
        )
    };

    app.session_generation = 1;
    let first = app.graphic_identity(&placement(app.session_generation));
    app.session_generation = 2;
    let replacement = app.graphic_identity(&placement(app.session_generation));

    assert_ne!(
        first, replacement,
        "surface and frame counters can restart in a replacement machine session"
    );
}

#[test]
fn old_session_graphics_completion_preserves_current_terminal_generation() {
    let mux = Mux::new("graphics-session-completion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session_generation = 2;
    app.pending_graphics_submission = Some(8);
    app.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
    app.rendered_pane_content_generations.insert(11, PaneContentGeneration::Terminal(21));

    app.commit_graphics_processing(crate::ui::graphics_writer::GraphicsProcessing {
        id: 7,
        session_generation: 1,
        graphics: vec![crate::ui::graphics_writer::ProcessedGraphic {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 13,
            pointer_frame_seq: Some(13),
        }],
    });

    assert_eq!(
        app.rendered_pane_content_generations.get(&11),
        Some(&PaneContentGeneration::Terminal(21)),
        "an old machine's colliding surface id must not replace current terminal identity"
    );
    assert_eq!(app.pending_graphics_submission, Some(8));
}

#[test]
fn pane_pointer_routes_bind_rendered_content_generation() {
    let pane_rect = Rect { x: 1, y: 2, width: 23, height: 10 };
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    let content_click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 3,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };
    let chrome_click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane_rect.x,
        row: pane_rect.y,
        modifiers: KeyModifiers::NONE,
    };

    for (kind, before, after, terminal_input) in [
        (
            SurfaceKind::Pty,
            PaneContentGeneration::Terminal(10),
            PaneContentGeneration::Terminal(11),
            Some(content),
        ),
        (
            SurfaceKind::Browser,
            PaneContentGeneration::Browser(20),
            PaneContentGeneration::Browser(21),
            None,
        ),
    ] {
        let pane = RenderedPaneRoute {
            pane: 7,
            surface: 9,
            kind: Some(kind),
            rect: pane_rect,
            bar: None,
            omnibar: None,
            omnibar_source_x: 0,
            content,
            content_source_x: 0,
            track: None,
            terminal_input,
        };
        let mut frame = RenderedPointerFrame {
            panes: vec![pane].into(),
            pane_content_generations: Arc::new(HashMap::from([(pane.surface, before)])),
            ..Default::default()
        };
        let content_before = frame.route_for_mouse(&content_click);
        let chrome_before = frame.route_for_mouse(&chrome_click);

        frame.pane_content_generations = Arc::new(HashMap::from([(pane.surface, after)]));
        let content_after = frame.route_for_mouse(&content_click);
        let chrome_after = frame.route_for_mouse(&chrome_click);

        assert_ne!(
            content_before, content_after,
            "{kind:?} content clicks must be invalidated by a rendered-content change"
        );
        assert_eq!(
            chrome_before, chrome_after,
            "{kind:?} content changes must not invalidate pane chrome"
        );
    }
}

#[test]
fn deferred_menu_click_cannot_retarget_a_replacement_tab() {
    let mux = Mux::new("stable-menu-resource-test", SurfaceOptions::default());
    let first = mux.new_browser_tab("about:blank#first".to_string(), None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second =
        mux.new_browser_tab("about:blank#second".to_string(), Some(pane), Some((80, 24))).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((80, 24));
    let area = app.pane_areas.iter().find(|area| area.pane == pane).copied().unwrap();
    let omnibar = area.omnibar.expect("browser tab should render an omnibar");
    let click = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: omnibar.x + 2,
        row: omnibar.y,
        modifiers: KeyModifiers::NONE,
    };
    app.menu =
        Some(ContextMenu::at(click.column, click.row, vec![vec![MenuAction::RenameTab(pane)]]));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::DrawPending;

    app.handle(AppEvent::Input(Event::Mouse(click))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    app.select_tab_for_client(Some(pane), Some(1), None);
    app.replace_tree(app.session.tree());
    assert_eq!(app.active_surface(), Some(second.id));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert!(
        app.prompt.is_none(),
        "the menu click rendered for the first tab must not rename the replacement tab"
    );
    mux.close_surface(first.id).unwrap();
    mux.close_surface(second.id).unwrap();
}

fn assert_rect_within_frame(rect: Rect, frame_size: (u16, u16)) {
    assert!(
        rect.x.saturating_add(rect.width) <= frame_size.0,
        "rectangle {rect:?} exceeds frame width {}",
        frame_size.0
    );
    assert!(
        rect.y.saturating_add(rect.height) <= frame_size.1,
        "rectangle {rect:?} exceeds frame height {}",
        frame_size.1
    );
}

fn assert_cached_geometry_within_frame(app: &App, frame_size: (u16, u16)) {
    assert_eq!(app.outer_size, frame_size, "cached outer size must match the drawn frame");
    assert_rect_within_frame(app.sidebar_layout.content, frame_size);
    for rect in [app.sidebar_layout.machine, app.sidebar_layout.workspace, app.sidebar_layout.tabs]
        .into_iter()
        .flatten()
    {
        assert_rect_within_frame(rect, frame_size);
    }
    for placement in &app.sidebar_layout.ordered {
        assert_rect_within_frame(placement.rect, frame_size);
    }
    assert_rect_within_frame(app.content_area, frame_size);
    for area in &app.pane_areas {
        assert_rect_within_frame(area.rect, frame_size);
        assert_rect_within_frame(area.content, frame_size);
        for rect in [area.bar, area.omnibar, area.track].into_iter().flatten() {
            assert_rect_within_frame(rect, frame_size);
        }
    }
    for (rect, _) in &app.hits {
        assert_rect_within_frame(*rect, frame_size);
    }
}

#[test]
fn frame_area_owner_resyncs_paint_after_backend_shrink() {
    let mux = Mux::new("frame-area-owner-paint-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((100, 20))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    assert_cached_geometry_within_frame(&app, (100, 20));

    terminal.backend_mut().resize(40, 10);
    app.render_action(&mut terminal, RenderAction::Paint).unwrap();

    assert_cached_geometry_within_frame(&app, (40, 10));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn frame_area_owner_zero_frame_drops_rendered_routes() {
    let mux = Mux::new("frame-area-owner-zero-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((40, 10))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    let mut terminal = Terminal::new(TestBackend::new(40, 10)).unwrap();

    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    assert!(!app.pane_areas.is_empty());
    assert!(!app.rendered_pointer_frame.panes.is_empty());

    terminal.backend_mut().resize(0, 0);
    app.render_action(&mut terminal, RenderAction::Paint).unwrap();

    assert_eq!(app.outer_size, (0, 0));
    assert!(app.pane_areas.is_empty());
    assert!(app.hits.is_empty());
    assert!(app.rendered_pointer_frame.panes.is_empty());
    assert!(app.rendered_pointer_frame.hits.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn terminal_paint_reuses_unchanged_pointer_owner_snapshots() {
    let (mux, surface) = test_mux("pointer-owner-paint-cache-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(1),
            id: "machine-1".to_string(),
            name: "machine-1".to_string(),
            subtitle: "cloud".to_string(),
            status: MachineStatus::Running,
        }],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    }));
    app.sidebar_visible = true;
    app.sync_layout((100, 20));
    app.menu = Some(ContextMenu::at(
        app.content_area.x + 2,
        app.content_area.y + 2,
        vec![vec![MenuAction::NewTab(app.active_pane().unwrap())]],
    ));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let first_menu = app.rendered_pointer_frame.menu.clone().expect("rendered menu");
    let first_machine = app
        .rendered_pointer_frame
        .hits
        .iter()
        .find_map(|route| match route.identity.as_deref() {
            Some(PointerHitIdentity::Machine(target)) => Some(target.context.clone()),
            Some(PointerHitIdentity::MachineContext(context)) => Some(context.clone()),
            _ => None,
        })
        .expect("rendered machine identity");

    app.render_action(&mut terminal, RenderAction::Paint).unwrap();
    let second_menu = app.rendered_pointer_frame.menu.clone().expect("rendered menu");
    let second_machine = app
        .rendered_pointer_frame
        .hits
        .iter()
        .find_map(|route| match route.identity.as_deref() {
            Some(PointerHitIdentity::Machine(target)) => Some(target.context.clone()),
            Some(PointerHitIdentity::MachineContext(context)) => Some(context.clone()),
            _ => None,
        })
        .expect("rendered machine identity");

    assert!(
        Arc::ptr_eq(&first_menu, &second_menu),
        "terminal output must not rebuild unchanged menu strings"
    );
    assert!(
        Arc::ptr_eq(&first_machine, &second_machine),
        "terminal output must not clone the app-wide machine catalog"
    );
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_tab_press_cannot_retarget_a_replacement_surface_at_the_same_index() {
    let mux = Mux::new("stable-tab-route-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((80, 24));
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let first_tab = app
        .hits
        .iter()
        .find_map(|(rect, hit)| match hit {
            crate::app::Hit::Tab { pane: hit_pane, index: 0 } if *hit_pane == pane => Some(*rect),
            _ => None,
        })
        .expect("first tab hit");
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: first_tab.x + first_tab.width.saturating_sub(1) / 2,
        row: first_tab.y,
        modifiers: KeyModifiers::NONE,
    };

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    app.tree.pane_mut(pane).unwrap().tabs.swap(0, 1);
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    app.replay_deferred_input().unwrap();

    assert!(
        app.drag.is_none(),
        "the old tab press must not arm the replacement surface at the same index"
    );
    mux.close_surface(first.id).unwrap();
    mux.close_surface(second.id).unwrap();
}

#[test]
fn deferred_scrollbar_press_cannot_reinterpret_changed_thumb_geometry() {
    let (mux, surface) = test_mux("stable-scrollbar-route-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    surface.with_terminal(|terminal| {
        for index in 0..100 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let track = app
        .hits
        .iter()
        .find_map(|(_, hit)| match hit {
            crate::app::Hit::Scrollbar { surface: id, track, .. } if *id == surface.id => {
                Some(*track)
            }
            _ => None,
        })
        .expect("rendered scrollbar");
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: track.x,
        row: track.y + track.height.saturating_sub(1),
        modifiers: KeyModifiers::NONE,
    };

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    surface.view_scroll_delta(-10_000).unwrap();
    assert_eq!(surface.view_scrollbar().map(|state| state.offset), Some(0));
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    app.replay_deferred_input().unwrap();

    assert_eq!(
        surface.view_scrollbar().map(|state| state.offset),
        Some(0),
        "a click rendered on the old thumb must not become a live track jump"
    );
    assert!(app.drag.is_none());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn active_scrollbar_drag_rebases_after_terminal_output_changes_geometry() {
    let (mux, surface) = test_mux("scrollbar-drag-rebase-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    surface.with_terminal(|terminal| {
        for index in 0..100 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let (track, scrollbar) = app
        .hits
        .iter()
        .find_map(|(_, hit)| match hit {
            crate::app::Hit::Scrollbar { surface: id, track, scrollbar } if *id == surface.id => {
                Some((*track, *scrollbar))
            }
            _ => None,
        })
        .expect("rendered scrollbar");
    let (thumb_y, thumb_len) = thumb_geometry(&scrollbar, track.height);
    let pointer_y = track.y + thumb_y + thumb_len.saturating_sub(1) / 2;
    app.start_scrollbar_drag(surface.id, track, scrollbar, pointer_y);
    assert!(matches!(app.drag, Some(Drag::Scrollbar { .. })));

    surface.with_terminal(|terminal| {
        for index in 100..200 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    app.handle_left_drag(track.x, pointer_y).unwrap();

    assert!(
        matches!(app.drag, Some(Drag::Scrollbar { .. })),
        "terminal output must rebase the active drag instead of releasing capture"
    );
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_click_fails_closed_after_pointer_map_generation_changes() {
    let mux = Mux::new("pointer-map-generation-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((80, 24));
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let new_screen = app
        .hits
        .iter()
        .find_map(|(rect, hit)| (*hit == crate::app::Hit::NewScreen).then_some(*rect))
        .expect("new screen hit");
    let screen_count = app.tree.active_workspace().unwrap().screens.len();

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: new_screen.x,
        row: new_screen.y,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    app.session.pending_mutation_with_impact(MutationImpact::PointerMap).supersede();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    app.replay_deferred_input().unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert_eq!(
        app.tree.active_workspace().unwrap().screens.len(),
        screen_count,
        "a click from an older pointer-map generation must not create a screen"
    );
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn rejected_input_shows_an_error_without_disconnecting() {
    let mux = Mux::new("oversized-input-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Oversized));
    assert_eq!(app.status_message.as_deref(), Some("Input exceeds the 4 MiB PTY buffer limit"));
    assert!(!app.quit);

    assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Saturated));
    assert_eq!(app.status_message.as_deref(), Some("PTY input queue is full; input was not sent"));
    assert!(!app.quit);

    assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Failed));
    assert_eq!(
        app.status_message.as_deref(),
        Some("PTY input is unavailable after a transport failure")
    );
    assert!(!app.quit);
}

#[test]
fn clean_terminal_exit_failure_uses_a_lifecycle_message() {
    let mux = Mux::new("clean-terminal-exit-status-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Ordered),
        reservation_id: None,
        label: "terminal exited",
        error: "terminal host has exited".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();

    assert_eq!(
        app.status_message.as_deref(),
        Some("Terminal exited; input was not sent"),
        "a clean terminal exit must not be presented as an input or transport failure"
    );
}

#[test]
fn rejected_release_clears_the_active_pty_drag() {
    let mux = Mux::new("rejected-release-drag-test", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: surface.id,
        handle: None,
        reservation_id: 41,
        release_bytes: PtyInputBytes::from_slice(b"fallback-release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));

    assert!(app.finish_pty_mouse_drag(4, 3, MouseButton::Left, KeyModifiers::NONE));

    assert!(app.drag.is_none());
    assert_eq!(app.status_message.as_deref(), Some("PTY input queue is full; input was not sent"));
}

#[test]
fn mismatched_release_preserves_the_active_pty_drag() {
    let mux = Mux::new("mismatched-release-drag-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 41,
        release_bytes: PtyInputBytes::from_slice(b"fallback-release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    assert!(app.finish_pty_mouse_drag(4, 3, MouseButton::Right, KeyModifiers::NONE));
    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));
}

#[test]
fn motion_failure_preserves_pty_drag_for_the_physical_release() {
    let mux = Mux::new("motion-failure-drag-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 1,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Right,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Motion),
        reservation_id: None,
        label: "PTY input",
        error: "write failed".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();

    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
}

#[test]
fn rejected_motion_enqueue_rolls_back_mouse_encoder_dedupe() {
    let mux = Mux::new("motion-enqueue-rollback-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
    let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
    let mut app = test_app(Session::Local(mux.clone()));
    let input = test_mouse_motion();

    assert!(!encode_test_mouse_motion(&handle, input).is_empty());
    assert!(encode_test_mouse_motion(&handle, input).is_empty());

    app.rollback_mouse_motion_for_enqueue_failure(
        surface.id,
        PtyInputKind::Motion,
        PtyInputEnqueueResult::Saturated,
    );
    assert!(!encode_test_mouse_motion(&handle, input).is_empty());
    assert!(encode_test_mouse_motion(&handle, input).is_empty());

    app.rollback_mouse_motion_for_enqueue_failure(
        surface.id,
        PtyInputKind::Motion,
        PtyInputEnqueueResult::Failed,
    );
    assert!(!encode_test_mouse_motion(&handle, input).is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn evicted_known_undelivered_motion_allows_same_cell_retry() {
    let mux = Mux::new("motion-cancel-rollback-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
    let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
    let mut app = test_app(Session::Local(mux.clone()));
    let input = test_mouse_motion();

    assert!(!encode_test_mouse_motion(&handle, input).is_empty());
    assert!(encode_test_mouse_motion(&handle, input).is_empty());
    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(surface.id),
        kind: Some(PtyInputKind::Motion),
        reservation_id: None,
        label: "PTY input",
        error: "remote session did not respond".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::Ambiguous,
    }))
    .unwrap();
    assert!(encode_test_mouse_motion(&handle, input).is_empty());

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(surface.id),
        kind: Some(PtyInputKind::Motion),
        reservation_id: None,
        label: "PTY input",
        error: "evicted from the bounded PTY queue before delivery".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();
    assert!(!encode_test_mouse_motion(&handle, input).is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn lane_failure_clears_pty_drag_after_nonpress_failure() {
    let mux = Mux::new("lane-failure-drag-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 1,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Right,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Motion),
        reservation_id: None,
        label: "PTY input",
        error: "remote session did not respond".to_string(),
        lane_failed: true,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();

    assert!(app.drag.is_none());
}

#[test]
fn ambiguous_press_failure_preserves_pty_drag_for_the_physical_release() {
    let mux = Mux::new("ambiguous-press-drag-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 7,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Press),
        reservation_id: Some(7),
        label: "PTY input",
        error: "remote session did not respond".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::Ambiguous,
    }))
    .unwrap();

    assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));
}

#[test]
fn dispatcher_timeout_preserves_ambiguous_press_for_recovery_release() {
    let mux = Mux::new("dispatcher-timeout-press-drag-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
    let mut app = test_app(Session::Local(mux.clone()));
    let (result, reservation_id) =
        app.pty_input.enqueue_with_reservation(PtyInputEvent::test_remote_timeout_input(
            surface.id,
            handle.clone(),
            PtyInputBytes::from_slice(b"press"),
            PtyInputKind::Press,
        ));
    assert_eq!(result, PtyInputEnqueueResult::Accepted);
    let reservation_id = reservation_id.unwrap();
    app.drag = Some(Drag::PtyMouse {
        surface: surface.id,
        handle: Some(handle.clone()),
        reservation_id,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    let deadline = Instant::now() + Duration::from_secs(1);
    while app.pty_failures.state.lock().unwrap().failures.is_empty() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(!app.pty_failures.state.lock().unwrap().failures.is_empty());
    app.apply_pty_failures();

    assert!(matches!(
        app.drag,
        Some(Drag::PtyMouse { surface: active, reservation_id: active_reservation, .. })
            if active == surface.id && active_reservation == reservation_id
    ));
    assert!(app.enqueue_pty_release(
        surface.id,
        Some(handle),
        reservation_id,
        PtyInputBytes::from_slice(b"release"),
    ));
    app.drag = None;
    mux.close_surface(surface.id).unwrap();
}
