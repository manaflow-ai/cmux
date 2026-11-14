use super::*;

fn ended(s: Value) -> bool {
    let t = TurnEnded::parse(Some(&json!({"turnId": "t1", "startedAt": 100}))).unwrap();
    t.matches(&s)
}

#[test]
fn a_turn_has_ended_once_its_end_is_recorded_or_the_session_cannot_end_it() {
    let running = json!({"status": "running", "turn": {"turnId": "t1"}, "lastTurn": {"turnId": "t0", "endedAt": 90}});
    assert!(!ended(running), "still running");
    // Taken out of the session, its end not recorded yet: not yet.
    let between =
        json!({"status": "running", "turn": null, "lastTurn": {"turnId": "t0", "endedAt": 90}});
    assert!(!ended(between), "its end is not recorded yet");
    // The turn before it ended in the millisecond it started.
    let last = json!({"turnId": "t0", "endedAt": 100});
    let tie = json!({"status": "running", "turn": {"turnId": "t1"}, "lastTurn": last.clone()});
    assert!(!ended(tie), "it runs");
    let tie = json!({"status": "running", "turn": null, "lastTurn": last});
    assert!(!ended(tie), "its end is not recorded yet, in the same millisecond");
    let recorded =
        json!({"status": "waiting", "turn": null, "lastTurn": {"turnId": "t1", "endedAt": 120}});
    assert!(ended(recorded), "recorded, while a background ask waits");
    let later =
        json!({"status": "ready", "turn": null, "lastTurn": {"turnId": "t2", "endedAt": 150}});
    assert!(ended(later), "a later turn ended since");
    let next = json!({"status": "running", "turn": {"turnId": "t2"}, "lastTurn": null});
    assert!(ended(next), "another turn runs");
    assert!(ended(json!({"status": "closed", "turn": null})));
    assert!(ended(json!({"sessionId": "s", "status": "closed", "missing": true})));
    let lost = json!({"status": "unreachable", "stale": true, "turn": {"turnId": "t1"}});
    assert!(ended(lost), "its machine is unreachable");
    assert!(TurnEnded::parse(Some(&json!({"turnId": ""}))).is_none());
    assert!(TurnEnded::parse(None).is_none());
}
