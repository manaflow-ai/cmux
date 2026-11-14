use super::shutdown_reason;
use serde_json::json;

#[test]
fn a_stop_logs_the_reason_its_client_gave_on_one_line() {
    assert_eq!(shutdown_reason(&json!({"reason": "update: build a -> b"})), "update: build a -> b");
    assert_eq!(shutdown_reason(&json!({"reason": "two\nlines"})), "two lines");
    assert_eq!(shutdown_reason(&json!({"reason": "x".repeat(500)})).chars().count(), 160);
}

#[test]
fn a_stop_without_a_reason_logs_unspecified() {
    assert_eq!(shutdown_reason(&json!({})), "unspecified");
    assert_eq!(shutdown_reason(&json!({"reason": "  "})), "unspecified");
    assert_eq!(shutdown_reason(&json!({"reason": 7})), "unspecified");
}
