//! Pointer capture leases, same-document navigation, and screencast capture verification.

use super::*;

#[test]
fn same_document_navigation_preserves_an_accepted_pointer_capture() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let authority = browser.latest_frame_seq().expect("initial pointer authority");
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(authority, 1.0, 1.0).expect("accepted pointer press");
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

    let _observed = handle_same_document_navigated(
        browser,
        &json!({"frameId": "main-frame", "url": "https://example.test/#next"}),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("same-document URL");
    let capture_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_same_document_paint(capture_epoch, test_frame(2)));

    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "a same-document navigation must preserve the balancing release for an accepted press"
    );
}

#[test]
fn page_initiated_same_document_navigation_requires_verified_pixels() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let authority = browser.latest_frame_seq().expect("initial pointer authority");
    let (_, capture_generation, motion_generation, ingress_motion_generation) =
        browser.capture_guarded_input_point(authority, 1.0, 1.0).expect("accepted pointer press");
    let navigation_epoch = browser.frame_epoch.latest_navigation();
    let frame_epoch = browser.frame_epoch.advance_same_document();

    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#page-initiated"
        }),
        frame_epoch,
    )
    .expect("same-document URL");

    assert!(
        browser.needs_same_document_paint(),
        "page-initiated navigation must reserve verified replacement pixels"
    );
    assert_eq!(
        browser.state.lock().unwrap().pointer_frame_seq,
        None,
        "the displayed pre-navigation bitmap must lose pointer admission immediately"
    );
    assert_eq!(
        browser.frame_epoch.latest_navigation(),
        navigation_epoch,
        "same-document navigation must not claim a new document epoch"
    );
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "an accepted press must retain only its balancing release ownership"
    );
    assert_eq!(
        browser.captured_pointer_route(
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            authority,
            authority,
            (1.0, 1.0),
        ),
        crate::browser::CapturedPointerRoute::MotionInvalidated,
        "same-document navigation must stop motion from the pre-navigation press"
    );
    assert!(browser.accept_same_document_paint(frame_epoch, test_frame(2)));
    assert_eq!(browser.latest_frame_seq(), Some(2));
}

#[test]
fn queued_same_document_navigation_survives_a_later_screencast_epoch() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let same_document_epoch = browser.frame_epoch.advance_same_document();

    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();
    let restart_epoch = browser.frame_epoch.advance();
    browser.confirm_reconfigure(queued, restart_epoch);
    assert!(browser.store_frame_for_epoch(test_frame(2), restart_epoch));

    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#queued"
        }),
        same_document_epoch,
    )
    .expect("same-document URL");

    assert!(
        browser.needs_same_document_paint(),
        "a later screencast restart must not discard the queued navigation barrier"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "pixels captured after the restart but before navigation handling are not authoritative"
    );
}

#[test]
fn ordinary_repaint_retains_presented_pointer_authority_and_capture() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let authority = browser.latest_frame_seq().expect("initial pointer authority");
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(authority, 1.0, 1.0).expect("accepted pointer press");

    browser.store_frame(test_frame(2));

    assert_eq!(
        browser.latest_frame().map(|frame| frame.seq),
        Some(2),
        "the visual frame must advance"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        Some(2),
        "each admitted bitmap must carry its own pointer authority"
    );
    assert_eq!(browser.state.lock().unwrap().pointer_frame_floor_seq, Some(1));
    assert!(
        browser.capture_guarded_input_point(authority, 1.0, 1.0).is_some(),
        "a still-presented bitmap must remain guarded while its route geometry is current"
    );
    assert!(
        browser.capture_guarded_input_point(2, 1.0, 1.0).is_none(),
        "the newly admitted bitmap must wait for a presentation acknowledgement"
    );
    acknowledge_local_presentation(browser, 2);
    assert!(
        browser.capture_guarded_input_point(authority, 1.0, 1.0).is_none(),
        "the owner must retain only its exact latest acknowledged bitmap"
    );
    assert!(browser.capture_guarded_input_point(2, 1.0, 1.0).is_some());
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "rotating bitmap authority must preserve ownership of a balancing release"
    );
}

#[test]
fn ordinary_repaint_preserves_captured_drag_motion() {
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

    browser.store_frame(test_frame(2));
    browser
        .mouse_event_blocking(
            crate::browser::BrowserMouseDispatch {
                input_owner: crate::browser::BrowserPointerOwner::Local,
                event_type: "mouseMoved",
                x: 24.0,
                y: 32.0,
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
                x: 24.0,
                y: 32.0,
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

    let motion = motion.expect("ordinary repaint must not stall an accepted drag");
    assert_eq!(motion["params"]["type"], "mouseMoved");
    assert_ne!(motion["params"]["x"], press["params"]["x"]);
    assert_ne!(motion["params"]["y"], press["params"]["y"]);
    assert_eq!(release["params"]["type"], "mouseReleased");
    assert_eq!(release["params"]["x"], motion["params"]["x"]);
    assert_eq!(release["params"]["y"], motion["params"]["y"]);
    assert!(active_pointer_presses.is_empty());
}

#[test]
fn viewport_change_rotates_pointer_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, motion_generation, ingress_motion_generation) = browser
        .capture_guarded_input_point(1, 1.0, 1.0)
        .expect("captured press under the original viewport");
    let mut resized = test_frame(2);
    resized.css_width += 1;

    browser.store_frame(resized);

    assert_eq!(browser.latest_frame_seq(), Some(2));
    assert_eq!(browser.state.lock().unwrap().pointer_frame_floor_seq, Some(2));
    assert!(
        browser.scale_guarded_input_point(Some(1), 1.0, 1.0).is_none(),
        "a bitmap viewport change must revoke the old coordinate mapping"
    );
    assert_eq!(
        browser.captured_pointer_route(
            capture_generation,
            motion_generation,
            ingress_motion_generation,
            1,
            1,
            (1.0, 1.0),
        ),
        crate::browser::CapturedPointerRoute::MotionInvalidated,
        "captured motion must not cross an unsolicited viewport mapping change"
    );
}

#[test]
fn legacy_pointer_capture_has_a_bounded_worker_lease() {
    let (runtime, server) = runtime_accepting_mouse_dispatches(vec!["mouseReleased"]);
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
    let now = Instant::now();
    let mut press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Legacy,
        capture_generation,
        motion_generation,
        ingress_motion_generation,
        1,
        (1.0, 1.0),
        Some(1),
    );
    press.compatibility_expires_at = Some(now);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);

    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        now,
    );

    assert!(
        failures.active_pointer_presses.is_empty(),
        "expiry must clear compatibility ownership even if release dispatch later fails"
    );
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn stationary_legacy_pointer_hold_outlives_five_seconds() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let capture_generation = browser.state.lock().unwrap().pointer_capture_generation;
    let motion_generation = browser.state.lock().unwrap().pointer_motion_generation;
    let ingress_motion_generation = browser.frame_epoch.pointer_motion_generation();
    let started = Instant::now();
    let press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Legacy,
        capture_generation,
        motion_generation,
        ingress_motion_generation,
        1,
        (1.0, 1.0),
        Some(1),
    );
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);

    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        started + Duration::from_millis(5_100),
    );

    assert!(
        failures.active_pointer_presses.contains_key("left"),
        "a live stationary legacy hold must not synthesize mouseReleased after five seconds"
    );
}

#[test]
fn local_pointer_capture_has_a_bounded_worker_lease() {
    let surface = test_surface();
    let press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Local,
        u64::MAX,
        1,
        1,
        1,
        (1.0, 1.0),
        Some(1),
    );
    let expiry = press
        .compatibility_expires_at
        .expect("local capture must schedule a balancing-release deadline");
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);

    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        expiry,
    );

    assert!(
        failures.active_pointer_presses.is_empty(),
        "an orphaned local press must not remain held in Chrome indefinitely"
    );
}

#[test]
fn expired_pointer_capture_does_not_release_into_a_new_document() {
    let (runtime, server, events_rx, stop_tx) = runtime_recording_mouse_dispatches();
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
    let now = Instant::now();
    let mut press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Legacy,
        capture_generation,
        motion_generation,
        ingress_motion_generation,
        1,
        (1.0, 1.0),
        Some(1),
    );
    press.compatibility_expires_at = Some(now);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);

    browser.frame_epoch.advance_navigation();
    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Weak::new(),
        surface.id,
        &mut failures,
        now,
    );
    let released_into_new_document = events_rx.recv_timeout(Duration::from_millis(250)).is_ok();

    stop_tx.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();

    assert!(failures.active_pointer_presses.is_empty());
    assert!(
        !released_into_new_document,
        "an expired capture must be discarded after its document authority changes"
    );
}

#[test]
fn negotiated_pointer_capture_has_no_idle_lease() {
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert(
        "left".to_string(),
        crate::browser::ActivePointerPress::new(
            crate::browser::BrowserPointerOwner::Client(41),
            1,
            1,
            1,
            1,
            (1.0, 1.0),
            Some(1),
        ),
    );

    assert!(
        crate::browser::next_pointer_lifecycle_deadline(&failures).is_none(),
        "a live negotiated client must retain a stationary browser capture"
    );
}

#[test]
fn idle_browser_worker_has_no_fixed_pointer_cleanup_poll() {
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    assert!(
        crate::browser::next_pointer_lifecycle_deadline(&failures).is_none(),
        "an idle browser worker must have no synthetic polling deadline"
    );

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Legacy,
        1,
        1,
        1,
        1,
        (1.0, 1.0),
        Some(1),
    );
    press.compatibility_expires_at = Some(deadline);
    failures.active_pointer_presses.insert("left".to_string(), press);

    assert_eq!(
        crate::browser::next_pointer_lifecycle_deadline(&failures),
        Some(deadline),
        "a compatibility capture must schedule only its real expiry"
    );
}

#[test]
fn pointer_release_retry_supersedes_expired_lease_deadline() {
    let now = Instant::now();
    let retry_at = now + Duration::from_millis(250);
    let mut press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Legacy,
        1,
        1,
        1,
        1,
        (1.0, 1.0),
        Some(1),
    );
    press.compatibility_expires_at = Some(now - Duration::from_millis(1));
    press.release_retry_at = Some(retry_at);
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);

    assert_eq!(
        crate::browser::next_pointer_lifecycle_deadline(&failures),
        Some(retry_at),
        "an abandoned-release retry must replace the expired compatibility deadline"
    );
}

#[test]
fn disconnected_client_pointer_capture_is_balanced() {
    let (runtime, server) = runtime_accepting_mouse_dispatches(vec!["mouseReleased"]);
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
    let press = crate::browser::ActivePointerPress::new(
        crate::browser::BrowserPointerOwner::Client(41),
        capture_generation,
        motion_generation,
        ingress_motion_generation,
        1,
        (1.0, 1.0),
        Some(1),
    );
    let mut failures = crate::browser::BrowserWorkerErrorState::default();
    failures.active_pointer_presses.insert("left".to_string(), press);
    let mux = Mux::new("disconnected-pointer-owner-test", SurfaceOptions::default());

    crate::browser::release_abandoned_pointer_presses(
        &surface,
        &Arc::downgrade(&mux),
        surface.id,
        &mut failures,
        Instant::now(),
    );

    assert!(
        failures.active_pointer_presses.is_empty(),
        "a disconnected client must lose capture through a balancing release"
    );
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn canonicalized_same_document_url_still_requests_capture() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

    let _observed = handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/path#section"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("same-document URL");

    assert!(
        browser.needs_same_document_paint(),
        "Chrome URL canonicalization must not strand the navigation authority reservation"
    );
}

#[test]
fn verified_capture_settles_one_timestampless_reservation_after_resize() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();
    let frame_epoch = browser.frame_epoch.advance();
    browser.confirm_reconfigure(queued, frame_epoch);
    let navigation_epoch = browser.frame_epoch.latest_navigation();

    assert_eq!(browser.latest_frame(), None);
    let reservation = 41;
    assert!(browser.reserve_screencast_capture(reservation, frame_epoch, navigation_epoch));
    assert!(browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch));
    assert!(browser.accept_screencast_capture(
        reservation,
        frame_epoch,
        navigation_epoch,
        test_frame(2),
    ));
    assert_eq!(browser.latest_frame_seq(), Some(2));
    assert!(
        !browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch),
        "the verified replacement must settle its in-flight reservation"
    );
    let later = 42;
    assert!(browser.reserve_screencast_capture(later, frame_epoch, navigation_epoch));
    browser.cancel_screencast_capture(later);
}

#[test]
fn stale_screencast_capture_cannot_settle_a_newer_same_epoch_reservation() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let frame_epoch = browser.frame_epoch.current();
    let navigation_epoch = browser.frame_epoch.latest_navigation();
    let stale = 51;
    assert!(browser.reserve_screencast_capture(stale, frame_epoch, navigation_epoch));
    assert!(
        !browser.reserve_screencast_capture(99, frame_epoch, navigation_epoch),
        "concurrent timestamp-less frames must coalesce into one reservation"
    );

    browser.store_frame(test_frame(2));
    let current = 52;
    assert!(browser.reserve_screencast_capture(current, frame_epoch, navigation_epoch));

    assert!(!browser.accept_screencast_capture(
        stale,
        frame_epoch,
        navigation_epoch,
        test_frame(3),
    ));
    assert!(
        browser.may_need_screencast_capture(current, frame_epoch, navigation_epoch),
        "a stale completion must preserve the replacement reservation"
    );
    assert!(browser.accept_screencast_capture(
        current,
        frame_epoch,
        navigation_epoch,
        test_frame(3),
    ));
    assert_eq!(browser.latest_frame().map(|frame| frame.seq), Some(3));
}

#[test]
fn failed_screencast_authority_suppresses_retries_for_epoch() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        // Paces the stop check only; set after the handshake, which may
        // take longer than 20 ms under load.
        ws.get_mut().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        let mut capture_attempts = 0;
        loop {
            if stop_rx.try_recv().is_ok() {
                break;
            }
            let request = match ws.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).unwrap(),
                Ok(_) => continue,
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(_) => break,
            };
            let method = request["method"].as_str().unwrap();
            let response = match method {
                "Target.setDiscoverTargets" => {
                    json!({"id": request["id"], "result": {}})
                }
                "Page.getFrameTree" => json!({
                    "id": request["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-1",
                                "url": "https://example.test"
                            }
                        }
                    }
                }),
                "Page.createIsolatedWorld" => json!({
                    "id": request["id"],
                    "result": {"executionContextId": 41}
                }),
                "Runtime.evaluate" => json!({
                    "id": request["id"],
                    "result": {
                        "result": {"type": "number", "value": 10_000.0}
                    }
                }),
                "Page.startScreencast" => {
                    let response = json!({"id": request["id"], "result": {}});
                    write_ws_json(&mut ws, response);
                    write_ws_json(
                        &mut ws,
                        json!({
                            "method": "Page.screencastFrame",
                            "sessionId": "session-1",
                            "params": {
                                "data": "AAAA",
                                "sessionId": 9,
                                "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                            }
                        }),
                    );
                    continue;
                }
                "Page.screencastFrameAck" => continue,
                "Page.captureScreenshot" => {
                    capture_attempts += 1;
                    json!({
                        "id": request["id"],
                        "error": {
                            "code": -32000,
                        "message": "CDP call Page.captureScreenshot timed out"
                        }
                    })
                }
                method => panic!("unexpected CDP method {method}"),
            };
            write_ws_json(&mut ws, response);
        }
        capture_attempts
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
    runtime.client.seed_main_frame("session-1").unwrap();
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let frame_epoch =
        runtime.client.start_screencast_with_frame_barrier("session-1", 80, 48).unwrap();
    let request = route.recv().expect("timestamp-less frame recovery request");
    let cmux_tui_cdp::CdpEvent::ScreencastFrameCaptureRequested {
        request_id: reservation,
        navigation_epoch,
        ..
    } = request
    else {
        panic!("expected timestamp-less frame recovery request");
    };
    assert!(browser.reserve_screencast_capture(reservation, frame_epoch, navigation_epoch));

    let capture = browser.authorize_screencast_capture_blocking(
        "session-1",
        "main-frame",
        "loader-1",
        reservation,
        frame_epoch,
        navigation_epoch,
    );
    let retry_needed =
        browser.may_need_screencast_capture(reservation, frame_epoch, navigation_epoch);

    stop_tx.send(()).unwrap();
    runtime.shutdown();
    let capture_attempts = server.join().unwrap();
    assert!(capture.is_err());
    assert_eq!(
        capture_attempts, 1,
        "a timeout must stop the retry batch before monopolizing the browser worker"
    );
    assert!(
        !retry_needed,
        "an exhausted recovery epoch must not start another frame-rate capture batch"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "exhausted timestamp-less recovery must revoke stale pixel authority"
    );
    assert!(
        matches!(
            browser.status(),
            BrowserStatus::Failed(ref error) if error.contains("reload to retry")
        ),
        "exhausted timestamp-less recovery must expose a bounded reload action"
    );
}

#[test]
fn failed_document_capture_exposes_a_retryable_terminal_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        // Paces the stop check only; set after the handshake, which may
        // take longer than 20 ms under load.
        ws.get_mut().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        let mut capture_attempts = 0;
        loop {
            if stop_rx.try_recv().is_ok() {
                break;
            }
            let request = match ws.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).unwrap(),
                Ok(_) => continue,
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(_) => break,
            };
            let method = request["method"].as_str().unwrap();
            let response = match method {
                "Target.setDiscoverTargets" | "Page.stopScreencast" | "Page.startScreencast" => {
                    json!({"id": request["id"], "result": {}})
                }
                "Page.createIsolatedWorld" => json!({
                    "id": request["id"],
                    "result": {"executionContextId": 41}
                }),
                "Runtime.evaluate" => json!({
                    "id": request["id"],
                    "result": {
                        "result": {"type": "number", "value": 10_000.0}
                    }
                }),
                "Page.getFrameTree" => json!({
                    "id": request["id"],
                    "result": {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "loader-2",
                                "url": "https://next.test"
                            }
                        }
                    }
                }),
                "Page.captureScreenshot" => {
                    capture_attempts += 1;
                    json!({
                        "id": request["id"],
                        "error": {
                            "code": -32000,
                            "message": "injected transient capture failure"
                        }
                    })
                }
                method => panic!("unexpected CDP method {method}"),
            };
            write_ws_json(&mut ws, response);
        }
        capture_attempts
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
    runtime.client.seed_main_frame("session-1").unwrap();
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({
            "frame": {
                "id": "main-frame",
                "loaderId": "loader-2",
                "url": "https://next.test"
            }
        }),
        navigation_epoch,
    );

    let capture = browser.authorize_document_paint_blocking(
        "session-1",
        "main-frame",
        "loader-2",
        navigation_epoch,
    );
    assert!(capture.is_err());
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "capture failure must not restore pointer authority to the previous document"
    );
    assert!(
        matches!(
            browser.status(),
            BrowserStatus::Failed(ref error) if error.contains("reload to retry")
        ),
        "exhausted document verification must expose a bounded recovery action"
    );
    browser.store_frame_for_epoch(test_frame(2), browser.frame_epoch.current());
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "later unverified frames must not escape the terminal failure"
    );
    let next_navigation = browser.begin_targeted_navigation_frame_transition();

    stop_tx.send(()).unwrap();
    runtime.shutdown();
    let capture_attempts = server.join().unwrap();
    assert!(
        (1..=AUTHORITY_CAPTURE_ATTEMPTS).contains(&capture_attempts),
        "document verification must make progress without exceeding its retry cap"
    );
    let next_error = next_navigation.as_ref().err().map(ToString::to_string);
    assert!(
        next_navigation.is_ok(),
        "reload must be able to start a fresh navigation after terminal failure: {next_error:?}"
    );
}

#[test]
fn document_verification_gives_each_bounded_attempt_a_full_budget() {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    const ATTEMPT_BUDGET: Duration = Duration::from_secs(2);
    const TRANSIENT_FAILURE_DELAY: Duration = Duration::from_millis(950);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let seed = read_ws_json(&mut ws);
        assert_eq!(seed["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "id": seed["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test"
                        }
                    }
                }
            }),
        );

        let mut attempts = 0;
        loop {
            let request = match ws.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                Ok(_) => None,
                Err(_) => break,
            };
            let Some(request) = request else { continue };
            let method = request["method"].as_str().unwrap();
            if method == "Page.stopScreencast" {
                attempts += 1;
                if attempts < AUTHORITY_CAPTURE_ATTEMPTS {
                    thread::sleep(TRANSIENT_FAILURE_DELAY);
                    if ws
                        .send(Message::Text(
                            json!({
                                "id": request["id"],
                                "error": {"message": "injected restart failure"}
                            })
                            .to_string()
                            .into(),
                        ))
                        .is_err()
                    {
                        break;
                    }
                    continue;
                }
            }
            let result = match method {
                "Page.stopScreencast" | "Page.startScreencast" => json!({}),
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                "Page.getFrameTree" => json!({
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-2",
                            "url": "https://next.test"
                        }
                    }
                }),
                "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                method => panic!("unexpected CDP method {method}"),
            };
            if ws
                .send(Message::Text(
                    json!({"id": request["id"], "result": result}).to_string().into(),
                ))
                .is_err()
            {
                break;
            }
        }
        attempts
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
    runtime.client.seed_main_frame("session-1").unwrap();
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));
    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({
            "frame": {
                "id": "main-frame",
                "loaderId": "loader-2",
                "url": "https://next.test"
            }
        }),
        navigation_epoch,
    );
    browser.state.lock().unwrap().pending_authority_deadline =
        Some(Instant::now() + Duration::from_secs(5));

    let result = browser.authorize_document_paint_with_attempt_budget_blocking(
        "session-1",
        "main-frame",
        "loader-2",
        navigation_epoch,
        ATTEMPT_BUDGET,
    );

    runtime.shutdown();
    let attempts = server.join().unwrap();
    assert!(
        result.is_ok(),
        "two slow transient restart failures must not starve the healthy bounded attempt: {result:?}"
    );
    assert_eq!(
        attempts, AUTHORITY_CAPTURE_ATTEMPTS,
        "document verification must reach the healthy final attempt"
    );
}

#[test]
fn late_document_paint_recovers_expired_navigation_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({
            "frame": {
                "id": "main-frame",
                "loaderId": "loader-2",
                "url": "https://never-paints.test"
            }
        }),
        navigation_epoch,
    );
    browser.state.lock().unwrap().pending_authority_deadline = Some(Instant::now());
    let message = browser
        .expire_navigation_authority(Instant::now())
        .expect("expired authority must surface a bounded recovery action");
    let status = browser.status();
    let state = browser.state.lock().unwrap();
    let pending_frame_epoch = state.pending_frame_epoch;
    let pending_document_epoch = state.pending_document_epoch;
    let pending_failure_recovery = state.pending_failure_recovery;
    drop(state);

    assert!(
        matches!(status.failure(), Some(crate::browser::BrowserFailure::NewPageVerification(_))),
        "an unpainted committed document must surface a reloadable failure: {status:?}"
    );
    assert!(message.contains("reload to retry"));
    assert_eq!(pending_frame_epoch, Some(navigation_epoch));
    assert_eq!(pending_document_epoch, Some(navigation_epoch));
    assert!(
        pending_failure_recovery,
        "the expired barrier must retain authority for a late current-document paint"
    );
    assert_eq!(browser.latest_frame_seq(), None);

    assert!(
        browser.accept_document_paint(navigation_epoch, navigation_epoch, test_frame(2),),
        "a late loader-verified paint must recover the still-current document"
    );
    assert_eq!(browser.status(), BrowserStatus::Live);
    assert_eq!(browser.latest_frame_seq(), Some(2));
}
