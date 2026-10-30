//! What keeps a session awake (`idle_eligible`): each of the gates a hub test can hold by hand.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

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

/// A ready chat with nothing going on is idle; an agent request waiting on its answer, a
/// sub-session at work, a stored-less Claude chat with turns, and a queued prompt each keep it.
#[tokio::test]
async fn each_gate_keeps_a_session_awake() {
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session), "a ready chat with nothing going on");
    {
        let _asked = AgentRequest::new(&session);
        assert!(!hub.idle_eligible(&session), "an agent request on its way");
    }
    assert!(hub.idle_eligible(&session));
    *session.work_below_since.lock().unwrap() = 1;
    assert!(!hub.idle_eligible(&session), "a sub-session at work");
    *session.work_below_since.lock().unwrap() = 0;
    {
        let mut m = session.meta.lock().unwrap();
        m.claude_unstored = true;
        m.turn_count = 1;
    }
    assert!(!hub.idle_eligible(&session), "a Claude chat whose turns are not stored");
    session.meta.lock().unwrap().claude_unstored = false;
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.idle_eligible(&session), "a queued prompt");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    assert!(hub.idle_eligible(&session));
    hub.shutdown_all().await;
}

/// A chat stored as hibernated comes back marked (it wakes on a click after a restart), and
/// clearing the hibernation drops the mark, a cause a wake recorded, and the stored flag.
#[tokio::test]
async fn a_stored_hibernation_comes_back_and_clearing_it_drops_every_trace() {
    let (hub, session) = chat().await;
    let mut meta = session.meta();
    meta.hibernated_ms = 1;
    meta.id = format!("{}-restored", meta.id);
    let restored = hub.make_session(meta);
    assert_ne!(restored.hibernated_at.load(Ordering::SeqCst), 0, "a restart lost the hibernation");
    hub.wake_cause(&restored, "click");
    hub.clear_hibernation(&restored);
    assert_eq!(restored.hibernated_at.load(Ordering::SeqCst), 0);
    assert!(restored.wake_cause.lock().unwrap().is_none(), "a stale wake cause");
    assert_eq!(restored.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}
