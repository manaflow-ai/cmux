//! RFD 0063 item 4: a move whose target the hub knows deleted ends on the watch's next ask,
//! given back here with reason `target_deleted`, with no offer to the person first.

use super::*;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

async fn until(out: &mut mpsc::Receiver<String>, pred: impl Fn(&Value) -> bool) -> Value {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), out.recv()).await;
        let line = line.expect("timed out").expect("connection closed");
        let value: Value = serde_json::from_str(&line).unwrap();
        if pred(&value) {
            return value;
        }
    }
}

#[tokio::test]
async fn a_move_whose_target_is_known_deleted_is_given_back_with_no_offer() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let send = |id: i64, m: &str, params: Value| Message::request(id, m, params).to_line();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(send(1, method::SESSION_NEW, new)).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();

    // A move to a daemon that is gone: no ask is answered; the hub's answer says deleted.
    let begin = json!({"sessionId": session.id, "interrupt": true,
                       "to": {"socket": "/tmp/acpmux-deleted-target.sock"}});
    let bundle = hub.transfer_request("_acpmux/transfer_begin", &begin).await.unwrap();
    let transfer_id = bundle["transferId"].as_str().unwrap().to_owned();
    test_seam::set(&transfer_id, TargetSays::Deleted);
    hub.set_transfer_lease(Duration::from_secs(1));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while session.moving().is_some() {
        assert!(tokio::time::Instant::now() < deadline, "the move to a deleted target never ended");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let kinds = |kind: &str| -> Vec<Value> {
        hub.events(&session.id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == kind)
            .map(|e| e.msg)
            .collect()
    };
    let aborted = kinds("transfer_aborted");
    assert_eq!(aborted.len(), 1, "{aborted:?}");
    assert_eq!(aborted[0]["reason"], "target_deleted", "{aborted:?}");
    assert!(kinds("transfer_undecided").is_empty(), "a deleted target is no question");
    hub.shutdown_all().await;
}
