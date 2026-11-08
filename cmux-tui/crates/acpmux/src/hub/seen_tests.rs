use super::*;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    (hub, s)
}

/// The newest mux `status` record that says the chat was read.
fn last_read(hub: &Hub, s: &Session) -> Option<Value> {
    let events = hub.store.events(&s.id, 0, 10_000).unwrap();
    events
        .into_iter()
        .rev()
        .find(|e| e.dir == "mux" && e.kind == "status" && e.msg["read"] == json!(true))
        .map(|e| e.msg)
}

#[tokio::test]
async fn coming_back_says_where_the_person_left_off_and_how_many_turns_ended() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    hub.append(&s, "mux", "note", json!({"seen": true}));
    let left_at = s.seq.load(Ordering::SeqCst);
    hub.attach_count(&s, -1, true);
    assert_eq!(s.meta().seen_seq, Some(left_at), "leaving keeps the seq the person saw");

    // Two turns end while nobody shows it; records in between move no mark.
    for _ in 0..2 {
        hub.append(&s, "mux", "note", json!({"seen": false}));
        hub.mark_unread_unless_work_below(&s);
    }
    let meta = s.meta();
    assert!(meta.unread);
    assert_eq!(meta.unread_turns, 2);
    assert_eq!(meta.seen_seq, Some(left_at), "only a hide moves the mark");

    hub.attach_count(&s, 1, true);
    let read = last_read(&hub, &s).expect("showing it logs the read status");
    assert_eq!(read["since"], json!(left_at));
    assert_eq!(read["turns"], json!(2));
    let meta = s.meta();
    assert!(!meta.unread);
    assert_eq!(meta.unread_turns, 0, "seeing it clears the count");
    let back = crate::store::LastReturn { since: left_at, turns: 2 };
    assert_eq!(meta.last_return, Some(back), "the return is kept while the person stays");
    // A second client opening it now still reads the return; leaving clears it.
    hub.attach_count(&s, 1, true);
    assert_eq!(s.meta().last_return, Some(back));
    hub.attach_count(&s, -1, true);
    hub.attach_count(&s, -1, true);
    assert_eq!(s.meta().last_return, None, "leaving ends the return");
}

#[tokio::test]
async fn a_hidden_client_moves_no_mark_and_a_chat_never_left_has_no_since() {
    let (hub, s) = chat().await;
    // An agent's hidden hold is not a person looking.
    hub.attach_count(&s, 1, false);
    hub.attach_count(&s, -1, false);
    assert_eq!(s.meta().seen_seq, None);

    hub.mark_unread_unless_work_below(&s);
    hub.attach_count(&s, 1, false);
    hub.set_visible(&s, true);
    let read = last_read(&hub, &s).expect("showing it logs the read status");
    assert_eq!(read["since"], Value::Null, "no person left it before");
    assert_eq!(read["turns"], json!(1));

    // Hiding it through `_acpmux/view` keeps the mark too.
    let before = s.seq.load(Ordering::SeqCst);
    hub.set_visible(&s, false);
    assert_eq!(s.meta().seen_seq, Some(before));
}

#[tokio::test]
async fn turns_that_end_while_background_work_runs_each_count() {
    let (hub, s) = chat().await;
    s.subagents.lock().unwrap().annotate_live(
        &mut json!({"sessionId": s.id, "update": {
            "sessionUpdate": "subagent_spawned", "subagentSessionId": "background",
            "background": true
        }}),
        true,
    );
    hub.refresh_work_below(&s);
    hub.mark_unread_unless_work_below(&s);
    hub.mark_unread_unless_work_below(&s);
    let meta = s.meta();
    assert!(!meta.unread, "the dot waits for the work");
    assert_eq!(meta.unread_turns, 2, "each unseen turn counts");
    hub.end_background_subagents(&s);
    let meta = s.meta();
    assert!(meta.unread);
    assert_eq!(meta.unread_turns, 2, "the work ending adds no turn");
}

#[tokio::test]
async fn coming_back_while_background_work_runs_tells_every_client_the_count_cleared() {
    let (hub, s) = chat().await;
    s.subagents.lock().unwrap().annotate_live(
        &mut json!({"sessionId": s.id, "update": {
            "sessionUpdate": "subagent_spawned", "subagentSessionId": "background",
            "background": true
        }}),
        true,
    );
    hub.refresh_work_below(&s);
    hub.mark_unread_unless_work_below(&s);
    assert!(!s.meta().unread, "the dot waits for the work");
    hub.attach_count(&s, 1, true);
    let read = last_read(&hub, &s).expect("clearing the count is published with no dot to clear");
    assert_eq!(read["turns"], json!(1));
    assert_eq!(s.meta().unread_turns, 0);
}
