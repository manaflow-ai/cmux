mod common;

use cmux_forum_hosted::{FeedEvent, StateFilter, Thread, ThreadCache, ThreadState};
use common::event;
use serde_json::json;

fn ev(v: serde_json::Value) -> FeedEvent {
    serde_json::from_value(v).unwrap()
}

fn comment(seq: u64, thread: u64, at: &str, excerpt: &str) -> FeedEvent {
    let mut v = event(seq, "comment.created", thread, "T", "open", at);
    v["comment"] = json!({"id": seq, "author": {"kind": "agent", "name": "a"}, "excerpt": excerpt, "cut": false, "length": 5});
    ev(v)
}

#[test]
fn events_open_comment_close_and_reopen() {
    let mut c = ThreadCache::new();
    assert!(c.apply(&ev(event(1, "thread.created", 5, "T", "open", "2026-11-01T00:00:00Z"))));
    assert!(c.apply(&comment(2, 5, "2026-11-01T01:00:00Z", "first")));
    assert!(c.apply(&comment(3, 5, "2026-11-01T02:00:00Z", "second")));
    let row = c.get(5).unwrap();
    assert_eq!(row.comments, 2);
    assert_eq!(row.last_excerpt.as_deref(), Some("second"));
    assert_eq!(row.updated_at, "2026-11-01T02:00:00Z");
    assert_eq!(row.created_at, "2026-11-01T00:00:00Z");

    assert!(c.apply(&ev(event(
        4,
        "thread.updated",
        5,
        "T renamed",
        "open",
        "2026-11-01T03:00:00Z"
    ))));
    assert!(c.apply(&ev(event(
        5,
        "thread.closed",
        5,
        "T renamed",
        "closed",
        "2026-11-01T04:00:00Z"
    ))));
    let row = c.get(5).unwrap();
    assert_eq!(row.title, "T renamed");
    assert_eq!(row.state, ThreadState::Closed);
    assert!(c.list(Some("general"), StateFilter::Open).is_empty());
    assert_eq!(c.list(Some("general"), StateFilter::Closed).len(), 1);

    assert!(c.apply(&ev(event(
        6,
        "thread.reopened",
        5,
        "T renamed",
        "open",
        "2026-11-01T05:00:00Z"
    ))));
    assert_eq!(c.get(5).unwrap().state, ThreadState::Open);
}

#[test]
fn replayed_events_do_not_double_count() {
    let mut c = ThreadCache::new();
    let events =
        vec![ev(event(1, "thread.created", 5, "T", "open", "t1")), comment(2, 5, "t2", "x")];
    assert_eq!(c.apply_all(&events), 2);
    assert_eq!(c.apply_all(&events), 0);
    assert_eq!(c.get(5).unwrap().comments, 1);
}

#[test]
fn seed_then_feed_skips_events_the_seed_already_counts() {
    let mut c = ThreadCache::new();
    let t: Thread = serde_json::from_value(json!({
        "number": 8, "title": "Seeded", "state": "open", "space": "ops", "comments": 4,
        "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-02T00:00:00Z"
    }))
    .unwrap();
    c.seed(std::slice::from_ref(&t), 10);
    assert!(!c.apply(&comment(9, 8, "2026-10-02T00:00:00Z", "old")));
    assert_eq!(c.get(8).unwrap().comments, 4);
    let mut newer = comment(11, 8, "2026-10-03T00:00:00Z", "new");
    newer.space = "ops".into();
    assert!(c.apply(&newer));
    assert_eq!(c.get(8).unwrap().comments, 5);

    // A stale seed does not roll a newer row back.
    c.seed(&[t], 10);
    assert_eq!(c.get(8).unwrap().comments, 5);
}

#[test]
fn list_is_per_space_newest_first_and_round_trips_json() {
    let mut c = ThreadCache::new();
    c.apply(&ev(event(1, "thread.created", 1, "old", "open", "2026-11-01T00:00:00Z")));
    c.apply(&ev(event(2, "thread.created", 2, "new", "open", "2026-11-03T00:00:00Z")));
    let mut other = ev(event(3, "thread.created", 3, "elsewhere", "open", "2026-11-04T00:00:00Z"));
    other.space = "ops".into();
    c.apply(&other);
    c.apply(&ev(event(4, "thread.created", 0, "no thread", "open", "t")));

    let general: Vec<u64> =
        c.list(Some("general"), StateFilter::Open).iter().map(|r| r.number).collect();
    assert_eq!(general, vec![2, 1]);
    assert_eq!(c.list(None, StateFilter::All).len(), 3);
    assert_eq!(c.list(Some("ops"), StateFilter::All)[0].title, "elsewhere");

    let back = ThreadCache::from_json(&c.to_json().unwrap()).unwrap();
    assert_eq!(back, c);
}

#[test]
fn unknown_event_kinds_still_parse() {
    let e = ev(event(1, "thread.moved", 2, "T", "open", "t"));
    assert_eq!(e.kind, cmux_forum_hosted::EventKind::Unknown);
}
