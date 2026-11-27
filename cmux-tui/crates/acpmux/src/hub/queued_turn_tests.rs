use super::*;
use crate::hub::{Control, NewRequest, TurnInfo};

/// A session of a test hub whose turn `turn-1` runs and has written its prompt.
async fn written_turn() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"}))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    *session.turn.lock().unwrap() =
        Some(TurnInfo::prompted("person", "hi", "turn-1", "p-1", Control::Local));
    hub.prompt_line_written(&session);
    (hub, session)
}

fn lifecycle(hub: &Arc<Hub>, session: &Arc<Session>, command: &str, state: &str) {
    hub.command_lifecycle(session, &json!({"command_uuid": command, "state": state}));
}

/// The `turn_queued` records `session`'s log holds.
fn queued(hub: &Hub, session: &Session) -> Vec<Value> {
    let mut out = Vec::new();
    let _ = hub.store.scan_kinds(&session.id, &["turn_queued"], &mut |e: EventRecord| {
        out.push(e.msg);
        true
    });
    out
}

const PAST_HELD: std::time::Duration = std::time::Duration::from_millis(1_300);

/// An idle chat: Claude Code starts the line at once, and the turn is never queued.
#[tokio::test]
async fn a_line_started_at_once_is_not_queued() {
    let (hub, session) = written_turn().await;
    lifecycle(&hub, &session, "line-1", "queued");
    lifecycle(&hub, &session, "line-1", "started");
    tokio::time::sleep(PAST_HELD).await;
    assert!(queued(&hub, &session).is_empty());
}

/// A line still held past `HELD`: the turn is queued behind the agent's work, once, and the
/// model's next sign ends it (`turn_heard`). A steered line's own hold is not the turn's.
#[tokio::test]
async fn a_held_line_logs_its_turn_queued_busy() {
    let (hub, session) = written_turn().await;
    lifecycle(&hub, &session, "line-1", "queued");
    lifecycle(&hub, &session, "steer-1", "queued");
    tokio::time::sleep(PAST_HELD).await;
    assert_eq!(queued(&hub, &session), [json!({"turnId": "turn-1", "on": "busy"})]);
    assert_eq!(session.silent_turn.lock().unwrap().as_deref(), Some("turn-1"));
    lifecycle(&hub, &session, "line-1", "started");
    lifecycle(&hub, &session, "line-2", "queued");
    tokio::time::sleep(PAST_HELD).await;
    assert_eq!(queued(&hub, &session).len(), 1, "only the turn's prompt line counts");
}

/// Held while a compaction runs: queued on the compaction.
#[tokio::test]
async fn a_line_held_by_a_compaction_logs_compacting() {
    let (hub, session) = written_turn().await;
    session.compacting.store(true, Ordering::SeqCst);
    lifecycle(&hub, &session, "line-1", "queued");
    tokio::time::sleep(PAST_HELD).await;
    assert_eq!(queued(&hub, &session), [json!({"turnId": "turn-1", "on": "compacting"})]);
}
