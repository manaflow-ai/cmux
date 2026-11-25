use super::*;
use serde_json::json;

fn rec(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: 0, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn left(records: &[EventRecord]) -> Vec<String> {
    let mut u = Unstarted::default();
    records.iter().for_each(|e| u.read(e));
    u.finish().iter().map(|e| e.msg["promptId"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn only_an_accepted_direct_prompt_whose_turn_never_started_is_left() {
    let um = |seq, p: &str, t: &str| rec(seq, "user_message", json!({"promptId": p, "turnId": t}));
    assert_eq!(left(&[um(1, "a", "ta")]), ["a"]);
    // Started, ended, refused: settled.
    assert!(
        left(&[um(1, "a", "ta"), rec(2, "turn_started", json!({"turnId": "ta", "promptId": "a"}))])
            .is_empty()
    );
    assert!(left(&[um(1, "a", "ta"), rec(2, "turn_result", json!({"turnId": "ta"}))]).is_empty());
    assert!(
        left(&[um(1, "a", "ta"), rec(2, "prompt_refused", json!({"promptId": "a"}))]).is_empty()
    );
    // A watched conversation's turn starts before its prompt is logged: not left.
    assert!(left(&[rec(1, "turn_started", json!({"turnId": "tw"})), um(2, "w", "tw")]).is_empty());
    // Out of the queue: `lost_start.rs`'s.
    assert!(
        left(&[rec(1, "queued", json!({"promptId": "a", "turnId": "ta"})), um(2, "a", "ta")])
            .is_empty()
    );
    // A steer starts no turn.
    assert!(
        left(&[rec(1, "user_message", json!({"promptId": "s", "turnId": "t", "steer": true}))])
            .is_empty()
    );
    // Run again under another turn id, which started: settled.
    assert!(
        left(&[
            um(1, "a", "t1"),
            um(2, "a", "t2"),
            rec(3, "turn_started", json!({"turnId": "t2", "promptId": "a"}))
        ])
        .is_empty()
    );
    // A trigger's prompt is its dispatcher's to send again.
    let trigger =
        json!({"promptId": "x", "turnId": "tx", "_meta": {"provenance": {"kind": "trigger"}}});
    assert!(left(&[rec(1, "user_message", trigger)]).is_empty());
    // Two left, oldest first.
    assert_eq!(left(&[um(1, "b", "tb"), um(2, "a", "ta")]), ["b", "a"]);
}
