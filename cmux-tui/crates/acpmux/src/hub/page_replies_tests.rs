use super::*;
use serde_json::json;

fn record(kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq: 1, at: 1, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

#[test]
fn a_kept_reply_answers_only_the_same_ask_of_the_same_log() {
    let replies = PageReplies::default();
    let ask = key(&json!({"sessionId": "c", "beforeSeq": 9, "limit": 400}));
    replies.put("c", ask.clone(), 7, 0, json!({"events": [1]}));
    assert_eq!(replies.get("c", &ask, 7, 0), Some(json!({"events": [1]})));
    // Another chat, another ask, a grown log or a changed one: read again.
    assert_eq!(replies.get("d", &ask, 7, 0), None);
    let other = key(&json!({"sessionId": "c", "beforeSeq": 9, "limit": 16}));
    assert_eq!(replies.get("c", &other, 7, 0), None);
    assert_eq!(replies.get("c", &ask, 7, 1), None);
    // A stale reply is dropped on sight: it never answers again, even at its own seq.
    assert_eq!(replies.get("c", &ask, 7, 0), None);
    assert_eq!(replies.len(), 0);
}

#[test]
fn who_asked_is_not_part_of_the_ask() {
    let app = key(&json!({"sessionId": "c", "limit": 400, "_meta": {"acpmux": {"via": "app"}}}));
    let peer = key(&json!({"sessionId": "c", "limit": 400}));
    assert_eq!(app, peer);
}

#[test]
fn at_most_entries_replies_are_kept_least_recently_asked_dropped_first() {
    let replies = PageReplies::default();
    for n in 0..ENTRIES + 4 {
        replies.put(&format!("c{n}"), "ask".into(), 1, 0, json!(n));
    }
    assert_eq!(replies.len(), ENTRIES);
    assert_eq!(replies.get("c0", "ask", 1, 0), None, "the oldest went first");
    // Asking again keeps a reply: the next put drops another.
    let newest_kept = format!("c{}", 4);
    assert!(replies.get(&newest_kept, "ask", 1, 0).is_some());
    replies.put("late", "ask".into(), 1, 0, json!("late"));
    assert!(replies.get(&newest_kept, "ask", 1, 0).is_some());
    assert_eq!(replies.get("c5", "ask", 1, 0), None);
}

#[test]
fn a_page_with_an_ask_in_it_is_never_kept() {
    assert!(keepable(&[record("agent_message_chunk", json!({}))]));
    assert!(!keepable(&[record("permission_request", json!({"request": {}}))]));
    assert!(!keepable(&[record("permission_group", json!({}))]));
    let asked = record(
        "request",
        json!({"method": crate::rpc::method::SESSION_REQUEST_PERMISSION, "params": {}}),
    );
    assert!(!keepable(&[asked]));
}
