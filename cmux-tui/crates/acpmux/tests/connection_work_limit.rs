//! A single client cannot create unbounded request work or starve another client.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

struct Fixture {
    root: std::path::PathBuf,
    hub: Arc<Hub>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn fixture() -> Fixture {
    use std::os::unix::fs::PermissionsExt;

    let root =
        std::env::temp_dir().join(format!("acpmux-connection-limit-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.join("config.json");
    std::fs::write(&config, "{}").unwrap();
    std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut cfg = Config::load_from_with(&config, &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, &root).unwrap();
    Fixture { root, hub: Hub::new(cfg, store) }
}

#[tokio::test(flavor = "current_thread")]
async fn a_request_burst_gets_busy_replies_and_does_not_block_another_connection() {
    let fixture = fixture();
    let hub = fixture.hub.clone();
    let (tx, inbound) = mpsc::channel(128);
    let (out, mut replies) = mpsc::channel(128);

    // Fill the inbound channel before starting the server. On the current
    // thread, the server can admit the queued frames without polling its
    // spawned handlers, so the in-flight limit is exercised deterministically.
    for id in 1..=80 {
        tx.try_send(Message::request(id, "_acpmux/unknown", json!({})).to_line()).unwrap();
    }
    drop(tx);
    let server = tokio::spawn(serve_connection(hub.clone(), inbound, out));

    let (other_tx, other_inbound) = mpsc::channel(1);
    let (other_out, mut other_replies) = mpsc::channel(1);
    let other = tokio::spawn(serve_connection(hub, other_inbound, other_out));
    other_tx.send(Message::request(1, "_acpmux/unknown", json!({})).to_line()).await.unwrap();
    drop(other_tx);

    let other_reply =
        tokio::time::timeout(Duration::from_secs(3), other_replies.recv()).await.unwrap().unwrap();
    let other_reply: Value = serde_json::from_str(&other_reply).unwrap();
    assert_eq!(other_reply["error"]["code"], -32601, "{other_reply}");

    let mut busy = 0;
    let mut handled = 0;
    for _ in 0..80 {
        let line =
            tokio::time::timeout(Duration::from_secs(3), replies.recv()).await.unwrap().unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        match reply["error"]["data"]["reason"].as_str() {
            Some("connection.busy") => {
                assert_eq!(reply["error"]["data"]["retryable"], true);
                busy += 1;
            }
            _ => {
                assert_eq!(reply["error"]["code"], -32601, "{reply}");
                handled += 1;
            }
        }
    }
    assert_eq!((handled, busy), (64, 16));
    tokio::time::timeout(Duration::from_secs(3), server).await.unwrap().unwrap();
    tokio::time::timeout(Duration::from_secs(3), other).await.unwrap().unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn notification_flood_does_not_delay_a_later_request() {
    let fixture = fixture();
    let (tx, inbound) = mpsc::channel(256);
    let (out, mut replies) = mpsc::channel(8);

    for _ in 0..(16 + 64 + 16) {
        tx.send(Message::notification("session/update", json!({})).to_line()).await.unwrap();
    }
    tx.send(Message::request(1, "_acpmux/unknown", json!({})).to_line()).await.unwrap();
    drop(tx);

    let server = tokio::spawn(serve_connection(fixture.hub.clone(), inbound, out));
    let line = tokio::time::timeout(Duration::from_secs(1), replies.recv()).await.unwrap().unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["error"]["code"], -32601, "{reply}");
    tokio::time::timeout(Duration::from_secs(3), server).await.unwrap().unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn cancellation_is_admitted_when_notification_queue_is_full() {
    let fixture = fixture();
    let (tx, inbound) = mpsc::channel(256);
    let (out, mut replies) = mpsc::channel(8);

    for _ in 0..(16 + 64) {
        tx.send(Message::notification("session/update", json!({})).to_line()).await.unwrap();
    }
    tx.send(
        Message::notification("session/cancel", json!({"sessionId": "missing-session"})).to_line(),
    )
    .await
    .unwrap();
    tx.send(Message::request(1, "_acpmux/unknown", json!({})).to_line()).await.unwrap();
    drop(tx);

    let server = tokio::spawn(serve_connection(fixture.hub.clone(), inbound, out));
    let line = tokio::time::timeout(Duration::from_secs(1), replies.recv()).await.unwrap().unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["error"]["code"], -32601, "{reply}");
    tokio::time::timeout(Duration::from_secs(3), server).await.unwrap().unwrap();
}
