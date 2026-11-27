//! Keyed updates keep the existing drained restart and app re-enrollment protocol.
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::{Arc, atomic::Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(config, store)
}

async fn reply(output: &mut mpsc::Receiver<String>, id: u64) -> Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let line = output.recv().await.expect("update connection remains open");
            let answer: Value = serde_json::from_str(&line).unwrap();
            if answer["id"] == json!(id) {
                return answer;
            }
        }
    })
    .await
    .expect("update answers within its test bound")
}

#[tokio::test]
async fn keyed_exec_request_drains_then_keeps_restart_and_reenrollment() {
    let old = hub();
    let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    old.person.install_spawn_key(key).unwrap();
    let held = old.update_admission.admit().unwrap();
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(32);
    let server = tokio::spawn(super::super::serve_connection_with(
        old.clone(),
        incoming,
        output,
        super::super::Origin::Local,
    ));
    input.send(Message::request(1, method::INITIALIZE, json!({
        "protocolVersion": 1, "clientInfo": {"name": "keyed-update-test", "version": "0"}
    })).to_line()).await.unwrap();
    assert!(reply(&mut outgoing, 1).await.get("error").is_none());
    input
        .send(
            Message::request(
                2,
                method::MUX_SHUTDOWN,
                json!({
                    "restart": true, "execUpdate": true, "reason": "keyed update regression"
                }),
            )
            .to_line(),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while old.update_admission.admit().is_ok() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("update closes admission before waiting for accepted work");
    assert!(!old.restart_requested.load(Ordering::SeqCst));
    drop(held);
    let answer = reply(&mut outgoing, 2).await;
    assert!(answer.get("error").is_none(), "{answer}");
    assert_eq!(answer["result"]["execUpdate"], false, "{answer}");
    assert!(old.restart_requested.load(Ordering::SeqCst));
    assert!(old.person.has_key(), "the old daemon never exports or clears its key");
    assert!(old.update_admission.admit().is_err(), "handoff keeps admission fenced");
    // The successor gets its key from the app through the existing verified enrollment,
    // independently of the old process. This is the same path used after keyed takeover.
    let next = hub();
    assert!(!next.person.has_key());
    assert_eq!(next.person.enroll(key, true).unwrap()["via"], "signature");
    assert!(next.person.has_key());
    drop(input);
    drop(outgoing);
    tokio::time::timeout(Duration::from_secs(5), server).await.unwrap().unwrap();
    old.close_owned_tasks().await;
    next.close_owned_tasks().await;
}
