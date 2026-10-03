//! The acpmux web listener applies the localhost listener rule
//! (plans/cmux-next/identity.md section 4): a foreign or `null` Origin, a
//! rebinding Host, and a missing or wrong token are refused before the
//! dashboard or the WebSocket protocol starts.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::server::{AGENT_PANE_ORIGIN, bind_ws, serve_ws};
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

fn upgrade(query: &str, host: &str, origin: Option<&str>) -> String {
    let origin = origin.map(|o| format!("Origin: {o}\r\n")).unwrap_or_default();
    format!(
        "GET /{query} HTTP/1.1\r\nHost: {host}\r\n{origin}Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
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
    let query = format!("?token={TOKEN}");
    assert_eq!(status(port, upgrade(&query, &host, None)).await, 101);
    assert_eq!(status(port, upgrade(&query, &host, Some(AGENT_PANE_ORIGIN))).await, 101);
    let own = format!("http://localhost:{port}");
    assert_eq!(status(port, upgrade(&query, &host, Some(&own))).await, 101);
}

#[tokio::test]
async fn websocket_with_foreign_origin_is_refused_even_with_the_token() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let query = format!("?token={TOKEN}");
    for origin in ["https://evil.example", "null", "file://", "http://127.0.0.1:1"] {
        assert_eq!(status(port, upgrade(&query, &host, Some(origin))).await, 403, "{origin}");
    }
}

#[tokio::test]
async fn websocket_with_a_rebinding_host_is_refused() {
    let port = listener().await;
    let query = format!("?token={TOKEN}");
    let host = format!("evil.example:{port}");
    assert_eq!(status(port, upgrade(&query, &host, None)).await, 403);
}

#[tokio::test]
async fn websocket_without_or_with_a_wrong_token_is_refused() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    assert_eq!(status(port, upgrade("", &host, None)).await, 401);
    assert_eq!(status(port, upgrade("?token=wrong", &host, None)).await, 401);
}

#[tokio::test]
async fn dashboard_page_needs_token_and_own_origin() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let query = format!("?token={TOKEN}");
    assert_eq!(status(port, page(&query, &host, None)).await, 200);
    assert_eq!(status(port, page("", &host, None)).await, 401);
    assert_eq!(status(port, page(&query, &host, Some("https://evil.example"))).await, 403);
    assert_eq!(status(port, page(&query, "evil.example", None)).await, 403);
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
    let query = format!("{long}?token={TOKEN}");
    let request = upgrade(&query, &host, Some("https://evil.example"));
    assert_eq!(status(port, request).await, 403);
}

#[tokio::test]
async fn a_page_request_with_large_localhost_cookies_is_served() {
    let port = listener().await;
    let host = format!("127.0.0.1:{port}");
    let cookie = format!("Cookie: c={}\r\n", "x".repeat(12 * 1024));
    let request = format!("GET /?token={TOKEN} HTTP/1.1\r\nHost: {host}\r\n{cookie}\r\n");
    assert_eq!(status(port, request).await, 200);
}

#[test]
fn dev_origins_are_loopback_http_with_a_port_only() {
    use acpmux::server::dev_origin;
    assert_eq!(dev_origin("http://127.0.0.1:4176/").unwrap(), "http://127.0.0.1:4176");
    assert_eq!(dev_origin("http://LOCALHOST:5173").unwrap(), "http://localhost:5173");
    for bad in [
        "https://127.0.0.1:4176",
        "http://evil.example:4176",
        "http://127.0.0.1",
        "http://localhost:80",
        "null",
        "cmux-agent://pane",
        "http://user@localhost:5173",
    ] {
        assert!(dev_origin(bad).is_err(), "{bad}");
    }
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
    let query = format!("?token={TOKEN}");
    assert_eq!(status(port, upgrade(&query, &host, Some("http://127.0.0.1:4176"))).await, 101);
    let plain = listener().await;
    let host = format!("127.0.0.1:{plain}");
    assert_eq!(status(plain, upgrade(&query, &host, Some("http://127.0.0.1:4176"))).await, 403);
}
