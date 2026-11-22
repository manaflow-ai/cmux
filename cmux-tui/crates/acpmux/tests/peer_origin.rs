//! ACP-REMOTE-GUARD P1: a peer daemon is `Origin::Peer` only with this
//! launch's peer token in the `x-acpmux-peer-token` header, next to the
//! dashboard token. The dashboard token alone, which every Web client
//! holds, never makes a peer, and no RPC returns the peer token.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::server::peer_auth::{HEADER, PeerAuth, token_path};
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const TOKEN: &str = "0123456789abcdef";

fn home(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("apo-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A listener with a peer token; returns its port and the token.
async fn listener(tag: &str) -> (u16, String) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub: Arc<Hub> = Hub::new(config, store);
    let h = home(tag);
    let auth = PeerAuth::create(&h).unwrap();
    let peer_token = std::fs::read_to_string(token_path(&h)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(hub, l, TOKEN.into(), auth));
    (port, peer_token)
}

/// Connect with `headers` (and `query`), send `first` (else a plain
/// `initialize`) and the requests in `then`; return every reply by id.
async fn session(
    port: u16,
    query: &str,
    headers: &[(&str, &str)],
    first: Option<Value>,
    then: &[(&str, Value)],
) -> Result<Vec<Value>, String> {
    let mut req = format!("ws://127.0.0.1:{port}/{query}").into_client_request().unwrap();
    for (k, v) in headers {
        let name = tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes());
        req.headers_mut().append(name.unwrap(), v.parse().unwrap());
    }
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await.map_err(|e| e.to_string())?;
    let init = first.unwrap_or_else(|| {
        json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}})
    });
    ws.send(Frame::Text(init.to_string().into())).await.unwrap();
    for (i, (m, p)) in then.iter().enumerate() {
        let r = json!({"jsonrpc": "2.0", "id": i + 1, "method": m, "params": p});
        ws.send(Frame::Text(r.to_string().into())).await.unwrap();
    }
    let mut replies = vec![Value::Null; then.len() + 1];
    let mut left = then.len() + 1;
    while left > 0 {
        let frame = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("a reply")
            .expect("open")
            .unwrap();
        let Frame::Text(t) = frame else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if let Some(id) = v.get("id").and_then(Value::as_u64) {
            replies[id as usize] = v;
            left -= 1;
        }
    }
    Ok(replies)
}

async fn origin(port: u16, query: &str, headers: &[(&str, &str)], first: Option<Value>) -> String {
    let r = session(port, query, headers, first, &[]).await.unwrap();
    r[0]["result"]["_meta"]["acpmux"]["origin"].as_str().unwrap_or_default().to_owned()
}

fn bearer() -> (&'static str, String) {
    ("authorization", format!("Bearer {TOKEN}"))
}

#[tokio::test]
async fn the_peer_token_header_with_the_dashboard_token_makes_a_peer() {
    let (port, peer) = listener("ok").await;
    let (a, b) = bearer();
    assert_eq!(origin(port, "", &[(a, &b), (HEADER, &peer)], None).await, "peer");
}

#[tokio::test]
async fn a_web_connection_with_the_dashboard_token_stays_web() {
    let (port, peer) = listener("web").await;
    let (a, b) = bearer();
    // The dashboard token alone.
    assert_eq!(origin(port, "", &[(a, &b)], None).await, "remote");
    // The peer marker without the peer token, or with a wrong or empty one.
    for wrong in ["", "x", &"0".repeat(64)] {
        assert_eq!(
            origin(port, "", &[(a, &b), (HEADER, wrong)], None).await,
            "remote",
            "{wrong:?}"
        );
    }
    // The token twice in two headers.
    assert_eq!(
        origin(port, "", &[(a, &b), (HEADER, &peer), (HEADER, &peer)], None).await,
        "remote"
    );
    // The right token anywhere but the header: the first frame, the query.
    let init = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {"protocolVersion": 1, "_meta": {"acpmux": {"peerToken": peer}}}});
    assert_eq!(origin(port, "", &[(a, &b)], Some(init)).await, "remote");
    let query = format!("?token={TOKEN}&peerToken={peer}");
    assert_eq!(origin(port, &query, &[], None).await, "remote");
}

#[tokio::test]
async fn the_peer_token_without_the_dashboard_token_is_refused() {
    let (port, peer) = listener("nodash").await;
    assert!(session(port, "", &[(HEADER, &peer)], None, &[]).await.is_err());
    let wrong = ("authorization", "Bearer wrong");
    assert!(session(port, "", &[wrong, (HEADER, &peer)], None, &[]).await.is_err());
}

#[tokio::test]
async fn no_rpc_returns_the_peer_token_to_a_web_connection() {
    let (port, peer) = listener("leak").await;
    let (a, b) = bearer();
    let reads = [
        ("_acpmux/status", json!({})),
        ("_acpmux/sessions", json!({})),
        ("_acpmux/peers", json!({})),
        ("_acpmux/harnesses", json!({})),
        ("_acpmux/defaults", json!({})),
        ("_acpmux/presets", json!({})),
        ("_acpmux/schema", json!({})),
        ("_acpmux/import", json!({"path": "run/peer.token"})),
    ];
    let replies = session(port, "", &[(a, &b)], None, &reads).await.unwrap();
    for (r, (m, _)) in replies.iter().skip(1).zip(reads.iter()) {
        assert!(!r.to_string().contains(&peer), "{m} returned the peer token: {r}");
    }
}
