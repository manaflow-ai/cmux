//! The acpmux web listener applies the localhost listener rule
//! (plans/cmux-next/identity.md section 4): a foreign or `null` Origin, a
//! rebinding Host, and a missing or wrong token are refused before the
//! dashboard or the WebSocket protocol starts. The token comes only from a
//! header (`server/ws_auth.rs`), never the URL.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::server::{AGENT_PANE_ORIGIN, bind_ws, bind_ws_with, serve_ws};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const TOKEN: &str = "0123456789abcdef";

async fn listener() -> u16 {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub: Arc<Hub> = Hub::new(config, store);
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws(hub, listener, TOKEN.into()));
    port
}

/// Send one raw request and return the response status code.
async fn status(port: u16, request: String) -> u16 {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut buf = vec![0u8; 1024];
    let n = tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut buf))
        .await
        .expect("response")
        .unwrap();
    let head = String::from_utf8_lossy(&buf[..n]);
    head.split_whitespace().nth(1).and_then(|code| code.parse().ok()).expect("status line")
}

/// An upgrade request with `token` as its bearer token (none when empty).
fn upgrade(token: &str, host: &str, origin: Option<&str>) -> String {
    upgrade_at("", token, host, origin)
}

/// `upgrade` of `/<path>`.
fn upgrade_at(path: &str, token: &str, host: &str, origin: Option<&str>) -> String {
    let origin = origin.map(|o| format!("Origin: {o}\r\n")).unwrap_or_default();
    let auth =
        if token.is_empty() { String::new() } else { format!("Authorization: Bearer {token}\r\n") };
    format!(
        "GET /{path} HTTP/1.1\r\nHost: {host}\r\n{origin}{auth}Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
}

fn page(query: &str, host: &str, origin: Option<&str>) -> String {
    let origin = origin.map(|o| format!("Origin: {o}\r\n")).unwrap_or_default();
    format!("GET /{query} HTTP/1.1\r\nHost: {host}\r\n{origin}\r\n")
}

#[tokio::test]
async fn websocket_with_token_and_allowed_origin_upgrades() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    assert_eq!(status(port, upgrade(TOKEN, &host, None)).await, 101);
    assert_eq!(status(port, upgrade(TOKEN, &host, Some(AGENT_PANE_ORIGIN))).await, 101);
    let own = format!("http://localhost:{port}");
    assert_eq!(status(port, upgrade(TOKEN, &host, Some(&own))).await, 101);
}

#[tokio::test]
async fn websocket_with_foreign_origin_is_refused_even_with_the_token() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    for origin in ["https://evil.example", "null", "file://", "http://127.0.0.1:1"] {
        assert_eq!(status(port, upgrade(TOKEN, &host, Some(origin))).await, 403, "{origin}");
    }
}

#[tokio::test]
async fn websocket_with_a_rebinding_host_is_refused() {
    let port = listener().await;
    let host = format!("evil.example:{port}");
    assert_eq!(status(port, upgrade(TOKEN, &host, None)).await, 403);
}

#[tokio::test]
async fn websocket_without_or_with_a_wrong_token_is_refused() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    assert_eq!(status(port, upgrade("", &host, None)).await, 401);
    assert_eq!(status(port, upgrade("wrong", &host, None)).await, 401);
}

/// Send one raw request and return the whole response head.
async fn response_head(port: u16, request: String) -> String {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut buf))
            .await
            .expect("response")
            .unwrap();
        if n == 0 {
            break;
        }
        head.extend_from_slice(&buf[..n]);
    }
    String::from_utf8_lossy(&head).into_owned()
}

fn upgrade_offering(host: &str, protocols: &str) -> String {
    format!(
        "GET / HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: {protocols}\r\n\r\n"
    )
}

/// A URL is logged, kept in history and sent as a Referer: the listener
/// token in the query alone admits nothing.
#[tokio::test]
async fn websocket_with_only_a_query_token_is_refused() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let query = format!("?token={TOKEN}");
    assert_eq!(status(port, upgrade_at(&query, "", &host, None)).await, 401);
    assert_eq!(status(port, upgrade_at(&query, "", &host, Some(AGENT_PANE_ORIGIN))).await, 401);
}

/// A browser cannot set an Authorization header: it offers the token as a
/// WebSocket subprotocol next to the plain `acpmux.v1`. The upgrade answers
/// with `acpmux.v1` only, never the token.
#[tokio::test]
async fn websocket_with_the_token_subprotocol_upgrades_and_echoes_only_the_plain_protocol() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let offered = format!("acpmux.v1, acpmux.token.{TOKEN}");
    let head = response_head(port, upgrade_offering(&host, &offered)).await;
    assert!(head.starts_with("HTTP/1.1 101"), "{head}");
    let protocols: Vec<&str> = head
        .lines()
        .filter_map(|l| l.split_once(':'))
        .filter(|(name, _)| name.trim().eq_ignore_ascii_case("sec-websocket-protocol"))
        .map(|(_, value)| value.trim())
        .collect();
    assert_eq!(protocols, ["acpmux.v1"], "{head}");
    assert!(!head.contains(TOKEN), "the response echoed the token: {head}");
    // The same in two headers, as some clients send them.
    let split = format!("acpmux.v1\r\nSec-WebSocket-Protocol: acpmux.token.{TOKEN}");
    let head = response_head(port, upgrade_offering(&host, &split)).await;
    assert!(head.starts_with("HTTP/1.1 101"), "{head}");
    assert!(!head.contains(TOKEN), "{head}");
}

#[tokio::test]
async fn websocket_with_a_wrong_or_lone_token_subprotocol_is_refused() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    for offered in [
        "acpmux.v1, acpmux.token.wrong".to_owned(),
        "acpmux.v1".to_owned(),
        // Without the plain protocol to answer with, a browser fails the
        // upgrade: refuse it rather than echo the token.
        format!("acpmux.token.{TOKEN}"),
    ] {
        let head = response_head(port, upgrade_offering(&host, &offered)).await;
        assert!(!head.starts_with("HTTP/1.1 101"), "{offered}: {head}");
        assert!(!head.contains(TOKEN), "{offered}: {head}");
    }
}

/// The page holds no secret: it is served without a token, so no link has
/// to carry one in its query. Its WebSocket still needs the token.
#[tokio::test]
async fn dashboard_page_is_served_without_a_token_in_its_url() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    stream.write_all(page("", &host, None).as_bytes()).await.unwrap();
    let mut body = Vec::new();
    tokio::time::timeout(std::time::Duration::from_secs(5), stream.read_to_end(&mut body))
        .await
        .expect("response")
        .unwrap();
    let body = String::from_utf8_lossy(&body);
    assert!(body.starts_with("HTTP/1.1 200"), "{}", &body[..body.len().min(200)]);
    assert!(!body.contains(TOKEN), "the page embeds the token");
    // The listener rule still holds for the page.
    assert_eq!(status(port, page("", &host, Some("https://evil.example"))).await, 403);
    assert_eq!(status(port, page("", "evil.example", None)).await, 403);
}

/// Plain ws:// on a network address carries the token in clear: never bound
/// unless the person opts in, and the refusal names the opt-in.
#[tokio::test]
async fn a_network_address_is_not_bound_without_the_opt_in() {
    for addr in ["0.0.0.0:0", "[::]:0"] {
        match bind_ws(addr).await {
            Ok(l) => panic!("{addr} was bound: {:?}", l.local_addr()),
            Err(e) => {
                let text = format!("{e:#}");
                assert!(text.contains("--insecure-network-listen"), "{addr}: {text}");
                assert!(text.contains("websocket.allowInsecureNetwork"), "{addr}: {text}");
            }
        }
    }
    // Loopback stays as it was.
    assert!(bind_ws("127.0.0.1:0").await.is_ok());
}

#[tokio::test]
async fn an_empty_token_never_starts_the_listener() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub: Arc<Hub> = Hub::new(config, store);
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    assert!(serve_ws(hub, listener, String::new()).await.is_err());
}

#[tokio::test]
async fn a_head_larger_than_the_peek_window_is_refused() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    // A long path pushes `Origin` past the bytes the listener inspects.
    let long = "a".repeat(4000);
    let request = upgrade_at(&long, TOKEN, &host, Some("https://evil.example"));
    assert_eq!(status(port, request).await, 403);
}

#[tokio::test]
async fn a_page_request_with_large_localhost_cookies_is_served() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let cookie = format!("Cookie: c={}\r\n", "x".repeat(12 * 1024));
    let request = format!("GET / HTTP/1.1\r\nHost: {host}\r\n{cookie}\r\n");
    assert_eq!(status(port, request).await, 200);
}

#[tokio::test]
async fn a_dev_origin_is_accepted_only_when_the_daemon_was_given_it() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    config.dev_origins = vec!["http://127.0.0.1:4176".into()];
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub: Arc<Hub> = Hub::new(config, store);
    let bound = bind_ws("127.0.0.1:0").await.unwrap();
    let port = bound.local_addr().unwrap().port();
    tokio::spawn(serve_ws(hub, bound, TOKEN.into()));
    let host = format!("127.0.0.1:{port}");
    assert_eq!(status(port, upgrade(TOKEN, &host, Some("http://127.0.0.1:4176"))).await, 101);
    let plain = listener().await;
    let host = format!("127.0.0.1:{plain}");
    assert_eq!(status(plain, upgrade(TOKEN, &host, Some("http://127.0.0.1:4176"))).await, 403);
}

#[tokio::test]
async fn a_wide_bind_keeps_the_host_rule() {
    // A non-loopback `websocket.listen` (opted in) widens the bind, never the Host
    // rule: a DNS-rebound name is refused. Names clients use come from
    // `websocket.allowedHosts`; address literals pass (a rebound page always
    // sends the domain name it loaded from).
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    config.websocket = Some(acpmux::config::WebSocketConfig {
        listen: "0.0.0.0:0".into(),
        token: Some(TOKEN.into()),
        allowed_origins: Vec::new(),
        allowed_hosts: vec!["mini.tail1234.ts.net".into()],
        token_rotated: 0,
        allow_insecure_network: true,
    });
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub: Arc<Hub> = Hub::new(config, store);
    let bound = bind_ws_with("0.0.0.0:0", true).await.unwrap();
    let port = bound.local_addr().unwrap().port();
    tokio::spawn(serve_ws(hub, bound, TOKEN.into()));
    for host in [format!("evil.example:{port}"), "other.tail1234.ts.net".to_owned()] {
        assert_eq!(status(port, upgrade(TOKEN, &host, None)).await, 403, "{host}");
        assert_eq!(status(port, page("", &host, None)).await, 403, "page {host}");
    }
    for host in [
        format!("mini.tail1234.ts.net:{port}"),
        format!("127.0.0.1:{port}"),
        format!("10.0.0.5:{port}"),
        format!("[fd7a:115c:a1e0::1]:{port}"),
    ] {
        assert_eq!(status(port, upgrade(TOKEN, &host, None)).await, 101, "{host}");
    }
}

#[tokio::test]
async fn a_frame_past_sixteen_mib_is_read() {
    // A prompt with a few screenshots is one frame past tungstenite's 16 MiB default. The listener
    // reads it and answers, instead of resetting the socket mid-send (2026-10-20, "The agent
    // connection was interrupted").
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;
    let port = listener().await;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let mut req = format!("ws://127.0.0.1:{port}/").into_client_request().unwrap();
    req.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
    let (mut ws, _) =
        tokio_tungstenite::connect_async_with_config(req, Some(acpmux::server::ws_config()), false)
            .await
            .expect("upgrade");
    let init = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": 1, "clientInfo": {"name": "test"}, "pad": "x".repeat(24 << 20)}});
    ws.send(Message::Text(init.to_string().into())).await.unwrap();
    loop {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(30), ws.next())
            .await
            .expect("an answer in time")
            .expect("the connection stays open")
            .expect("no reset");
        if let Message::Text(t) = frame {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            if v.get("id") == Some(&serde_json::json!(1)) {
                break;
            }
        }
    }
}

/// A client that stops halfway through its upgrade request is closed after the handshake
/// deadline (5 s, as the request head's peek): it never holds its connection task and
/// descriptor without end (acpmux-audit.md finding 15).
#[tokio::test]
async fn a_websocket_upgrade_that_stalls_midway_is_closed() {
    let port = listener().await;
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    // The head routes it to the WebSocket path; the blank line that ends it never comes.
    let partial = format!("GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n");
    stream.write_all(partial.as_bytes()).await.unwrap();
    let mut buf = [0u8; 64];
    let read = tokio::time::timeout(std::time::Duration::from_secs(9), stream.read(&mut buf)).await;
    let closed = matches!(read, Ok(Ok(0)) | Ok(Err(_)));
    assert!(closed, "the stalled upgrade was still open after 9 s: {read:?}");
}
