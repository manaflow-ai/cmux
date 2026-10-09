//! Navigation barriers, superseded navigations, and guarded pointer press and release.

use super::*;

#[test]
fn unguarded_pointer_input_requires_a_current_admitted_frame() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    {
        let mut state = browser.state.lock().unwrap();
        crate::browser::BrowserSurface::set_pointer_frame_locked(&mut state, None);
    }

    assert!(
        browser.scale_guarded_input_point(None, 1.0, 1.0).is_none(),
        "legacy mouse input must not bypass invalidated pointer authority"
    );
    assert!(
        browser.scale_guarded_wheel(None, 1.0, 1.0, 1.0).is_none(),
        "legacy wheel input must not bypass invalidated pointer authority"
    );
}

#[test]
fn queued_frame_before_navigation_barrier_stays_non_authoritative() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    assert!(!route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(
        cmux_tui_cdp::ScreencastFrame {
            session_id: "session-test".to_string(),
            data_b64: "queued-before-barrier".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            ack_id: 2,
            frame_epoch: 0,
        },
    )));

    browser.invalidate_pointer_frame();
    let queued = route.try_recv().expect("queued screencast frame");
    let cmux_tui_cdp::CdpEvent::ScreencastFrame(frame) = queued else {
        panic!("expected queued screencast frame");
    };
    browser.store_frame_for_epoch(
        BrowserFrame {
            session_id: frame.session_id,
            data_b64: frame.data_b64,
            css_width: frame.css_width,
            css_height: frame.css_height,
            image_width: frame.image_width,
            image_height: frame.image_height,
            seq: 0,
        },
        frame.frame_epoch,
    );

    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "a frame queued before invalidation must not reopen pointer admission"
    );
}

#[test]
fn older_navigation_event_cannot_settle_a_newer_command_barrier() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let older_epoch = browser.frame_epoch.advance();
    browser.begin_navigation_frame_transition().expect("navigation reservation");
    let expected_epoch = browser.state.lock().unwrap().pending_frame_epoch.unwrap();
    assert_ne!(older_epoch, expected_epoch);

    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://old.test", "name": "old"}}),
        older_epoch,
    );

    assert_eq!(browser.latest_frame_seq(), None);
    assert_eq!(browser.state.lock().unwrap().pending_frame_epoch, Some(expected_epoch));
    assert_ne!(browser.url(), "https://old.test");
}

#[test]
fn failed_newer_navigation_preserves_a_queued_committed_navigation() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let committed_epoch = browser.frame_epoch.advance_navigation();
    let newer = browser.begin_navigation_frame_transition().expect("newer navigation");
    let newer_epoch = newer.expected_frame_epoch.expect("newer navigation epoch");
    assert!(committed_epoch < newer_epoch);

    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
        committed_epoch,
    );
    browser.restore_pointer_frame_after_failed_command(newer);

    assert_eq!(browser.url(), "https://committed.test");
    assert!(
        browser.needs_document_paint(committed_epoch),
        "the committed document must remain pending after the newer command fails"
    );
    let paint_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));
    assert_eq!(browser.latest_frame_seq(), Some(2));
    let state = browser.state.lock().unwrap();
    assert_eq!(state.accepted_navigation_epoch, committed_epoch);
    assert_eq!(state.accepted_frame_epoch, paint_epoch);
    assert_eq!(state.pending_navigation_epoch, None);
    assert_eq!(state.pending_document_epoch, None);
}

#[test]
fn verified_committed_navigation_survives_a_newer_command_failure() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let committed_epoch = browser.frame_epoch.advance_navigation();
    let newer = browser.begin_navigation_frame_transition().expect("newer navigation");

    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
        committed_epoch,
    );
    let paint_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));
    browser.restore_pointer_frame_after_failed_command(newer);

    assert_eq!(browser.url(), "https://committed.test");
    assert_eq!(browser.latest_frame_seq(), Some(2));
    let state = browser.state.lock().unwrap();
    assert_eq!(state.accepted_navigation_epoch, committed_epoch);
    assert_eq!(state.accepted_frame_epoch, paint_epoch);
    assert_eq!(state.pending_frame_epoch, None);
    assert_eq!(state.pending_navigation_epoch, None);
    assert_eq!(state.pending_document_epoch, None);
}

#[test]
fn failed_replacement_restores_a_verified_commit_from_the_superseded_command() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let committed_epoch = browser.frame_epoch.advance_navigation();
    browser.begin_navigation_frame_transition().expect("unresolved newer navigation");
    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://committed.test", "name": "committed"}}),
        committed_epoch,
    );
    let paint_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_document_paint(committed_epoch, paint_epoch, test_frame(2)));

    let replacement =
        browser.begin_superseding_navigation_frame_transition(true).expect("replacement");
    browser.restore_pointer_frame_after_failed_command(replacement);

    assert_eq!(
        browser.latest_frame_seq(),
        Some(2),
        "the stopped command's verified document must regain pointer authority"
    );
    let state = browser.state.lock().unwrap();
    assert_eq!(state.accepted_navigation_epoch, committed_epoch);
    assert_eq!(state.accepted_frame_epoch, paint_epoch);
    assert_eq!(state.pending_navigation_epoch, None);
}

#[test]
fn reconfigure_completion_dominates_queued_older_navigation_epoch() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();

    let navigation_epoch = browser.frame_epoch.advance_navigation();
    let reconfigure_epoch = browser.frame_epoch.advance();
    browser.confirm_reconfigure(queued, reconfigure_epoch);
    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://next.test", "name": "next"}}),
        navigation_epoch,
    );
    browser.store_frame_for_epoch(test_frame(2), reconfigure_epoch);

    let state = browser.state.lock().unwrap();
    assert_eq!(
        state.accepted_frame_epoch, reconfigure_epoch,
        "an older queued navigation must not roll frame admission behind a completed resize"
    );
    assert_eq!(state.pending_frame_epoch, Some(reconfigure_epoch));
    assert_eq!(state.pending_document_epoch, Some(navigation_epoch));
    assert_eq!(
        state.latest_frame.as_ref().map(|frame| frame.seq),
        None,
        "unverified frames must remain pending even at the newest capture epoch"
    );
}

#[test]
fn reconfigure_completion_does_not_release_uncommitted_navigation() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    browser.begin_navigation_frame_transition().expect("navigation reservation");

    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();
    let reconfigure_epoch = browser.frame_epoch.advance();
    browser.confirm_reconfigure(queued, reconfigure_epoch);
    browser.store_frame_for_epoch(test_frame(2), reconfigure_epoch);

    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "a resize frame cannot prove that an unresolved navigation committed"
    );
    assert!(
        browser.begin_navigation_frame_transition().is_err(),
        "the unresolved navigation must keep command serialization ownership across a resize"
    );

    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({"frame": {"url": "https://next.test", "name": "next"}}),
        navigation_epoch,
    );
    browser.store_frame_for_epoch(test_frame(3), navigation_epoch);
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "the navigation stream cannot authorize its own document identity"
    );
    assert!(browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(3)));

    assert_eq!(
        browser.latest_frame_seq(),
        Some(3),
        "a loader-authorized paint may regain pointer authority"
    );
}

#[test]
fn latest_navigation_supersedes_an_uncommitted_reload_epoch() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (superseded_tx, superseded_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let reload = read_ws_json(&mut ws);
        assert_eq!(reload["method"], "Page.reload");
        write_ws_json(&mut ws, json!({"id": reload["id"], "result": {}}));

        let Ok(message) = ws.read() else {
            superseded_tx.send(false).unwrap();
            return;
        };
        let stop_loading: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
        if stop_loading["method"] != "Page.stopLoading" {
            superseded_tx.send(false).unwrap();
            return;
        }
        write_ws_json(&mut ws, json!({"id": stop_loading["id"], "result": {}}));

        let navigate = read_ws_json(&mut ws);
        assert_eq!(navigate["method"], "Page.navigate");
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "main-frame",
                        "loaderId": "next-loader",
                        "url": "https://next.test"
                    }
                }
            }),
        );
        write_ws_json(
            &mut ws,
            json!({
                "id": navigate["id"],
                "result": {"frameId": "main-frame", "loaderId": "next-loader"}
            }),
        );
        superseded_tx.send(true).unwrap();
        stop_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let route = runtime.register("target-1", "session-1");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    start_surface_thread(
        surface.clone(),
        route,
        Weak::new(),
        Arc::downgrade(&runtime),
        "session-1".to_string(),
    )
    .unwrap();
    browser.store_frame(test_frame(1));

    browser.reload_blocking().unwrap();
    let navigate_result = browser.navigate_blocking("https://next.test");
    let superseded = superseded_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap_or(false);

    let mut admitted = false;
    if navigate_result.is_ok() {
        let deadline = Instant::now() + BROWSER_TEST_EVENT_TIMEOUT;
        while Instant::now() < deadline
            && browser.state.lock().unwrap().pending_navigation_epoch.is_some()
        {
            thread::yield_now();
        }
        let navigation_epoch = browser.frame_epoch.current();
        admitted = browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(2));
    }
    let _ = stop_tx.send(());
    runtime.shutdown();
    server.join().unwrap();

    assert!(
        navigate_result.is_ok(),
        "the latest URL must replace an unresolved reload instead of being consumed"
    );
    assert!(superseded, "Chrome must cancel the unresolved load before accepting its replacement");
    assert!(admitted, "the replacement document must regain pointer authority");
    let state = browser.state.lock().unwrap();
    assert_eq!(state.pending_frame_epoch, None);
    assert_eq!(state.pending_navigation_epoch, None);
    assert_eq!(state.accepted_frame_epoch, browser.frame_epoch.current());
    drop(state);
    assert_eq!(browser.url(), "https://next.test");
}

#[test]
fn reload_supersedes_an_uncommitted_navigation() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (superseded_tx, superseded_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let first_reload = read_ws_json(&mut ws);
        assert_eq!(first_reload["method"], "Page.reload");
        write_ws_json(&mut ws, json!({"id": first_reload["id"], "result": {}}));

        let Ok(message) = ws.read() else {
            superseded_tx.send(false).unwrap();
            return;
        };
        let stop_loading: Value = serde_json::from_str(message.to_text().unwrap()).unwrap();
        if stop_loading["method"] != "Page.stopLoading" {
            superseded_tx.send(false).unwrap();
            return;
        }
        write_ws_json(&mut ws, json!({"id": stop_loading["id"], "result": {}}));

        let second_reload = read_ws_json(&mut ws);
        if second_reload["method"] != "Page.reload" {
            superseded_tx.send(false).unwrap();
            return;
        }
        write_ws_json(&mut ws, json!({"id": second_reload["id"], "result": {}}));
        superseded_tx.send(true).unwrap();
        stop_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));

    browser.reload_blocking().unwrap();
    let second_reload = browser.reload_blocking();
    let superseded = superseded_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap_or(false);

    let _ = stop_tx.send(());
    runtime.shutdown();
    server.join().unwrap();

    assert!(
        second_reload.is_ok(),
        "reload must replace an unresolved navigation instead of remaining permanently blocked"
    );
    assert!(superseded, "Chrome must cancel the unresolved navigation before accepting the retry");
    let state = browser.state.lock().unwrap();
    assert!(state.pending_navigation_epoch.is_some());
    assert_eq!(state.pointer_frame_seq, None, "the retry must remain fail-closed until paint");
}

#[test]
fn superseded_uncommitted_navigation_rollback_restores_original_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("initial pointer authority");
    let first = browser.begin_navigation_frame_transition().unwrap();
    browser.finish_navigation_command(first, Ok(())).unwrap();
    assert_eq!(browser.latest_frame_seq(), None);

    let replacement = browser.begin_superseding_navigation_frame_transition(true).unwrap();
    browser.restore_pointer_frame_after_failed_command(replacement);

    assert_eq!(
        browser.latest_frame_seq(),
        Some(1),
        "a stopped uncommitted navigation must retain the original rollback authority"
    );
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "rollback must restore the capture generation that owned the displayed document"
    );
}

#[test]
fn ambiguous_guarded_press_failure_retains_release_ownership() {
    let (runtime, server) = runtime_rejecting_one_mouse_dispatch();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let mut active_pointer_presses = std::collections::HashMap::new();

    let result = browser.mouse_event_blocking(
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Legacy,
            event_type: "mousePressed",
            x: 1.0,
            y: 1.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: Some(1),
        },
        &mut active_pointer_presses,
    );

    assert!(result.is_err());
    assert!(
        active_pointer_presses.contains_key("left"),
        "a timed-out press may have reached Chrome and still owns its balancing release"
    );
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn guarded_press_capture_cannot_be_stolen_by_another_input_client() {
    let (runtime, server) =
        runtime_accepting_mouse_dispatches(vec!["mousePressed", "mouseReleased"]);
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let mut active_pointer_presses = std::collections::HashMap::new();

    for dispatch in [
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Client(41),
            event_type: "mousePressed",
            x: 1.0,
            y: 1.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: Some(1),
        },
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Client(42),
            event_type: "mousePressed",
            x: 2.0,
            y: 2.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: Some(1),
        },
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Client(42),
            event_type: "mouseReleased",
            x: 2.0,
            y: 2.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: Some(1),
        },
    ] {
        browser.mouse_event_blocking(dispatch, &mut active_pointer_presses).unwrap();
    }
    assert_eq!(
        active_pointer_presses.get("left").map(|press| press.input_owner),
        Some(crate::browser::BrowserPointerOwner::Client(41)),
        "a competing client must not overwrite or consume the original press capture"
    );

    browser
        .mouse_event_blocking(
            crate::browser::BrowserMouseDispatch {
                input_owner: crate::browser::BrowserPointerOwner::Client(41),
                event_type: "mouseReleased",
                x: 1.0,
                y: 1.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        )
        .unwrap();
    assert!(active_pointer_presses.is_empty());

    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn ambiguous_guarded_release_failure_gets_one_bounded_retry() {
    let (runtime, server, retry_rx) = runtime_rejecting_then_observing_mouse_retry();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
    let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
    let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
    let mut active_pointer_presses = std::collections::HashMap::from([(
        "left".to_string(),
        crate::browser::ActivePointerPress::new(
            crate::browser::BrowserPointerOwner::Local,
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        ),
    )]);

    let result = browser.mouse_event_blocking(
        crate::browser::BrowserMouseDispatch {
            input_owner: crate::browser::BrowserPointerOwner::Local,
            event_type: "mouseReleased",
            x: 1.0,
            y: 1.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: Some(1),
        },
        &mut active_pointer_presses,
    );

    assert!(result.is_err());
    assert!(
        active_pointer_presses.contains_key("left"),
        "a timed-out release must remain retryable"
    );
    browser.mark_failed("browser is not responding".to_string());
    assert!(
        browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
        "the not-responding transition must revoke admission for new pointer input"
    );
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "the not-responding transition must preserve an accepted release capture"
    );

    let mut failures =
        crate::browser::BrowserWorkerErrorState { active_pointer_presses, ..Default::default() };
    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        Instant::now() + Duration::from_secs(1),
    );
    assert!(
        failures.active_pointer_presses.is_empty(),
        "the worker must consume an ambiguous release through one scheduled retry"
    );
    assert!(
        retry_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap(),
        "the balancing release must retain its dispatched coordinates across invalidation"
    );

    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn abandoned_pointer_release_timeout_gets_one_bounded_retry() {
    let (runtime, server, retry_rx) = runtime_rejecting_then_observing_mouse_retry();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
    let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
    let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert(
        "left".to_string(),
        crate::browser::ActivePointerPress::new(
            crate::browser::BrowserPointerOwner::Client(41),
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            (1.0, 1.0),
            Some(1),
        ),
    );
    let now = Instant::now();

    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        now,
    );
    let retained_after_timeout = failures.active_pointer_presses.contains_key("left");
    let retry_at = failures
        .active_pointer_presses
        .get("left")
        .and_then(|press| press.release_retry_at)
        .expect("the ambiguous release must schedule one retry");
    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        now,
    );
    let retained_before_retry = failures.active_pointer_presses.contains_key("left");
    let retried_without_yielding = retry_rx.recv_timeout(Duration::from_millis(20)).ok();
    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        retry_at,
    );
    let consumed_after_retry = failures.active_pointer_presses.is_empty();
    let retry_observed = retried_without_yielding
        .unwrap_or_else(|| retry_rx.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap());

    runtime.shutdown();
    server.join().unwrap();

    assert!(
        retained_after_timeout,
        "the first ambiguous cleanup release must remain owned for one retry"
    );
    assert!(retry_at > now, "the retry must yield the worker before another CDP call");
    assert!(
        retained_before_retry,
        "the retry must remain pending until its deferred lifecycle deadline"
    );
    assert!(
        retried_without_yielding.is_none(),
        "the worker must not perform two potentially long CDP calls back-to-back"
    );
    assert!(consumed_after_retry, "the bounded cleanup retry must consume the press");
    assert!(retry_observed, "cleanup must dispatch one balancing release retry");
}

#[test]
fn captured_release_remains_admitted_during_ambiguous_reconfigure() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");

    browser.begin_reconfigure_frame_transition();

    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "a geometry barrier must preserve an accepted press's balancing release"
    );
}

#[test]
fn geometry_change_suppresses_captured_motion_and_releases_at_last_authoritative_point() {
    let (runtime, server, events, stop) = runtime_recording_mouse_dispatches();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let mut active_pointer_presses = std::collections::HashMap::new();

    browser
        .mouse_event_blocking(
            crate::browser::BrowserMouseDispatch {
                input_owner: crate::browser::BrowserPointerOwner::Local,
                event_type: "mousePressed",
                x: 8.0,
                y: 16.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        )
        .unwrap();
    let press = events.recv_timeout(Duration::from_secs(1)).unwrap();

    let queued = browser.reserve_reconfigure(20, 10).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();
    browser.confirm_reconfigure(queued, browser.frame_epoch.advance());
    browser
        .mouse_event_blocking(
            crate::browser::BrowserMouseDispatch {
                input_owner: crate::browser::BrowserPointerOwner::Local,
                event_type: "mouseMoved",
                x: 80.0,
                y: 80.0,
                button: Some("left"),
                click_count: None,
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        )
        .unwrap();
    let motion = events.recv_timeout(Duration::from_millis(100)).ok();

    browser
        .mouse_event_blocking(
            crate::browser::BrowserMouseDispatch {
                input_owner: crate::browser::BrowserPointerOwner::Local,
                event_type: "mouseReleased",
                x: 80.0,
                y: 80.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: Some(1),
            },
            &mut active_pointer_presses,
        )
        .unwrap();
    let release = events.recv_timeout(Duration::from_secs(1)).unwrap();
    stop.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();

    assert!(
        motion.is_none(),
        "motion captured under the old geometry must not cross a resize barrier"
    );
    assert_eq!(release["params"]["type"], "mouseReleased");
    assert_eq!(release["params"]["x"], press["params"]["x"]);
    assert_eq!(release["params"]["y"], press["params"]["y"]);
    assert!(
        active_pointer_presses.is_empty(),
        "the balancing release must settle the retained press"
    );
}

#[test]
fn pointer_admission_changes_are_broadcast_to_attach_clients() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let (_snapshot, stream) = browser.attach_frames();

    let invalidation = browser.invalidate_pointer_frame();
    stream
        .notify
        .recv_timeout(Duration::from_secs(1))
        .expect("pointer invalidation must wake attached clients");
    let invalidated = stream
        .slot
        .lock()
        .unwrap()
        .state
        .take()
        .expect("pointer invalidation must publish browser state");
    assert_eq!(
        invalidated.pointer_frame_seq, None,
        "attached clients must stop admitting the retained frame"
    );

    browser.restore_pointer_frame_after_failed_command(invalidation);
    stream
        .notify
        .recv_timeout(Duration::from_secs(1))
        .expect("failed-command rollback must wake attached clients");
    let restored = stream
        .slot
        .lock()
        .unwrap()
        .state
        .take()
        .expect("failed-command rollback must publish browser state");
    assert_eq!(
        restored.pointer_frame_seq,
        Some(1),
        "attached clients must restore admission after a rejected navigation"
    );
}

#[test]
fn ingress_navigation_hides_stale_pointer_authority_from_attach_clients() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let stale_epoch = browser.frame_epoch.current();

    browser.frame_epoch.advance_navigation();
    let (snapshot, stream) = browser.attach_frames();
    browser.store_frame_for_epoch(test_frame(2), stale_epoch);
    stream
        .notify
        .recv_timeout(Duration::from_secs(1))
        .expect("stale queued frame must still update retained pixels");
    let update = stream.slot.lock().unwrap().frame.take().expect("stale retained frame");

    assert_eq!(
        snapshot.pointer_frame_seq, None,
        "an initial attach must not export authority after ingress observes navigation"
    );
    assert_eq!(
        update.pointer_frame_seq, None,
        "a queued old-epoch frame must not regain exported pointer authority"
    );
}

#[test]
fn geometry_pointer_admission_invalidation_is_broadcast_to_attach_clients() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let (_snapshot, stream) = browser.attach_frames();

    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.confirm_reconfigure(queued, browser.frame_epoch.advance());

    stream
        .notify
        .recv_timeout(Duration::from_secs(1))
        .expect("geometry invalidation must wake attached clients");
    let invalidated = stream
        .slot
        .lock()
        .unwrap()
        .state
        .take()
        .expect("geometry invalidation must publish browser state");
    assert_eq!(
        invalidated.pointer_frame_seq, None,
        "attached clients must stop admitting the pre-resize frame"
    );
}

#[test]
fn pointer_capture_survives_repaint_but_not_navigation() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live press frame");

    browser.store_frame(test_frame(2));
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "ordinary repaint frames must preserve pointer capture"
    );

    let reconfigure = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.confirm_reconfigure(reconfigure, browser.frame_epoch.advance());
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "geometry changes must preserve capture so the page receives its release"
    );

    browser.invalidate_pointer_frame();
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_none(),
        "navigation must revoke pointer capture from the previous document"
    );
}

#[test]
fn failed_navigation_dispatch_restores_the_rendered_frame_admission() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        let navigate = read_ws_json(&mut ws);
        assert_eq!(navigate["method"], "Page.navigate");
        write_ws_json(
            &mut ws,
            json!({"id": navigate["id"], "error": {"message": "injected failure"}}),
        );
        stop_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    assert!(browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some());
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live press frame");

    assert!(browser.navigate_blocking("https://next.test").is_err());

    let restored = browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_some();
    let capture_restored =
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some();
    stop_tx.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();
    assert!(restored, "a rejected navigation must leave the rendered frame interactive");
    assert!(capture_restored, "a rejected navigation must restore active capture ownership");
}

#[test]
fn response_level_navigation_failure_clears_frame_epoch_reservation() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        let navigate = read_ws_json(&mut ws);
        assert_eq!(navigate["method"], "Page.navigate");
        write_ws_json(
            &mut ws,
            json!({"id": navigate["id"], "result": {"errorText": "navigation rejected"}}),
        );
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));

    assert!(browser.navigate_blocking("https://rejected.test").is_err());

    assert_eq!(
        browser.state.lock().unwrap().pending_frame_epoch,
        None,
        "a response-level failure must not poison the next navigation epoch"
    );
    assert_eq!(browser.state.lock().unwrap().pending_navigation_epoch, None);
    runtime.shutdown();
    server.join().unwrap();
}
