//! `HubEvent::row`, `update_line` and `event_params` ([`Shared`]): connections sending one record
//! share them, and the event ring keeps none once they sent them (cmuxterm-hq#14649).

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

/// The fleet's daemons grew 520 to 900 MB an hour: every event the ring and a connection's queue
/// kept held its record's `session/update` line and `_acpmux/event` params, each a copy of the
/// whole message (a big tool output three times over), until 8,192 later records pushed it out.
#[test]
fn the_ring_keeps_no_line_or_params_after_a_connection_sent_them() {
    let event = row_log::row_event("a");
    // A connection's queue holds its own clone of the event (`server/interest.rs` `Inbox`).
    let queued = event.clone();
    let output = "x".repeat(1 << 20);
    let line = queued.update_line.get_or_build(|| Some(output.clone())).unwrap();
    let params = queued
        .event_params
        .get_or_build(|| Some(serde_json::json!({"output": output.clone()})))
        .unwrap();
    // A second connection sending it meanwhile shares the one copy.
    let shared = event.update_line.get_or_build(|| Some(String::new())).unwrap();
    assert!(Arc::ptr_eq(&line, &shared));
    assert!(event.event_params.held());
    let (line, params) = (Arc::downgrade(&line), Arc::downgrade(&params));
    drop(shared);
    drop(queued);
    // Sent: the ring's copy of the event still lives, the line and params it was sent with do not.
    assert!(line.upgrade().is_none());
    assert!(params.upgrade().is_none());
    assert!(!event.update_line.held());
    assert!(!event.event_params.held());
}

#[test]
fn a_line_too_large_for_one_frame_is_not_kept() {
    let line: Shared<String> = Shared::default();
    assert!(line.get_or_build(|| None).is_none());
    assert!(!line.held());
    assert_eq!(line.get_or_build(|| Some("l".into())).as_deref().map(String::as_str), Some("l"));
}
