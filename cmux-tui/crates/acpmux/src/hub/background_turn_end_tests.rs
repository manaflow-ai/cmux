//! A turn the agent runs on its own (`background_turn.rs`) always gets its `ended` record: when
//! its agent process exits (a direct agent's exit, not only a hosted one's), and when its chat
//! closes. Without it the pane's background line spun on in an idle or closed chat.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

/// A hub with one open chat whose stand-in agent is running.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

async fn send(session: &Session, item: Inbound) {
    session.inbound_tx.send(item).await.unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    applied.await.unwrap();
}

fn last_seq(hub: &Hub, session: &Session) -> u64 {
    hub.events(&session.id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq)
}

/// The background-turn records logged after `seq`.
fn marks(hub: &Hub, session: &Session, seq: u64) -> Vec<Value> {
    hub.events(&session.id, seq, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == background_turn::RECORD_KIND)
        .map(|e| e.msg)
        .collect()
}

/// The agent starts work with no acpmux turn: a background turn starts.
fn start_background(hub: &Hub, session: &Session) {
    hub.background_turn_update(
        session,
        &json!({"sessionUpdate": "agent_message_chunk", "messageId": "m1",
                "content": {"type": "text", "text": "Checking the deploy"}}),
    );
}

#[tokio::test]
async fn a_direct_agents_exit_ends_its_background_turn() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let seq = last_seq(&hub, &session);
    start_background(&hub, &session);
    session.harness_turn.store(true, Ordering::SeqCst);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;

    let logged = marks(&hub, &session, seq);
    assert_eq!(logged.len(), 2, "a started and an ended record: {logged:?}");
    assert_eq!(logged[0]["state"], "started");
    assert_eq!(logged[1]["state"], "ended");
    assert_eq!(logged[1]["id"], logged[0]["id"]);
    assert_eq!(logged[1]["reason"], "exit");
    assert!(!session.harness_turn.load(Ordering::SeqCst), "no turn of its own runs after its exit");
}

#[tokio::test]
async fn closing_a_chat_ends_its_background_turn_once() {
    let (hub, session) = chat().await;
    let seq = last_seq(&hub, &session);
    start_background(&hub, &session);
    hub.kill(&session, false).await.unwrap();
    // The killed agent's own exit may land after the close: it ends nothing more.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let logged = marks(&hub, &session, seq);
    let ended: Vec<_> = logged.iter().filter(|m| m["state"] == "ended").collect();
    assert_eq!(ended.len(), 1, "one ended record: {logged:?}");
    assert_eq!(ended[0]["id"], logged[0]["id"]);
    assert_eq!(session.status(), SessionStatus::Closed);
}

#[tokio::test]
async fn an_exit_with_no_background_turn_logs_none() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let seq = last_seq(&hub, &session);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;
    assert!(marks(&hub, &session, seq).is_empty());
}
