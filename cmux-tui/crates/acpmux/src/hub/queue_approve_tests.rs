//! A prompt that waits for the owner never reaches the agent by a flag a race left on it (review
//! of #26747): its author's Send now is refused under the lock that would make it a steer, a steer
//! flag forced on it lets nothing out (`queue_turn`, `take_queued`), and once approved it runs in
//! its place as a queued prompt, never as a steer.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// The first message on `out` that `pred` matches.
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

fn user_messages(hub: &Hub, session: &str, prompt_id: &str) -> Vec<Value> {
    let events = hub.events(session, 0, 10_000).unwrap();
    let mine = |e: &&EventRecord| e.kind == "user_message" && e.msg["promptId"] == prompt_id;
    events.iter().filter(mine).map(|e| e.msg.clone()).collect()
}

#[tokio::test]
async fn a_held_prompt_with_a_steer_flag_never_reaches_the_agent() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "env": {"FAKE_CLAUDE_STEER": "1"}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    let local = crate::server::Origin::Local;
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), rx, out_tx, local));
    let send = |id: i64, m: &str, params: Value| Message::request(id, m, params).to_line();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(send(1, method::SESSION_NEW, new)).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    let prompt = |id: &str, text: &str| {
        json!({"sessionId": session.id, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id}}})
    };
    tx.send(send(2, method::SESSION_PROMPT, prompt("p-run", "until-cancel"))).await.unwrap();
    until(&mut out, |v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    let guest = json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"});
    let mut held = prompt("g-1", "guest words");
    held["_meta"]["acpmux"]["author"] = guest.clone();
    held["_meta"]["acpmux"]["steer"] = json!(true);
    tx.send(send(3, method::SESSION_PROMPT, held)).await.unwrap();
    until(&mut out, |v| {
        v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "g-1"
    })
    .await;

    // Its author's Send now into the running turn: refused under the lock that would steer it.
    let now = json!({"sessionId": session.id, "promptId": "g-1", "op": "send_now",
                     "_meta": {"acpmux": {"author": guest}}});
    let refused = hub.queue_edit(&session, &now, Control::Local, false, None).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "queue.awaiting_owner");

    // A steer flag forced on it, as a lost race would leave it: nothing lets it out.
    for q in session.queue.lock().unwrap().iter_mut().filter(|q| q.prompt_id == "g-1") {
        q.steer = true;
    }
    session.queue_moved.notify_waiters();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(user_messages(&hub, &session.id, "g-1").is_empty(), "it reached the agent");
    assert!(session.queue().iter().any(|q| q.prompt_id == "g-1" && q.awaiting_owner));

    // Approved, it runs once the turn ends, in its place and not as a steer.
    hub.approve_queued(&session, "g-1", 0).unwrap();
    hub.cancel(&session).await.unwrap();
    let answer = until(&mut out, |v| v["id"] == 3).await;
    assert!(answer.get("error").is_none(), "{answer}");
    let ran = user_messages(&hub, &session.id, "g-1");
    assert_eq!(ran.len(), 1, "{ran:?}");
    assert_ne!(ran[0]["steer"], true, "it went in as a steer: {:?}", ran[0]);
}
