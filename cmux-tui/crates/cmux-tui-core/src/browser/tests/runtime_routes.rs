//! Runtime setup, CDP routing, surface routes, and the worker command queue.

use super::*;

#[test]
fn confirmed_provider_close_detaches_without_closing_the_target() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (detached_tx, detached_rx) = mpsc::channel();
    let server = thread::Builder::new()
        .name("browser-provider-close-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id":discover["id"],"result":{}}));

            let detached = read_ws_json(&mut ws);
            detached_tx.send(detached.clone()).unwrap();
            write_ws_json(&mut ws, json!({"id":detached["id"],"result":{}}));
        })
        .unwrap();
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::Provider,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let _route = runtime.register("provider-target", "provider-session");
    browser
        .mark_live(BrowserSession {
            runtime: runtime.clone(),
            target_id: "provider-target".to_string(),
            session_id: "provider-session".to_string(),
        })
        .unwrap();

    browser.close_confirmed().unwrap();
    runtime.client.flush_outbound(Duration::from_secs(1)).unwrap();
    let detached = detached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(detached["method"], "Target.detachFromTarget");
    assert_eq!(detached["params"]["sessionId"], "provider-session");
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after close");

    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn frames_do_not_clear_failed_status() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));
    assert_eq!(browser.status(), BrowserStatus::Live);

    // Chrome keeps streaming frames of the previous page after a
    // failed navigation; they must not mask the failure: the status
    // stays Failed and latest_frame() hides the stale frame so the
    // pane shows the failure text.
    browser.mark_failed("nope".into());
    browser.store_frame(test_frame(2));
    assert_eq!(browser.status(), BrowserStatus::Failed("nope".into()));
    assert_eq!(browser.latest_frame(), None);
    assert_eq!(browser.latest_frame_metadata(), None);

    // Clearing the error restores the retained frame.
    browser.clear_error();
    assert_eq!(browser.status(), BrowserStatus::Live);
    assert_eq!(browser.latest_frame().map(|frame| frame.seq), Some(2));
    assert_eq!(browser.latest_frame_metadata(), Some((2, 80, 48, None)));
}

#[test]
fn arbitrary_failure_text_cannot_grant_navigation_recovery() {
    let (runtime, server) = runtime_accepting_mouse_dispatches(vec![]);
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    browser.mark_failed(format!(
        "{}untrusted transport text{}",
        crate::browser::BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX,
        crate::browser::BROWSER_VERIFICATION_FAILED_SUFFIX
    ));

    let recovery = browser.require_navigation_session();

    runtime.shutdown();
    server.join().unwrap();
    assert!(
        recovery.is_err(),
        "display text that resembles a retryable failure must not grant recovery authority"
    );
}

#[test]
fn repeated_latest_frame_reads_share_the_encoded_payload() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    browser.store_frame(test_frame(1));

    let first = browser.latest_frame().expect("first frame");
    let second = browser.latest_frame().expect("second frame");

    assert_eq!(
        first.data_b64.as_ptr(),
        second.data_b64.as_ptr(),
        "reading the current frame must not copy its encoded image payload"
    );
}

#[test]
fn capture_scale_respects_budget_and_fixed_override() {
    let opts = BrowserCaptureOptions { max_capture_megapixels: 2.0, fixed_capture_scale: None };
    let scale = capture_scale_for(4760, 2548, opts);
    assert!(scale < 1.0);
    assert_eq!(scaled_pixels(4760, 2548, scale), (1933, 1035));

    let small = capture_scale_for(800, 600, opts);
    assert_eq!(small, 1.0);
    assert_eq!(scaled_pixels(800, 600, small), (800, 600));

    let fixed =
        BrowserCaptureOptions { max_capture_megapixels: 2.0, fixed_capture_scale: Some(0.5) };
    assert_eq!(capture_scale_for(800, 600, fixed), 0.5);
    assert_eq!(scaled_pixels(800, 600, 0.5), (400, 300));

    let configured = BrowserCaptureOptions::from_options(&SurfaceOptions {
        browser_max_capture_megapixels: 20.0,
        browser_capture_scale: Some(1.0),
        ..SurfaceOptions::default()
    });
    let capped_scale = capture_scale_for(4760, 2548, configured);
    let capped = scaled_pixels(4760, 2548, capped_scale);
    assert!(u64::from(capped.0) * u64::from(capped.1) <= 2_010_000);
}

#[test]
fn launched_runtime_cleans_headless_user_agent_once_and_replays_per_surface() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();

    let server = thread::Builder::new()
        .name("browser-stealth-ua-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let mut start_count = 0;
            loop {
                let request = read_ws_json(&mut ws);
                let id = request["id"].clone();
                let method = request["method"].as_str().unwrap().to_string();
                seen_tx.send(request.clone()).unwrap();
                match method.as_str() {
                    "Target.setDiscoverTargets" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                    }
                    "Browser.getVersion" => {
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": id,
                                "result": {
                                    "userAgent": "Mozilla/5.0 HeadlessChrome/136.0 HeadlessChrome/136.0 Safari/537.36"
                                }
                            }),
                        );
                    }
                    "Emulation.setUserAgentOverride" => {
                        assert_eq!(
                            request["params"]["userAgent"],
                            "Mozilla/5.0 Chrome/136.0 Chrome/136.0 Safari/537.36"
                        );
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                    }
                    "Page.getFrameTree" => {
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": id,
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-1",
                                            "url": "about:blank"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.enable"
                    | "Page.setLifecycleEventsEnabled"
                    | "Emulation.setDeviceMetricsOverride"
                    | "Page.startScreencast" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        if method == "Page.startScreencast" {
                            start_count += 1;
                            if start_count == 2 {
                                break;
                            }
                        }
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
        })
        .unwrap();

    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::Launched,
    )
    .unwrap();
    let opts = SurfaceOptions::default();
    let first =
        new_surface(11, "https://one.test".into(), (10, 5), (8, 16), &opts, Weak::new()).unwrap();
    runtime.setup_attached_surface(&first, "target-1", "session-1", "https://one.test").unwrap();
    let second =
        new_surface(12, "https://two.test".into(), (10, 5), (8, 16), &opts, Weak::new()).unwrap();
    runtime.setup_attached_surface(&second, "target-2", "session-2", "https://two.test").unwrap();

    server.join().unwrap();
    let methods = seen_rx
        .try_iter()
        .map(|value| value["method"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(methods.iter().filter(|method| method.as_str() == "Browser.getVersion").count(), 1);
    assert_eq!(
        methods.iter().filter(|method| method.as_str() == "Emulation.setUserAgentOverride").count(),
        2
    );
    runtime.shutdown();
}

#[test]
fn launched_runtime_continues_when_browser_version_fails() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();

    let server = thread::Builder::new()
        .name("browser-stealth-version-failure-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            loop {
                let request = read_ws_json(&mut ws);
                let id = request["id"].clone();
                let method = request["method"].as_str().unwrap().to_string();
                seen_tx.send(request.clone()).unwrap();
                match method.as_str() {
                    "Target.setDiscoverTargets" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                    }
                    "Browser.getVersion" => {
                        write_ws_json(
                            &mut ws,
                            json!({"id": id, "error": {"code": -32000, "message": "unavailable"}}),
                        );
                    }
                    "Page.getFrameTree" => {
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": id,
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-1",
                                            "url": "about:blank"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.enable"
                    | "Page.setLifecycleEventsEnabled"
                    | "Emulation.setDeviceMetricsOverride"
                    | "Page.startScreencast" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        if method == "Page.startScreencast" {
                            break;
                        }
                    }
                    "Emulation.setUserAgentOverride" => {
                        panic!("user agent override should be skipped after getVersion failure")
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
        })
        .unwrap();

    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::Launched,
    )
    .unwrap();
    let surface = test_surface();
    runtime
        .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
        .unwrap();

    server.join().unwrap();
    let methods = seen_rx
        .try_iter()
        .map(|value| value["method"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert!(methods.iter().any(|method| method == "Browser.getVersion"));
    assert!(!methods.iter().any(|method| method == "Emulation.setUserAgentOverride"));
    runtime.shutdown();
}

#[test]
fn discovery_events_are_drained_before_the_discovery_response() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::Builder::new()
        .name("browser-discovery-backpressure-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], "Target.setDiscoverTargets");
            for index in 0..=cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
                write_ws_json(
                    &mut ws,
                    json!({
                        "method": "Target.targetCreated",
                        "params": {
                            "targetInfo": {
                                "targetId": format!("target-{index}"),
                                "type": "page",
                                "title": "",
                                "url": "about:blank"
                            }
                        }
                    }),
                );
            }
            write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
        })
        .unwrap();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let connect = thread::spawn(move || {
        done_tx
            .send(crate::browser::BrowserRuntime::connect_to_endpoint(
                &format!("ws://{addr}/devtools/browser/fake"),
                BrowserSource::External,
            ))
            .unwrap();
    });

    let runtime = done_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("discovery events blocked the response")
        .unwrap();
    runtime.shutdown();
    connect.join().unwrap();
    server.join().unwrap();
}

#[test]
fn stalled_surface_route_does_not_block_shared_cdp_reader() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (flood_tx, flood_rx) = mpsc::channel();
    let (sent_tx, sent_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::Builder::new()
        .name("browser-surface-backpressure-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let request = read_ws_json(&mut ws);
            assert_eq!(request["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            flood_rx.recv().unwrap();
            for index in 0..=(cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY + 1) {
                write_ws_json(
                    &mut ws,
                    json!({
                        "method": "Target.targetInfoChanged",
                        "params": {
                            "targetInfo": {
                                "targetId": "target-stalled",
                                "type": "page",
                                "title": format!("title-{index}"),
                                "url": "https://example.test"
                            }
                        }
                    }),
                );
            }
            sent_tx.send(()).unwrap();
            // The reply follows the whole flood on the socket, so the
            // client reads it only if the stalled route did not block
            // the shared reader.
            let version = read_ws_json(&mut ws);
            assert_eq!(version["method"], "Browser.getVersion");
            write_ws_json(
                &mut ws,
                json!({
                    "id": version["id"],
                    "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
                }),
            );
            let _ = stop_rx.recv();
        })
        .unwrap();

    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let _stalled_route = runtime.register("target-stalled", "session-stalled");
    flood_tx.send(()).unwrap();
    sent_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();

    let client = runtime.client.clone();
    let (version_tx, version_rx) = mpsc::channel();
    let version_call = thread::spawn(move || {
        version_tx.send(client.browser_version()).unwrap();
    });
    // A blocked reader never delivers the reply, so this bound only ends
    // a failing run; a passing one does not depend on timing.
    let version = version_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND);
    stop_tx.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();
    version_call.join().unwrap();
    assert!(version.is_ok(), "stalled surface blocked the shared CDP reader: {version:?}");
}

#[test]
fn title_event_burst_keeps_surface_route_live_and_delivers_latest() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    let event = |index| {
        cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo {
            session_id: Some("session-1".to_string()),
            target_id: "target-1".to_string(),
            title: format!("title-{index}"),
            url: "https://example.test".to_string(),
        })
    };

    assert!(!route.deliver(event(0)));
    for index in 1..=cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
        assert!(!route.deliver(event(index)));
    }
    assert!(!route.is_closed());

    let mut latest = String::new();
    while let Some(received) = route.try_recv() {
        if let cmux_tui_cdp::CdpEvent::TargetInfoChanged(info) = received {
            latest = info.title;
            if latest == format!("title-{}", cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY) {
                break;
            }
        }
    }
    assert_eq!(latest, format!("title-{}", cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY));
}

#[test]
fn coalesced_surface_state_keeps_chronological_order() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    let target = |title: &str| {
        cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo {
            session_id: Some("session-1".to_string()),
            target_id: "target-1".to_string(),
            title: title.to_string(),
            url: "https://example.test".to_string(),
        })
    };
    assert!(!route.deliver(target("old")));
    assert!(!route.deliver(cmux_tui_cdp::CdpEvent::FrameNavigated {
        params: Value::Null,
        session_id: "session-1".to_string(),
        frame_epoch: 1,
    }));
    assert!(!route.deliver(target("new")));

    assert!(matches!(route.try_recv().unwrap(), cmux_tui_cdp::CdpEvent::FrameNavigated { .. }));
    assert!(matches!(
        route.try_recv().unwrap(),
        cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo { title, .. })
            if title == "new"
    ));
}

#[test]
fn surface_route_retains_only_the_latest_screencast_frame() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    let frame = |index| {
        cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
            session_id: "session-1".to_string(),
            data_b64: format!("frame-{index}"),
            css_width: 80,
            css_height: 24,
            image_width: 80,
            image_height: 24,
            ack_id: index,
            frame_epoch: 0,
        })
    };

    for index in 1..=3 {
        assert!(!route.deliver(frame(index)));
    }
    let received = route.try_recv().unwrap();
    let cmux_tui_cdp::CdpEvent::ScreencastFrame(frame) = received else {
        panic!("expected a screencast frame");
    };
    assert_eq!(frame.ack_id, 3);
    assert!(route.try_recv().is_none(), "stale frames remained queued");
}

#[test]
fn critical_overflow_does_not_silently_evict_latest_frame() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    let frame = cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
        session_id: "session-1".to_string(),
        data_b64: "frame-latest".to_string(),
        css_width: 80,
        css_height: 24,
        image_width: 80,
        image_height: 24,
        ack_id: 1,
        frame_epoch: 0,
    });
    assert!(!route.deliver(frame));
    for index in 1..cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
            method: format!("Test.event{index}"),
            params: Value::Null,
            session_id: Some("session-1".to_string()),
        }));
    }

    let overflowed = route.deliver(cmux_tui_cdp::CdpEvent::Other {
        method: "Test.overflow".to_string(),
        params: Value::Null,
        session_id: Some("session-1".to_string()),
    });
    assert!(overflowed, "critical overflow silently evicted authoritative state");
    assert!(route.is_closed());
}

#[test]
fn final_frame_overflow_fails_route_instead_of_going_stale() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    for index in 0..cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY {
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
            method: format!("Test.event{index}"),
            params: Value::Null,
            session_id: Some("session-1".to_string()),
        }));
    }
    let overflowed =
        route.deliver(cmux_tui_cdp::CdpEvent::ScreencastFrame(cmux_tui_cdp::ScreencastFrame {
            session_id: "session-1".to_string(),
            data_b64: "frame-final".to_string(),
            css_width: 80,
            css_height: 24,
            image_width: 80,
            image_height: 24,
            ack_id: 1,
            frame_epoch: 0,
        }));

    assert!(overflowed);
    assert!(route.is_closed());
}

#[test]
fn oversized_surface_event_fails_the_route() {
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    let overflowed = route.deliver(cmux_tui_cdp::CdpEvent::Other {
        method: "Test.large".to_string(),
        params: json!({
            "payload": "x".repeat(cmux_tui_cdp::CDP_EVENT_QUEUE_MAX_BYTES),
        }),
        session_id: Some("session-1".to_string()),
    });

    assert!(overflowed);
    assert!(route.is_closed());
}

#[test]
fn unregister_closes_and_wakes_surface_route() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let request = read_ws_json(&mut ws);
        assert_eq!(request["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
        let _ = stop_rx.recv();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let route = runtime.register("target-1", "session-1");
    let cleanup_route = route.clone();
    let (done_tx, done_rx) = mpsc::channel();
    let waiter = thread::spawn(move || {
        let first = route.recv();
        let second = route.recv();
        done_tx.send((first, second)).unwrap();
    });

    runtime.unregister("target-1", "session-1");
    let events = done_rx.recv_timeout(Duration::from_millis(200));
    stop_tx.send(()).unwrap();
    runtime.shutdown();
    server.join().unwrap();
    if events.is_err() {
        cleanup_route.close("test cleanup".to_string());
    }
    waiter.join().unwrap();
    let (first, second) = events.expect("unregister left surface route blocked");
    assert!(matches!(first, Some(cmux_tui_cdp::CdpEvent::Closed(_))));
    assert!(second.is_none());
}

#[test]
fn shutdown_closes_and_wakes_surface_route_before_cdp_disconnect() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let request = read_ws_json(&mut ws);
        assert_eq!(request["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
        let _ = stop_rx.recv();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let route = runtime.register("target-1", "session-1");
    let (done_tx, done_rx) = mpsc::channel();
    let waiter = thread::spawn(move || {
        let first = route.recv();
        let second = route.recv();
        done_tx.send((first, second)).unwrap();
    });

    runtime.shutdown();
    let (first, second) = done_rx
        .recv_timeout(Duration::from_millis(200))
        .expect("shutdown left surface route blocked");
    assert!(matches!(first, Some(cmux_tui_cdp::CdpEvent::Closed(_))));
    assert!(second.is_none());

    stop_tx.send(()).unwrap();
    server.join().unwrap();
    waiter.join().unwrap();
}

#[test]
fn closed_surface_route_closes_its_cdp_target() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (closed_tx, closed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        let close = read_ws_json(&mut ws);
        assert_eq!(close["method"], "Target.closeTarget");
        assert_eq!(close["params"]["targetId"], "target-1");
        write_ws_json(&mut ws, json!({"id": close["id"], "result": {"success": true}}));
        closed_tx.send(()).unwrap();
    });
    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().unwrap();
    let route = runtime.register("target-1", "session-1");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });
    start_surface_thread(
        surface.clone(),
        route.clone(),
        Weak::new(),
        Arc::downgrade(&runtime),
        "session-1".to_string(),
    )
    .unwrap();

    route.close("CDP surface event queue overflow".to_string());
    closed_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("closed surface route did not close its CDP target");
    assert!(browser.is_dead());
    assert!(browser.session.lock().unwrap().is_none());

    runtime.shutdown();
    server.join().unwrap();
}

#[test]
fn external_runtime_does_not_query_or_override_user_agent() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    let server = thread::Builder::new()
        .name("browser-external-stealth-negative-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            loop {
                let request = read_ws_json(&mut ws);
                let id = request["id"].clone();
                let method = request["method"].as_str().unwrap().to_string();
                match method.as_str() {
                    "Target.setDiscoverTargets" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                    }
                    "Page.getFrameTree" => {
                        write_ws_json(
                            &mut ws,
                            json!({
                                "id": id,
                                "result": {
                                    "frameTree": {
                                        "frame": {
                                            "id": "main-frame",
                                            "loaderId": "loader-1",
                                            "url": "about:blank"
                                        }
                                    }
                                }
                            }),
                        );
                    }
                    "Page.enable"
                    | "Page.setLifecycleEventsEnabled"
                    | "Emulation.setDeviceMetricsOverride"
                    | "Page.startScreencast" => {
                        write_ws_json(&mut ws, json!({"id": id, "result": {}}));
                        if method == "Page.startScreencast" {
                            break;
                        }
                    }
                    "Browser.getVersion" | "Emulation.setUserAgentOverride" => {
                        panic!("external runtimes must not receive launched-runtime stealth calls")
                    }
                    method => panic!("unexpected CDP method {method}"),
                }
            }
        })
        .unwrap();

    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    runtime
        .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
        .unwrap();

    server.join().unwrap();
    runtime.shutdown();
}

#[test]
fn setup_subscribes_before_seeding_main_frame_authority() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::Builder::new()
        .name("browser-main-frame-seed-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

            for expected in ["Page.enable", "Page.setLifecycleEventsEnabled"] {
                let request = read_ws_json(&mut ws);
                assert_eq!(
                    request["method"], expected,
                    "document events must be subscribed before authority is snapshotted"
                );
                write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            }

            let frame_tree = read_ws_json(&mut ws);
            assert_eq!(
                frame_tree["method"], "Page.getFrameTree",
                "the post-subscription snapshot must reconcile the current root loader"
            );
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

            for expected in ["Emulation.setDeviceMetricsOverride", "Page.startScreencast"] {
                let request = read_ws_json(&mut ws);
                assert_eq!(request["method"], expected);
                write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
            }
        })
        .unwrap();

    let runtime = crate::browser::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    runtime.client.register_frame_epoch("session-1", browser.frame_epoch.clone());

    runtime
        .setup_attached_surface(&surface, "target-1", "session-1", "https://example.test")
        .unwrap();

    server.join().unwrap();
    runtime.shutdown();
}

#[test]
fn latest_navigation_slot_drains_once() {
    let latest_nav = Arc::new(Mutex::new(Some(SequencedBrowserCommand {
        sequence: 7,
        command: BrowserCommand::Navigate("https://next.test".to_string()),
    })));

    let command = take_latest_worker_commands(&latest_nav).expect("pending navigation");
    assert_eq!(command.sequence, 7);
    match &command.command {
        BrowserCommand::Navigate(url) => assert_eq!(url, "https://next.test"),
        _ => panic!("nav command was lost"),
    }
    assert!(latest_nav.lock().unwrap().is_none());
}

#[test]
fn coalesced_navigation_keeps_replacement_order_after_intervening_input() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(Duration::from_secs(1)).unwrap();

    browser.navigate("https://first.test").unwrap();
    browser.mouse_event("mousePressed", 1.0, 1.0, Some("left"), Some(1)).unwrap();
    let replacement_sequence = browser.command_order.lock().unwrap().next_sequence;
    browser.navigate("https://latest.test").unwrap();

    {
        let pending = browser.latest_nav.lock().unwrap();
        let pending = pending.as_ref().expect("coalesced navigation");
        assert_eq!(
            pending.sequence, replacement_sequence,
            "the replacement navigation must retain its position after intervening pointer input"
        );
        assert!(matches!(
            &pending.command,
            BrowserCommand::Navigate(url) if url == "https://latest.test"
        ));
    }

    release.send(()).unwrap();
    browser.kill();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
}

#[test]
fn replacing_queued_screencast_authority_releases_its_reservation() {
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(Duration::from_secs(1)).unwrap();
    browser.store_frame(test_frame(1));
    let frame_epoch = browser.frame_epoch.current();
    let navigation_epoch = browser.frame_epoch.latest_navigation();
    let reservation_id = 71;
    assert!(browser.reserve_screencast_capture(reservation_id, frame_epoch, navigation_epoch,));
    browser
        .enqueue_latest_authority(BrowserCommand::AuthorizeScreencastCapture {
            session_id: "session-1".to_string(),
            frame_id: "main-frame".to_string(),
            loader_id: "loader-1".to_string(),
            reservation_id,
            frame_epoch,
            navigation_epoch,
        })
        .unwrap();
    browser
        .enqueue_latest_authority(BrowserCommand::AuthorizeSameDocumentPaint {
            session_id: "session-1".to_string(),
            frame_id: "main-frame".to_string(),
            loader_id: "loader-1".to_string(),
        })
        .unwrap();

    let released = browser.state.lock().unwrap().pending_screencast_capture.is_none();
    browser.kill();
    release.send(()).unwrap();
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after kill");
    assert!(released, "replacing a queued recovery must not retain its ownership token");
}
