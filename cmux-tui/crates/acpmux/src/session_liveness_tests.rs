use super::*;
use serde_json::json;

#[test]
fn stuck_classifies_harness_failures_and_clears_only_after_success() {
    for (error, kind, reason) in [
        ("API Error: 503 authentication_failed", "", StuckReason::HarnessUnavailable),
        ("HTTP 500 Internal Server Error", "", StuckReason::HarnessUnavailable),
        ("Selected model is at capacity", "", StuckReason::Capacity),
        ("HTTP 403 Forbidden", "", StuckReason::Auth),
        ("OAuth token expired", "", StuckReason::Auth),
        ("could not launch", "spawn.failed", StuckReason::SpawnFailed),
    ] {
        let mut failures = HarnessFailures::default();
        let failed = json!({"status":"failed", "errorText":error, "errorKind":kind});
        for seq in 1..=3 {
            failures.observe(&failed, seq, seq * 100);
            assert_eq!(failures.stuck().is_some(), seq == 3, "{error}");
        }
        assert_eq!(failures.stuck().map(|s| (s.0, s.1)), Some((reason, 300)));
        failures.observe(&failed, 3, 999); // duplicate log replay
        failures.observe(&json!({"status":"cancelled"}), 4, 400);
        assert_eq!(failures.stuck().unwrap().1, 300);
        failures.observe(&json!({"status":"completed", "stopReason":"end_turn"}), 5, 500);
        assert!(failures.stuck().is_none());
    }
}

#[test]
fn stuck_ignores_unrelated_errors_and_redacts_credentials() {
    for error in [
        "simulated internal error",
        "retry after 2503s",
        "tool use was rejected",
        "HTTP 403 permission denied",
        "403 permission_error: this key cannot use the model",
    ] {
        assert_eq!(classify(&json!({}), error), None);
    }
    let mut failures = HarnessFailures::default();
    let failed = json!({"status":"failed", "errorText":"HTTP 503 https://alice:password@example.com Bearer secret-token"});
    for seq in 1..=3 {
        failures.observe(&failed, seq, seq);
    }
    let error = failures.stuck().unwrap().2;
    assert!(!error.contains("password"), "{error}");
    assert!(!error.contains("secret-token"), "{error}");
    for (error, secret) in [
        (r#"HTTP 503 password="correct horse, battery staple" retry"#, "horse"),
        (r#"HTTP 503 {"api_key": "a b\"c, d"} retry"#, "c, d"),
        ("HTTP 503 secret='one two, three'", "two"),
        (r#"HTTP 401 Authorization: Bearer "abc123""#, "abc123"),
        (r#"HTTP 401 Authorization: Basic 'dXNlcjpwYXNz word'"#, "word"),
        (r#"HTTP 503 token="cut off before the quote"#, "before"),
    ] {
        let redacted = redact(error);
        assert!(!redacted.contains(secret), "{redacted}");
        assert!(redacted.starts_with("HTTP "), "{redacted}");
    }
}
