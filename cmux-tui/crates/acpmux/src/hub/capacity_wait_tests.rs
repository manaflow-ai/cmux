use super::*;
use serde_json::json;

const POOL: &str =
    "API Error: 503 no non-exhausted claude accounts available; next account frees up in 29m";
const OVERLOAD: &str = "API Error: Repeated 529 Overloaded errors";

fn failed(error: &str) -> Value {
    json!({"turnId": "t1", "status": "failed", "errorText": error, "endedAt": 1_000_u64})
}

fn retry(reason: RetryReason) -> RetrySummary {
    RetrySummary {
        attempt: 1,
        of: 4,
        reason,
        next_at: 41_000,
        prompt_id: "p1".into(),
        turn_id: "t1".into(),
    }
}

#[test]
fn a_capacity_retry_waits_with_its_time_turn_and_raw_error() {
    for error in [POOL, OVERLOAD] {
        let wait =
            of(Some(&failed(error)), Some(&retry(RetryReason::Capacity)), false, None).unwrap();
        assert_eq!(wait.reason, RetryReason::Capacity);
        assert_eq!(wait.resumes_at, Some(41_000));
        assert_eq!(wait.turn_id.as_deref(), Some("t1"));
        assert_eq!(wait.since, Some(1_000));
        assert_eq!(wait.error.as_deref(), Some(error));
    }
}

#[test]
fn a_rate_limit_hold_is_a_capacity_wait() {
    let wait = of(None, None, false, Some(90_000)).unwrap();
    assert_eq!(wait.reason, RetryReason::RateLimit);
    assert_eq!(wait.resumes_at, Some(90_000));
    let retry = retry(RetryReason::RateLimit);
    assert!(of(Some(&failed("API Error: 429 rate limit")), Some(&retry), false, None).is_some());
}

#[test]
fn a_capacity_continuation_being_decided_waits_with_no_time_yet() {
    let wait = of(Some(&failed(POOL)), None, true, None).unwrap();
    assert_eq!(wait.reason, RetryReason::Capacity);
    assert_eq!(wait.resumes_at, None);
    assert_eq!(wait.turn_id.as_deref(), Some("t1"));
}

#[test]
fn other_causes_and_strands_are_no_capacity_wait() {
    // Nothing continues it: a failed turn, drawn as one.
    assert!(of(Some(&failed(OVERLOAD)), None, false, None).is_none());
    // A connection drop or a dead agent is retried too, but is no capacity wait.
    let transport = retry(RetryReason::Transport);
    assert!(of(Some(&failed("connection reset")), Some(&transport), false, None).is_none());
    assert!(of(Some(&failed("connection reset")), None, true, None).is_none());
    // A finished turn.
    let done = json!({"turnId": "t1", "status": "completed", "endedAt": 1});
    assert!(of(Some(&done), None, false, None).is_none());
}

#[test]
fn the_raw_error_is_cut_for_the_disclosure() {
    let long = format!("{OVERLOAD} {}", "x".repeat(2_000));
    let wait = of(Some(&failed(&long)), Some(&retry(RetryReason::Capacity)), false, None).unwrap();
    assert_eq!(wait.error.unwrap().chars().count(), MAX_ERROR_CHARS);
}

#[test]
fn a_list_row_reads_paused_for_capacity_with_its_time() {
    // 2026-11-24T22:41:00Z
    let wait = json!({"reason": "capacity", "resumesAt": 1_795_560_060_000_u64});
    assert_eq!(paused_line(&wait).as_deref(), Some("paused for capacity, resumes ~22:41Z"));
    let deciding = json!({"reason": "rate_limit"});
    assert_eq!(paused_line(&deciding).as_deref(), Some("paused for capacity"));
    assert_eq!(paused_line(&Value::Null), None);
}

#[test]
fn the_lane_says_paused_not_the_raw_error_and_is_never_failed() {
    let last = failed(OVERLOAD);
    for reason in [RetryReason::Capacity, RetryReason::RateLimit] {
        let retry = retry(reason);
        let wait = of(Some(&last), Some(&retry), false, None).unwrap();
        let summary = json!({
            "status": "ready", "turn": null, "turnCount": 3,
            "lastMessage": {"role": "agent", "text": OVERLOAD},
            "lastTurn": crate::hub::auto_resume::row_last_turn(Some(&last), Some(&retry), false),
            "capacityWait": serde_json::to_value(&wait).unwrap(),
        });
        let lane = crate::hub::views::lane(&summary);
        assert_eq!(lane["state"], "working", "{reason:?}");
        assert_eq!(lane["step"], "paused for capacity, resumes ~00:00Z", "{reason:?}");
        assert!(lane["error"].is_null());
    }
}
