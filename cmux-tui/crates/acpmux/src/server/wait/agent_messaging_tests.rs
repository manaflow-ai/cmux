use super::*;

/// A `wait` right after `send --no-wait` read the receiver's idle state from before the
/// message reached it (round-2 eval, A4: exit 0 `idle` in 0.5 s). With a turn still coming
/// (`Hub::work_coming`) the idle row is neither ready nor done; a permission still answers.
#[test]
fn an_idle_session_with_a_turn_coming_is_not_ready_yet() {
    let idle = json!({"status": "ready", "turn": null, "unread": true});
    assert!(Until::Ready.matches(&idle));
    assert!(Until::Done.matches(&idle));
    let mut coming = idle.clone();
    coming.set(WORK_COMING, json!(true));
    assert!(!Until::Ready.matches(&coming), "the message has not started its turn yet");
    assert!(!Until::Done.matches(&coming));
    assert!(!Until::Running.matches(&coming));
    let mut asks = coming.clone();
    asks.set("pendingPermissions", json!(1));
    assert!(Until::Permission.matches(&asks));
    let closed = json!({"status": "closed", WORK_COMING: true});
    assert!(Until::Closed.matches(&closed));
}
