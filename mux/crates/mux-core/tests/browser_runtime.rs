use std::net::TcpListener;
use std::panic::{self, AssertUnwindSafe};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use mux_core::{Mux, SurfaceKind, SurfaceOptions};
use serde_json::{json, Value};
use tungstenite::{accept, Message};

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

fn run_with_timeout(name: &'static str, timeout: Duration, f: impl FnOnce() + Send + 'static) {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = panic::catch_unwind(AssertUnwindSafe(f));
        let _ = tx.send(result);
    });

    match rx.recv_timeout(timeout) {
        Ok(Ok(())) => {}
        Ok(Err(payload)) => panic::resume_unwind(payload),
        Err(_) => panic!("{name} exceeded timeout of {timeout:?}"),
    }
}

#[test]
fn two_browser_surfaces_share_external_runtime_and_demux_frames() {
    run_with_timeout(
        "two_browser_surfaces_share_external_runtime_and_demux_frames",
        Duration::from_secs(60),
        two_browser_surfaces_share_external_runtime_and_demux_frames_body,
    );
}

fn two_browser_surfaces_share_external_runtime_and_demux_frames_body() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (closed_tx, closed_rx) = mpsc::channel();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let mut next_target = 1u32;
        let mut closed = 0u8;

        loop {
            let request = read_json(&mut ws);
            let id = request["id"].clone();
            match request["method"].as_str().unwrap() {
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
                "Page.enable" | "Emulation.setDeviceMetricsOverride" | "Page.stopScreencast" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Page.startScreencast" => {
                    let session = request["sessionId"].as_str().unwrap().to_string();
                    let seq = if session == "session-1" { 101 } else { 202 };
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                    write_json(
                        &mut ws,
                        json!({
                            "method": "Page.screencastFrame",
                            "sessionId": session,
                            "params": {
                                "data": format!("png-{seq}"),
                                "metadata": {"deviceWidth": 80, "deviceHeight": 40},
                                "sessionId": seq
                            }
                        }),
                    );
                }
                "Page.screencastFrameAck" => {
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                }
                "Target.closeTarget" => {
                    let target = request["params"]["targetId"].as_str().unwrap().to_string();
                    closed_tx.send(target).unwrap();
                    write_json(&mut ws, json!({"id": id, "result": {"success": true}}));
                    closed += 1;
                    if closed == 2 {
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
    let mux = Mux::new("browser-runtime-test", opts);
    let first = mux.new_browser_tab("one.test".to_string(), None, Some((10, 5))).unwrap();
    let second = mux.new_browser_tab("two.test".to_string(), None, Some((10, 5))).unwrap();

    assert_eq!(first.kind(), SurfaceKind::Browser);
    assert_eq!(second.kind(), SurfaceKind::Browser);
    assert_eq!(first.browser_source().unwrap().as_str(), "external");
    assert_eq!(second.browser_source().unwrap().as_str(), "external");

    let first_frame =
        wait_for(|| first.browser_frame(), Duration::from_secs(2)).expect("first frame");
    let second_frame =
        wait_for(|| second.browser_frame(), Duration::from_secs(2)).expect("second frame");
    assert_eq!(first_frame.session_id, "session-1");
    assert_eq!(first_frame.seq, 101);
    assert_eq!(second_frame.session_id, "session-2");
    assert_eq!(second_frame.seq, 202);

    mux.close_surface(first.id);
    assert_eq!(closed_rx.recv_timeout(Duration::from_secs(2)).unwrap(), "target-1");
    mux.close_surface(second.id);
    assert_eq!(closed_rx.recv_timeout(Duration::from_secs(2)).unwrap(), "target-2");
    mux.shutdown();
    server.join().unwrap();
}
