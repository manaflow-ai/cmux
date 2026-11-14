use super::*;

#[test]
fn only_a_steer_the_turn_took_counts_as_in_it() {
    let err = |m: &str| Err(RpcError::internal(m.to_owned()));
    assert!(steer_entered_turn(&Ok(json!({}))));
    assert!(steer_entered_turn(&err("agent process closed")));
    assert!(!steer_entered_turn(&err(crate::claude_stdio::STEER_NO_TURN)));
    assert!(!steer_entered_turn(&err(crate::claude_stdio::STEER_WITHDRAWN)));
}
