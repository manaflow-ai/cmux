use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use mux_cdp::{CdpClient, CdpEvent, discover_browser_ws_url, resolve_browser_ws_url};
use serde_json::{Value, json};
use tungstenite::{Message, accept};

static TEST_LOCK: Mutex<()> = Mutex::new(());

fn read_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).unwrap(),
            _ => {}
        }
    }
}

fn write_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>, value: &Value) {
    ws.send(Message::Text(value.to_string().into())).unwrap();
}

#[test]
fn fake_cdp_flat_sessions_correlation_events_and_screencast_ack() {
    let _guard = TEST_LOCK.lock().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();

        let create = read_json(&mut ws);
        assert_eq!(create["method"], "Target.createTarget");
        assert_eq!(create["params"]["url"], "https://example.test");
        write_json(&mut ws, &json!({"id": create["id"], "result": {"targetId": "target-1"}}));

        let attach = read_json(&mut ws);
        assert_eq!(attach["method"], "Target.attachToTarget");
        assert_eq!(attach["params"]["targetId"], "target-1");
        assert_eq!(attach["params"]["flatten"], true);
        write_json(&mut ws, &json!({"id": attach["id"], "result": {"sessionId": "session-1"}}));

        let first = read_json(&mut ws);
        let second = read_json(&mut ws);
        assert_eq!(first["sessionId"], "session-1");
        assert_eq!(second["sessionId"], "session-1");
        write_json(&mut ws, &json!({"id": second["id"], "result": {"name": second["method"]}}));
        write_json(&mut ws, &json!({"id": first["id"], "result": {"name": first["method"]}}));

        write_json(
            &mut ws,
            &json!({
                "method": "Target.targetInfoChanged",
                "params": {
                    "targetInfo": {
                        "targetId": "target-1",
                        "title": "Example",
                        "url": "https://example.test/"
                    }
                }
            }),
        );

        write_json(
            &mut ws,
            &json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "iVBORw0KGgo=",
                    "metadata": {"deviceWidth": 640, "deviceHeight": 480},
                    "sessionId": 42
                }
            }),
        );
        let ack = read_json(&mut ws);
        assert_eq!(ack["method"], "Page.screencastFrameAck");
        assert_eq!(ack["sessionId"], "session-1");
        assert_eq!(ack["params"]["sessionId"], 42);
        write_json(&mut ws, &json!({"id": ack["id"], "result": {}}));
    });

    let (event_tx, event_rx) = std::sync::mpsc::channel();
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    let target_id = client.create_target("https://example.test").unwrap();
    assert_eq!(target_id, "target-1");
    let session_id = client.attach_to_target(&target_id).unwrap();
    assert_eq!(session_id, "session-1");

    let left_client = client.clone();
    let right_client = client.clone();
    let right_session_id = session_id.clone();
    let left =
        thread::spawn(move || left_client.call("Test.left", json!({}), Some(&session_id)).unwrap());
    let right = {
        thread::spawn(move || {
            right_client.call("Test.right", json!({}), Some(&right_session_id)).unwrap()
        })
    };
    let left = left.join().unwrap();
    let right = right.join().unwrap();
    assert_eq!(left["name"], "Test.left");
    assert_eq!(right["name"], "Test.right");
    let client_guard = client;

    let info = event_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    match info {
        CdpEvent::TargetInfoChanged(info) => {
            assert_eq!(info.session_id, None);
            assert_eq!(info.target_id, "target-1");
            assert_eq!(info.title, "Example");
            assert_eq!(info.url, "https://example.test/");
        }
        other => panic!("unexpected event: {other:?}"),
    }

    let frame = event_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    match frame {
        CdpEvent::ScreencastFrame(frame) => {
            assert_eq!(frame.session_id, "session-1");
            assert_eq!(frame.data_b64, "iVBORw0KGgo=");
            assert_eq!(frame.css_width, 640);
            assert_eq!(frame.css_height, 480);
            assert_eq!(frame.ack_id, 42);
        }
        other => panic!("unexpected event: {other:?}"),
    }

    server.join().unwrap();
    drop(client_guard);
}

#[test]
fn fake_cdp_activate_target_then_bring_page_to_front() {
    let _guard = TEST_LOCK.lock().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();

        let activate = read_json(&mut ws);
        assert_eq!(activate["method"], "Target.activateTarget");
        assert_eq!(activate["params"]["targetId"], "target-1");
        assert!(activate.get("sessionId").is_none());
        write_json(&mut ws, &json!({"id": activate["id"], "result": {}}));

        let front = read_json(&mut ws);
        assert_eq!(front["method"], "Page.bringToFront");
        assert_eq!(front["sessionId"], "session-1");
        write_json(&mut ws, &json!({"id": front["id"], "result": {}}));
    });

    let (event_tx, _event_rx) = std::sync::mpsc::channel();
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.activate_target("target-1", "session-1").unwrap();
    server.join().unwrap();
}

#[test]
fn fake_cdp_dispatches_button_none_mouse_move_without_click_count() {
    let _guard = TEST_LOCK.lock().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();

        let request = read_json(&mut ws);
        assert_eq!(request["method"], "Input.dispatchMouseEvent");
        assert_eq!(request["sessionId"], "session-1");
        assert_eq!(request["params"]["type"], "mouseMoved");
        assert_eq!(request["params"]["x"], 22.0);
        assert_eq!(request["params"]["y"], 18.0);
        assert_eq!(request["params"]["button"], "none");
        assert!(request["params"].get("clickCount").is_none());
        write_json(&mut ws, &json!({"id": request["id"], "result": {}}));
    });

    let (event_tx, _event_rx) = std::sync::mpsc::channel();
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.dispatch_mouse_event("session-1", "mouseMoved", 22.0, 18.0, Some("none"), None).unwrap();
    server.join().unwrap();
}

#[test]
fn resolves_json_version_and_discovers_loopback_port() {
    let _guard = TEST_LOCK.lock().unwrap();
    let (port, expected, server) = serve_json_version_once();
    assert_eq!(resolve_browser_ws_url(&format!("http://127.0.0.1:{port}")).unwrap(), expected);
    server.join().unwrap();

    let (port, expected, server) = serve_json_version_once();
    assert_eq!(discover_browser_ws_url(&[port]).unwrap(), expected);
    server.join().unwrap();
}

fn serve_json_version_once() -> (u16, String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let expected = format!("ws://127.0.0.1:{port}/devtools/browser/external");

    let server = thread::spawn({
        let expected = expected.clone();
        move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request_bytes = Vec::new();
            let mut buf = [0u8; 1024];
            while !request_bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                let n = stream.read(&mut buf).unwrap();
                if n == 0 {
                    break;
                }
                request_bytes.extend_from_slice(&buf[..n]);
            }
            let request = String::from_utf8_lossy(&request_bytes);
            assert!(request.starts_with("GET /json/version HTTP/1.1\r\n"));
            let body = json!({ "webSocketDebuggerUrl": expected }).to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        }
    });
    (port, expected, server)
}
