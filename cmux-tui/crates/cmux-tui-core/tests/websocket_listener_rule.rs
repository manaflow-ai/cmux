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
