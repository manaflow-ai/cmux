//! Worker lifecycle, timeouts, not-responding notices, and input point mapping.

use super::*;

#[test]
fn kill_drops_sender_and_worker_exits() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();

    browser.kill();
    assert!(browser.navigate("after-close.test").is_err());
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
}

#[test]
fn browser_resizes_preserve_input_barriers_and_completion() {
    let mux = Mux::new("ordered-browser-resize-test", SurfaceOptions::default());
    let surface = new_surface(
        1,
        "https://example.test".into(),
        (10, 5),
        (8, 16),
        &SurfaceOptions::default(),
        Arc::downgrade(&mux),
    )
    .unwrap();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let events = mux.subscribe();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(Duration::from_secs(1)).unwrap();

    assert!(browser.resize(11, 5).unwrap());
    browser.mouse_event("mousePressed", 1.0, 1.0, Some("left"), Some(1)).unwrap();
    assert!(browser.resize(12, 6).unwrap());

    release.send(()).unwrap();
    let resized = (0..2)
        .map(|_| {
            loop {
                if let MuxEvent::SurfaceResized { cols, rows, .. } = events.recv().unwrap() {
                    break (cols, rows);
                }
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(resized, vec![(11, 5), (12, 6)]);
    browser.kill();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
}

#[test]
fn full_command_queue_retains_mouse_releases_without_unbounded_growth() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    browser.enqueue_control(BrowserCommand::Hold { entered, release: held }).unwrap();
    started.recv_timeout(Duration::from_secs(1)).unwrap();
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
        browser.enqueue_control(BrowserCommand::Activate).unwrap();
    }

    let (attempting_tx, attempting_rx) = mpsc::channel();
    let (enqueued_tx, enqueued_rx) = mpsc::channel();
    let release_surface = surface.clone();
    let enqueue = thread::spawn(move || {
        attempting_tx.send(()).unwrap();
        let result = release_surface.browser_mouse_event(
            "mouseReleased",
            1.0,
            1.0,
            Some("left"),
            Some(1),
        );
        enqueued_tx.send(result).unwrap();
    });
    attempting_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    enqueued_rx
        .recv_timeout(Duration::from_millis(100))
        .expect("retaining a mouse release must not wait for regular queue capacity")
        .unwrap();
    for offset in 1..crate::browser::BROWSER_RETAINED_RELEASE_CAPACITY {
        surface
            .browser_mouse_event(
                "mouseReleased",
                1.0 + offset as f64,
                1.0,
                Some("left"),
                Some(1),
            )
            .expect("the bounded release lane must retain accepted releases");
    }
    assert!(
        surface
            .browser_mouse_event("mouseReleased", 100.0, 2.0, Some("left"), Some(1))
            .is_err(),
        "the bounded release lane must reject input beyond its capacity"
    );

    release.send(()).unwrap();
    enqueue.join().unwrap();
    browser.kill();
    done.recv_timeout(Duration::from_secs(1))
        .expect("browser worker exited after reliable release");
}

#[test]
fn timeout_failed_status_notice_is_emitted_once_per_stall_episode() {
    let surface = test_surface();
    let mux = Mux::new("timeout-latch-test", SurfaceOptions::default());
    let events = mux.subscribe();
    let weak = Arc::downgrade(&mux);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        MuxEvent::Status(message) if message == "CDP call Page.navigate timed out"
    ));
    while events.try_recv().is_ok() {}

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        MuxEvent::Status(message) if message == crate::browser::BROWSER_NOT_RESPONDING_MESSAGE
    ));
    while events.try_recv().is_ok() {}

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    assert!(events.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn locally_discarded_pointer_input_preserves_browser_timeout_streak() {
    let (runtime, server, dispatched, stop) = runtime_recording_mouse_dispatches();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let mux = Mux::new("discarded-pointer-timeout-test", SurfaceOptions::default());
    let events = mux.subscribe();
    let weak = Arc::downgrade(&mux);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    while events.try_recv().is_ok() {}
    browser.invalidate_pointer_frame();
    let discarded = browser.mouse_event_blocking(
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Local,
            event_type: "mouseMoved",
            x: 1.0,
            y: 1.0,
            button: None,
            click_count: None,
            frame_seq: Some(1),
        },
        &mut failures.active_pointer_presses,
    );
    assert_eq!(discarded.as_ref().unwrap(), &crate::browser::BrowserWorkerSuccess::LocallySettled);
    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        true,
        discarded,
        &mut failures,
    );
    let streak_after_discard = failures.consecutive_timeouts;

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.reload timed out")),
        &mut failures,
    );
    let reported_not_responding = events.try_iter().any(|event| {
        matches!(
            event,
            MuxEvent::Status(message) if message == crate::browser::BROWSER_NOT_RESPONDING_MESSAGE
        )
    });
    let dispatched_stale_input = dispatched.recv_timeout(Duration::from_millis(100)).is_ok();

    stop.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();

    assert_eq!(
        streak_after_discard, 1,
        "a locally discarded pointer sample must not count as a browser response"
    );
    assert!(
        reported_not_responding,
        "the second real CDP timeout must still enter the visible recovery state"
    );
    assert!(!dispatched_stale_input, "stale pointer input must remain local");
}

#[test]
fn frame_clearing_not_responding_rearms_timeout_notice() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let mux = Mux::new("timeout-frame-reset-test", SurfaceOptions::default());
    let events = mux.subscribe();
    let weak = Arc::downgrade(&mux);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    while events.try_recv().is_ok() {}

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        MuxEvent::Status(message) if message == crate::browser::BROWSER_NOT_RESPONDING_MESSAGE
    ));
    assert_eq!(
        browser.status(),
        BrowserStatus::Failed(crate::browser::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
    );
    while events.try_recv().is_ok() {}

    browser.store_frame(test_frame(1));
    assert_eq!(browser.status(), BrowserStatus::Live);

    crate::browser::record_browser_worker_result(
        &surface,
        &weak,
        surface.id,
        false,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
        &mut failures,
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        MuxEvent::Status(message) if message == crate::browser::BROWSER_NOT_RESPONDING_MESSAGE
    ));
    assert_eq!(
        browser.status(),
        BrowserStatus::Failed(crate::browser::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
    );
}

// Regression: when a fresh frame clears the worker's not-responding
// failure, the recovery must be broadcast to attach clients (remote TUIs),
// not just flipped in memory. Before the fix `store_frame` set status back
// to Live but left the "browser failed: ..." title `mark_failed` had
// written and never marked the state dirty, so attached clients stayed
// stuck on the failed status/title even as frames streamed in.
#[test]
fn recovery_from_not_responding_broadcasts_live_state_to_attach_clients() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    // Give the surface a known URL so the recovered title is derived from it.
    browser.set_url_title("https://recovered.test".to_string(), "recovered".to_string());
    // Attach before the failure so the tap observes both the failure and the recovery.
    let (_snapshot, stream) = browser.attach_frames();

    let failed_title = format!("browser failed: {}", crate::browser::BROWSER_NOT_RESPONDING_MESSAGE);
    browser.mark_not_responding();
    let failed = stream.slot.lock().unwrap().state.clone().expect("failure was broadcast");
    assert_eq!(
        failed.status,
        BrowserStatus::Failed(crate::browser::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
    );
    assert_eq!(failed.title, failed_title);
    // Simulate the event thread drawing the failure and consuming the dirty
    // flag, so the recovery below starts from a clean flag like it would in
    // production.
    assert!(browser.take_dirty(), "mark_failed must mark the surface dirty");

    // A fresh frame proves Chrome recovered.
    browser.store_frame(test_frame(1));
    assert_eq!(browser.status(), BrowserStatus::Live);
    // The event thread that delivers this frame emits the local TUI redraw
    // via `if !dirty.swap(true)`. store_frame must leave that transition
    // available (dirty still clear) instead of pre-consuming it, or the
    // local status line stays stuck on the failure.
    assert!(
        !browser.take_dirty(),
        "recovery must not pre-consume the dirty transition the event thread emits on"
    );
    let recovered =
        stream.slot.lock().unwrap().state.clone().expect("recovery must be broadcast too");
    assert_eq!(recovered.status, BrowserStatus::Live);
    assert_ne!(
        recovered.title, failed_title,
        "recovered attach state still shows the stale failure title"
    );
    assert_eq!(recovered.title, "https://recovered.test");
    let recovered_frame =
        stream.slot.lock().unwrap().frame.clone().expect("recovery must publish the frame");
    assert_eq!(
        recovered.pointer_frame_seq, recovered_frame.pointer_frame_seq,
        "coalesced recovery state must not revoke the frame's pointer authority"
    );
    assert!(
        recovered.pointer_frame_seq.is_some(),
        "the recovery snapshot must expose the fresh frame's pointer authority"
    );
}

#[test]
fn runtime_never_discovers_or_launches_an_isolated_browser() {
    let opts = SurfaceOptions::default();
    let explicit_opts = SurfaceOptions {
        cdp_url: Some("ws://127.0.0.1:9/devtools/browser/explicit".to_string()),
        ..opts.clone()
    };
    let (url, source) = runtime_endpoint(&explicit_opts).unwrap();
    assert_eq!(url, "ws://127.0.0.1:9/devtools/browser/explicit");
    assert_eq!(source, BrowserSource::External);

    let error = runtime_endpoint(&opts).expect_err("provider-less runtime must fail");
    assert!(error.to_string().contains("no cmux-browser provider is attached"));
}

#[test]
fn input_mapping_uses_latest_frame_viewport() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");
    {
        let state = browser.state.lock().unwrap();
        assert_eq!(state.pane_pixels, (4760, 2548));
    }

    let mut frame = test_frame(1);
    frame.css_width = 2320;
    frame.css_height = 1363;
    browser.store_frame(frame);

    assert_eq!(browser.scale_input_point(2380.0, 1274.0), (1160.0, 681.5));
    assert_eq!(browser.scale_delta(100.0), 100.0 * 1363.0 / 2548.0);
}

#[test]
fn input_mapping_falls_back_to_capture_pixels_before_first_frame() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");

    assert_eq!(browser.scale_input_point(2380.0, 1274.0), (966.5, 517.5));
    let expected_scale = browser.state.lock().unwrap().capture_scale;
    assert!((browser.scale_delta(100.0) - 100.0 * expected_scale).abs() < f64::EPSILON);
}

#[test]
fn input_mapping_uses_new_capture_geometry_while_waiting_for_resized_frame() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (476, 182), (10, 14), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");

    let mut frame = test_frame(1);
    frame.css_width = 2320;
    frame.css_height = 1363;
    browser.store_frame(frame);

    let queued = browser.reserve_reconfigure(400, 100).expect("changed geometry");
    browser.confirm_reconfigure(queued, browser.frame_epoch.advance());

    let state = browser.state.lock().unwrap();
    assert_eq!(state.latest_frame, None);
    assert_eq!(state.page_viewport, None);
    let (pane_width, pane_height) = state.pane_pixels;
    let (capture_width, capture_height) = state.capture_pixels;
    let capture_scale = state.capture_scale;
    drop(state);

    assert_eq!(
        browser.scale_input_point(f64::from(pane_width), f64::from(pane_height)),
        (f64::from(capture_width), f64::from(capture_height))
    );
    assert!((browser.scale_delta(100.0) - 100.0 * capture_scale).abs() < f64::EPSILON);
}

#[test]
fn input_mapping_clamps_to_page_viewport() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));

    assert_eq!(browser.scale_input_point(-5.0, 999.0), (0.0, 48.0));
}

#[test]
fn guarded_input_mapping_requires_current_route_pointer_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());

    browser.store_frame(test_frame(2));
    assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
    assert!(
        browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none(),
        "receiving a replacement frame must not acknowledge its presentation"
    );
    acknowledge_local_presentation(browser, 2);
    assert!(
        browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
        "acknowledging the replacement must retire the owner's previous exact token"
    );
    assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_some());

    browser.mark_failed("failed".to_string());
    assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none());
}

#[test]
fn pointer_presentations_are_exact_and_scoped_to_each_input_owner() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let first = crate::browser::BrowserPointerOwner::Client(7);
    let second = crate::browser::BrowserPointerOwner::Client(8);
    browser.store_frame(test_frame(1));

    assert!(browser.acknowledge_pointer_frame_from(first, 1));
    {
        let state = browser.state.lock().unwrap();
        assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 1));
        assert!(!browser.presented_pointer_frame_is_current_locked(&state, second, 1));
    }

    browser.store_frame(test_frame(2));
    {
        let state = browser.state.lock().unwrap();
        assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 1));
        assert!(!browser.presented_pointer_frame_is_current_locked(&state, first, 2));
    }
    assert!(browser.acknowledge_pointer_frame_from(first, 2));
    {
        let state = browser.state.lock().unwrap();
        assert!(!browser.presented_pointer_frame_is_current_locked(&state, first, 1));
        assert!(browser.presented_pointer_frame_is_current_locked(&state, first, 2));
        assert!(!browser.presented_pointer_frame_is_current_locked(&state, second, 2));
    }
    browser.forget_pointer_owner(first);
    assert!(browser.state.lock().unwrap().presented_pointer_frames.is_empty());
}

#[test]
fn queued_pointer_admission_survives_only_same_route_repaints() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let owner = crate::browser::BrowserPointerOwner::Client(7);
    browser.store_frame(test_frame(1));
    let admission =
        browser.admit_pointer_frame(owner, Some(1)).expect("initial pointer admission");

    browser.store_frame(test_frame(2));
    assert!(browser.acknowledge_pointer_frame_from(owner, 2));
    assert!(
        browser
            .scale_guarded_input_point_from(owner, Some(1), Some(admission), 1.0, 1.0)
            .is_some(),
        "a later presentation must not discard an already queued click"
    );

    browser.invalidate_pointer_frame();
    assert!(
        browser
            .scale_guarded_input_point_from(owner, Some(1), Some(admission), 1.0, 1.0)
            .is_none(),
        "document or geometry invalidation must still revoke queued input"
    );
}

#[test]
fn ingress_navigation_epoch_revokes_pointer_before_surface_event_delivery() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");

    browser.frame_epoch.advance_navigation();

    assert!(
        browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
        "a queued navigation event must close guarded pointer admission at CDP ingress"
    );
    assert!(
        browser.capture_guarded_input_point(1, 1.0, 1.0).is_none(),
        "a queued navigation event must reject a new pointer capture"
    );
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_none(),
        "a queued navigation event must revoke an existing pointer capture"
    );
}

#[test]
fn navigation_invalidates_pointer_admission_until_a_new_frame() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
    assert_eq!(browser.latest_frame_seq(), Some(1));

    let frame_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://next.test", "name": "next"}}),
        frame_epoch,
    );

    assert_eq!(
        browser.latest_frame().map(|frame| frame.seq),
        Some(1),
        "navigation keeps the last image available for rendering"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "the retained image must not remain pointer-admissible"
    );
    assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none());
    browser.store_frame(test_frame(2));
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "an unverified streamed frame must remain non-interactive"
    );
    assert!(browser.accept_document_paint(frame_epoch, frame_epoch, test_frame(2)));
    assert_eq!(browser.latest_frame_seq(), Some(2));
    assert!(
        browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_none(),
        "verified pixels must still wait for the renderer presentation"
    );
    acknowledge_local_presentation(browser, 2);
    assert!(browser.scale_guarded_input_point(Some(2), 1.0, 1.0).is_some());
}
