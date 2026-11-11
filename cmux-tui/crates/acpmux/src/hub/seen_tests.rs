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

// Showing is not seeing (Leo, 2026-11-11): a chat left on screen while the person is away keeps
// its turns unread, and their return says where they stopped attending.

#[tokio::test]
async fn a_person_idle_at_the_bottom_keeps_turns_unread_and_returns_to_where_they_stopped() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    hub.append(&s, "mux", "note", json!({"seen": true}));
    let last_input = s.seq.load(Ordering::SeqCst);
    // Output streams after their last input, before the client's idle window ran out.
    hub.append(&s, "mux", "note", json!({"seen": false}));
    assert_eq!(hub.look_changed(&s, Look::Attending, Look::Idle, Some(last_input)), None);
    assert!(hub.shown(&s), "an idle client still shows the chat: process, recap, presence");
    assert!(!hub.attended(&s));
    assert_eq!(s.meta().seen_seq, Some(last_input), "left off at the last input, not at the timeout");

    hub.append(&s, "mux", "note", json!({"seen": false}));
    hub.note_turn_end(&s);
    let meta = s.meta();
    assert!(meta.unread, "a turn that ends on screen with nobody attending is unread");
    assert_eq!(meta.unread_turns, 1);

    let back = hub.look_changed(&s, Look::Idle, Look::Attending, None);
    let want = crate::store::LastReturn { since: last_input, turns: 1 };
    assert_eq!(back, Some(want), "coming back answers the return for the client to draw");
    let read = last_read(&hub, &s).expect("coming back logs the read status");
    assert_eq!(read["since"], json!(last_input));
    assert!(!s.meta().unread);
}

#[tokio::test]
async fn a_person_who_attends_at_the_bottom_sees_each_turn() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    hub.append(&s, "mux", "note", json!({"seen": true}));
    hub.note_turn_end(&s);
    let meta = s.meta();
    assert!(!meta.unread);
    assert_eq!(meta.unread_turns, 0);
    // Going idle after reading it all leaves nothing new behind.
    let at = s.seq.load(Ordering::SeqCst);
    hub.look_changed(&s, Look::Attending, Look::Idle, Some(at));
    assert!(!s.meta().unread, "the turn ended before their last input: they saw it");
    assert_eq!(hub.look_changed(&s, Look::Idle, Look::Attending, None), None);
}

#[tokio::test]
async fn a_turn_that_ended_after_the_last_input_is_missed_when_idle_is_noticed() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    let last_input = s.seq.load(Ordering::SeqCst);
    hub.append(&s, "mux", "note", json!({"seen": false}));
    // The turn ends inside the idle window, while the client still counted the person attending.
    hub.note_turn_end(&s);
    assert!(!s.meta().unread);
    hub.look_changed(&s, Look::Attending, Look::Idle, Some(last_input));
    let meta = s.meta();
    assert!(meta.unread, "it ended after the person's last input");
    assert_eq!(meta.unread_turns, 1);
    assert_eq!(meta.seen_seq, Some(last_input));
}

#[tokio::test]
async fn another_attending_client_still_sees_and_an_idle_one_lets_go_cleanly() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    hub.attach_count(&s, 1, true);
    hub.look_changed(&s, Look::Attending, Look::Idle, None);
    assert!(hub.attended(&s), "the other client's person attends");
    hub.note_turn_end(&s);
    assert!(!s.meta().unread);
    // The idle one detaches the way server/view.rs lets it go: hidden first.
    hub.look_changed(&s, Look::Idle, Look::Hidden, None);
    hub.attach_count(&s, -1, false);
    assert_eq!(s.idle.load(Ordering::SeqCst), 0);
    assert_eq!(s.hidden.load(Ordering::SeqCst), 0);
    assert!(hub.attended(&s));
}

#[tokio::test]
async fn coming_back_from_idle_mid_turn_counts_what_the_running_turn_wrote() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    let last_input = s.seq.load(Ordering::SeqCst);
    hub.look_changed(&s, Look::Attending, Look::Idle, Some(last_input));
    hub.set_status(&s, SessionStatus::Running);
    hub.append(&s, "mux", "note", json!({"seen": false}));
    let back = hub.look_changed(&s, Look::Idle, Look::Attending, None);
    assert_eq!(back.map(|b| b.since), Some(last_input), "the output written while away is new");
}
