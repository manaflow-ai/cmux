use std::io::{BufRead, BufReader, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, MuxEvent, SurfaceOptions, server};
use serde_json::{Value, json};
use tungstenite::{Message, WebSocket, client};

const TEST_TOKEN: &str = "test-token";

fn connect(addr: SocketAddr) -> WebSocket<TcpStream> {
    connect_raw(addr)
}

fn connect_raw(addr: SocketAddr) -> WebSocket<TcpStream> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    client(format!("ws://{addr}/"), stream).unwrap().0
}

fn authenticated_connect(addr: SocketAddr) -> WebSocket<TcpStream> {
    let mut websocket = connect(addr);
    send_json(&mut websocket, json!({"auth": {"token": TEST_TOKEN}}));
    websocket
}

fn send_json(websocket: &mut WebSocket<TcpStream>, value: Value) {
    websocket.send(Message::Text(value.to_string().into())).unwrap();
}

fn read_json(websocket: &mut WebSocket<TcpStream>) -> Value {
    loop {
        // valgrind's signal delivery interrupts blocking reads with EINTR.
        match websocket.read() {
            Ok(Message::Text(text)) => return serde_json::from_str(&text).unwrap(),
            Ok(Message::Ping(data)) => websocket.send(Message::Pong(data)).unwrap(),
            Ok(message) => panic!("expected a JSON text frame, got {message:?}"),
            Err(tungstenite::Error::Io(error))
                if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => panic!("websocket read failed: {error}"),
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

fn unique_socket(name: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    // serve() chmods the socket's parent directory; temp_dir() itself can be
    // root-owned (/tmp on Linux CI), so the socket needs a user-owned subdir.
    let dir = std::env::temp_dir().join(format!("cmux-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(format!("cmux-{name}-{}.sock", NEXT.fetch_add(1, Ordering::Relaxed)))
}

fn read_line_until(reader: &mut impl BufRead, predicate: impl Fn(&Value) -> bool) -> Value {
    loop {
        let value = read_json_line(reader);
        if predicate(&value) {
            return value;
        }
    }
}

fn read_json_line(reader: &mut impl BufRead) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(!line.is_empty(), "Unix connection closed before expected message");
    serde_json::from_str(&line).unwrap()
}

#[test]
fn websocket_server_allows_pairing_without_a_static_token() {
    let mux = Mux::new("ws-token-optional", SurfaceOptions::default());

    for token in [None, Some(String::new()), Some("   ".to_string())] {
        let server =
            server::serve_websocket(mux.clone(), "127.0.0.1:0".parse().unwrap(), token, false);
        assert!(server.is_ok(), "WebSocket listener rejected pairing mode");
    }

    mux.shutdown();
}

#[test]
fn websocket_server_rejects_tokens_that_cannot_fit_the_auth_limit() {
    let mux = Mux::new("ws-token-size", SurfaceOptions::default());
    let result = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some("x".repeat(8 * 1024)),
        false,
    );

    assert!(result.is_err(), "WebSocket listener accepted an unusably large token");
    mux.shutdown();
}

#[test]
fn websocket_rejects_oversized_authentication_frames() {
    let mux = Mux::new("ws-auth-frame-limit", SurfaceOptions::default());
    let server = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some(TEST_TOKEN.to_string()),
        false,
    )
    .unwrap();

    let mut websocket = connect_raw(server.local_addr());
    websocket.send(Message::Text("x".repeat(8 * 1024).into())).unwrap();
    assert!(
        matches!(websocket.read(), Ok(Message::Close(_)) | Err(_)),
        "oversized pre-authentication frame remained accepted"
    );

    mux.shutdown();
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
        let mut websocket = connect_raw(server.local_addr());
        send_json(&mut websocket, first_frame);
        assert!(matches!(
            websocket.read(),
            Ok(Message::Close(_))
                | Err(tungstenite::Error::ConnectionClosed)
                | Err(tungstenite::Error::AlreadyClosed)
        ));
    }

    let mut websocket = connect_raw(server.local_addr());
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
fn websocket_pairing_is_approved_over_trusted_unix_and_credential_reconnects() {
    let mux = Mux::new("ws-pairing", SurfaceOptions::default());
    let socket_path = unique_socket("ws-pairing");
    server::serve(mux.clone(), Some(socket_path.clone())).unwrap();
    let websocket_server =
        server::serve_websocket(mux.clone(), "127.0.0.1:0".parse().unwrap(), None, false).unwrap();

    let unix = transport::connect(&socket_path).unwrap();
    unix.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut unix_writer = unix.try_clone_box().unwrap();
    let mut unix_reader = BufReader::new(unix);
    writeln!(unix_writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 1)["ok"], true);

    let mut websocket = connect(websocket_server.local_addr());
    send_json(&mut websocket, json!({"pair": {"request": true}}));
    let tui_challenge =
        read_line_until(&mut unix_reader, |value| value["event"] == "pairing-requested");
    let browser_challenge = read_until(&mut websocket, |value| value.get("pairing").is_some());
    assert_eq!(tui_challenge["code"], browser_challenge["pairing"]["code"]);
    assert_eq!(tui_challenge["request"], browser_challenge["pairing"]["id"]);

    let request = tui_challenge["request"].as_u64().unwrap();
    writeln!(
        unix_writer,
        r#"{{"id":2,"cmd":"pairing-response","request":{request},"approve":true}}"#
    )
    .unwrap();
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 2)["ok"], true);
    let paired = read_until(&mut websocket, |value| value.get("paired").is_some());
    let credential = paired["paired"]["credential"].as_str().unwrap().to_string();
    send_json(&mut websocket, json!({"id": 3, "cmd": "identify"}));
    assert_eq!(read_until(&mut websocket, |value| value["id"] == 3)["ok"], true);

    let mut reconnect = connect(websocket_server.local_addr());
    send_json(&mut reconnect, json!({"auth": {"token": credential}}));
    send_json(&mut reconnect, json!({"id": 4, "cmd": "identify"}));
    assert_eq!(read_until(&mut reconnect, |value| value["id"] == 4)["ok"], true);

    mux.shutdown();
    server::cleanup(&socket_path);
}

#[test]
fn websocket_streams_subscribe_and_attach_and_survives_unclean_disconnect() {
    let mux = Mux::new("ws-streams", SurfaceOptions::default());
    let surface = mux
        .run_command_surface(vec!["/bin/cat".to_string()], None, true, None, None, Some((80, 24)))
        .unwrap()
        .surface;
    let server = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some(TEST_TOKEN.to_string()),
        false,
    )
    .unwrap();

    let mut websocket = authenticated_connect(server.local_addr());
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

    let mut second = authenticated_connect(server.local_addr());
    send_json(&mut second, json!({"id": 4, "cmd": "identify"}));
    let identify = read_json(&mut second);
    assert_eq!(identify["ok"], true);
    assert_eq!(identify["data"]["protocol"], server::PROTOCOL_VERSION);

    mux.shutdown();
}

#[test]
fn websocket_subscriber_receives_cross_connection_event_without_poll_delay() {
    let mux = Mux::new("ws-outbound-latency", SurfaceOptions::default());
    let server = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some("test-token".to_string()),
        false,
    )
    .unwrap();

    let mut subscriber = authenticated_connect(server.local_addr());
    send_json(&mut subscriber, json!({"id": 1, "cmd": "subscribe"}));
    assert_eq!(read_until(&mut subscriber, |value| value["id"] == 1)["ok"], true);

    let mut trigger = authenticated_connect(server.local_addr());
    send_json(&mut trigger, json!({"id": 2, "cmd": "identify"}));
    assert_eq!(read_until(&mut trigger, |value| value["id"] == 2)["ok"], true);

    // Round-trip a ping so the server has returned to waiting for this
    // connection's next inbound frame before another connection emits.
    subscriber.send(Message::Ping(Vec::new().into())).unwrap();
    loop {
        match subscriber.read().unwrap() {
            Message::Pong(_) => break,
            Message::Ping(data) => subscriber.send(Message::Pong(data)).unwrap(),
            Message::Text(_) => {}
            message => panic!("expected pong while synchronizing reader, got {message:?}"),
        }
    }
    std::thread::sleep(Duration::from_millis(5));

    let started = Instant::now();
    send_json(&mut trigger, json!({"id": 3, "cmd": "set-window-title", "title": "latency-marker"}));
    let event = read_until(&mut subscriber, |value| {
        value["event"] == "window-title-requested" && value["title"] == "latency-marker"
    });
    let elapsed = started.elapsed();

    eprintln!("cross-connection outbound event latency: {elapsed:?}");
    assert_eq!(event["title"], "latency-marker");
    // Valgrind slows everything ~30x; the workflow raises the budget there.
    // The regression being guarded (outbound events serialized behind a 100ms
    // read poll) inflates far past any budget under the same slowdown.
    let budget_ms = std::env::var("CMUX_TEST_WS_LATENCY_BUDGET_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(50);
    assert!(
        elapsed < Duration::from_millis(budget_ms),
        "outbound event took {elapsed:?}; expected it well below the 100 ms disconnect poll"
    );
    assert_eq!(read_until(&mut trigger, |value| value["id"] == 3)["ok"], true);

    mux.shutdown();
}

#[test]
fn clients_list_identify_resize_and_detach_across_transports() {
    let mux = Mux::new("client-presence", SurfaceOptions::default());
    let surface = mux
        .run_command_surface(vec!["/bin/cat".to_string()], None, true, None, None, Some((80, 24)))
        .unwrap()
        .surface;
    let socket_path = unique_socket("client-presence");
    server::serve(mux.clone(), Some(socket_path.clone())).unwrap();
    let websocket_server = server::serve_websocket(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some(TEST_TOKEN.to_string()),
        false,
    )
    .unwrap();

    let unix = transport::connect(&socket_path).unwrap();
    unix.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut unix_writer = unix.try_clone_box().unwrap();
    let mut unix_reader = BufReader::new(unix);
    writeln!(unix_writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 1)["ok"], true);
    writeln!(unix_writer, r#"{{"id":2,"cmd":"attach-surface","surface":{surface}}}"#).unwrap();
    assert_eq!(
        read_line_until(&mut unix_reader, |value| value["event"] == "vt-state")["surface"],
        surface
    );
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 2)["ok"], true);

    let mut websocket = authenticated_connect(websocket_server.local_addr());
    send_json(
        &mut websocket,
        json!({"id": 3, "cmd": "set-client-info", "name": "lawrences-iphone", "kind": "web"}),
    );
    assert_eq!(read_until(&mut websocket, |value| value["id"] == 3)["ok"], true);
    send_json(&mut websocket, json!({"id": 4, "cmd": "attach-surface", "surface": surface}));
    assert_eq!(
        read_until(&mut websocket, |value| value["event"] == "vt-state")["surface"],
        surface
    );
    assert_eq!(read_until(&mut websocket, |value| value["id"] == 4)["ok"], true);

    writeln!(unix_writer, r#"{{"id":5,"cmd":"list-clients"}}"#).unwrap();
    let clients = read_line_until(&mut unix_reader, |value| value["id"] == 5);
    let clients = clients["data"].as_array().unwrap();
    assert_eq!(clients.len(), 2);
    let unix_client = clients.iter().find(|client| client["transport"] == "unix").unwrap();
    let ws_client = clients.iter().find(|client| client["transport"] == "ws").unwrap();
    assert_eq!(unix_client["self"], true);
    assert_eq!(ws_client["self"], false);
    assert_eq!(ws_client["name"], "lawrences-iphone");
    assert_eq!(ws_client["kind"], "web");
    assert_eq!(unix_client["attached"], json!([surface]));
    assert_eq!(ws_client["attached"], json!([surface]));
    let unix_id = unix_client["client"].as_u64().unwrap();
    let ws_id = ws_client["client"].as_u64().unwrap();

    writeln!(
        unix_writer,
        r#"{{"id":60,"cmd":"resize-surface","surface":{surface},"cols":120,"rows":40}}"#
    )
    .unwrap();
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 60)["ok"], true);

    send_json(
        &mut websocket,
        json!({"id": 6, "cmd": "resize-surface", "surface": surface, "cols": 101, "rows": 37}),
    );
    assert_eq!(read_until(&mut websocket, |value| value["id"] == 6)["ok"], true);
    writeln!(unix_writer, r#"{{"id":7,"cmd":"list-clients"}}"#).unwrap();
    let clients = read_line_until(&mut unix_reader, |value| value["id"] == 7);
    let ws_client = clients["data"]
        .as_array()
        .unwrap()
        .iter()
        .find(|client| client["client"] == ws_id)
        .unwrap();
    assert_eq!(ws_client["sizes"], json!([{"surface": surface, "cols": 101, "rows": 37}]));
    assert_eq!(mux.surface(surface).unwrap().size(), (101, 37));

    writeln!(unix_writer, r#"{{"id":8,"cmd":"detach-client","client":{ws_id}}}"#).unwrap();
    assert_eq!(
        read_until(&mut websocket, |value| value["event"] == "detached")["surface"],
        surface
    );
    assert!(matches!(
        websocket.read(),
        Ok(Message::Close(_))
            | Err(tungstenite::Error::ConnectionClosed)
            | Err(tungstenite::Error::AlreadyClosed)
    ));
    let mut saw_detached = false;
    let mut saw_response = false;
    while !saw_detached || !saw_response {
        let value = read_json_line(&mut unix_reader);
        if value["event"] == "client-detached" && value["client"] == ws_id {
            assert_eq!(value, json!({"event": "client-detached", "client": ws_id}));
            saw_detached = true;
        }
        if value["id"] == 8 {
            assert_eq!(value["ok"], true);
            saw_response = true;
        }
    }
    assert_eq!(mux.surface(surface).unwrap().size(), (120, 40));

    writeln!(unix_writer, r#"{{"id":9,"cmd":"detach-client","client":{unix_id}}}"#).unwrap();
    assert_eq!(read_line_until(&mut unix_reader, |value| value["id"] == 9)["ok"], true);
    assert_eq!(
        read_line_until(&mut unix_reader, |value| value["event"] == "detached")["surface"],
        surface
    );
    let mut eof = String::new();
    assert_eq!(unix_reader.read_line(&mut eof).unwrap(), 0);

    mux.shutdown();
    server::cleanup(&socket_path);
}

#[test]
fn websocket_non_loopback_bind_requires_and_accepts_explicit_insecure_opt_in() {
    let mux = Mux::new("ws-bind", SurfaceOptions::default());
    let error = server::serve_websocket(
        mux.clone(),
        "0.0.0.0:0".parse().unwrap(),
        Some(TEST_TOKEN.to_string()),
        false,
    )
    .err()
    .expect("non-loopback bind should fail");
    assert!(error.to_string().contains("--ws-insecure-bind"));

    let server = server::serve_websocket(
        mux.clone(),
        "0.0.0.0:0".parse().unwrap(),
        Some(TEST_TOKEN.to_string()),
        true,
    )
    .unwrap();
    let addr = SocketAddr::from(([127, 0, 0, 1], server.local_addr().port()));
    let mut websocket = authenticated_connect(addr);
    send_json(&mut websocket, json!({"id": 1, "cmd": "identify"}));
    let identify = read_json(&mut websocket);
    assert_eq!(identify["ok"], true);
    assert_eq!(identify["data"]["protocol"], server::PROTOCOL_VERSION);

    mux.shutdown();
}
