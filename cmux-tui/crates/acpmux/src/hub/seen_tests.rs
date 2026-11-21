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

/// `_acpmux/markRead` (cmux's `chat.mark_read`): clears the dot and the count and tells every
/// client, but moves no "where they left off" mark, since nobody looked.
#[tokio::test]
async fn marking_read_clears_the_dot_and_count_without_moving_the_mark() {
    let (hub, s) = chat().await;
    hub.attach_count(&s, 1, true);
    let left_at = s.seq.load(Ordering::SeqCst);
    hub.attach_count(&s, -1, true);
    hub.mark_unread_unless_work_below(&s);
    hub.mark_unread_unless_work_below(&s);
    assert!(s.meta().unread);

    hub.mark_read_answered(&s).expect("marked read");
    let meta = s.meta();
    assert!(!meta.unread);
    assert_eq!(meta.unread_turns, 0);
    assert_eq!(meta.seen_seq, Some(left_at), "nobody looked: the mark stays");
    assert_eq!(meta.last_return, None);
    let read = last_read(&hub, &s).expect("every client hears it");
    assert_eq!((read["since"].clone(), read["turns"].clone()), (Value::Null, json!(2)));

    // Read already: no new record.
    let before = s.seq.load(Ordering::SeqCst);
    hub.mark_read_answered(&s).expect("still fine");
    assert_eq!(s.seq.load(Ordering::SeqCst), before);
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
    assert_eq!(
        s.meta().seen_seq,
        Some(last_input),
        "left off at the last input, not at the timeout"
    );

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

// The seen cursor (`read_through`, Leo, 2026-11-12: "when you restart the update, all of a sudden
// it's just, like, you know, it's there and it's noisy").

const ALICE: &str = "tailnet:alice@example.com";

/// A hub on a store in `root` (one that keeps `session.json`), or in memory.
fn hub_at(root: Option<&std::path::Path>) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = if root.is_some() { StoreMode::Local } else { StoreMode::Memory };
    let store =
        crate::store::open(&cfg.store, root.unwrap_or(std::path::Path::new("/nonexistent")))
            .unwrap();
    Hub::new(cfg, store)
}

fn notes(hub: &Hub, s: &Session, n: usize) -> u64 {
    for _ in 0..n {
        hub.append(s, "mux", "note", json!({"row": true}));
    }
    s.seq.load(Ordering::SeqCst)
}

#[tokio::test]
async fn seen_moves_the_cursor_forward_only_and_never_past_the_log() {
    let (hub, s) = chat().await;
    assert_eq!(hub.read_through(&s, OWNER_READER), None, "nothing seen yet");
    let mid = notes(&hub, &s, 3);
    let end = notes(&hub, &s, 3);
    assert_eq!(hub.mark_read_through(&s, OWNER_READER, mid), mid);
    assert_eq!(hub.mark_read_through(&s, OWNER_READER, mid - 2), mid, "never back");
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(mid));
    assert_eq!(
        hub.mark_read_through(&s, OWNER_READER, end + 50),
        end,
        "clamped to the newest record"
    );
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(end));
}

#[tokio::test]
async fn attach_view_reconnect_notices_and_mux_records_never_move_it() {
    let (hub, s) = chat().await;
    let seen = notes(&hub, &s, 2);
    hub.mark_read_through(&s, OWNER_READER, seen);
    // An attach that shows the chat, a view change, idle and back, a reconnect.
    hub.attach_count(&s, 1, true);
    hub.look_changed(&s, Look::Attending, Look::Idle, None);
    hub.look_changed(&s, Look::Idle, Look::Attending, None);
    hub.set_visible(&s, false);
    hub.set_visible(&s, true);
    hub.attach_count(&s, -1, true);
    hub.attach_count(&s, 1, true);
    // A notice, a status, the read status a return logs, a turn end.
    hub.append(&s, "mux", "notice", json!({"text": "restarted"}));
    hub.append(&s, "mux", "status", json!({"status": "idle", "read": true}));
    hub.note_turn_end(&s);
    hub.mark_unread(&s);
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(seen), "only _acpmux/seen moves it");
    assert!(s.seq.load(Ordering::SeqCst) > seen, "records did land after it");
}

#[tokio::test]
async fn each_person_has_their_own_cursor() {
    let (hub, s) = chat().await;
    let early = notes(&hub, &s, 2);
    let late = notes(&hub, &s, 2);
    hub.mark_read_through(&s, OWNER_READER, late);
    hub.mark_read_through(&s, ALICE, early);
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(late));
    assert_eq!(hub.read_through(&s, ALICE), Some(early));
    assert_eq!(hub.read_through(&s, "tailnet:bob@example.com"), None);
    // Alice reading on moves only hers.
    hub.mark_read_through(&s, ALICE, late);
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(late));
    assert_eq!(hub.read_through(&s, ALICE), Some(late));
}

#[tokio::test]
async fn mark_unread_with_a_seq_moves_it_back_only() {
    let (hub, s) = chat().await;
    let early = notes(&hub, &s, 2);
    let late = notes(&hub, &s, 2);
    hub.mark_read_through(&s, OWNER_READER, late);
    assert_eq!(hub.mark_read_back(&s, OWNER_READER, early), early);
    assert_eq!(hub.mark_read_back(&s, OWNER_READER, late), early, "never forward");
    assert_eq!(hub.read_through(&s, OWNER_READER), Some(early));
}

#[tokio::test]
async fn the_cursor_survives_a_restart_of_the_daemon() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-read-through");
    let hub = hub_at(Some(dir.path()));
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let seen = notes(&hub, &s, 3);
    hub.mark_read_through(&s, OWNER_READER, seen);
    hub.mark_read_through(&s, ALICE, seen - 1);
    notes(&hub, &s, 2);
    let id = s.id.clone();
    drop(s);
    hub.store.flush_session(&id).unwrap();
    hub.shutdown_all().await;
    drop(hub);

    let restarted = hub_at(Some(dir.path()));
    let kept = restarted.store.load(&id).unwrap().unwrap();
    assert_eq!(kept.read_through.get(OWNER_READER), Some(&seen), "kept in session.json");
    let s = restarted.resolve(&id).unwrap();
    // Coming back after the restart (an attach that shows it) moves nothing.
    restarted.attach_count(&s, 1, true);
    assert_eq!(restarted.read_through(&s, OWNER_READER), Some(seen));
    assert_eq!(restarted.read_through(&s, ALICE), Some(seen - 1));
    restarted.shutdown_all().await;
}
