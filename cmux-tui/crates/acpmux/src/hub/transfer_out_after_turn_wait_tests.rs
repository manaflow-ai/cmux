use super::{AFTER_TURN_WAIT, after_turn_wait};
use serde_json::json;
use std::time::Duration;

/// Item C: the mover's `--timeout` bounds the daemon's wait for the turn, never past 15 min.
#[test]
fn the_movers_timeout_bounds_the_wait_for_the_turn() {
    assert_eq!(after_turn_wait(&json!({})), AFTER_TURN_WAIT);
    assert_eq!(after_turn_wait(&json!({"afterTurnTimeoutMs": 30_000})), Duration::from_secs(30));
    assert_eq!(after_turn_wait(&json!({"afterTurnTimeoutMs": u64::MAX})), AFTER_TURN_WAIT);
}
