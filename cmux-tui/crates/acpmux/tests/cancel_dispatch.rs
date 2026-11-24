//! `_acpmux/dispatch` makes its chat with a `session/new` of its own, which runs on a task of
//! its own (`server::requests::request_on_own_task`, so its poll frame is not stacked on the
//! dispatch's). A client that cancels the dispatch while that chat is still starting gets the
//! cancelled error, and the chat is not left behind: the inner task is aborted with the request,
//! and the half-made chat is discarded as when the request awaited it in place.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs the stand-in agent (tests/fake_agent.py) in its hub.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const WAIT: Duration = Duration::from_secs(30);
/// JSON-RPC's RequestCancelled (LSP).
const REQUEST_CANCELLED: i64 = -32800;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cancelled_dispatch_leaves_no_chat_behind() {
    // A stand-in agent that spends 5 s before it reads its first line: the chat is still
    // starting when the cancel comes.
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "env": {"FAKE_BOOT_CPU_MS": "5000"}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(64);
    let (out_tx, mut out) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), rx, out_tx, Origin::Local));

    let cwd = std::env::temp_dir().to_string_lossy().into_owned();
    let dispatch = json!({"brief": "hello", "briefId": "brief-c1", "host": "local", "cwd": cwd});
    tx.send(Message::request(1, "_acpmux/dispatch", dispatch).to_line()).await.unwrap();
    let deadline = tokio::time::Instant::now() + WAIT;
    while hub.sessions().is_empty() {
        assert!(tokio::time::Instant::now() < deadline, "the dispatch's chat never started");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let cancel = Message::notification("$/cancel_request", json!({"requestId": 1}));
    tx.send(cancel.to_line()).await.unwrap();

    let answer = loop {
        let line = tokio::time::timeout(WAIT, out.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v["id"] == json!(1) {
            break v;
        }
    };
    assert_eq!(answer["error"]["code"], json!(REQUEST_CANCELLED), "{answer}");

    let deadline = tokio::time::Instant::now() + WAIT;
    while !hub.sessions().is_empty() {
        let ids: Vec<_> = hub.sessions().iter().map(|s| s.id.clone()).collect();
        assert!(tokio::time::Instant::now() < deadline, "left behind: {ids:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
