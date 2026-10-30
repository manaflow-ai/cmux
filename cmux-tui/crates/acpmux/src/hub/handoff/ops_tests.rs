//! A handoff's start under the write rule (`hub/request_writes.rs`):
//! `cargo test -p acpmux handoff_start_waits`.

use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::config::{Config, StoreMode};
use crate::hub::{Control, Hub, request_writes};
use crate::rpc::{Message, method};

/// A hub with two fake harnesses of different families (a handoff goes to another family), and
/// a session on the first one, made over a connection as a client makes it.
async fn hub_with_source() -> (Arc<Hub>, String) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fsource": {"argv": ["python3", fake], "family": "source"},
            "ftarget": {"argv": ["python3", fake], "family": "target"},
        },
        "defaultHarness": "fsource",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(256);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let line = out_rx.recv().await.expect("the session/new reply");
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == 1 {
            let id = reply["result"]["sessionId"].as_str().expect("a session id").to_owned();
            // The connection stays open while the test runs: its sender lives in a task.
            tokio::spawn(async move {
                let _keep = in_tx;
                std::future::pending::<()>().await;
            });
            return (hub, id);
        }
    }
}

/// Third review: a handoff's prompt runs on a spawned task, so the request that answers
/// "started" must wait for the target's records up to the acceptance, and count as committed
/// work (a retry would hand off twice).
#[tokio::test]
async fn handoff_start_waits_for_the_targets_prompt_records() {
    let (hub, source) = hub_with_source().await;
    let p = json!({"sessionId": source, "harness": "ftarget", "handoffKey": "k-writes"});
    let prepared = hub.handoff_prepare(&p, false).await.expect("prepare");
    let id = prepared["handoffId"].as_str().expect("a handoff id").to_owned();
    let target = prepared["target"]["sessionId"].as_str().expect("a target").to_owned();
    let start = json!({"handoffId": id, "revision": 1,
                       "checkpoint": {"ref": "abc123", "attest": true}});
    let (started, writes) = request_writes::scope(Box::pin({
        let hub = hub.clone();
        async move { hub.handoff_start(&start, Control::Local).await }
    }))
    .await;
    let started = started.expect("start");
    assert_eq!(started["outcome"], json!("started"), "{started}");
    // The record of the handoff's prompt in the target's log (its user message or its place in
    // the queue), which the acceptance comes after.
    let prompt_id = started["promptId"].as_str().expect("a prompt id").to_owned();
    let events = hub.store.events(&target, 0, usize::MAX).expect("the target's log");
    let prompt_seq = events
        .iter()
        .find(|e| {
            matches!(e.kind.as_str(), "user_message" | "queued")
                && e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id.as_str())
        })
        .map(|e| e.seq)
        .unwrap_or_else(|| panic!("no record of the handoff's prompt: {events:?}"));
    assert!(
        writes.noted(&target).is_some_and(|seq| seq >= prompt_seq),
        "the handoff answered `started` before its prompt's record {prompt_seq} was waited for: \
         {writes:?}"
    );
    assert!(writes.kept(), "a started handoff is committed work");
}
