//! A close is final against the writers that race it: a turn's end and an agent's exit
//! (`Hub::set_status_unless_closed`). Before, each read `status()` and then wrote its own
//! status, so a close between the two came back `disconnected` or `idle`
//! (subsessions.rs agents_start_children_within_their_width_and_depth_limits).

use super::*;
use serde_json::json;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn session(hub: &Hub, id: &str, status: &str) -> Arc<Session> {
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 0, "updatedAt": 0,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

fn status_records(hub: &Hub, id: &str) -> Vec<Value> {
    hub.events(id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "status")
        .map(|e| e.msg["status"].clone())
        .collect()
}

#[tokio::test]
async fn a_closed_session_stays_closed_when_its_turn_ends_or_its_agent_exits_after_the_close() {
    let hub = hub();
    let s = session(&hub, "closed-race", "running");
    // The close lands first; the turn's end and the agent's exit write after it.
    hub.set_status(&s, SessionStatus::Closed);
    hub.set_status_unless_closed(&s, SessionStatus::Disconnected);
    hub.set_status_unless_closed(&s, SessionStatus::Idle);
    hub.set_status_unless_closed(&s, SessionStatus::Ready);
    assert_eq!(s.status(), SessionStatus::Closed);
    assert_eq!(status_records(&hub, "closed-race"), vec![json!("closed")]);
}

#[tokio::test]
async fn a_session_that_is_not_closed_takes_the_status() {
    let hub = hub();
    let s = session(&hub, "open", "running");
    hub.set_status_unless_closed(&s, SessionStatus::Disconnected);
    assert_eq!(s.status(), SessionStatus::Disconnected);
    assert_eq!(status_records(&hub, "open"), vec![json!("disconnected")]);
}
