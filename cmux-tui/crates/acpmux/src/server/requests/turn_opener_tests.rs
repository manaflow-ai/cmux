use super::*;

fn rec(seq: u64, kind: &str, msg: Value) -> crate::store::EventRecord {
    crate::store::EventRecord {
        seq,
        at: 0,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

#[test]
fn a_steer_does_not_start_a_turn() {
    assert!(starts_turn(&rec(3, "user_message", json!({"text": "go"}))));
    assert!(!starts_turn(&rec(4, "user_message", json!({"text": "also", "steer": true}))));
    assert!(!starts_turn(&rec(5, "turn_result", json!({}))));
    let mut agent = rec(6, "user_message", json!({}));
    agent.dir = "in".into();
    assert!(!starts_turn(&agent));
}
