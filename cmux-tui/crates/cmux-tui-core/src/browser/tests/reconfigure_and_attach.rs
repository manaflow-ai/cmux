//! Loaderless navigation, reconfigure and resize, attach frames, and URL normalization.

use super::*;

#[test]
fn loaderless_navigation_response_reconciles_the_unchanged_document() {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
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
        write_ws_json(&mut ws, json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}));
        for expected in [
            "Page.getFrameTree",
            "Page.stopScreencast",
            "Page.createIsolatedWorld",
            "Runtime.evaluate",
            "Page.startScreencast",
            "Page.getFrameTree",
            "Page.captureScreenshot",
            "Page.getFrameTree",
        ] {
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], expected);
            let result = match expected {
                "Page.getFrameTree" => json!({
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test#same-document"
                        }
                    }
                }),
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                _ => json!({}),
            };
            write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
        }
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));

    let result = browser.navigate_blocking("https://example.test#same-document");
    let state = browser.state.lock().unwrap();
    let pending_frame_epoch = state.pending_frame_epoch;
    let pending_navigation_epoch = state.pending_navigation_epoch;
    let pointer_frame_seq = state.pointer_frame_seq;
    drop(state);
    runtime.shutdown();
    server.join().unwrap();

    assert!(result.is_ok());
    assert_eq!(
        pending_frame_epoch, None,
        "a loaderless acknowledgment must not leave a cross-document barrier behind"
    );
    assert_eq!(pending_navigation_epoch, None);
    assert_eq!(
        pointer_frame_seq,
        Some(2),
        "the unchanged document must regain authority through freshly captured pixels"
    );
    assert_eq!(
        browser.navigation_commit_wait_timeouts.load(Ordering::Acquire),
        0,
        "loaderless same-document navigation waited out an epoch that cannot advance"
    );
}

#[test]
fn loaderless_navigation_retries_snapshot_invalidated_by_same_document_event() {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
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

        let navigate = read_ws_json(&mut ws);
        assert_eq!(navigate["method"], "Page.navigate");
        write_ws_json(&mut ws, json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}));

        let first_snapshot = read_ws_json(&mut ws);
        assert_eq!(first_snapshot["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "method": "Page.navigatedWithinDocument",
                "sessionId": "session-1",
                "params": {
                    "frameId": "main-frame",
                    "url": "https://example.test#same-document"
                }
            }),
        );
        write_ws_json(
            &mut ws,
            json!({
                "id": first_snapshot["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test#same-document"
                        }
                    }
                }
            }),
        );

        let retry = match ws.read() {
            Ok(message @ (Message::Text(_) | Message::Binary(_))) => {
                Some(serde_json::from_slice::<Value>(&message.into_data()).unwrap())
            }
            Ok(_) | Err(_) => None,
        };
        let Some(retry) = retry else { return false };
        assert_eq!(retry["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "id": retry["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test#same-document"
                        }
                    }
                }
            }),
        );

        for expected in [
            "Page.stopScreencast",
            "Page.createIsolatedWorld",
            "Runtime.evaluate",
            "Page.startScreencast",
            "Page.getFrameTree",
            "Page.captureScreenshot",
            "Page.getFrameTree",
        ] {
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], expected);
            let result = match expected {
                "Page.getFrameTree" => json!({
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test#same-document"
                        }
                    }
                }),
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                _ => json!({}),
            };
            write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
        }
        true
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

    let result = browser.navigate_blocking("https://example.test#same-document");
    let pointer_frame_seq = browser.state.lock().unwrap().pointer_frame_seq;
    runtime.shutdown();
    let retried = server.join().unwrap();

    assert!(
        result.is_ok(),
        "a normal same-document event race must retry its invalidated snapshot: {result:?}"
    );
    assert!(retried, "loaderless reconciliation did not request a fresh snapshot");
    assert_eq!(
        pointer_frame_seq,
        Some(2),
        "verified post-navigation pixels must restore pointer authority"
    );
}

#[test]
fn loaderless_navigation_snapshot_failure_settles_the_transition() {
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
        write_ws_json(&mut ws, json!({"id": navigate["id"], "result": {"frameId": "main-frame"}}));
        let snapshot = read_ws_json(&mut ws);
        assert_eq!(snapshot["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "id": snapshot["id"],
                "error": {"code": -32000, "message": "snapshot unavailable"}
            }),
        );
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.store_frame(test_frame(1));

    let result = browser.navigate_blocking("https://example.test#same-document");
    let state = browser.state.lock().unwrap();
    let pending_frame_epoch = state.pending_frame_epoch;
    let pending_navigation_epoch = state.pending_navigation_epoch;
    let pending_same_document_navigation = state.pending_same_document_navigation;
    let status = state.status.clone();
    drop(state);
    let retry = browser.begin_targeted_navigation_frame_transition();
    runtime.shutdown();
    server.join().unwrap();

    assert!(result.is_err(), "the failed snapshot must be reported");
    assert_eq!(pending_frame_epoch, None);
    assert_eq!(pending_navigation_epoch, None);
    assert!(!pending_same_document_navigation);
    assert!(
        matches!(
            status.failure(),
            Some(crate::browser::BrowserFailure::UpdatedPageVerification(_))
        ),
        "the retryable terminal failure must remain visible"
    );
    assert!(
        retry.is_ok(),
        "a transient loaderless snapshot failure must not block later navigation controls"
    );
}

#[test]
fn download_navigation_restores_current_document_pointer_authority() {
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
            json!({
                "id": navigate["id"],
                "result": {
                    "frameId": "main-frame",
                    "isDownload": true,
                    "errorText": "net::ERR_ABORTED"
                }
            }),
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
    let previous_url = browser.url();

    browser.navigate_blocking("https://example.test/download").unwrap();

    let state = browser.state.lock().unwrap();
    assert_eq!(state.pending_frame_epoch, None);
    assert_eq!(state.pending_navigation_epoch, None);
    assert_eq!(
        state.pointer_frame_seq,
        Some(1),
        "a download must leave the unchanged document interactive"
    );
    drop(state);
    assert_eq!(browser.url(), previous_url, "a download must not replace the document URL");
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn timed_out_navigation_keeps_pointer_admission_blocked() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let invalidation = browser.invalidate_pointer_frame();

    let result: anyhow::Result<()> = browser.restore_pointer_frame_on_command_error(
        invalidation,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
    );

    assert!(result.is_err());
    assert_eq!(
        browser.latest_frame_seq(),
        None,
        "an ambiguously delivered navigation must remain fail-closed"
    );
}

#[test]
fn production_navigation_timeout_keeps_pointer_admission_blocked() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let invalidation = browser.begin_navigation_frame_transition().unwrap();
    let expected_epoch = invalidation.expected_frame_epoch;

    let result: anyhow::Result<()> = browser.finish_navigation_command(
        invalidation,
        Err(anyhow::anyhow!("CDP call Page.navigate timed out")),
    );

    assert!(result.is_err());
    let state = browser.state.lock().unwrap();
    assert_eq!(
        state.pending_frame_epoch, expected_epoch,
        "an ambiguous production timeout must retain its navigation barrier"
    );
    assert_eq!(state.pending_navigation_epoch, expected_epoch);
    assert_eq!(state.pointer_frame_seq, None);
}

#[test]
fn successful_navigation_without_commit_keeps_pointer_admission_blocked() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let invalidation = browser.begin_navigation_frame_transition().unwrap();
    let expected_epoch = invalidation.expected_frame_epoch;

    let result: anyhow::Result<()> = browser.finish_navigation_command(invalidation, Ok(()));

    assert!(result.is_ok());
    let state = browser.state.lock().unwrap();
    assert_eq!(
        state.pending_frame_epoch, expected_epoch,
        "command acknowledgment must not settle navigation before its authoritative event"
    );
    assert_eq!(state.pending_navigation_epoch, expected_epoch);
    assert_eq!(
        state.pointer_frame_seq, None,
        "the pre-navigation frame must remain non-interactive while commit is unresolved"
    );
}

#[test]
fn failed_reconfigure_restores_frame_admission_and_capture() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let metrics = read_ws_json(&mut ws);
        assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
        write_ws_json(
            &mut ws,
            json!({"id": metrics["id"], "error": {"message": "injected resize failure"}}),
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
    acknowledge_local_presentation(browser, 1);
    let (_, capture_generation, _, _) =
        browser.capture_guarded_input_point(1, 1.0, 1.0).expect("live pointer capture");
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

    assert!(browser.reconfigure_reserved_blocking(queued).is_err());

    let state = browser.state.lock().unwrap();
    assert_eq!(
        state.pending_frame_epoch, None,
        "a rejected resize must release its frame-epoch reservation"
    );
    assert_eq!(state.pointer_frame_seq, Some(1));
    drop(state);
    assert!(
        browser.scale_captured_input_point(capture_generation, 1.0, 1.0).is_some(),
        "a resize failure must preserve ownership of a balancing pointer release"
    );
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn reconfigure_failure_after_metrics_commit_keeps_pointer_admission_blocked() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let frame_tree = read_ws_json(&mut ws);
        assert_eq!(frame_tree["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "id": frame_tree["id"],
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

        let metrics = read_ws_json(&mut ws);
        assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
        write_ws_json(&mut ws, json!({"id": metrics["id"], "result": {}}));

        let stop = read_ws_json(&mut ws);
        assert_eq!(stop["method"], "Page.stopScreencast");
        write_ws_json(&mut ws, json!({"id": stop["id"], "result": {}}));

        let isolated_world = read_ws_json(&mut ws);
        assert_eq!(isolated_world["method"], "Page.createIsolatedWorld");
        write_ws_json(
            &mut ws,
            json!({
                "id": isolated_world["id"],
                "result": {"executionContextId": 41}
            }),
        );

        let wall_time = read_ws_json(&mut ws);
        assert_eq!(wall_time["method"], "Runtime.evaluate");
        write_ws_json(
            &mut ws,
            json!({
                "id": wall_time["id"],
                "result": {
                    "result": {"type": "number", "value": 10_000.0}
                }
            }),
        );

        let start = read_ws_json(&mut ws);
        assert_eq!(start["method"], "Page.startScreencast");
        write_ws_json(
            &mut ws,
            json!({"id": start["id"], "error": {"message": "injected capture failure"}}),
        );
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
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

    assert!(browser.reconfigure_reserved_blocking(queued).is_err());

    let state = browser.state.lock().unwrap();
    assert!(
        state.pending_frame_epoch.is_some(),
        "a post-mutation failure must retain the frame-epoch reservation"
    );
    assert_eq!(
        state.pointer_frame_seq, None,
        "the pre-resize frame must not regain pointer authority after partial reconfiguration"
    );
    drop(state);
    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn reconfigure_survives_unavailable_screencast_clock_probe() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let frame_tree = read_ws_json(&mut ws);
        assert_eq!(frame_tree["method"], "Page.getFrameTree");
        write_ws_json(
            &mut ws,
            json!({
                "id": frame_tree["id"],
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

        let metrics = read_ws_json(&mut ws);
        assert_eq!(metrics["method"], "Emulation.setDeviceMetricsOverride");
        write_ws_json(&mut ws, json!({"id": metrics["id"], "result": {}}));

        let stop = read_ws_json(&mut ws);
        assert_eq!(stop["method"], "Page.stopScreencast");
        write_ws_json(&mut ws, json!({"id": stop["id"], "result": {}}));

        let isolated_world = read_ws_json(&mut ws);
        assert_eq!(isolated_world["method"], "Page.createIsolatedWorld");
        write_ws_json(
            &mut ws,
            json!({
                "id": isolated_world["id"],
                "error": {"message": "scripts unavailable"}
            }),
        );

        let start = read_ws_json(&mut ws);
        assert_eq!(start["method"], "Page.startScreencast");
        write_ws_json(&mut ws, json!({"id": start["id"], "result": {}}));
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
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");

    let result = browser.reconfigure_reserved_blocking(queued);

    runtime.shutdown();
    let server_result = server.join();
    assert!(
        result.is_ok(),
        "an unavailable optional clock probe must not fail browser resize: {result:?}"
    );
    server_result.unwrap();
    assert_eq!(browser.status(), BrowserStatus::Live);
    assert_eq!(browser.size(), (11, 5));
    let state = browser.state.lock().unwrap();
    assert_eq!(state.pending_frame_epoch, None);
    assert_eq!(
        state.pointer_frame_seq, None,
        "pointer input must wait for a frame verified after the resize"
    );
}

#[test]
fn frames_stalled_requires_live_surface_over_threshold() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let now = Instant::now();
    {
        let mut state = browser.state.lock().unwrap();
        state.status = BrowserStatus::Live;
        state.live_since = Some(now - Duration::from_secs(3));
        state.last_frame_at = None;
    }
    assert!(browser.frames_stalled_at(now));

    browser.store_frame(test_frame(1));
    assert!(!browser.frames_stalled_at(Instant::now()));

    browser.mark_failed("nope".to_string());
    {
        let mut state = browser.state.lock().unwrap();
        state.last_frame_at = Some(now - Duration::from_secs(3));
    }
    assert!(!browser.frames_stalled_at(now));
}

#[test]
fn same_size_resize_does_not_reset_stall_state() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let now = Instant::now();
    {
        let mut state = browser.state.lock().unwrap();
        state.status = BrowserStatus::Live;
        state.live_since = Some(now - Duration::from_secs(10));
        state.last_frame_at = Some(now - Duration::from_secs(3));
        state.stall_nudged = true;
    }
    assert!(browser.frames_stalled_at(now));

    assert!(browser.reserve_reconfigure(10, 5).is_none());
    {
        let state = browser.state.lock().unwrap();
        assert_eq!(state.last_frame_at, Some(now - Duration::from_secs(3)));
        assert!(state.stall_nudged);
    }
    assert!(browser.frames_stalled_at(now));

    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.reconfigure_reserved_blocking(queued).unwrap();
    let state = browser.state.lock().unwrap();
    assert_eq!(state.last_frame_at, None);
    assert!(!state.stall_nudged);
    assert!(!crate::browser::frames_stalled_locked(&state, Instant::now(), false));
}

#[test]
fn cell_pixel_mismatch_requires_browser_resize() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");
    assert!(!browser.resize_needed(10, 5));

    *browser.cell_pixels.lock().unwrap() = (9, 16);
    assert!(browser.resize_needed(10, 5));
}

#[test]
fn cell_pixel_change_reports_only_accepted_reconfigure() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");

    assert!(browser.set_cell_pixel_size(9, 16).unwrap());
    assert!(!browser.set_cell_pixel_size(9, 16).unwrap());
}

#[test]
fn rejected_cell_pixel_enqueue_can_retry_the_same_metrics() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
        assert!(browser.enqueue_test_command(BrowserCommand::Activate));
    }

    let (reported_tx, reported_rx) = mpsc::channel();
    assert!(
        browser
            .set_cell_pixel_size_reporting(
                9,
                16,
                Box::new(move |accepted| reported_tx.send(accepted).unwrap()),
            )
            .is_err()
    );
    assert!(reported_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_none());

    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match browser.set_cell_pixel_size(9, 16) {
            Ok(true) => break,
            Err(_) if Instant::now() < deadline => thread::yield_now(),
            result => panic!("same cell metrics were not retryable: {result:?}"),
        }
    }

    browser.kill();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after retry");
}

#[test]
fn full_command_queue_retains_pointer_release_without_blocking_producer() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release_worker, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
        assert!(browser.enqueue_test_command(BrowserCommand::Activate));
    }

    let queued_surface = surface.clone();
    let (settled_tx, settled_rx) = mpsc::channel();
    let enqueue = thread::spawn(move || {
        let result =
            queued_surface.browser_mouse_event("mouseReleased", 1.0, 1.0, Some("left"), Some(1));
        settled_tx.send(result).unwrap();
    });
    // The worker is still held, so the queue stays full: a producer that
    // blocked on it would never settle, and the bound only ends that run.
    let settled_while_full = settled_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND);
    assert_eq!(
        browser.command_order.lock().unwrap().retained_releases.len(),
        1,
        "the nonblocking enqueue must retain the release"
    );

    release_worker.send(()).unwrap();
    if settled_while_full.is_err() {
        settled_rx
            .recv_timeout(BROWSER_TEST_SAFETY_BOUND)
            .expect("release enqueue should settle after the worker drains")
            .unwrap();
    }
    enqueue.join().unwrap();
    browser.kill();
    done.recv_timeout(BROWSER_TEST_SAFETY_BOUND).expect("browser worker exited after release");

    assert!(
        settled_while_full.is_ok(),
        "retaining a release must not block the shared browser input producer"
    );
}

#[test]
fn synthesized_key_press_survives_the_final_core_queue_boundary() {
    let (runtime, server, observed, start) = runtime_recording_key_dispatches();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    browser
        .mark_live(BrowserSession {
            runtime: runtime.clone(),
            target_id: "target-1".to_string(),
            session_id: "session-1".to_string(),
        })
        .unwrap();
    let (entered, started) = mpsc::channel();
    let (release_worker, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(Duration::from_secs(1)).unwrap();
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY - 1 {
        assert!(browser.enqueue_test_command(BrowserCommand::WakeLatest));
    }

    surface.browser_key_press("j", "KeyJ", 74, 1, None).unwrap();
    start.send(()).unwrap();
    release_worker.send(()).unwrap();

    let event_types = observed.recv_timeout(BROWSER_TEST_EVENT_TIMEOUT).unwrap();
    browser.kill();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
    runtime.shutdown();
    server.join().unwrap();
    assert_eq!(
        event_types,
        vec!["keyDown", "keyUp"],
        "the final bounded queue split a synthesized key press"
    );
}

#[test]
fn resize_acceptance_is_reported_by_worker_before_execution() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(Duration::from_secs(1)).unwrap();
    let accepted = Arc::new(AtomicBool::new(false));
    let reported = accepted.clone();
    let (completion_tx, completion_rx) = mpsc::sync_channel(1);

    assert!(
        browser
            .resize_reporting_completion(
                11,
                5,
                Box::new(move |reservation_id| {
                    assert!(reservation_id.is_some());
                    reported.store(true, Ordering::Release);
                }),
                Some(completion_tx),
            )
            .unwrap()
            .is_some()
    );
    assert!(!accepted.load(Ordering::Acquire));
    assert!(matches!(
        completion_rx.recv_timeout(Duration::from_millis(10)),
        Err(mpsc::RecvTimeoutError::Timeout)
    ));
    let pending =
        browser.pending_resize_completion(11, 5).unwrap().expect("pending resize completion");
    assert!(pending.reservation > 0);
    assert!(matches!(
        pending.completion.recv_timeout(Duration::from_millis(10)),
        Err(mpsc::RecvTimeoutError::Timeout)
    ));
    for _ in 1..MAX_RECONFIGURE_WAITERS_PER_RESERVATION {
        drop(browser.pending_resize_completion(11, 5).unwrap().unwrap());
    }
    let error = browser.pending_resize_completion(11, 5).err().expect("waiter cap error");
    assert!(error.to_string().contains("too many waiters"));
    let (duplicate_tx, duplicate_rx) = mpsc::channel();
    assert!(
        browser
            .resize_reporting_acceptance(
                11,
                5,
                Box::new(move |accepted| duplicate_tx.send(accepted).unwrap()),
            )
            .unwrap()
            .is_none()
    );
    assert!(duplicate_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_none());

    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while !accepted.load(Ordering::Acquire) && Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(accepted.load(Ordering::Acquire));
    assert!(completion_rx.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
    assert!(pending.completion.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
    browser.kill();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after release");
}

#[test]
fn pending_browser_resize_suppresses_duplicates_until_reconfigure_completes() {
    let opts = SurfaceOptions::default();
    let surface =
        new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new())
            .unwrap();
    let browser = surface.as_browser().expect("browser surface");
    *browser.cell_pixels.lock().unwrap() = (9, 16);

    let queued = browser.reserve_reconfigure(10, 5).expect("changed geometry");
    assert!(!browser.resize_needed(10, 5));
    assert!(browser.reserve_reconfigure(10, 5).is_none());

    browser.reconfigure_reserved_blocking(queued).unwrap();
    assert!(!browser.resize_needed(10, 5));
    assert!(browser.reserve_reconfigure(10, 5).is_none());
}

#[test]
fn rejected_resize_releases_joined_completion_waiters() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    let pending = browser.pending_resize_completion(11, 5).unwrap().expect("pending completion");

    browser.release_reconfigure(queued);

    let error = pending
        .completion
        .recv_timeout(Duration::from_secs(1))
        .unwrap()
        .expect_err("rejected resize completion");
    assert!(error.contains("rejected before execution"));
    assert!(browser.state.lock().unwrap().reconfigure_waiters.is_empty());
}

#[test]
fn browser_resize_failure_retries_are_bounded_and_new_sizes_cancel_the_latch() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");

    for attempt in 1..=3 {
        let queued = browser.reserve_reconfigure(11, 5).expect("resize must enter pending state");
        let (recorded_attempt, retry_delay) =
            browser.fail_reconfigure(queued).expect("pending resize failure must be recorded");
        assert_eq!(recorded_attempt, attempt);
        assert_eq!(retry_delay.is_some(), attempt < 3);
        assert!(!browser.resize_needed(11, 5));
        if attempt < 3 {
            browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
                Some(Instant::now() - Duration::from_millis(1));
            assert!(browser.resize_needed(11, 5));
        }
    }

    assert!(!browser.resize_needed(11, 5));
    assert!(browser.resize_needed(12, 5));
    assert!(browser.resize_needed(11, 5));
}

#[test]
fn exhausted_reconfigure_recovery_exposes_a_retryable_terminal_failure() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));

    for attempt in 1..=3 {
        let queued = browser.reserve_reconfigure(11, 5).expect("resize must enter pending state");
        browser.begin_reconfigure_frame_transition();
        let (_, retry_delay) =
            browser.fail_reconfigure(queued).expect("resize failure must be recorded");
        if attempt < 3 {
            assert!(retry_delay.is_some());
            browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
                Some(Instant::now() - Duration::from_millis(1));
        }
    }

    assert!(
        matches!(
            browser.status(),
            BrowserStatus::Failed(ref error) if error.contains("reload to retry")
        ),
        "exhausted resize recovery must expose a bounded recovery action"
    );
    assert_eq!(
        browser.state.lock().unwrap().pending_frame_epoch,
        None,
        "terminal resize failure must settle its frame reservation"
    );
    assert!(
        browser.begin_navigation_frame_transition().is_ok(),
        "reload must be able to start after terminal resize failure"
    );
    browser.clear_error();
    assert!(
        browser.resize_needed(11, 5),
        "successful reload dispatch must rearm the failed geometry"
    );
}

#[test]
fn reconfigure_retry_reuses_unsettled_frame_epoch() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let queued = browser.reserve_reconfigure(11, 5).expect("changed geometry");
    browser.begin_reconfigure_frame_transition();
    let first_epoch = browser.state.lock().unwrap().pending_frame_epoch.unwrap();
    browser.fail_reconfigure(queued).expect("first failure recorded");
    browser.state.lock().unwrap().reconfigure_failure.as_mut().unwrap().retry_at =
        Some(Instant::now() - Duration::from_millis(1));
    let retry = browser.reserve_reconfigure(11, 5).expect("retry accepted");

    browser.begin_reconfigure_frame_transition();

    assert_eq!(
        browser.state.lock().unwrap().pending_frame_epoch,
        Some(first_epoch),
        "a retry must wait for the same single response barrier"
    );
    browser.fail_reconfigure(retry).expect("retry failure recorded");
}

#[test]
fn attach_frames_are_latest_wins_and_close_detaches() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let (_state, stream) = browser.attach_frames();

    browser.store_frame(test_frame(1));
    browser.store_frame(test_frame(2));
    browser.store_frame(test_frame(3));

    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let frame = stream.slot.lock().unwrap().frame.take().expect("latest frame");
    assert_eq!(frame.frame.seq, 3);
    assert!(stream.notify.try_recv().is_err());

    browser.store_frame(test_frame(4));
    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let frame = stream.slot.lock().unwrap().frame.take().expect("next latest frame");
    assert_eq!(frame.frame.seq, 4);

    browser.kill();
    assert!(stream.notify.recv_timeout(Duration::from_secs(1)).is_err());
}

#[test]
fn pending_attach_frame_inherits_newer_authority_state() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let (_state, stream) = browser.attach_frames();
    browser.store_frame(test_frame(1));
    {
        let mut state = browser.state.lock().unwrap();
        state.status = BrowserStatus::Failed("navigation failed".to_string());
        state.pointer_frame_seq = None;
        browser.mark_state_dirty_locked(&mut state);
    }

    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let update = std::mem::take(&mut *stream.slot.lock().unwrap());
    let frame = update.frame.expect("pending frame");
    assert_eq!(frame.status, BrowserStatus::Failed("navigation failed".to_string()));
    assert_eq!(frame.pointer_frame_seq, None);
}

#[test]
fn pending_attach_state_inherits_newer_frame_authority() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let (_state, stream) = browser.attach_frames();

    assert!(browser.set_title("queued state".to_string()));
    browser.store_frame(test_frame(2));

    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let update = std::mem::take(&mut *stream.slot.lock().unwrap());
    let state = update.state.expect("pending state");
    let frame = update.frame.expect("newer pending frame");
    assert_eq!(
        state.pointer_frame_seq, frame.pointer_frame_seq,
        "a state queued before a newer frame must inherit that frame's pointer authority"
    );
    assert_eq!(frame.frame.seq, 2);
}

#[test]
fn pointer_admission_barriers_order_pending_attach_frames() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    let (_snapshot, stream) = browser.attach_frames();

    browser.store_frame(test_frame(2));
    let invalidation = browser.invalidate_pointer_frame();
    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let invalidated = std::mem::take(&mut *stream.slot.lock().unwrap());
    assert!(invalidated.state.is_some(), "invalidation state must supersede the pending frame");
    assert!(
        invalidated.frame.is_none(),
        "a pre-invalidation frame must not be delivered after the barrier"
    );

    browser.restore_pointer_frame_after_failed_command(invalidation);
    stream.notify.recv_timeout(Duration::from_secs(1)).unwrap();
    let restored = std::mem::take(&mut *stream.slot.lock().unwrap());
    assert!(restored.state.is_some(), "rollback state must restore pointer admission");
    assert_eq!(
        restored.frame.map(|frame| frame.frame.seq),
        Some(2),
        "rollback must resend the retained frame after discarding it at the barrier"
    );
}

#[test]
fn launched_surfaces_never_report_frame_stalls() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let now = Instant::now();
    {
        let mut state = browser.state.lock().unwrap();
        state.status = BrowserStatus::Live;
        state.source = Some(BrowserSource::Launched);
        state.live_since = Some(now - Duration::from_secs(3));
        state.last_frame_at = None;
    }
    assert!(!browser.frames_stalled_at(now));

    {
        let mut state = browser.state.lock().unwrap();
        state.source = Some(BrowserSource::External);
    }
    assert!(browser.frames_stalled_at(now));
}

#[test]
fn worker_double_timeout_marks_browser_not_responding_without_waiting() {
    let surface = test_surface();
    let mut failures = crate::browser::BrowserWorkerErrorState::default();

    crate::browser::record_browser_worker_result(
        &surface,
        &Weak::new(),
        surface.id,
        true,
        Err(anyhow::anyhow!("CDP call Input.dispatchMouseEvent timed out")),
        &mut failures,
    );
    assert_ne!(
        surface.as_browser().unwrap().status(),
        BrowserStatus::Failed(crate::browser::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
    );

    crate::browser::record_browser_worker_result(
        &surface,
        &Weak::new(),
        surface.id,
        true,
        Err(anyhow::anyhow!("CDP call Input.dispatchMouseEvent timed out")),
        &mut failures,
    );
    assert_eq!(
        surface.as_browser().unwrap().status(),
        BrowserStatus::Failed(crate::browser::BROWSER_NOT_RESPONDING_MESSAGE.to_string())
    );
}

#[test]
fn normalizes_browser_urls() {
    assert_eq!(normalize_url("example.com"), "https://example.com");
    assert_eq!(normalize_url("example.com:8080"), "https://example.com:8080");
    assert_eq!(normalize_url(" https://example.com "), "https://example.com");
    assert_eq!(normalize_url("https://example.com/a"), "https://example.com/a");
    assert_eq!(normalize_url("about:blank"), "about:blank");
    assert_eq!(normalize_url("file:///tmp/test.html"), "file:///tmp/test.html");
    assert_eq!(normalize_url("mailto:test@example.com"), "mailto:test@example.com");
    assert_eq!(normalize_url("localhost:3000/path"), "http://localhost:3000/path");
    assert_eq!(normalize_url("127.0.0.1/test"), "http://127.0.0.1/test");
    assert_eq!(normalize_url("[::1]:8080"), "http://[::1]:8080");
    assert_eq!(normalize_url("myhost:8080"), "https://www.google.com/search?q=myhost%3A8080");
    assert_eq!(normalize_url("plainwords"), "https://www.google.com/search?q=plainwords");
    assert_eq!(normalize_url("two words?"), "https://www.google.com/search?q=two%20words%3F");
}

#[test]
fn normalization_is_idempotent() {
    for input in ["localhost:3000", "example.com", "two words?", "mailto:x@y.z"] {
        let once = normalize_url(input);
        assert_eq!(normalize_url(&once), once, "not idempotent for {input:?}");
    }
}
