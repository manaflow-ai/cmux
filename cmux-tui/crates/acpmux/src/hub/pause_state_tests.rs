use super::*;
use serde_json::json;

const POOL: &str = "API Error: 503 no non-exhausted claude accounts available; next account frees up in 47m (retry after 2766s).";

#[test]
fn a_waiting_retry_is_a_pause_with_its_reason_and_time() {
    // 2026-11-24T22:41:00Z
    let row = json!({"retry": {"attempt": 1, "of": 4, "reason": "capacity", "nextAt": 1_795_560_060_000_u64,
        "promptId": "p", "turnId": "t"}, "lastTurn": {"status": "failed", "errorText": POOL}});
    let state = of_row(&row).unwrap();
    assert_eq!(
        state,
        PauseState::Paused { reason: "capacity".into(), resumes_at: Some(1_795_560_060_000) }
    );
    assert_eq!(short_line(&state), "paused: capacity, resumes 22:41Z");
}

#[test]
fn a_rate_limit_hold_and_a_retry_being_decided_are_pauses() {
    let held = json!({"rateLimitedUntil": 1_795_560_060_000_u64});
    assert_eq!(short_line(&of_row(&held).unwrap()), "paused: rate limit, resumes 22:41Z");
    let deciding =
        json!({"retryDeciding": true, "lastTurn": {"status": "failed", "errorText": POOL}});
    assert_eq!(short_line(&of_row(&deciding).unwrap()), "paused: capacity, resumes soon");
}

#[test]
fn a_failed_turn_with_nothing_to_continue_it_is_stranded_with_its_cause() {
    for (error, want) in [
        (POOL, "capacity"),
        ("API Error: Repeated 529 Overloaded errors", "capacity"),
        ("No space left on device (os error 28)", "disk"),
        ("agent process closed", "agent_exited"),
        ("API Error: 400 invalid_request_error: bad", "refused"),
        ("simulated internal error", "error"),
    ] {
        let row = json!({"status": "idle", "lastTurn": {"status": "failed", "errorText": error}});
        match of_row(&row) {
            Some(PauseState::Stranded { cause, .. }) => assert_eq!(cause, want, "{error}"),
            other => panic!("{error}: {other:?}"),
        }
    }
    assert!(is_outage("capacity") && !is_outage("disk") && !is_outage("refused"));
}

#[test]
fn a_running_queued_or_finished_chat_is_neither() {
    let failed = json!({"status": "failed", "errorText": POOL});
    assert_eq!(of_row(&json!({"status": "running", "lastTurn": failed})), None);
    assert_eq!(of_row(&json!({"queued": 1, "lastTurn": failed})), None);
    assert_eq!(of_row(&json!({"turn": {"turnId": "t2"}, "lastTurn": failed})), None);
    assert_eq!(of_row(&json!({"lastTurn": {"status": "completed"}})), None);
    assert_eq!(of_row(&json!({})), None);
}
