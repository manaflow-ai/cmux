//! `browser-provider-native-hosting-v1` at the daemon socket and CDP
//! boundary: a natively hosted provider target keeps its native geometry (no
//! `Emulation.setDeviceMetricsOverride`, no `Target.activateTarget`) and is
//! screencast only while a frame viewer is attached. The daemon-hosted
//! contract (metrics + screencast on attach) stays covered by
//! `browser_runtime.rs`.
#![cfg(unix)]
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
mod support;
use cmux_tui_core::{BrowserStatus, Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::DaemonMuxOps;
use tungstenite::{Message, accept};

/// CDP methods a natively hosted target must never receive from the daemon.
const FORBIDDEN: [&str; 3] =
    ["Emulation.setDeviceMetricsOverride", "Target.activateTarget", "Page.bringToFront"];

fn test_duration(duration: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    duration.saturating_mul(scale)
}

fn read_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Option<Value> {
    loop {
        match ws.read().ok()? {
            Message::Text(text) => return Some(serde_json::from_str(&text).unwrap()),
            Message::Binary(bytes) => return Some(serde_json::from_slice(&bytes).unwrap()),
            Message::Close(_) => return None,
            _ => {}
        }
    }
}

fn write_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>, value: Value) {
    ws.send(Message::Text(value.to_string().into())).unwrap();
}

/// A provider endpoint that answers every call the daemon may make and
/// reports each request. It never refuses a forbidden call: the test asserts
/// on what was sent, so a regression reads as a failed assertion.
fn run_native_provider_endpoint(listener: TcpListener, seen: mpsc::Sender<Value>) {
    let (stream, _) = listener.accept().unwrap();
    let mut ws = accept(stream).unwrap();
    while let Some(request) = read_json(&mut ws) {
        let id = request["id"].clone();
        let method = request["method"].as_str().unwrap().to_string();
        let _ = seen.send(request.clone());
        match method.as_str() {
            "Target.attachToTarget" => {
                assert_eq!(request["params"]["targetId"], "native-target");
                write_json(&mut ws, json!({"id": id, "result": {"sessionId": "native-session"}}));
            }
            "Page.getFrameTree" => write_json(
                &mut ws,
                json!({"id": id, "result": {"frameTree": {"frame": {
                    "id": "main-frame", "loaderId": "loader-1", "url": "https://example.test"
                }}}}),
            ),
            "Page.createIsolatedWorld" => {
                write_json(&mut ws, json!({"id": id, "result": {"executionContextId": 41}}));
            }
            "Runtime.evaluate" => write_json(
                &mut ws,
                json!({"id": id, "result": {"result": {"type": "number", "value": 10_000.0}}}),
            ),
            "Page.startScreencast" => {
                write_json(&mut ws, json!({"id": id, "result": {}}));
                write_json(
                    &mut ws,
                    json!({
                        "method": "Page.screencastFrame",
                        "sessionId": "native-session",
                        "params": {
                            "data": "bmF0aXZl",
                            "metadata": {
                                "deviceWidth": 1280,
                                "deviceHeight": 800,
                                "timestamp": 10.002
                            },
                            "sessionId": 61
                        }
                    }),
                );
            }
            "Target.closeTarget" => panic!("provider mode must not close a browser-owned tab"),
            "Target.createTarget" => panic!("provider mode must not create a target"),
            _ => write_json(&mut ws, json!({"id": id, "result": {}})),
        }
    }
}

/// Receive requests until `method` arrives; return it and the methods seen
/// before it.
fn recv_until(rx: &mpsc::Receiver<Value>, method: &str) -> (Value, Vec<String>) {
    let deadline = Instant::now() + test_duration(Duration::from_secs(30));
    let mut before = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let value = rx.recv_timeout(remaining).unwrap_or_else(|error| {
            panic!("timed out waiting for CDP {method}: {error}; seen before: {before:?}")
        });
        let name = value["method"].as_str().unwrap_or("<none>").to_string();
        if name == method {
            return (value, before);
        }
        before.push(name);
    }
}

fn assert_none_forbidden(step: &str, methods: &[String]) {
    for forbidden in FORBIDDEN {
        assert!(
            !methods.iter().any(|method| method == forbidden),
            "{step}: a natively hosted target got {forbidden}; methods: {methods:?}"
        );
    }
}

fn send_line(stream: &mut UnixStream, value: Value) {
    let mut line = value.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).unwrap();
}

fn read_reply(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn recv_attach_event(reader: &mut BufReader<UnixStream>, event: &str) -> Value {
    let deadline = Instant::now() + test_duration(Duration::from_secs(30));
    loop {
        assert!(Instant::now() < deadline, "timed out waiting for attach event {event}");
        let value = read_reply(reader);
        if value.get("event").and_then(Value::as_str) == Some(event) {
            return value;
        }
    }
}

/// A guarded TUI client attached to the browser surface at 30x10 cells.
fn attach_viewer(socket: &std::path::Path, surface: u64, id: u64) -> BufReader<UnixStream> {
    let mut stream = UnixStream::connect(socket).unwrap();
    send_line(
        &mut stream,
        json!({
            "id": id,
            "cmd": "set-client-info",
            "kind": "tui",
            "capabilities": [server::GUARDED_BROWSER_POINTER_CAPABILITY],
        }),
    );
    let mut viewer = BufReader::new(stream);
    let info = read_reply(&mut viewer);
    assert_eq!(info["ok"], true, "viewer registration failed: {info}");
    send_line(
        viewer.get_mut(),
        json!({"id": id + 1, "cmd": "attach-surface", "surface": surface, "cols": 30, "rows": 10}),
    );
    viewer
}

fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let deadline = Instant::now() + test_duration(timeout);
    loop {
        if let Some(value) = f() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn native_hosted_provider_keeps_native_geometry_and_screencasts_only_for_viewers() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();
    let endpoint = thread::spawn(move || run_native_provider_endpoint(listener, seen_tx));

    let mux = Mux::new("native-hosted-provider-test", SurfaceOptions::default());
    let socket_path = std::env::temp_dir()
        .join(format!("cmux-native-hosted-{}", std::process::id()))
        .join("session.sock");
    server::serve(mux.clone(), Some(socket_path.clone())).unwrap();
    mux.set_cell_pixel_size(10, 20);

    let identify = {
        let mut stream = UnixStream::connect(&socket_path).unwrap();
        send_line(&mut stream, json!({"id": 1, "cmd": "identify"}));
        read_reply(&mut BufReader::new(stream))
    };
    assert!(
        identify["data"]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == server::BROWSER_PROVIDER_NATIVE_HOSTING_CAPABILITY),
        "identify must advertise native hosting: {identify}"
    );

    let surface =
        mux.new_browser_tab("example.test".to_string(), None, Some((10, 5))).expect("browser tab");
    let tab_id = surface.resource_identity().expect("tab identity").tab_id.to_string();

    // The native provider registers its tab with hosting:"native".
    let mut provider_stream = UnixStream::connect(&socket_path).unwrap();
    send_line(
        &mut provider_stream,
        json!({
            "id": 2,
            "cmd": "register-browser-provider",
            "provider_id": "native-browser",
            "endpoint": format!("ws://{addr}/devtools/browser/native"),
            "authentication": "none",
            "hosting": "native",
            "targets": [{"tab_id": tab_id, "target_id": "native-target"}],
        }),
    );
    let mut provider = BufReader::new(provider_stream);
    let registered = read_reply(&mut provider);
    assert_eq!(registered["ok"], true, "registration failed: {registered}");
    assert_eq!(registered["data"]["hosting"], "native");

    wait_for(
        || matches!(surface.browser_status(), Some(BrowserStatus::Live)).then_some(()),
        Duration::from_secs(30),
    )
    .unwrap_or_else(|| panic!("native target never went live: {:?}", surface.browser_status()));

    // A pane resize with no viewer changes nothing in the page.
    assert!(surface.resize(40, 12).expect("resize accepted"));

    // A frame viewer attaches: only now does a screencast start, and it is
    // the first screencast or metrics call the target ever got.
    let mut viewer = attach_viewer(&socket_path, surface.id, 3);
    let (start, before_viewer) = recv_until(&seen_rx, "Page.startScreencast");
    assert_none_forbidden("attach and resize without a viewer", &before_viewer);
    assert!(
        !before_viewer.iter().any(|method| method == "Page.startScreencast"),
        "no screencast before a viewer attached: {before_viewer:?}"
    );
    assert_eq!(start["sessionId"], "native-session");
    let frame = recv_attach_event(&mut viewer, "frame");
    assert_eq!(frame["data"], "bmF0aXZl", "the viewer gets the native frames: {frame}");

    // A resize while viewed resizes only the frames.
    assert!(surface.resize(50, 15).expect("resize accepted"));
    let (_, before_restart) = recv_until(&seen_rx, "Page.stopScreencast");
    let (restart, during_restart) = recv_until(&seen_rx, "Page.startScreencast");
    assert_none_forbidden("resize with a viewer", &[before_restart, during_restart].concat());
    assert_eq!(restart["params"]["maxWidth"], 500);
    assert_eq!(restart["params"]["maxHeight"], 300);

    // The last viewer leaves: the screencast stops.
    drop(viewer);
    let (_, before_stop) = recv_until(&seen_rx, "Page.stopScreencast");
    assert_none_forbidden("viewer detach", &before_stop);

    // A new viewer starts it again. Its frames then stall (the endpoint
    // sends one frame per start); input on a stalled native page must not
    // bring the native window's target to the front.
    let mut second = attach_viewer(&socket_path, surface.id, 5);
    let (_, before_second) = recv_until(&seen_rx, "Page.startScreencast");
    assert_none_forbidden("second viewer attach", &before_second);
    let frame = recv_attach_event(&mut second, "frame");
    assert_eq!(frame["data"], "bmF0aXZl");
    wait_for(
        || surface.browser_frames_stalled().filter(|stalled| *stalled),
        Duration::from_secs(10),
    )
    .expect("the viewed native page's frames stalled");
    // The input may be refused for a client-owned pointer; either way the
    // detach below is the fence for anything it could have sent.
    let _ = surface.browser_mouse_event("mousePressed", 12.0, 9.0, Some("left"), Some(1));
    drop(second);
    let (_, before_second_stop) = recv_until(&seen_rx, "Page.stopScreencast");
    assert_none_forbidden("input on a stalled viewed page", &before_second_stop);

    mux.close_surface(surface.id).unwrap();
    drop(provider);
    mux.shutdown();
    server::cleanup(&socket_path);
    endpoint.join().unwrap();
    let rest: Vec<String> = seen_rx
        .try_iter()
        .map(|value| value["method"].as_str().unwrap_or("<none>").to_string())
        .collect();
    assert_none_forbidden("shutdown", &rest);
    assert!(
        !rest.iter().any(|method| method == "Page.startScreencast"),
        "no screencast after the last viewer left: {rest:?}"
    );
}
