use std::net::{Shutdown, SocketAddr, TcpStream};
use std::time::Duration;

use base64::Engine;
use cmux_tui_core::{Mux, MuxEvent, SurfaceOptions, server};
use serde_json::{Value, json};
use tungstenite::{Message, WebSocket, client};

fn connect(addr: SocketAddr) -> WebSocket<TcpStream> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    client(format!("ws://{addr}/"), stream).unwrap().0
}

fn send_json(websocket: &mut WebSocket<TcpStream>, value: Value) {
    websocket.send(Message::Text(value.to_string().into())).unwrap();
}

fn read_json(websocket: &mut WebSocket<TcpStream>) -> Value {
    loop {
        match websocket.read().unwrap() {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Ping(data) => websocket.send(Message::Pong(data)).unwrap(),
            message => panic!("expected a JSON text frame, got {message:?}"),
        }
    }
}

fn read_until(websocket: &mut WebSocket<TcpStream>, predicate: impl Fn(&Value) -> bool) -> Value {
    loop {
        let value = read_json(websocket);
        if predicate(&value) {
            return value;
        }
    }
}

#[test]
fn websocket_auth_accepts_exact_preamble_and_rejects_missing_or_wrong_tokens() {
    let mux = Mux::new("ws-auth", SurfaceOptions::default());
    let server = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some("correct horse".to_string()),
        false,
    )
    .unwrap();

    for first_frame in
        [json!({"id": 1, "cmd": "identify"}), json!({"auth": {"token": "wrong battery"}})]
    {
        let mut websocket = connect(server.local_addr());
        send_json(&mut websocket, first_frame);
        assert!(matches!(
            websocket.read(),
            Ok(Message::Close(_))
                | Err(tungstenite::Error::ConnectionClosed)
                | Err(tungstenite::Error::AlreadyClosed)
        ));
    }

    let mut websocket = connect(server.local_addr());
    send_json(&mut websocket, json!({"auth": {"token": "correct horse"}}));
    send_json(&mut websocket, json!({"id": 7, "cmd": "identify"}));
    let identify = read_json(&mut websocket);
    assert_eq!(identify["id"], 7);
    assert_eq!(identify["ok"], true);
    assert_eq!(identify["data"]["protocol"], server::PROTOCOL_VERSION);
    assert_eq!(identify["data"]["session"], "ws-auth");

    mux.shutdown();
}

#[test]
fn websocket_streams_subscribe_and_attach_and_survives_unclean_disconnect() {
    let mux = Mux::new("ws-streams", SurfaceOptions::default());
    let surface = mux
        .run_command_surface(vec!["/bin/cat".to_string()], None, true, None, None, Some((80, 24)))
        .unwrap()
        .surface;
    let server =
        server::serve_websocket(mux.clone(), "127.0.0.1:0".parse().unwrap(), None, false).unwrap();

    let mut websocket = connect(server.local_addr());
    send_json(&mut websocket, json!({"id": 1, "cmd": "subscribe"}));
    let subscribe = read_until(&mut websocket, |value| value["id"] == 1);
    assert_eq!(subscribe["ok"], true);
    mux.emit(MuxEvent::TreeChanged);
    let tree_changed = read_until(&mut websocket, |value| value["event"] == "tree-changed");
    assert_eq!(tree_changed, json!({"event": "tree-changed"}));

    send_json(&mut websocket, json!({"id": 2, "cmd": "attach-surface", "surface": surface}));
    let vt_state = read_until(&mut websocket, |value| value["event"] == "vt-state");
    assert_eq!(vt_state["surface"], surface);
    assert!(
        base64::engine::general_purpose::STANDARD
            .decode(vt_state["data"].as_str().unwrap())
            .is_ok()
    );
    let attach = read_until(&mut websocket, |value| value["id"] == 2);
    assert_eq!(attach["ok"], true);

    let marker = "cmux-websocket-roundtrip";
    send_json(
        &mut websocket,
        json!({"id": 3, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    let output = read_until(&mut websocket, |value| {
        value["event"] == "output"
            && value["data"]
                .as_str()
                .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok())
                .is_some_and(|bytes| String::from_utf8_lossy(&bytes).contains(marker))
    });
    assert_eq!(output["surface"], surface);

    websocket.get_mut().shutdown(Shutdown::Both).unwrap();
    drop(websocket);

    let mut second = connect(server.local_addr());
    send_json(&mut second, json!({"id": 4, "cmd": "identify"}));
    let identify = read_json(&mut second);
    assert_eq!(identify["ok"], true);
    assert_eq!(identify["data"]["protocol"], server::PROTOCOL_VERSION);

    mux.shutdown();
}

#[test]
fn websocket_non_loopback_bind_requires_and_accepts_explicit_insecure_opt_in() {
    let mux = Mux::new("ws-bind", SurfaceOptions::default());
    let error = server::serve_websocket(mux.clone(), "0.0.0.0:0".parse().unwrap(), None, false)
        .err()
        .expect("non-loopback bind should fail");
    assert!(error.to_string().contains("--ws-insecure-bind"));

    let server =
        server::serve_websocket(mux.clone(), "0.0.0.0:0".parse().unwrap(), None, true).unwrap();
    let addr = SocketAddr::from(([127, 0, 0, 1], server.local_addr().port()));
    let mut websocket = connect(addr);
    send_json(&mut websocket, json!({"id": 1, "cmd": "identify"}));
    let identify = read_json(&mut websocket);
    assert_eq!(identify["ok"], true);
    assert_eq!(identify["data"]["protocol"], server::PROTOCOL_VERSION);

    mux.shutdown();
}
