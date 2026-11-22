//! Document paint authority: screencast generations, lifecycle paint, same-document capture.

use super::*;

#[test]
fn post_commit_screencast_frame_does_not_claim_document_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));

    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({
            "frame": {
                "id": "main-frame",
                "loaderId": "next-loader",
                "url": "https://next.test"
            }
        }),
        navigation_epoch,
    );
    browser.store_frame_for_epoch(test_frame(2), navigation_epoch);

    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "a streamed frame without committed-loader paint proof must remain non-interactive"
    );
}

#[test]
fn old_screencast_generation_cannot_overwrite_authorized_pixels() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let navigation_epoch = browser.frame_epoch.advance_navigation();
    handle_frame_navigated(
        browser,
        json!({
            "frame": {
                "id": "main-frame",
                "loaderId": "next-loader",
                "url": "https://next.test"
            }
        }),
        navigation_epoch,
    );
    let capture_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_document_paint(navigation_epoch, capture_epoch, test_frame(2)));

    browser.store_frame_for_epoch(test_frame(3), navigation_epoch);
    assert_eq!(
        browser.latest_frame_seq(),
        Some(2),
        "a delayed frame from the stopped stream must not replace authorized pixels"
    );
    browser.store_frame_for_epoch(test_frame(3), capture_epoch);
    assert_eq!(
        browser.latest_frame_seq(),
        Some(3),
        "the restarted stream must bind authority to its newly admitted bitmap"
    );
    assert_eq!(
        browser.latest_frame().map(|frame| frame.seq),
        Some(3),
        "the restarted stream may advance the visual frame"
    );
}

#[test]
fn lifecycle_paint_authorizes_loader_bracketed_capture_end_to_end() {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (start_tx, start_rx) = mpsc::channel();
    let (next_frame_tx, next_frame_rx) = mpsc::channel();
    let (recaptured_tx, recaptured_rx) = mpsc::channel();
    let (race_start_tx, race_start_rx) = mpsc::channel();
    let (stale_capture_started_tx, stale_capture_started_rx) = mpsc::channel();
    let (send_replacement_tx, send_replacement_rx) = mpsc::channel();
    let (replacement_sent_tx, replacement_sent_rx) = mpsc::channel();
    let (release_stale_tx, release_stale_rx) = mpsc::channel();
    let (replacement_captured_tx, replacement_captured_rx) = mpsc::channel();
    let (final_frame_tx, final_frame_rx) = mpsc::channel();
    let (final_capture_tx, final_capture_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        start_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "main-frame",
                        "loaderId": "loader-2",
                        "url": "https://next.test"
                    }
                }
            }),
        );
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
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.lifecycleEvent",
                "sessionId": "session-1",
                "params": {
                    "frameId": "main-frame",
                    "loaderId": "loader-2",
                    "name": "firstPaint",
                    "timestamp": 1.0
                }
            }),
        );

        let mut authority_calls = 0;
        while authority_calls < 7 {
            let request = read_ws_json(&mut ws);
            match request["method"].as_str().unwrap() {
                "Page.screencastFrameAck" => {}
                "Page.stopScreencast" | "Page.startScreencast" => {
                    authority_calls += 1;
                    write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
                }
                "Page.getFrameTree" => {
                    authority_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
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
                    );
                }
                "Page.createIsolatedWorld" => {
                    authority_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {"executionContextId": 41}
                        }),
                    );
                }
                "Runtime.evaluate" => {
                    authority_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {
                                "result": {"type": "number", "value": 10_000.0}
                            }
                        }),
                    );
                }
                "Page.captureScreenshot" => {
                    authority_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {"data": ONE_PIXEL_PNG}
                        }),
                    );
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
        next_frame_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "c2Vjb25k",
                    "sessionId": 10,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                }
            }),
        );
        let mut recapture_calls = 0;
        while recapture_calls < 3 {
            let request = read_ws_json(&mut ws);
            match request["method"].as_str().unwrap() {
                "Page.screencastFrameAck" => {}
                "Page.getFrameTree" => {
                    recapture_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
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
                    );
                }
                "Page.captureScreenshot" => {
                    recapture_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {"data": ONE_PIXEL_PNG}
                        }),
                    );
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
        recaptured_tx.send(()).unwrap();
        race_start_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "cHJlcA==",
                    "sessionId": 11,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 48,
                        "timestamp": 10_001.0
                    }
                }
            }),
        );
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "c3RhbGU=",
                    "sessionId": 12,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                }
            }),
        );
        loop {
            let request = read_ws_json(&mut ws);
            match request["method"].as_str().unwrap() {
                "Page.screencastFrameAck" => {}
                "Page.getFrameTree" => {
                    write_ws_json(
                        &mut ws,
                        json!({
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
                    );
                }
                "Page.captureScreenshot" => {
                    stale_capture_started_tx.send(()).unwrap();
                    send_replacement_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                    write_ws_json(
                        &mut ws,
                        json!({
                            "method": "Page.screencastFrame",
                            "sessionId": "session-1",
                            "params": {
                                "data": "dGltZWQ=",
                                "sessionId": 13,
                                "metadata": {
                                    "deviceWidth": 80,
                                    "deviceHeight": 48,
                                    "timestamp": 10_002.0
                                }
                            }
                        }),
                    );
                    write_ws_json(
                        &mut ws,
                        json!({
                            "method": "Page.screencastFrame",
                            "sessionId": "session-1",
                            "params": {
                                "data": "bmV3ZXI=",
                                "sessionId": 14,
                                "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                            }
                        }),
                    );
                    replacement_sent_tx.send(()).unwrap();
                    release_stale_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "error": {
                                "code": -32000,
                                "message": "CDP call Page.captureScreenshot timed out"
                            }
                        }),
                    );
                    break;
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
        let mut replacement_calls = 0;
        while replacement_calls < 3 {
            let request = read_ws_json(&mut ws);
            match request["method"].as_str().unwrap() {
                "Page.screencastFrameAck" => {}
                "Page.getFrameTree" => {
                    replacement_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
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
                    );
                }
                "Page.captureScreenshot" => {
                    replacement_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {"data": ONE_PIXEL_PNG}
                        }),
                    );
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
        replacement_captured_tx.send(()).unwrap();
        final_frame_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "ZmluYWw=",
                    "sessionId": 15,
                    "metadata": {"deviceWidth": 80, "deviceHeight": 48}
                }
            }),
        );
        ws.get_mut().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut final_calls = 0;
        while final_calls < 3 && Instant::now() < deadline {
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
            match request["method"].as_str().unwrap() {
                "Page.screencastFrameAck" => {}
                "Page.getFrameTree" => {
                    final_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
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
                    );
                }
                "Page.captureScreenshot" => {
                    final_calls += 1;
                    write_ws_json(
                        &mut ws,
                        json!({
                            "id": request["id"],
                            "result": {"data": ONE_PIXEL_PNG}
                        }),
                    );
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
        final_capture_tx.send(final_calls == 3).unwrap();
        stop_rx.recv_timeout(Duration::from_secs(1)).unwrap();
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

    start_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline && browser.latest_frame_seq() != Some(2) {
        thread::yield_now();
    }
    assert_eq!(browser.latest_frame_seq(), Some(2));
    assert_eq!(
        browser.latest_frame().map(|frame| frame.data_b64.clone()),
        Some(ONE_PIXEL_PNG.to_string())
    );

    next_frame_tx.send(()).unwrap();
    recaptured_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline && browser.latest_frame().is_none_or(|frame| frame.seq != 3) {
        thread::yield_now();
    }
    assert_eq!(
        browser.latest_frame().map(|frame| frame.seq),
        Some(3),
        "the timestamp-less stream frame must not be admitted before its replacement"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        Some(3),
        "the loader-verified replacement must rotate pointer authority with its bitmap"
    );
    assert_eq!(
        browser.latest_frame().map(|frame| frame.data_b64.clone()),
        Some(ONE_PIXEL_PNG.to_string()),
        "later timestamp-less pixels must update through a loader-verified capture"
    );

    race_start_tx.send(()).unwrap();
    stale_capture_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let stale_reservation = browser
        .state
        .lock()
        .unwrap()
        .pending_screencast_capture
        .expect("first timestamp-less capture reservation")
        .id;
    send_replacement_tx.send(()).unwrap();
    replacement_sent_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let replacement_reservation = loop {
        let state = browser.state.lock().unwrap();
        if state.latest_frame.as_ref().is_some_and(|frame| frame.data_b64 == "dGltZWQ=")
            && let Some(reservation) = state.pending_screencast_capture
            && reservation.id != stale_reservation
        {
            break reservation.id;
        }
        drop(state);
        assert!(Instant::now() < deadline, "replacement reservation was not established");
        thread::yield_now();
    };
    release_stale_tx.send(()).unwrap();
    replacement_captured_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let state = browser.state.lock().unwrap();
        if state.latest_frame.as_ref().is_some_and(|frame| frame.seq == 6)
            && state.pending_screencast_capture.is_none()
        {
            break;
        }
        drop(state);
        assert!(
            Instant::now() < deadline,
            "replacement capture {replacement_reservation} was not accepted"
        );
        thread::yield_now();
    }
    // Recovery is intentionally rate-limited at CDP ingress. Wait past
    // that bound without emitting a timestamped frame, so this still
    // proves the stale failure did not suppress the later request.
    thread::sleep(Duration::from_millis(1_100));
    final_frame_tx.send(()).unwrap();
    let final_capture_started = final_capture_rx.recv_timeout(Duration::from_secs(2)).unwrap();

    stop_tx.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();
    assert!(
        final_capture_started,
        "a stale capture failure must not suppress later same-epoch recovery"
    );
}

#[test]
fn same_document_capture_reopens_authority_without_a_new_navigation_epoch() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let navigation_epoch = browser.frame_epoch.latest_navigation();
    let url = "https://example.test/#next";
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");

    let _observed = handle_same_document_navigated(
        browser,
        &json!({"frameId": "main-frame", "url": url}),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("same-document URL");
    assert!(browser.needs_same_document_paint());
    let capture_epoch = browser.frame_epoch.advance();
    assert!(browser.accept_same_document_paint(capture_epoch, test_frame(2)));

    let state = browser.state.lock().unwrap();
    assert_eq!(browser.frame_epoch.latest_navigation(), navigation_epoch);
    assert_eq!(state.pending_frame_epoch, None);
    assert_eq!(state.pending_navigation_epoch, None);
    assert_eq!(state.pointer_frame_seq, Some(2));
}

#[test]
fn failed_same_document_capture_exposes_a_retryable_terminal_failure() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#next"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("same-document URL");
    let failed_capture_epoch = browser.frame_epoch.advance();

    browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));

    assert!(
        matches!(
            browser.status(),
            BrowserStatus::Failed(ref error) if error.contains("reload to retry")
        ),
        "exhausted same-document verification must expose a bounded recovery action"
    );
    browser.store_frame_for_epoch(test_frame(2), failed_capture_epoch);
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "later unverified frames must not escape the terminal failure"
    );
    assert!(
        browser.begin_targeted_navigation_frame_transition().is_ok(),
        "reload must be able to start a fresh navigation after terminal failure"
    );
}

#[test]
fn unrelated_same_document_event_cannot_clear_verification_failure() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#failed"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("same-document URL");
    browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));

    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#unrelated"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("later same-document URL");
    browser.store_frame_for_epoch(test_frame(2), browser.frame_epoch.current());

    assert!(
        matches!(
            browser.status().failure(),
            Some(crate::browser::BrowserFailure::UpdatedPageVerification(_))
        ),
        "an unrelated lifecycle event must preserve the terminal verification failure"
    );
    assert!(
        browser.latest_frame().is_none(),
        "unverified pixels must remain hidden after the unrelated event"
    );
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "unverified pixels must not recreate pointer authority"
    );

    browser.begin_targeted_navigation_frame_transition().expect("explicit recovery");
    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#recovery"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("recovery URL");
    assert!(
        matches!(
            browser.status().failure(),
            Some(crate::browser::BrowserFailure::UpdatedPageVerification(_))
        ),
        "the recovery command acknowledgment must not clear failure before pixel verification"
    );
    assert!(browser.accept_same_document_paint(browser.frame_epoch.current(), test_frame(3)));
    assert_eq!(browser.status(), BrowserStatus::Live);
    assert!(
        browser.latest_frame_seq().is_some(),
        "the matching verified recovery paint must reopen pointer authority"
    );
}

#[test]
fn explicit_retry_can_verify_pixels_while_surface_is_failed() {
    let (runtime, server, _dispatched, stop) = runtime_recording_mouse_dispatches();
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
    browser.begin_targeted_navigation_frame_transition().expect("failed navigation");
    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#failed"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("failed URL");
    browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));
    browser.begin_targeted_navigation_frame_transition().expect("explicit retry");
    handle_same_document_navigated(
        browser,
        &json!({
            "frameId": "main-frame",
            "url": "https://example.test/#recovery"
        }),
        browser.frame_epoch.advance_same_document(),
    )
    .expect("recovery URL");
    assert!(
        browser.require_live_session().is_err(),
        "ordinary browser input must remain blocked until retry pixels are verified"
    );

    let recovery =
        browser.authorize_same_document_paint_blocking("session-1", "main-frame", "loader-1");

    stop.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();

    assert!(
        recovery.is_ok(),
        "the explicit retry must be allowed to capture verification pixels: {recovery:?}"
    );
    assert_eq!(browser.status(), BrowserStatus::Live);
    assert!(
        browser.latest_frame_seq().is_some(),
        "verified retry pixels must restore pointer authority"
    );
}

#[test]
fn rejected_streamed_frames_do_not_emit_surface_output() {
    let options = SurfaceOptions::default();
    let mux = Mux::new("rejected-browser-frame-redraw-test", options.clone());
    let surface = new_surface(
        1,
        "https://example.test".into(),
        (10, 5),
        (8, 16),
        &options,
        Arc::downgrade(&mux),
    )
    .expect("browser surface creation");
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    browser.begin_targeted_navigation_frame_transition().expect("same-document reservation");
    let rejected_epoch = browser.frame_epoch.advance();
    browser.fail_same_document_authority(&anyhow::anyhow!("injected capture failure"));
    assert!(browser.take_dirty(), "terminal failure must request its own redraw");

    let events = mux.subscribe();
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    start_surface_thread(
        surface.clone(),
        route.clone(),
        Arc::downgrade(&mux),
        Weak::new(),
        "session-test".to_string(),
    )
    .unwrap();
    assert!(!route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(
        cmux_tui_cdp::ScreencastFrame {
            session_id: "session-test".to_string(),
            data_b64: "rejected-after-failure".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            ack_id: 2,
            frame_epoch: rejected_epoch,
        },
    )));

    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline
        && browser
            .state
            .lock()
            .unwrap()
            .pending_frame
            .as_ref()
            .is_none_or(|(_, frame)| frame.data_b64 != "rejected-after-failure")
    {
        thread::yield_now();
    }
    assert!(
        browser
            .state
            .lock()
            .unwrap()
            .pending_frame
            .as_ref()
            .is_some_and(|(_, frame)| frame.data_b64 == "rejected-after-failure"),
        "surface thread did not process the rejected frame"
    );
    assert!(
        events.recv_timeout(Duration::from_millis(100)).is_err(),
        "a frame rejected by the epoch gate must not request a TUI redraw"
    );
    assert!(!browser.take_dirty(), "a rejected frame must not mark the surface dirty");

    route.close("test cleanup".to_string());
}
