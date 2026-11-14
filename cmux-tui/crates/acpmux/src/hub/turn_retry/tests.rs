use super::*;
use crate::hub::{Control, NewRequest, TurnInfo};

#[test]
fn only_a_claude_retry_of_a_refused_sign_in_ends_its_turn() {
    let claude = |status: u64, error: &str| {
        claude_retry(&json!({"attempt": 3, "max_retries": 10,
            "error_status": status, "error": error}))
    };
    assert!(sign_in_refused(&claude(401, "authentication_failed")));
    assert!(sign_in_refused(&claude(403, "authentication_failed")));
    assert!(!sign_in_refused(&claude(503, "server_error")));
    assert!(!sign_in_refused(&claude(429, "rate_limit")));
    let codex = codex_retry(&json!({"message": "Reconnecting... 3/5",
            "codexErrorInfo": {"responseStreamDisconnected": {"httpStatusCode": 401}}}));
    assert!(!sign_in_refused(&codex), "Codex's own retries are its to end");
}

/// A session of a test hub whose turn `turn-1` runs, and a refused retry at `attempt`.
async fn running_turn() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"}))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    *session.turn.lock().unwrap() =
        Some(TurnInfo::prompted("person", "hi", "turn-1", "p-1", Control::Local));
    (hub, session)
}

fn refused(attempt: u64) -> Value {
    claude_retry(&json!({"attempt": attempt, "max_retries": 10, "error_status": 401,
            "error": "authentication_failed"}))
}

/// The first refused retry may be a sign-in being refreshed: it ends nothing. The second
/// ends the turn.
#[tokio::test]
async fn a_refused_sign_in_ends_its_turn_at_the_second_retry() {
    let (hub, session) = running_turn().await;
    hub.end_sign_in_refused(&session, &refused(1));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(session.steer_end.borrow().is_none(), "the first refused retry ends nothing");
    hub.end_sign_in_refused(&session, &refused(2));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let ended = session.steer_end.borrow().clone();
    let (_, answer) = ended.expect("the second refused retry ends the turn");
    assert_eq!(answer.pointer("/_meta/acpmux/signInRefused/attempt"), Some(&json!(2)));
}

/// The end at the third retry, then the fourth: one end, the third's (review F2).
#[tokio::test]
async fn a_refused_sign_in_schedules_one_end_per_turn() {
    let (hub, session) = running_turn().await;
    hub.end_sign_in_refused(&session, &refused(3));
    hub.end_sign_in_refused(&session, &refused(4));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let ended = session.steer_end.borrow().clone();
    let (turn, answer) = ended.expect("the turn ends");
    assert_eq!(turn, "turn-1");
    assert_eq!(answer.pointer("/_meta/acpmux/signInRefused/attempt"), Some(&json!(3)));
}

/// A new agent for the turn (a failover keeps the turn id) before the end runs: the end is
/// not carried out on it (review F1).
#[tokio::test]
async fn a_refused_sign_in_end_spares_the_turns_next_agent() {
    let (hub, session) = running_turn().await;
    hub.end_sign_in_refused(&session, &refused(3));
    hub.hold_stalled_count(&session);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(session.steer_end.borrow().is_none(), "the next agent's turn is not ended");
    // That agent's own refused retries still end the turn.
    hub.end_sign_in_refused(&session, &refused(3));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let end = session.steer_end.borrow().clone();
    assert_eq!(
        end.map(|(turn, _)| turn).as_deref(),
        Some("turn-1"),
        "the next agent's refusal ends it"
    );
}

#[test]
fn a_refused_sign_in_fails_typed_as_signed_out() {
    let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"signInRefused":
            {"attempt": 3, "errorStatus": 401, "error": "authentication_failed"}}}});
    let mut e = Hub::sign_in_refused_error(&answer).unwrap();
    crate::recovery::annotate(&mut e, None);
    assert_eq!(
        e.data.as_ref().unwrap()["errorKind"],
        crate::recovery::kind::AUTH_SIGNED_OUT,
        "{e:?}"
    );
    assert!(Hub::sign_in_refused_error(&json!({"stopReason": "cancelled"})).is_none());
}

#[test]
fn claude_line_keeps_what_a_client_shows() {
    let line = json!({"type": "system", "subtype": "api_retry", "attempt": 7, "max_retries": 10,
            "retry_delay_ms": 75000, "error_status": 503, "error": "server_error"});
    assert_eq!(
        claude_retry(&line),
        json!({"source": "claude", "attempt": 7, "maxRetries": 10, "retryDelayMs": 75000,
                "errorStatus": 503, "error": "server_error"})
    );
    let bare = json!({"attempt": 1, "max_retries": 10, "error": "unknown"});
    assert_eq!(claude_retry(&bare), json!({"source": "claude", "attempt": 1, "maxRetries": 10}));
}

#[test]
fn codex_error_reads_its_count_and_status() {
    let err = json!({"message": "Reconnecting... 2/5", "willRetry": true,
            "codexErrorInfo": {"responseStreamDisconnected": {"httpStatusCode": 502}},
            "additionalDetails": "stream disconnected before completion"});
    assert_eq!(
        codex_retry(&err),
        json!({"source": "codex", "attempt": 2, "maxRetries": 5, "errorStatus": 502,
                "error": "stream disconnected before completion"})
    );
    let plain = json!({"message": "stream error: connection reset", "willRetry": true});
    assert_eq!(
        codex_retry(&plain),
        json!({"source": "codex", "error": "stream error: connection reset"})
    );
    let bare = json!({"message": "Reconnecting... 1", "willRetry": true});
    assert_eq!(codex_retry(&bare), json!({"source": "codex", "attempt": 1}));
}

#[test]
fn attempt_is_the_last_count() {
    assert_eq!(attempt_of("Reconnecting... 2/5"), Some((2, 5)));
    assert_eq!(attempt_of("retrying (3/10)…"), Some((3, 10)));
    assert_eq!(attempt_of("see /v1/responses"), None);
    assert_eq!(attempt_of("6/5"), None);
}
