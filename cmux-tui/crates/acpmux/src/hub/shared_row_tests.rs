//! `HubEvent::row` (`SharedRow`): watchers sending one record share its row, and the event ring
//! keeps none once they sent it (cmuxterm-hq#14649).

use super::*;

#[test]
fn watchers_share_a_row_while_one_sends_it() {
    let row = SharedRow::default();
    let mut builds = 0;
    let first = row.get_or_build(|| {
        builds += 1;
        Some(serde_json::json!({"sessionId": "a"}))
    });
    let second = row.get_or_build(|| {
        builds += 1;
        Some(serde_json::json!({"sessionId": "b"}))
    });
    assert_eq!(builds, 1);
    assert!(Arc::ptr_eq(first.as_ref().unwrap(), second.as_ref().unwrap()));
}

#[test]
fn the_ring_keeps_no_row_after_its_watchers_sent_it() {
    let event = row_log::row_event("a");
    let [_, full, _] = &event.row.cells;
    let sent = full.get_or_build(|| Some(serde_json::json!({"spans": vec![0u64; 512]}))).unwrap();
    let held = Arc::downgrade(&sent);
    drop(sent);
    // The ring's copy of the event (`event`) still lives; the row it was sent with does not.
    assert!(held.upgrade().is_none());
    let again = full.get_or_build(|| Some(serde_json::json!({"sessionId": "a"}))).unwrap();
    assert_eq!(*again, serde_json::json!({"sessionId": "a"}));
}

#[test]
fn a_gone_session_builds_no_row() {
    let row = SharedRow::default();
    assert!(row.get_or_build(|| None).is_none());
    assert!(row.get_or_build(|| Some(Value::Null)).is_some());
}
