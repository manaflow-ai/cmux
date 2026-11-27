//! A Claude Code /loop's goal ends with the agent process that runs the loop (`loop_goal.rs`),
//! also when a forced Stop restart drops the stopped agent's own clear (`cancel.rs`).

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

fn goal_update(agent: u64, goal: Value) -> Inbound {
    let update = json!({"sessionUpdate": "session_info_update", "_meta": {"goal": goal}});
    Inbound::Notification {
        method: method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "agent-session", "update": update})),
        agent,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    }
}

/// The `_meta.goal` of each logged session_info_update after `seq`.
fn logged_goals(hub: &Hub, session: &Session, seq: u64) -> Vec<Value> {
    hub.events(&session.id, seq, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "in" && e.kind == "session_info_update")
        .filter_map(|e| e.msg.pointer("/params/update/_meta/goal").cloned())
        .collect()
}

/// The `kind` the chat's goal keeps (`"loop"` for a Claude Code /loop).
fn goal_kind(session: &Session) -> Option<String> {
    session.meta().goal?.extra.get("kind").and_then(Value::as_str).map(str::to_owned)
}

fn last_seq(hub: &Hub, session: &Session) -> u64 {
    hub.events(&session.id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq)
}

#[tokio::test]
async fn a_forced_stop_restart_ends_the_loop_goal_its_agent_dropped() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let looping = json!({"kind": "loop", "status": "active", "objective": "check the deploy", "nextRunAt": 9});
    send(&session, goal_update(child.generation, looping)).await;
    assert_eq!(goal_kind(&session).as_deref(), Some("loop"));

    // The forced restart (`cancel.rs`): the stopped agent's own clear at its exit is dropped.
    session.stopped_agent.store(child.generation, Ordering::SeqCst);
    send(&session, goal_update(child.generation, Value::Null)).await;
    assert!(session.meta().goal.is_some(), "the stopped agent's updates are dropped");
    let seq = last_seq(&hub, &session);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;

    assert_eq!(session.meta().goal, None, "the loop died with its process");
    assert_eq!(logged_goals(&hub, &session, seq), vec![Value::Null], "clients see it end");
}

#[tokio::test]
async fn an_exit_keeps_a_goal_that_is_not_a_loop() {
    let (hub, session) = chat().await;
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let goal = json!({"status": "active", "objective": "Ship the fix"});
    send(&session, goal_update(child.generation, goal)).await;
    let seq = last_seq(&hub, &session);
    send(&session, Inbound::Exited { pid: child.pid, code: None, host_seq: None }).await;
    assert_eq!(
        session.meta().goal.map(|goal| goal.objective).as_deref(),
        Some("Ship the fix"),
        "a harness's persisted goal outlives its process"
    );
    assert!(logged_goals(&hub, &session, seq).is_empty());
}
