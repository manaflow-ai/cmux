//! Tests: panic reporting around terminal restore, surface attach and its
//! failures, tree refresh, input and resize sync, and graphics on attach.

use super::*;

#[test]
fn panic_report_is_emitted_after_terminal_restore() {
    let events = Mutex::new(Vec::new());
    let result: std::thread::Result<()> = {
        events.lock().unwrap().push("restore");
        Err(Box::new(()))
    };
    let result = report_after_unwind(result, || events.lock().unwrap().push("panic"));

    assert!(result.is_err());
    assert_eq!(*events.lock().unwrap(), vec!["restore", "panic"]);
}

#[test]
fn host_terminal_resize_marks_graphics_scene_for_retransmission() {
    let mux = Mux::new("resize-graphics-invalidation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    assert!(!app.graphics_host_scene_reset_pending);

    assert_eq!(app.handle(AppEvent::Input(Event::Resize(120, 40))).unwrap(), RenderAction::Draw);

    assert!(app.graphics_host_scene_reset_pending);
}

#[test]
fn graphics_scene_cache_skips_text_only_snapshot_rebuilds() {
    let mux = Mux::new("graphics-scene-cache-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    app.pane_areas.push(PaneArea {
        pane: 1,
        surface: surface.id,
        rect: Rect { x: 0, y: 0, width: 82, height: 26 },
        bar: Some(Rect { x: 0, y: 0, width: 82, height: 1 }),
        omnibar: None,
        content: Rect { x: 1, y: 1, width: 80, height: 24 },
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, Rect { x: 1, y: 1, width: 80, height: 24 });
    let snapshot = Arc::new(KittyGraphicsSnapshot { generation: 7, ..Default::default() });
    app.rendered_kitty_graphics.insert(surface.id, snapshot.clone());

    app.emit_graphics().unwrap();
    app.rendered_kitty_graphics.insert(surface.id, snapshot);
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 1);

    app.rendered_kitty_graphics.insert(
        surface.id,
        Arc::new(KittyGraphicsSnapshot { generation: 7, ..Default::default() }),
    );
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 2);

    app.cell_pixels = (9, 18);
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 3);

    app.pane_areas[0].content.x = 2;
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 4);

    app.menu = Some(ContextMenu::at(10, 5, vec![vec![MenuAction::CopyPaneId(1)]]));
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 5);

    app.graphics_scene_cache.invalidate();
    app.emit_graphics().unwrap();
    assert_eq!(app.graphics_scene_cache.rebuilds, 6);
}

#[test]
fn graphics_scene_cache_rebuilds_only_the_dirty_surface_projection() {
    let mux = Mux::new("graphics-surface-cache-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((40, 24))).unwrap();
    let second = mux.new_workspace(None, Some((40, 24))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.graphics_supported = true;
    app.pane_areas = vec![
        PaneArea {
            pane: 1,
            surface: first.id,
            rect: Rect { x: 0, y: 0, width: 42, height: 26 },
            bar: Some(Rect { x: 0, y: 0, width: 42, height: 1 }),
            omnibar: None,
            content: Rect { x: 1, y: 1, width: 40, height: 24 },
            track: None,
            viewport: None,
        },
        PaneArea {
            pane: 2,
            surface: second.id,
            rect: Rect { x: 42, y: 0, width: 42, height: 26 },
            bar: Some(Rect { x: 42, y: 0, width: 42, height: 1 }),
            omnibar: None,
            content: Rect { x: 43, y: 1, width: 40, height: 24 },
            track: None,
            viewport: None,
        },
    ];
    for area in &app.pane_areas {
        app.rendered_terminal_bounds.insert(area.surface, area.content);
        app.rendered_kitty_graphics.insert(
            area.surface,
            Arc::new(KittyGraphicsSnapshot { generation: 1, ..Default::default() }),
        );
    }
    app.emit_graphics().unwrap();

    app.rendered_kitty_graphics
        .insert(first.id, Arc::new(KittyGraphicsSnapshot { generation: 2, ..Default::default() }));
    app.graphics_dirty_surfaces.insert(first.id);
    app.emit_dirty_graphics().unwrap();

    assert_eq!(app.graphics_scene_cache.projection_rebuilds.get(&first.id), Some(&2));
    assert_eq!(app.graphics_scene_cache.projection_rebuilds.get(&second.id), Some(&1));
    assert_eq!(app.graphics_scene_cache.rebuilds, 2);
}

#[test]
fn horizontal_viewport_keeps_visible_kitty_placement_aligned() {
    let mux = Mux::new("viewport-kitty-placement-test", SurfaceOptions::default());
    let created = mux.new_workspace(None, Some((10, 2))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.cell_pixels = (10, 20);
    let area = PaneArea {
        pane: 1,
        surface: created.id,
        rect: Rect { x: 0, y: 0, width: 7, height: 4 },
        bar: Some(Rect { x: 0, y: 0, width: 7, height: 1 }),
        omnibar: None,
        content: Rect { x: 1, y: 1, width: 5, height: 2 },
        track: None,
        viewport: Some(PaneViewportClip {
            rect_source_x: 5,
            full_rect_width: 12,
            omnibar_source_x: 0,
            full_omnibar_width: 0,
            content_source_x: 5,
            full_content_width: 10,
        }),
    };
    app.rendered_terminal_bounds.insert(created.id, area.content);
    app.rendered_kitty_graphics.insert(
        created.id,
        Arc::new(KittyGraphicsSnapshot {
            generation: 1,
            images: vec![KittyImage {
                id: 41,
                number: 0,
                generation: 1,
                width: 20,
                height: 20,
                format: KittyImageFormat::Rgb,
                data: Arc::from(vec![0; 20 * 20 * 3]),
            }],
            placements: vec![KittyPlacement {
                key: KittyPlacementKey { image_id: 41, placement_id: 7, ordinal: 0 },
                image_id: 41,
                placement_id: 7,
                is_internal: false,
                x_offset: 0,
                y_offset: 0,
                source_x: 0,
                source_y: 0,
                source_width: 20,
                source_height: 20,
                columns: 2,
                rows: 1,
                grid_cols: 2,
                grid_rows: 1,
                pixel_width: 20,
                pixel_height: 20,
                viewport_col: 5,
                viewport_row: 0,
                viewport_visible: true,
                anchor: None,
                z: 0,
            }],
        }),
    );
    let surface = app.session.surface(created.id).unwrap();

    let placements = app.graphic_placements_for_area(area, Some(&surface), &[]);

    assert_eq!(placements.len(), 1);
    assert_eq!(placements[0].rect, Rect { x: 1, y: 1, width: 2, height: 1 });
    assert_eq!(placements[0].source, Some(GraphicSourceRect { x: 0, y: 0, width: 20, height: 20 }));
}

#[test]
fn host_resize_without_ioctl_pixels_preserves_last_queried_cell_measurement() {
    let mux = Mux::new("resize-cell-pixel-preservation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.cell_pixels = (11, 19);

    app.handle(AppEvent::Input(Event::Resize(120, 40))).unwrap();

    assert_eq!(app.cell_pixels, (11, 19));
}

#[test]
fn superseded_client_refresh_results_are_ignored() {
    let mux = Mux::new("stale-client-refresh-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.client_refresh_generation.store(2, Ordering::Release);

    app.handle(AppEvent::ClientsUpdated {
        generation: 1,
        result: Err("stale snapshot".to_string()),
    })
    .unwrap();

    assert!(app.status_message.is_none());
}

#[test]
fn failed_size_release_keeps_lease_retryable_until_success() {
    let mux = Mux::new("size-release-retry-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.visible_size_surfaces.insert(7);
    app.pending_size_releases.insert(7);

    app.session.pending_mutations.fetch_add(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::SurfaceSizeReleaseFailed {
        surface: 7,
        error: "transport closed".to_string(),
    }))
    .unwrap();
    assert!(app.visible_size_surfaces.contains(&7));
    assert!(!app.pending_size_releases.contains(&7));

    app.pending_size_releases.insert(7);
    app.session.pending_mutations.fetch_add(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::SurfaceSizeReleaseCanceled {
        surface: 7,
    }))
    .unwrap();
    assert!(app.visible_size_surfaces.contains(&7));
    assert!(!app.pending_size_releases.contains(&7));

    app.pending_size_releases.insert(7);
    app.session.pending_mutations.fetch_add(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::SurfaceSizeReleased { surface: 7 }))
        .unwrap();
    assert!(!app.visible_size_surfaces.contains(&7));
    assert!(!app.pending_size_releases.contains(&7));
}

#[test]
fn reverse_viewport_sweep_cancels_a_queued_size_release_and_reasserts() {
    let mux = Mux::new("reverse-animation-size-release-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((78, 22))).unwrap();
    let base = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(base, 1.0, Some((78, 22))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.config.viewport.animation = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 25));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert_eq!(app.viewport_offset, 80);

    mux.resize_surface_for_client(first.id, 0, 78, 22).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block queued size release",
        false,
        move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.visible_size_surfaces.insert(first.id);
    let surface = app.session.surface(first.id).unwrap();
    let prior_claim = match app.session.surface_resize_decision(first.id, (78, 22), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("the queued resize must claim the surface"),
    };
    assert!(app.session.resize_surface(first.id, surface, 78, 22, false, prior_claim));
    let prior_claim_token =
        app.session.surface_resize_claims.lock().unwrap().get(&first.id).unwrap().token;
    assert!(app.session.release_surface_size(first.id));
    app.pending_size_releases.insert(first.id);
    app.focus_pane_after_input(base);
    app.config.viewport.animation = true;
    app.sync_layout((80, 25));

    let reassert_claim_token =
        app.session.surface_resize_claims.lock().unwrap().get(&first.id).unwrap().token;
    let release_canceled = !app.pending_size_releases.contains(&first.id);
    release_tx.send(()).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert!(release_canceled, "a visible surface must no longer be pending release");
    assert_ne!(
        reassert_claim_token, prior_claim_token,
        "the reverse sweep must supersede an older resize claim"
    );
    assert!(
        app.session.has_surface_size_report(first.id),
        "the stale release must not drop the visible surface's sizing lease"
    );

    mux.close_surface(first.id).unwrap();
    mux.close_surface(right.id).unwrap();
}

#[test]
fn failed_surface_sync_is_bounded_until_lifecycle_recovery() {
    let mux = Mux::new("surface-sync-failure-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));

    app.session.attach_surface(77, Some((80, 24)));
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 77,
                operation: "attach",
                ..
            },
            ..
        }
    ));
    app.handle(settled).unwrap();
    assert!(!app.session.can_attach_surface(77));
    app.session.attach_surface(77, Some((80, 24)));
    assert!(events.try_recv().is_err());

    let claim = match app.session.surface_resize_decision(88, (100, 30), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("first resize must queue"),
    };
    app.session.resize_surface(88, SurfaceHandle::RemoteBrowserUnsupported, 100, 30, false, claim);
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 88,
                operation: "resize",
                ..
            },
            ..
        }
    ));
    app.handle(settled).unwrap();
    assert!(matches!(
        app.session.surface_resize_decision(88, (100, 30), true),
        SurfaceResizeDecision::Failed
    ));

    app.session.clear_surface_sync_failures();
    assert!(app.session.can_attach_surface(77));
    assert!(matches!(
        app.session.surface_resize_decision(88, (100, 30), true),
        SurfaceResizeDecision::NeedsQueue(_)
    ));
}

#[test]
fn retiring_surface_during_inflight_attach_is_not_a_sync_failure() {
    let mux = Mux::new("surface-retired-during-attach-test", SurfaceOptions::default());
    let surface = 77;
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    app.replace_tree(notify_tree(surface, false));

    let reached = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let hook_reached = reached.clone();
    let hook_release = release.clone();
    *app.session.surface_attach_after_obsolete_check.lock().unwrap() = Some(Arc::new(move || {
        hook_reached.wait();
        hook_release.wait();
    }));

    app.session.attach_surface(surface, Some((80, 24)));
    reached.wait();
    app.session.forget_surface(surface);
    // The authoritative refresh can prune the general tombstone before
    // the in-flight attach returns. Its claim must retain the retirement.
    app.session.reconcile_retired_surfaces(&TreeView::default());
    assert!(!app.session.retired_surfaces.lock().unwrap().contains(&surface));
    release.wait();

    let settled = loop {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if matches!(
            &event,
            AppEvent::SurfaceAttachSettled {
                outcome: crate::app::SurfaceAttachOutcome::Retired { surface: 77 },
            }
        ) {
            break event;
        }
        app.handle(event).unwrap();
    };
    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Retired { surface: 77 }
        }
    ));
    app.handle(settled).unwrap();
    assert!(app.status_message.is_none());
    assert!(!app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
}

#[test]
fn server_confirmed_missing_surface_during_attach_is_a_silent_retirement() {
    let surface = 77;
    let session = crate::session::test_remote_session_with_missing_surface_attach(surface);
    let (mut app, events) = test_app_with_events(session);
    app.replace_tree(notify_tree(surface, false));

    app.session.attach_surface(surface, Some((80, 24)));
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();

    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Retired { surface: 77 },
        }
    ));
    app.handle(settled).unwrap();
    assert!(app.status_message.is_none());
    assert!(!app.tab_locations.contains_key(&surface));
    assert!(app.session.has_pending_mutations(), "retirement must refresh the stale tree");
    assert!(!app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
    assert!(!app.session.can_attach_surface(surface));
}

#[test]
fn mirror_retirement_before_tree_refresh_is_a_silent_attach_retirement() {
    let surface = 7;
    let (session, attach_started, release_attach) = test_remote_session_with_deferred_attach();
    let (mut app, events) = test_app_with_events(session);
    app.replace_tree(notify_tree(surface, false));

    app.session.attach_surface(surface, Some((80, 24)));
    attach_started.recv_timeout(Duration::from_secs(1)).unwrap();

    // The remote mirror can observe detach before the authoritative tree
    // refresh reaches OrderedSession and retires its outer attach claim.
    app.session.inner.forget_surface(surface);
    release_attach.send(()).unwrap();

    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Retired { surface: 7 },
        }
    ));
    app.handle(settled).unwrap();
    assert!(app.status_message.is_none());
    assert!(!app.tab_locations.contains_key(&surface));
    assert!(!app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
}

#[test]
fn retiring_surface_does_not_swallow_attach_transport_failure() {
    let surface = 77;
    let reached = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let session = crate::session::test_remote_session_with_blocked_attach_transport_failure(
        reached.clone(),
        release.clone(),
    );
    assert!(session.take_remote_tree_stale());
    let (mut app, events) = test_app_with_events(session);
    app.replace_tree(notify_tree(surface, false));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    app.session.attach_surface(surface, Some((80, 24)));
    reached.wait();
    app.session.forget_surface(surface);
    app.session.reconcile_retired_surfaces(&TreeView::default());
    release.wait();

    let settled = loop {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if matches!(
            &event,
            AppEvent::SurfaceAttachSettled {
                outcome: crate::app::SurfaceAttachOutcome::Failed {
                    surface: 77,
                    operation: "attach",
                    ..
                },
            }
        ) {
            break event;
        }
        app.handle(event).unwrap();
    };
    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Failed {
                surface: 77,
                operation: "attach",
                error,
                ..
            }
        } if error.contains("remote transport write failed")
    ));
    app.handle(settled).unwrap();
    assert!(app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
}

#[test]
fn unrelated_stale_tree_before_attach_request_preserves_the_sync_failure() {
    let session = crate::session::test_remote_session_without_provider_authority();
    assert!(session.take_remote_tree_stale());
    let surface = 77;
    let (mut app, events) = test_app_with_events(session);
    app.replace_tree(notify_tree(surface, false));

    let reached = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let hook_reached = reached.clone();
    let hook_release = release.clone();
    *app.session.surface_attach_after_obsolete_check.lock().unwrap() = Some(Arc::new(move || {
        hook_reached.wait();
        hook_release.wait();
    }));

    app.session.attach_surface(surface, Some((80, 24)));
    reached.wait();
    app.session.invalidate_remote_tree();
    app.session.begin_shutdown();
    release.wait();

    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Failed {
                surface: 77,
                operation: "attach",
                ..
            }
        }
    ));
    app.handle(settled).unwrap();
    assert!(app.status_message.as_deref().is_some_and(|message| {
        message.contains("surface 77 attach failed")
            && message.contains("remote response wait canceled for shutdown")
    }));
    assert!(app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
}

#[test]
fn unrelated_stale_tree_during_attach_preserves_the_sync_failure() {
    let session = crate::session::test_remote_session_without_provider_authority();
    assert!(session.take_remote_tree_stale());
    let surface = 77;
    let (mut app, events) = test_app_with_events(session);
    app.replace_tree(notify_tree(surface, false));

    let session = app.session.inner.clone();
    *app.session.surface_attach_after_obsolete_check.lock().unwrap() = Some(Arc::new(move || {
        session.invalidate_remote_tree();
        session.begin_shutdown();
    }));

    app.session.attach_surface(surface, Some((80, 24)));

    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        &settled,
        AppEvent::SurfaceAttachSettled {
            outcome: crate::app::SurfaceAttachOutcome::Failed {
                surface: 77,
                operation: "attach",
                ..
            }
        }
    ));
    app.handle(settled).unwrap();
    assert!(app.status_message.as_deref().is_some_and(|message| {
        message.contains("surface 77 attach failed")
            && message.contains("remote response wait canceled for shutdown")
    }));
    assert!(app.session.surface_attach_failures.lock().unwrap().contains_key(&surface));
}

#[test]
fn ambiguous_attach_timeout_survives_lifecycle_clear_until_reconnect() {
    let mux = Mux::new("ambiguous-attach-timeout-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));
    app.session
        .surface_attach_failures
        .lock()
        .unwrap()
        .insert(77, crate::app::next_surface_sync_failure(None, false, true));

    app.session.clear_surface_sync_failures();

    assert!(app.session.surface_attach_failures.lock().unwrap().contains_key(&77));
    assert!(!app.session.can_attach_surface(77));
}

#[test]
fn ambiguous_attach_timeout_discards_input_and_requests_reconnect() {
    let mux = Mux::new("ambiguous-attach-reconnect-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        Some(77),
        1,
    ));
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(settled(crate::app::SessionMutationOutcome::SurfaceSyncFailed {
        surface: 77,
        operation: "attach",
        error: "remote session did not respond".to_string(),
        reconnect_required: true,
    }))
    .unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(
        app.status_message
            .as_deref()
            .is_some_and(|message| message.contains("detach and reconnect"))
    );
}

#[test]
fn surface_attach_failure_status_uses_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_SURFACE_ATTACH_FAILURE_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("app::tests::surface_attach_failure_status_uses_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese surface attach failure child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let mux = Mux::new("surface-attach-failure-locale-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.handle(AppEvent::SurfaceAttachSettled {
        outcome: crate::app::SurfaceAttachOutcome::Failed {
            surface: 77,
            operation: "attach",
            error: "offline".to_string(),
            reconnect_required: false,
        },
    })
    .unwrap();
    assert_eq!(
        app.status_message.as_deref(),
        Some("サーフェス 77 の接続に失敗しました。再試行は制限されています: offline")
    );

    app.handle(AppEvent::SurfaceAttachSettled {
        outcome: crate::app::SurfaceAttachOutcome::Failed {
            surface: 77,
            operation: "attach",
            error: "timeout".to_string(),
            reconnect_required: true,
        },
    })
    .unwrap();
    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "サーフェス 77 の接続結果は不明です。入力を続ける前に切断して再接続してください: timeout"
        )
    );

    app.session.pending_mutations.store(1, Ordering::Release);
    app.handle(AppEvent::SessionMutationSettled {
        outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
            surface: 77,
            operation: "resize",
            error: "offline".to_string(),
            reconnect_required: false,
        },
        impact: MutationImpact::Ordered,
    })
    .unwrap();
    assert_eq!(
        app.status_message.as_deref(),
        Some("サーフェス 77 のサイズ変更に失敗しました。再試行は制限されています: offline")
    );
}

#[test]
fn graphics_status_events_use_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_GRAPHICS_STATUS_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("app::tests::graphics_status_events_use_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese graphics status child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let mux = Mux::new("graphics-status-locale-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session
        .surface_resize_ownership
        .lock()
        .unwrap()
        .insert(7, SurfaceResizeOwnership { desired: (90, 31), reservation_id: None });

    app.status_message = Some("直前のコマンドは完了しました".to_string());
    crate::client_log::start_test_log_capture();
    for retry_exhausted in [false, true] {
        let action = app
            .handle(AppEvent::Mux(MuxEvent::GraphicsStatus(
                cmux_tui_core::GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted,
                    summary: Arc::<str>::from("surface 7: offline"),
                },
            )))
            .unwrap();
        assert_eq!(action, RenderAction::None);
        assert_eq!(app.status_message.as_deref(), Some("直前のコマンドは完了しました"));
    }
    let kitty_records = crate::client_log::take_test_log_capture();
    assert_eq!(kitty_records.len(), 2);
    for (record, expected) in kitty_records.iter().zip([
        "Kitty 画像予算の更新に失敗しました。再試行しています: surface 7: offline",
        "Kitty 画像予算の更新に失敗し、再試行回数の上限に達したため停止しました: surface 7: offline",
    ]) {
        assert_eq!(record.level, "WARN");
        assert_eq!(record.area, "kitty-graphics");
        assert_eq!(record.message, expected);
    }

    let cases = [
        (
            MuxEvent::GraphicsStatus(
                cmux_tui_core::GraphicsStatus::KittyImageBudgetWorkerStartFailed {
                    error: Arc::<str>::from("thread unavailable"),
                },
            ),
            "Kitty 画像予算ワーカーを開始できませんでした: thread unavailable",
        ),
        (
            MuxEvent::GraphicsStatus(
                cmux_tui_core::GraphicsStatus::CellPixelUpdateRetriesExhausted {
                    attempts: 5,
                    remaining: 2,
                    cell_pixels: (8, 16),
                },
            ),
            "セルピクセル更新は 5 回の再試行後に停止しました。8x16 で未収束のサーフェスが 2 個あります。後続のホスト確認応答で復旧できます",
        ),
        (
            MuxEvent::SurfaceResizeFailed {
                surface: 7,
                cols: 90,
                rows: 31,
                error: Arc::<str>::from("device metrics rejected"),
                retry_after_ms: None,
                reservation_id: None,
            },
            "ブラウザサーフェス 7 の 90x31 へのサイズ変更に失敗しました: device metrics rejected",
        ),
    ];
    for (event, expected) in cases {
        app.handle(AppEvent::Mux(event)).unwrap();
        assert_eq!(app.status_message.as_deref(), Some(expected));
    }
    app.handle(AppEvent::BrowserResizeFailed(BrowserResizeFailure {
        surface_id: 8,
        cols: 100,
        rows: 40,
        error: "viewport rejected".to_string(),
    }))
    .unwrap();
    assert_eq!(
        app.status_message.as_deref(),
        Some("ブラウザサーフェス 8 の 100x40 へのサイズ変更に失敗しました: viewport rejected")
    );
}

#[test]
fn kitty_budget_failures_do_not_replace_the_user_status_message() {
    let mux = Mux::new("kitty-status-preservation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.status_message = Some("command completed".to_string());
    crate::client_log::start_test_log_capture();

    let summary = "surface 7: host did not acknowledge limits";
    for retry_exhausted in [false, true] {
        let action = app
            .handle(AppEvent::Mux(MuxEvent::GraphicsStatus(
                cmux_tui_core::GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted,
                    summary: Arc::<str>::from(summary),
                },
            )))
            .unwrap();
        assert_eq!(action, RenderAction::None);
        assert_eq!(app.status_message.as_deref(), Some("command completed"));
    }

    let records = crate::client_log::take_test_log_capture();
    assert_eq!(records.len(), 2);
    for (record, expected) in records.iter().zip([
        "Kitty image budget update failed, retrying: surface 7: host did not acknowledge limits",
        "Kitty image budget update failed, stopped after exhausting retries: surface 7: host did not acknowledge limits",
    ]) {
        assert_eq!(record.level, "WARN");
        assert_eq!(record.area, "kitty-graphics");
        assert_eq!(record.message, expected);
    }
}

#[test]
fn first_input_for_missing_mirror_is_deferred_through_attach() {
    let mux = Mux::new("missing-mirror-input-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let surface = 77;
    app.replace_tree(notify_tree(surface, false));
    app.pane_areas.push(browser_completion_area(surface));

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 77,
                operation: "attach",
                ..
            },
            ..
        }
    ));
    app.handle(settled).unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();
    assert_eq!(app.deferred_input.len(), 1);
}

#[test]
fn terminally_failed_retained_motion_does_not_block_a_later_key() {
    let (mux, healthy) = test_mux("failed-retained-motion-order-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    let failed_surface = 77;
    app.replace_tree(notify_tree(healthy.id, false));
    app.pane_areas = vec![browser_completion_area(healthy.id), {
        let mut area = browser_completion_area(failed_surface);
        area.pane = 3;
        area.rect.x = 40;
        area.bar.as_mut().unwrap().x = 40;
        area.omnibar.as_mut().unwrap().x = 40;
        area.content.x = 40;
        area
    }];
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(88)));

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 49,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert!(app.pending_pointer_motion.is_some());
    assert_eq!(app.deferred_input.len(), 1);

    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 77,
                operation: "attach",
                ..
            },
            ..
        }
    ));
    app.handle(settled).unwrap();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert!(app.pending_pointer_motion.is_none());
    assert!(app.deferred_input.is_empty());
    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "x");
    mux.close_surface(healthy.id).unwrap();
}

#[test]
fn pointer_input_waits_for_a_cached_surface_attach_claim() {
    let (mux, surface) = test_mux("cached-attach-claim-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(notify_tree(surface.id, false));
    app.pane_areas.push(browser_completion_area(surface.id));
    app.session
        .surface_attach_claims
        .lock()
        .unwrap()
        .insert(surface.id, SurfaceAttachClaimState::default());

    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    };
    app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();

    assert_eq!(app.pending_pointer_motion.map(|pending| pending.event), Some(motion));

    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    };
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();

    assert!(matches!(
        app.deferred_input.front().map(|input| &input.event),
        Some(TerminalInput::Mouse(event)) if *event == press
    ));

    app.session.surface_attach_claims.lock().unwrap().remove(&surface.id);
    app.replay_deferred_input().unwrap();

    assert!(app.pending_pointer_motion.is_none());
    assert!(app.deferred_input.is_empty());

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn retained_pointer_motion_retries_a_missing_surface_attach() {
    let mux = Mux::new("missing-mirror-pointer-retry-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let surface = 77;
    app.replace_tree(notify_tree(surface, false));
    app.pane_areas.push(browser_completion_area(surface));
    app.session.surface_attach_failures.lock().unwrap().insert(
        surface,
        crate::app::SurfaceSyncFailureState {
            attempts: 1,
            retry_after: Some(Instant::now() + Duration::from_secs(30)),
            sticky_until_reconnect: false,
        },
    );

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.pending_pointer_motion.is_some());
    assert!(!app.session.has_pending_mutations());
    assert!(events.try_recv().is_err());

    app.session.surface_attach_failures.lock().unwrap().get_mut(&surface).unwrap().retry_after =
        Some(Instant::now() - Duration::from_millis(1));
    app.retry_pending_surface_attach();

    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 77,
                operation: "attach",
                ..
            },
            ..
        }
    ));
}

#[test]
fn retained_pointer_attach_waits_for_a_fresh_rendered_route() {
    let mux = Mux::new("stale-pointer-attach-route-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    let stale_surface = 77;
    app.pane_areas.push(browser_completion_area(stale_surface));
    app.retain_pointer_motion(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 1,
        destination_generation: 0,
        result: Ok(TreeView::default()),
    })
    .unwrap();
    app.retry_pending_surface_attach();

    assert!(
        !app.session.has_pending_mutations(),
        "a stale frame must not choose a surface to attach"
    );
}

#[test]
fn retained_pointer_motion_retry_skips_a_rate_limited_deferred_surface() {
    let mux = Mux::new("missing-mirror-pointer-starvation-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let deferred_surface = 77;
    let pointer_surface = 88;
    app.replace_tree(notify_tree(deferred_surface, false));
    app.pane_areas.push(browser_completion_area(deferred_surface));
    let mut pointer_area = browser_completion_area(pointer_surface);
    pointer_area.rect.x = 40;
    pointer_area.bar.as_mut().unwrap().x = 40;
    pointer_area.omnibar.as_mut().unwrap().x = 40;
    pointer_area.content.x = 40;
    app.pane_areas.push(pointer_area);
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        Some(deferred_surface),
        1,
    ));
    app.pending_pointer_motion = Some(crate::app::PendingPointerMotion {
        event: MouseEvent {
            kind: MouseEventKind::Moved,
            column: 49,
            row: 3,
            modifiers: KeyModifiers::NONE,
        },
        destination: Some(pointer_surface),
        focus_generation: 0,
        sequence: 2,
    });
    app.session.surface_attach_failures.lock().unwrap().insert(
        deferred_surface,
        crate::app::SurfaceSyncFailureState {
            attempts: 1,
            retry_after: Some(Instant::now() + Duration::from_secs(30)),
            sticky_until_reconnect: false,
        },
    );

    app.retry_pending_surface_attach();

    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::SurfaceSyncFailed {
                surface: 88,
                operation: "attach",
                ..
            },
            ..
        }
    ));
}

#[test]
fn replacing_tree_retires_removed_browser_input_state() {
    let mux = Mux::new("browser-input-topology-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (dispatcher, _blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let surface = 41;
    app.replace_tree(browser_completion_tree(surface, surface));
    let _ = app.browser_input.enqueue(BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::InsertText("x".to_string()),
    });
    assert!(app.browser_input.tracks_surface(surface));

    app.replace_tree(TreeView::default());

    assert!(!app.browser_input.tracks_surface(surface));
}

#[test]
fn transient_surface_sync_failures_stop_after_bounded_backoff() {
    let first = crate::app::next_surface_sync_failure(None, true, false);
    assert_eq!(first.attempts, 1);
    assert!(crate::app::surface_sync_failure_blocks(first));

    let elapsed = crate::app::SurfaceSyncFailureState {
        attempts: first.attempts,
        retry_after: Some(Instant::now() - Duration::from_millis(1)),
        sticky_until_reconnect: false,
    };
    assert!(!crate::app::surface_sync_failure_blocks(elapsed));
    let capped = (0..10)
        .fold(elapsed, |state, _| crate::app::next_surface_sync_failure(Some(state), true, false));
    assert_eq!(capped.attempts, 6);
    assert!(capped.retry_after.is_none());
    assert!(capped.sticky_until_reconnect);
    assert!(crate::app::surface_sync_failure_blocks(capped));
}

#[test]
fn due_session_resize_failure_rearms_idle_loop_retry() {
    let mux = Mux::new("session-resize-retry-due-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));

    assert!(!app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));
    assert!(!app.session.surface_resize_retry_due());

    app.session
        .surface_resize_ownership
        .lock()
        .unwrap()
        .insert(41, SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(7) });
    assert!(app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));
    assert!(app.session.surface_resize_retry_due());

    app.session.confirm_surface_resize(41, (90, 31), Some(7));
    assert!(!app.session.surface_resize_retry_due());
    assert!(!app.session.surface_resize_ownership.lock().unwrap().contains_key(&41));
}

#[test]
fn stale_same_geometry_completion_does_not_release_newer_resize_owner() {
    let mux = Mux::new("resize-owner-identity-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));
    app.session
        .surface_resize_ownership
        .lock()
        .unwrap()
        .insert(41, SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(9) });

    app.session.confirm_surface_resize(41, (90, 31), Some(7));
    assert_eq!(
        app.session.surface_resize_ownership.lock().unwrap().get(&41).copied(),
        Some(SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(9) })
    );
    assert!(!app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));

    app.session.confirm_surface_resize(41, (90, 31), Some(9));
    assert!(!app.session.surface_resize_ownership.lock().unwrap().contains_key(&41));
}

#[test]
fn refresh_sequences_are_monotonic_across_identity_and_background_paths() {
    let mux = Mux::new("refresh-sequence-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let newer = notify_tree(22, false);
    let older = notify_tree(11, false);
    app.session.pending_mutations.store(1, Ordering::Release);
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        1,
    ));

    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 2,
        destination_generation: 0,
        result: Ok(newer.clone()),
    })
    .unwrap();
    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree: older.clone(),
        authoritative_generation: 0,
        destination_generation: 0,
        refresh_sequence: 1,
    }))
    .unwrap();
    assert_eq!(app.tree.workspaces()[0].screens[0].panes[0].tabs[0].surface, 22);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    assert_eq!(app.deferred_input.len(), 1);

    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.session.pending_mutations.store(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree: newer,
        authoritative_generation: 0,
        destination_generation: 0,
        refresh_sequence: 4,
    }))
    .unwrap();
    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 3,
        destination_generation: 0,
        result: Ok(older),
    })
    .unwrap();
    assert_eq!(app.tree.workspaces()[0].screens[0].panes[0].tabs[0].surface, 22);
}

#[test]
fn stale_identity_refresh_retires_completion_against_newer_tree() {
    let mux = Mux::new("stale-identity-completion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let surface = 41;
    let tree = browser_completion_tree(surface, surface);
    app.pane_areas.push(browser_completion_area(surface));
    app.pending_session_completions.push_back(SessionCompletion {
        mutation_generation: 4,
        semantic_intent: None,
        action: SessionCompletionAction::BrowserTabCreated { surface },
    });

    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 2,
        destination_generation: 0,
        result: Ok(tree.clone()),
    })
    .unwrap();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.retain_pointer_motion(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    });
    app.session.pending_mutations.store(1, Ordering::Release);
    let action = app
        .handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree,
            authoritative_generation: 4,
            destination_generation: 0,
            refresh_sequence: 1,
        }))
        .unwrap();

    assert!(app.pending_session_completions.is_empty());
    assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(surface));
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    assert_eq!(action, RenderAction::Draw);
}

#[test]
fn background_tree_snapshot_sets_input_routing_barrier() {
    let mux = Mux::new("background-routing-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 1,
        destination_generation: 0,
        result: Ok(notify_tree(22, false)),
    })
    .unwrap();

    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(app.deferred_input.len(), 1);
}

#[test]
fn background_tree_refresh_stops_after_retry_budget() {
    let mux = Mux::new("background-refresh-budget-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    for refresh_sequence in 1..=u64::from(BACKGROUND_REFRESH_RETRIES) + 1 {
        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence,
            destination_generation: 0,
            result: Err("offline".to_string()),
        })
        .unwrap();
    }

    assert_eq!(app.background_refresh_attempts, BACKGROUND_REFRESH_RETRIES);
    assert!(app.background_refresh_retry_at.is_none());
    assert!(
        app.status_message
            .as_deref()
            .is_some_and(|message| message.contains("automatic retries stopped, reconnect"))
    );
}

#[test]
fn retired_surface_tombstones_are_remote_only_and_pruned_authoritatively() {
    let mux = Mux::new("surface-tombstone-churn-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));
    for surface in 1..=1_000 {
        app.session.forget_surface(surface);
    }
    assert!(app.session.retired_surfaces.lock().unwrap().is_empty());

    let mut app = app;
    app.session.remote = true;
    for surface in 1..=1_000 {
        app.session.forget_surface(surface);
    }
    assert_eq!(app.session.retired_surfaces.lock().unwrap().len(), 1_000);
    app.session.reconcile_retired_surfaces(&notify_tree(1_000, false));
    assert_eq!(*app.session.retired_surfaces.lock().unwrap(), HashSet::from([1_000]));
    app.session.reconcile_retired_surfaces(&TreeView::default());
    assert!(app.session.retired_surfaces.lock().unwrap().is_empty());
}
