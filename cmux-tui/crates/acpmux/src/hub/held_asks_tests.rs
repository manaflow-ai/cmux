use super::*;
use serde_json::json;

fn ask(id: &str) -> PeerNotice {
    PeerNotice::Notification {
        method: "_acpmux/permission_pending".into(),
        params: json!({"sessionId": id}),
        link: 1,
    }
}

#[test]
fn only_a_listed_sessions_asks_of_the_same_peer_and_generation_come_back() {
    let held = HeldAsks::default();
    held.hold("p", 1, "s1", ask("s1"));
    held.hold("p", 1, "s2", ask("s2"));
    held.hold("q", 1, "s1", ask("s1"));
    held.hold("p", 0, "s1", ask("s1"));
    let back = held.take_listed("p", 1, |s| s == "s1");
    assert_eq!(back.len(), 1);
    assert!(held.take_listed("p", 1, |s| s == "s1").is_empty());
    assert_eq!(held.take_listed("p", 1, |_| true).len(), 1);
    assert_eq!(held.take_listed("q", 1, |_| true).len(), 1);
}

#[test]
fn a_resolved_ask_is_forgotten() {
    let held = HeldAsks::default();
    let pending = |id: &str, p: &str| PeerNotice::Notification {
        method: "_acpmux/permission_pending".into(),
        params: json!({"sessionId": id, "permissionId": p}),
        link: 1,
    };
    let record = |id: &str, p: &str| PeerNotice::Notification {
        method: "_acpmux/event".into(),
        params: json!({"sessionId": id, "kind": "permission_request", "msg": {"permissionId": p}}),
        link: 1,
    };
    held.hold("p", 1, "s", pending("s", "a"));
    held.hold("p", 1, "s", record("s", "a"));
    held.hold("p", 1, "s", pending("s", "b"));
    held.hold("p", 1, "t", pending("t", "a"));
    held.forget("p", "s", Some("a"));
    assert_eq!(held.take_listed("p", 1, |id| id == "s").len(), 1);
    held.hold("p", 1, "s", pending("s", "c"));
    held.forget("p", "s", None);
    assert!(held.take_listed("p", 1, |id| id == "s").is_empty());
    assert_eq!(held.take_listed("p", 1, |_| true).len(), 1);
}

#[test]
fn held_asks_are_bounded() {
    let held = HeldAsks::default();
    held.hold("q", 1, "s", ask("s"));
    for i in 0..MAX_HELD + 10 {
        held.hold("p", 1, &format!("s{i}"), ask("s"));
    }
    assert_eq!(held.take_listed("p", 1, |_| true).len(), MAX_HELD);
    assert_eq!(held.take_listed("q", 1, |_| true).len(), 1, "one peer's asks pushed out another's");
}
