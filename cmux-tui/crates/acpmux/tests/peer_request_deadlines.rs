//! A live link can answer pings while its request handler hangs. Creation and brief listing
//! must return on their own budgets, without dropping the peer or leaking pending replies.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Ws;

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3",
            concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn call(hub: &Arc<Hub>, method: &str, params: Value) -> Value {
    let (tx, rx) = mpsc::channel(64);
    let (out, mut replies) = mpsc::channel(4096);
    let task = tokio::spawn(serve_connection(hub.clone(), rx, out));
    tx.send(Message::request(1, method, params).to_line()).await.unwrap();
    let result = loop {
        let line = replies.recv().await.unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            break v;
        }
    };
    task.abort();
    result
}

/// Handshakes and pings succeed; a requested method can hang indefinitely. The count channel
/// lets a test prove every peer was asked before any of the stalled requests timed out.
async fn peer(
    hub: &Arc<Hub>,
    name: &str,
    hang: bool,
    seen: mpsc::UnboundedSender<String>,
) -> tokio::task::JoinHandle<()> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let label = name.to_owned();
    let task = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        while let Some(Ok(frame)) = ws.next().await {
            let Ws::Text(text) = frame else { continue };
            let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                continue;
            };
            let result = match m.as_str() {
                method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                    "origin": "peer", "features": []}}}),
                method::MUX_WATCH => json!({"sessions": []}),
                method::SESSION_NEW | method::MUX_BRIEFS => {
                    seen.send(label.clone()).unwrap();
                    if hang {
                        continue;
                    }
                    if m == method::SESSION_NEW {
                        json!({"sessionId": "created"})
                    } else {
                        json!({"briefs": [{"briefId": "healthy", "status": "running"}]})
                    }
                }
                _ => json!({}),
            };
            if ws.send(Ws::Text(Message::ok(id, result).to_line().into())).await.is_err() {
                break;
            }
        }
    });
    hub.add_peer(name, &format!("ws://127.0.0.1:{port}"), Some("token".into()), None, true)
        .await
        .unwrap();
    assert!(hub.peer_by_name(name).unwrap().link().is_ready());
    task
}

fn run(f: impl std::future::Future<Output = ()>) {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
        .block_on(f);
}

#[test]
fn hung_peer_session_new_returns_readable_error_within_deadline() {
    run(async {
        let hub = hub();
        let (tx, _rx) = mpsc::unbounded_channel();
        let task = peer(&hub, "hung", true, tx).await;
        let started = tokio::time::Instant::now();
        let reply = tokio::time::timeout(
            Duration::from_secs(35),
            call(&hub, method::SESSION_NEW, json!({"_meta": {"acpmux": {"peer": "hung"}}})),
        )
        .await
        .expect("session/new must not wait for the generic 600-second peer timeout");
        assert!(started.elapsed() >= Duration::from_secs(29));
        assert_eq!(reply["error"]["data"]["reason"], "peer_start_timeout", "{reply}");
        let message = reply["error"]["message"].as_str().unwrap();
        assert!(message.contains("hung") && message.contains("30 seconds"), "{message}");
        assert!(message.contains("may still") && message.contains("before retrying"), "{message}");
        let peer = hub.peer_by_name("hung").unwrap();
        assert!(peer.link().is_ready());
        tokio::task::yield_now().await;
        assert_eq!(peer.pending_requests().await, 0);
        hub.remove_peer("hung").await.unwrap();
        task.abort();
    });
}

#[test]
fn briefs_asks_all_peers_in_parallel_and_keeps_healthy_rows_within_total_budget() {
    run(async {
        let hub = hub();
        let local = call(
            &hub,
            method::MUX_DISPATCH,
            json!({"brief": "say hi", "title": "local brief", "host": "local",
                "cwd": std::env::temp_dir(), "harness": "fake"}),
        )
        .await;
        let local_id = local["result"]["brief"]["briefId"].as_str().unwrap();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut tasks = Vec::new();
        for name in ["hung-a", "healthy", "hung-b"] {
            tasks.push(peer(&hub, name, name != "healthy", tx.clone()).await);
        }
        let request_hub = hub.clone();
        let request =
            tokio::spawn(async move { call(&request_hub, method::MUX_BRIEFS, json!({})).await });
        for _ in 0..3 {
            tokio::time::timeout(Duration::from_secs(2), rx.recv())
                .await
                .expect("brief listing must ask all peers without waiting for the hung one")
                .unwrap();
        }
        let reply = tokio::time::timeout(Duration::from_secs(12), request)
            .await
            .expect("all peers share a 10-second budget")
            .unwrap();
        let rows = reply["result"]["briefs"].as_array().unwrap();
        for id in [local_id, "healthy"] {
            assert!(rows.iter().any(|row| row["briefId"] == id), "{reply}");
        }
        tokio::task::yield_now().await;
        for name in ["hung-a", "healthy", "hung-b"] {
            let peer = hub.peer_by_name(name).unwrap();
            assert!(peer.link().is_ready());
            assert_eq!(peer.pending_requests().await, 0);
            hub.remove_peer(name).await.unwrap();
        }
        for task in tasks {
            task.abort();
        }
    });
}
