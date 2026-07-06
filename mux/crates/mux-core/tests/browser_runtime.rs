use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use mux_core::{server, BrowserStatus, Mux, SurfaceKind, SurfaceOptions};
use serde_json::{json, Value};
use tungstenite::{accept, Message};

static TEST_LOCK: Mutex<()> = Mutex::new(());
static SOCKET_SERIAL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn read_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).unwrap(),
            _ => {}
        }
    }
}

fn write_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>, value: Value) {
    ws.send(Message::Text(value.to_string())).unwrap();
}

fn rpc(path: &std::path::Path, mut cmd: Value) -> Value {
    let mut stream = UnixStream::connect(path).unwrap();
    if cmd.get("id").is_none() {
        cmd["id"] = json!(1);
    }
    let mut line = cmd.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).unwrap();
    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader.read_line(&mut response).unwrap();
    serde_json::from_str(&response).unwrap()
}

fn recv_method(rx: &mpsc::Receiver<Value>, method: &str) -> Value {
    recv_method_where(rx, method, |_| true)
}

fn recv_method_where(
    rx: &mpsc::Receiver<Value>,
    method: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    // On timeout, the panic lists what DID arrive during this wait so a
    // CI-only failure identifies the stalled step without a rerun.
    let mut drained = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let value = rx.recv_timeout(remaining).unwrap_or_else(|err| {
            panic!(
                "timed out waiting for CDP method {method}: {err}; \
                 methods drained during this wait: {drained:?}"
            )
        });
        if value.get("method").and_then(|v| v.as_str()) == Some(method) && predicate(&value) {
            return value;
        }
        drained.push(
            value.get("method").and_then(|v| v.as_str()).unwrap_or("<no-method>").to_string(),
        );
    }
}

fn recv_attach_event(reader: &mut BufReader<UnixStream>, event: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(Instant::now() < deadline, "timed out waiting for attach event {event}");
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line.is_empty() {
            panic!("attach stream closed while waiting for {event}");
        }
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("event").and_then(|v| v.as_str()) == Some(event) {
            return value;
        }
    }
}

fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let start = Instant::now();
    loop {
        if let Some(value) = f() {
            return Some(value);
        }
        if start.elapsed() > timeout {
            return None;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn socket_browser_attach_streams_frames_input_and_cell_pixels() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();
    let (frame_tx, frame_rx) = mpsc::channel();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let mut next_target = 1u32;
        let mut start_count = 0u32;
        let mut closed = 0u32;
        let mut opener_second_frame_sent = false;
        let mut opener_ack_count = 0u32;

        loop {
            let request = read_json(&mut ws);
            let id = request["id"].clone();
            let method = request["method"].as_str().unwrap().to_string();
            seen_tx.send(request.clone()).unwrap();
            match method.as_str() {
                "Target.setDiscoverTargets" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.createTarget" => {
                    let target = format!("target-{next_target}");
                    next_target += 1;
                    write_json(&mut ws, json!({"id": id, "result": {"targetId": target}}));
                }
                "Target.attachToTarget" => {
                    let target = request["params"]["targetId"].as_str().unwrap();
                    let session = target.replace("target", "session");
                    write_json(&mut ws, json!({"id": id, "result": {"sessionId": session}}));
                }
                "Page.enable"
                | "Emulation.setDeviceMetricsOverride"
                | "Page.stopScreencast"
                | "Target.activateTarget"
                | "Page.bringToFront"
                | "Input.dispatchMouseEvent"
                | "Input.insertText"
                | "Page.navigateToHistoryEntry"
                | "Page.reload"
                | "Page.handleJavaScriptDialog" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Page.navigate" => {
                    let url = request["params"]["url"].as_str().unwrap();
                    let result = if url.contains("bad.test") {
                        json!({"errorText": "net::ERR_NAME_NOT_RESOLVED"})
                    } else {
                        json!({})
                    };
                    write_json(&mut ws, json!({"id": id, "result": result}));
                    if url.contains("live.test") && !opener_second_frame_sent {
                        frame_rx.recv_timeout(Duration::from_secs(30)).unwrap();
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": "session-1",
                                "params": {
                                    "data": "c2Vjb25k",
                                    "metadata": {"deviceWidth": 100, "deviceHeight": 50},
                                    "sessionId": 77
                                }
                            }),
                        );
                        opener_second_frame_sent = true;
                    }
                }
                "Page.getNavigationHistory" => {
                    write_json(
                        &mut ws,
                        json!({
                            "id": id,
                            "result": {
                                "currentIndex": 1,
                                "entries": [
                                    {"id": 10, "url": "https://back.test", "title": "back"},
                                    {"id": 11, "url": "https://current.test", "title": "current"},
                                    {"id": 12, "url": "https://forward.test", "title": "forward"}
                                ]
                            }
                        }),
                    );
                }
                "Page.startScreencast" => {
                    let session = request["sessionId"].as_str().unwrap().to_string();
                    start_count += 1;
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                    if start_count == 1 {
                        frame_rx.recv_timeout(Duration::from_secs(30)).unwrap();
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": session,
                                "params": {
                                    "data": "iVBORw0KGgo=",
                                    "metadata": {"deviceWidth": 100, "deviceHeight": 50},
                                    "sessionId": 77
                                }
                            }),
                        );
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Page.javascriptDialogOpening",
                                "sessionId": session,
                                "params": {"type": "alert", "message": "hi"}
                            }),
                        );
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Target.targetCreated",
                                "params": {
                                    "targetInfo": {
                                        "targetId": "target-unrelated",
                                        "openerId": "target-missing",
                                        "type": "page",
                                        "title": "",
                                        "url": "https://unrelated.test"
                                    }
                                }
                            }),
                        );
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Target.targetCreated",
                                "params": {
                                    "targetInfo": {
                                        "targetId": "target-popup",
                                        "openerId": "target-1",
                                        "type": "page",
                                        "title": "",
                                        "url": "https://popup.test"
                                    }
                                }
                            }),
                        );
                    } else if session == "session-popup" {
                        write_json(
                            &mut ws,
                            json!({
                                "method": "Page.screencastFrame",
                                "sessionId": session,
                                "params": {
                                    "data": "cG9wdXA=",
                                    "metadata": {"deviceWidth": 40, "deviceHeight": 20},
                                    "sessionId": 88
                                }
                            }),
                        );
                    }
                }
                "Page.screencastFrameAck" => {
                    if request["sessionId"] == "session-1" {
                        assert_eq!(request["params"]["sessionId"], 77);
                        opener_ack_count += 1;
                    }
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.closeTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"success": true}}));
                    closed += 1;
                    if closed >= 2 {
                        assert_eq!(opener_ack_count, 2);
                        break;
                    }
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
    });

    let opts = SurfaceOptions {
        cdp_url: Some(format!("ws://{addr}/devtools/browser/fake")),
        browser_discover: false,
        ..Default::default()
    };
    let mux = Mux::new("browser-socket-test", opts);
    let socket_path = std::env::temp_dir()
        .join(format!(
            "cmux-browser-socket-test-{}-{}",
            std::process::id(),
            SOCKET_SERIAL.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ))
        .join("session.sock");
    server::serve(mux.clone(), Some(socket_path.clone())).unwrap();
    let created = rpc(
        &socket_path,
        json!({"id": 1, "cmd": "new-browser-tab", "url": "example.test", "cols": 10, "rows": 5}),
    );
    assert_eq!(created["ok"], true);
    let surface = created["data"]["surface"].as_u64().unwrap();

    // A second tab in the same pane, sized differently, becomes the active
    // tab. The popup adopted from `surface` below must be sized from
    // `surface` (the opener), not from this now-active tab.
    let other_tab =
        rpc(&socket_path, json!({"id": 100, "cmd": "new-tab", "cwd": "/", "cols": 40, "rows": 20}));
    assert_eq!(other_tab["ok"], true, "new-tab failed: {other_tab}");
    let other_tab_surface = other_tab["data"]["surface"].as_u64().unwrap();

    let mut attach = UnixStream::connect(&socket_path).unwrap();
    attach
        .write_all(
            json!({"id": 2, "cmd": "attach-surface", "surface": surface}).to_string().as_bytes(),
        )
        .unwrap();
    attach.write_all(b"\n").unwrap();
    let mut attach_reader = BufReader::new(attach);
    let state = recv_attach_event(&mut attach_reader, "browser-state");
    assert_eq!(state["surface"], surface);
    assert_eq!(state["url"], "https://example.test");
    assert!(state["frame"].is_null());

    frame_tx.send(()).unwrap();
    let frame = recv_attach_event(&mut attach_reader, "frame");
    assert_eq!(frame["surface"], surface);
    assert_eq!(frame["seq"], 1);
    assert_eq!(frame["width"], 100);
    assert_eq!(frame["height"], 50);
    assert_eq!(frame["data"], "iVBORw0KGgo=");

    let navigate = rpc(
        &socket_path,
        json!({"id": 101, "cmd": "browser-navigate", "surface": surface, "url": "live.test"}),
    );
    assert_eq!(navigate["ok"], true, "browser-navigate failed: {navigate}");
    let live_state = recv_attach_event(&mut attach_reader, "browser-state");
    assert_eq!(live_state["surface"], surface);
    assert_eq!(live_state["url"], "https://live.test");
    assert_eq!(live_state["status"], "live");
    assert!(live_state.get("frame").is_none(), "state re-emit must not include frame payload");

    frame_tx.send(()).unwrap();
    let second_frame = recv_attach_event(&mut attach_reader, "frame");
    assert_eq!(second_frame["surface"], surface);
    assert_eq!(second_frame["seq"], 2);
    assert_eq!(second_frame["width"], 100);
    assert_eq!(second_frame["height"], 50);
    assert_eq!(second_frame["data"], "c2Vjb25k");

    let dialog = recv_method(&seen_rx, "Page.handleJavaScriptDialog");
    assert_eq!(dialog["sessionId"], "session-1");
    assert_eq!(dialog["params"]["accept"], false);
    let popup_attach = recv_method(&seen_rx, "Target.attachToTarget");
    assert_eq!(popup_attach["params"]["targetId"], "target-popup");
    let popup_surface = wait_for(
        || {
            mux.with_state(|state| {
                let popup =
                    state.surfaces.keys().copied().find(|candidate| {
                        *candidate != surface && *candidate != other_tab_surface
                    })?;
                (state.surfaces.len() == 3).then_some(popup)
            })
        },
        Duration::from_secs(10),
    )
    .expect("popup tab adopted");
    assert_eq!(
        mux.surface(popup_surface).unwrap().size(),
        (10, 5),
        "popup must inherit the opener's size, not the pane's active (non-opener) tab"
    );
    let popup_start = recv_method_where(&seen_rx, "Page.startScreencast", |value| {
        value["sessionId"] == "session-popup"
    });
    assert_eq!(popup_start["sessionId"], "session-popup");
    let opener_frame = mux.surface(surface).and_then(|surface| surface.browser_frame()).unwrap();
    assert_eq!(opener_frame.session_id, "session-1");
    assert_eq!(opener_frame.seq, 2);
    let popup_frame = wait_for(
        || {
            mux.surface(popup_surface)
                .and_then(|surface| surface.browser_frame())
                .filter(|frame| frame.seq == 1)
        },
        Duration::from_secs(10),
    )
    .expect("popup surface received its own frame");
    assert_eq!(popup_frame.session_id, "session-popup");
    assert_eq!(popup_frame.data_b64, "cG9wdXA=");
    let opener_frame_after_popup =
        mux.surface(surface).and_then(|surface| surface.browser_frame()).unwrap();
    assert_eq!(opener_frame_after_popup.session_id, "session-1");
    assert_eq!(opener_frame_after_popup.seq, 2);
    while seen_rx.try_recv().is_ok() {}
    thread::sleep(Duration::from_millis(100));
    while let Ok(value) = seen_rx.try_recv() {
        assert_ne!(
            value
                .get("params")
                .and_then(|params| params.get("targetId"))
                .and_then(|target| target.as_str()),
            Some("target-unrelated"),
            "unrelated popup target was attached"
        );
    }
    mux.with_state(|state| assert_eq!(state.surfaces.len(), 3));

    let mouse = rpc(
        &socket_path,
        json!({
            "id": 3,
            "cmd": "browser-mouse",
            "surface": surface,
            "kind": "down",
            "x_px": 12.5,
            "y_px": 9.0,
            "button": "left",
            "click_count": 1
        }),
    );
    assert_eq!(mouse["ok"], true);
    let mouse_request = recv_method(&seen_rx, "Input.dispatchMouseEvent");
    assert_eq!(mouse_request["sessionId"], "session-1");
    assert_eq!(mouse_request["params"]["type"], "mousePressed");
    assert_eq!(mouse_request["params"]["x"], 15.625);
    assert_eq!(mouse_request["params"]["y"], 5.625);

    let insert = rpc(
        &socket_path,
        json!({"id": 4, "cmd": "browser-insert-text", "surface": surface, "text": "hello"}),
    );
    assert_eq!(insert["ok"], true);
    let insert_request = recv_method(&seen_rx, "Input.insertText");
    assert_eq!(insert_request["sessionId"], "session-1");
    assert_eq!(insert_request["params"]["text"], "hello");

    let metrics = rpc(
        &socket_path,
        json!({"id": 5, "cmd": "set-cell-pixels", "width_px": 11, "height_px": 17}),
    );
    assert_eq!(metrics["ok"], true);
    let metrics_request =
        recv_method_where(&seen_rx, "Emulation.setDeviceMetricsOverride", |value| {
            value["params"]["width"] == 110 && value["params"]["height"] == 85
        });
    assert_eq!(metrics_request["params"]["width"], 110);
    assert_eq!(metrics_request["params"]["height"], 85);

    let back = rpc(&socket_path, json!({"id": 6, "cmd": "browser-back", "surface": surface}));
    assert_eq!(back["ok"], true);
    let back_nav = recv_method(&seen_rx, "Page.navigateToHistoryEntry");
    assert_eq!(back_nav["sessionId"], "session-1");
    assert_eq!(back_nav["params"]["entryId"], 10);

    let forward = rpc(&socket_path, json!({"id": 7, "cmd": "browser-forward", "surface": surface}));
    assert_eq!(forward["ok"], true);
    let forward_nav = recv_method(&seen_rx, "Page.navigateToHistoryEntry");
    assert_eq!(forward_nav["sessionId"], "session-1");
    assert_eq!(forward_nav["params"]["entryId"], 12);

    let reload = rpc(&socket_path, json!({"id": 8, "cmd": "browser-reload", "surface": surface}));
    assert_eq!(reload["ok"], true);
    let reload_request = recv_method(&seen_rx, "Page.reload");
    assert_eq!(reload_request["sessionId"], "session-1");

    let navigate = rpc(
        &socket_path,
        json!({"id": 9, "cmd": "browser-navigate", "surface": surface, "url": "bad.test"}),
    );
    assert_eq!(navigate["ok"], false);
    assert!(navigate["error"].as_str().unwrap().contains("ERR_NAME_NOT_RESOLVED"));
    let navigate_request = recv_method(&seen_rx, "Page.navigate");
    assert_eq!(navigate_request["sessionId"], "session-1");
    assert_eq!(navigate_request["params"]["url"], "https://bad.test");
    let failed = wait_for(
        || match mux.surface(surface)?.browser_status()? {
            BrowserStatus::Failed(error) => Some(error),
            BrowserStatus::Starting | BrowserStatus::Live => None,
        },
        Duration::from_secs(10),
    )
    .expect("navigate errorText surfaced as browser failure");
    assert_eq!(failed, "net::ERR_NAME_NOT_RESOLVED");

    mux.close_surface(surface);
    mux.shutdown();
    server::cleanup(&socket_path);
    server.join().unwrap();
}

#[test]
fn browser_capture_scale_applies_to_metrics_screencast_and_input() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        loop {
            let request = read_json(&mut ws);
            let id = request["id"].clone();
            let method = request["method"].as_str().unwrap().to_string();
            seen_tx.send(request.clone()).unwrap();
            match method.as_str() {
                "Target.setDiscoverTargets" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.createTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"targetId": "target-1"}}));
                }
                "Target.attachToTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"sessionId": "session-1"}}));
                }
                "Page.enable"
                | "Emulation.setDeviceMetricsOverride"
                | "Page.startScreencast"
                | "Input.dispatchMouseEvent" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.closeTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"success": true}}));
                    break;
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
    });

    let opts = SurfaceOptions {
        cdp_url: Some(format!("ws://{addr}/devtools/browser/fake")),
        browser_discover: false,
        browser_max_capture_megapixels: 0.01,
        ..Default::default()
    };
    let mux = Mux::new("browser-scale-test", opts);
    mux.set_cell_pixel_size(100, 100);
    let surface = mux
        .new_browser_tab("example.test".to_string(), None, Some((100, 100)))
        .expect("browser tab");

    let metrics = recv_method(&seen_rx, "Emulation.setDeviceMetricsOverride");
    assert_eq!(metrics["sessionId"], "session-1");
    assert_eq!(metrics["params"]["width"], 100);
    assert_eq!(metrics["params"]["height"], 100);
    let screencast = recv_method(&seen_rx, "Page.startScreencast");
    assert_eq!(screencast["sessionId"], "session-1");
    assert_eq!(screencast["params"]["maxWidth"], 100);
    assert_eq!(screencast["params"]["maxHeight"], 100);

    wait_for(
        || matches!(surface.browser_status(), Some(BrowserStatus::Live)).then_some(()),
        Duration::from_secs(10),
    )
    .expect("browser went live");
    surface.browser_mouse_event("mousePressed", 5_000.0, 5_000.0, Some("left"), Some(1)).unwrap();
    let mouse = recv_method(&seen_rx, "Input.dispatchMouseEvent");
    assert_eq!(mouse["sessionId"], "session-1");
    assert_eq!(mouse["params"]["x"], 50.0);
    assert_eq!(mouse["params"]["y"], 50.0);

    mux.shutdown();
    server.join().unwrap();
}

#[test]
fn stalled_external_browser_nudges_target_once_before_interaction() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        loop {
            let request = read_json(&mut ws);
            let id = request["id"].clone();
            let method = request["method"].as_str().unwrap().to_string();
            seen_tx.send(request.clone()).unwrap();
            match method.as_str() {
                "Target.setDiscoverTargets" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.createTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"targetId": "target-1"}}));
                }
                "Target.attachToTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"sessionId": "session-1"}}));
                }
                "Page.enable"
                | "Emulation.setDeviceMetricsOverride"
                | "Page.startScreencast"
                | "Target.activateTarget"
                | "Page.bringToFront"
                | "Input.dispatchMouseEvent" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.closeTarget" => {
                    write_json(&mut ws, json!({"id": id, "result": {"success": true}}));
                    break;
                }
                method => panic!("unexpected CDP method {method}"),
            }
        }
    });

    let opts = SurfaceOptions {
        cdp_url: Some(format!("ws://{addr}/devtools/browser/fake")),
        browser_discover: false,
        ..Default::default()
    };
    let mux = Mux::new("browser-stall-nudge-test", opts);
    let surface =
        mux.new_browser_tab("example.test".to_string(), None, Some((10, 5))).expect("browser tab");
    wait_for(
        || matches!(surface.browser_status(), Some(BrowserStatus::Live)).then_some(()),
        Duration::from_secs(10),
    )
    .expect("browser went live");
    wait_for(
        || surface.browser_frames_stalled().filter(|stalled| *stalled),
        Duration::from_secs(4),
    )
    .expect("browser frames stalled");
    while seen_rx.try_recv().is_ok() {}

    surface.browser_mouse_event("mousePressed", 12.0, 9.0, Some("left"), Some(1)).unwrap();
    let activate = recv_method(&seen_rx, "Target.activateTarget");
    assert_eq!(activate["params"]["targetId"], "target-1");
    let front = recv_method(&seen_rx, "Page.bringToFront");
    assert_eq!(front["sessionId"], "session-1");
    let mouse = recv_method(&seen_rx, "Input.dispatchMouseEvent");
    assert_eq!(mouse["sessionId"], "session-1");
    assert_eq!(mouse["params"]["type"], "mousePressed");

    surface.browser_mouse_event("mousePressed", 13.0, 10.0, Some("left"), Some(1)).unwrap();
    let second_mouse = seen_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(second_mouse["method"], "Input.dispatchMouseEvent");
    assert_eq!(second_mouse["params"]["x"], 13.0);

    mux.shutdown();
    server.join().unwrap();
}

#[test]
fn browser_tab_creation_is_async_and_surfaces_bootstrap_failure() {
    let _guard = TEST_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let closed_port = {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let opts = SurfaceOptions {
        cdp_url: Some(format!("ws://127.0.0.1:{closed_port}/devtools/browser/missing")),
        browser_discover: false,
        ..Default::default()
    };
    let mux = Mux::new("browser-async-failure-test", opts);
    let started = Instant::now();
    let surface = mux
        .new_browser_tab("example.test".to_string(), None, Some((10, 5)))
        .expect("tab insertion should not wait for CDP bootstrap");
    assert!(
        started.elapsed() < Duration::from_millis(500),
        "new_browser_tab blocked for {:?}",
        started.elapsed()
    );
    assert_eq!(surface.kind(), SurfaceKind::Browser);
    mux.with_state(|state| assert_eq!(state.surfaces.len(), 1));
    let status = wait_for(
        || match surface.browser_status() {
            Some(BrowserStatus::Failed(error)) => Some(error),
            _ => None,
        },
        Duration::from_secs(10),
    )
    .expect("browser bootstrap failure surfaced");
    assert!(
        status.contains("Connection refused")
            || status.contains("connection refused")
            || status.contains("failed to lookup address information")
            || status.contains("timed out"),
        "{status}"
    );
    mux.shutdown();
}
