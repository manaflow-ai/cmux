//! The daemon WebSocket listener applies the localhost listener rule
//! (plans/cmux-next/identity.md section 4) at the handshake: a foreign or
//! `null` Origin and a rebinding Host are refused with 403 before the first
//! protocol frame, even with the right token. A missing or wrong token is
//! refused after the handshake (websocket_transport.rs covers that).

use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::json;
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::{Message, client};

const TOKEN: &str = "listener-rule-token";

fn handshake(
    addr: SocketAddr,
    host: Option<&str>,
    origin: Option<&str>,
) -> Result<tungstenite::WebSocket<TcpStream>, u16> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut request = format!("ws://{addr}/").into_client_request().unwrap();
    if let Some(host) = host {
        request.headers_mut().insert("host", HeaderValue::from_str(host).unwrap());
    }
    if let Some(origin) = origin {
        request.headers_mut().insert("origin", HeaderValue::from_str(origin).unwrap());
    }
    match client(request, stream) {
        Ok((websocket, _)) => Ok(websocket),
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response))) => {
            Err(response.status().as_u16())
        }
        Err(error) => panic!("unexpected handshake error: {error}"),
    }
}

fn identify(websocket: &mut tungstenite::WebSocket<TcpStream>) -> bool {
    websocket.send(Message::Text(json!({"auth": {"token": TOKEN}}).to_string().into())).unwrap();
    websocket.send(Message::Text(json!({"id": 1, "cmd": "identify"}).to_string().into())).unwrap();
    match websocket.read() {
        Ok(Message::Text(text)) => {
            serde_json::from_str::<serde_json::Value>(&text).unwrap()["ok"] == true
        }
        _ => false,
    }
}

fn listener(
    name: &str,
    access: &server::WebSocketAccess,
) -> (std::sync::Arc<Mux>, server::WebSocketServer) {
    let mux = Mux::new(name, SurfaceOptions::default());
    let server = server::serve_websocket_with_access(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some(TOKEN.to_string()),
        false,
        access,
    )
    .unwrap();
    (mux, server)
}

#[test]
fn a_native_client_and_the_own_origin_are_accepted() {
    let (mux, server) = listener("ws-rule-ok", &Default::default());
    let addr = server.local_addr();
    let mut native = handshake(addr, None, None).expect("native client");
    assert!(identify(&mut native));
    let own = format!("http://localhost:{}", addr.port());
    let mut page = handshake(addr, None, Some(&own)).expect("own origin");
    assert!(identify(&mut page));
    mux.shutdown();
}

#[test]
fn a_foreign_origin_is_refused_even_with_the_token() {
    let (mux, server) = listener("ws-rule-origin", &Default::default());
    let addr = server.local_addr();
    for origin in ["https://evil.example", "null", "http://127.0.0.1:1", "file://"] {
        assert_eq!(handshake(addr, None, Some(origin)).err(), Some(403), "{origin}");
    }
    mux.shutdown();
}

#[test]
fn a_rebinding_host_is_refused() {
    let (mux, server) = listener("ws-rule-host", &Default::default());
    let addr = server.local_addr();
    let host = format!("evil.example:{}", addr.port());
    assert_eq!(handshake(addr, Some(&host), None).err(), Some(403));
    mux.shutdown();
}

#[test]
fn added_origins_and_hosts_are_accepted_and_nothing_else() {
    let access = server::WebSocketAccess {
        origins: vec!["http://localhost:5173".into()],
        hosts: vec!["mini.tail1234.ts.net".into()],
    };
    let (mux, server) = listener("ws-rule-added", &access);
    let addr = server.local_addr();
    let mut page = handshake(addr, None, Some("http://localhost:5173")).expect("added origin");
    assert!(identify(&mut page));
    let mut tailnet = handshake(addr, Some("mini.tail1234.ts.net"), None).expect("added host");
    assert!(identify(&mut tailnet));
    assert_eq!(handshake(addr, None, Some("http://localhost:5174")).err(), Some(403));
    assert_eq!(handshake(addr, Some("other.tail1234.ts.net"), None).err(), Some(403));
    mux.shutdown();
}

#[test]
fn a_non_loopback_bind_keeps_the_host_and_origin_rules() {
    // `--ws-insecure-bind` widens the bind, never the Host rule: a
    // DNS-rebound name is still refused. Names the daemon cannot list come
    // from `--ws-allow-host`; address literals pass (a rebound page always
    // sends the domain name it loaded from).
    let mux = Mux::new("ws-rule-wide-bind", SurfaceOptions::default());
    let access = server::WebSocketAccess {
        origins: Vec::new(),
        hosts: vec!["mini.tail1234.ts.net".into()],
    };
    let server = server::serve_websocket_with_access(
        mux.clone(),
        "0.0.0.0:0".parse().unwrap(),
        Some(TOKEN.to_string()),
        true,
        &access,
    )
    .unwrap();
    let port = server.local_addr().port();
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    for host in [format!("evil.example:{port}"), "other.tail1234.ts.net".to_owned()] {
        assert_eq!(handshake(addr, Some(&host), None).err(), Some(403), "{host}");
    }
    for origin in ["https://evil.example", "null"] {
        assert_eq!(handshake(addr, None, Some(origin)).err(), Some(403), "{origin}");
    }
    for host in [
        format!("mini.tail1234.ts.net:{port}"),
        format!("127.0.0.1:{port}"),
        format!("192.168.1.20:{port}"),
        format!("[fd7a:115c:a1e0::1]:{port}"),
    ] {
        let mut websocket = handshake(addr, Some(&host), None).expect(&host);
        assert!(identify(&mut websocket), "{host}");
    }
    mux.shutdown();
}

fn send(websocket: &mut tungstenite::WebSocket<TcpStream>, value: serde_json::Value) {
    websocket.send(Message::Text(value.to_string().into())).unwrap();
}

fn read_value(websocket: &mut tungstenite::WebSocket<TcpStream>) -> Option<serde_json::Value> {
    match websocket.read() {
        Ok(Message::Text(text)) => serde_json::from_str(&text).ok(),
        _ => None,
    }
}

fn closed_by_policy(websocket: &mut tungstenite::WebSocket<TcpStream>) -> bool {
    loop {
        match websocket.read() {
            Ok(Message::Close(Some(frame))) => {
                return frame.code == tungstenite::protocol::frame::coding::CloseCode::Policy;
            }
            Ok(Message::Text(_)) | Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => continue,
            _ => return false,
        }
    }
}

#[test]
fn without_the_token_a_client_is_admitted_only_after_the_user_confirms() {
    let mux = Mux::new("ws-rule-pairing", SurfaceOptions::default());
    let server = server::serve_websocket_with_access(
        mux.clone(),
        "127.0.0.1:0".parse().unwrap(),
        Some(TOKEN.to_string()),
        false,
        &Default::default(),
    )
    .unwrap();
    let addr = server.local_addr();

    // Missing token: a command as the first frame closes the socket.
    let mut missing = handshake(addr, None, None).unwrap();
    send(&mut missing, json!({"id": 1, "cmd": "identify"}));
    assert!(closed_by_policy(&mut missing), "missing token");

    // Wrong token.
    let mut wrong = handshake(addr, None, None).unwrap();
    send(&mut wrong, json!({"auth": {"token": "not-the-token"}}));
    send(&mut wrong, json!({"id": 1, "cmd": "identify"}));
    assert!(closed_by_policy(&mut wrong), "wrong token");

    // Pairing: nothing is admitted while the request is pending, and a
    // denial closes the socket.
    let mut denied = handshake(addr, None, None).unwrap();
    send(&mut denied, json!({"pair": {"request": true}}));
    let challenge = read_value(&mut denied).expect("challenge");
    let request = challenge["pairing"]["id"].as_u64().expect("pairing id");
    denied.get_mut().set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    send(&mut denied, json!({"id": 2, "cmd": "identify"}));
    assert!(read_value(&mut denied).is_none(), "a pending pairing answered a command");
    denied.get_mut().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    assert_eq!(mux.pending_pairings().len(), 1);
    assert!(mux.respond_pairing(request, false));
    assert!(closed_by_policy(&mut denied), "denied pairing");

    // Only the user's approval admits the client.
    let mut approved = handshake(addr, None, None).unwrap();
    send(&mut approved, json!({"pair": {"request": true}}));
    let challenge = read_value(&mut approved).expect("challenge");
    let request = challenge["pairing"]["id"].as_u64().expect("pairing id");
    assert!(mux.respond_pairing(request, true));
    let paired = read_value(&mut approved).expect("paired");
    assert!(paired["paired"]["credential"].is_string(), "{paired}");
    send(&mut approved, json!({"id": 3, "cmd": "identify"}));
    let reply = read_value(&mut approved).expect("identify");
    assert_eq!(reply["ok"], true, "{reply}");
    mux.shutdown();
}
