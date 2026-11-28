//! The `reason` an `_acpmux/shutdown` request gives, as the log keeps it.

use serde_json::Value;

/// The longest `_acpmux/shutdown` `reason` the log keeps, in characters.
const SHUTDOWN_REASON_MAX: usize = 160;

/// The `reason` a client gave for `_acpmux/shutdown`, one line for the log: control characters
/// become spaces and it is cut at [`SHUTDOWN_REASON_MAX`] characters. A client that gives none
/// (an older app or CLI) logs `unspecified`, which the daily count of stops reads as unknown.
pub(super) fn shutdown_reason(params: &Value) -> String {
    let given = params.get("reason").and_then(Value::as_str).map(str::trim).unwrap_or_default();
    if given.is_empty() {
        return "unspecified".to_owned();
    }
    given.chars().take(SHUTDOWN_REASON_MAX).map(|c| if c.is_control() { ' ' } else { c }).collect()
}

#[cfg(test)]
mod shutdown_reason_tests {
    use super::shutdown_reason;
    use serde_json::json;

    #[test]
    fn a_stop_logs_the_reason_its_client_gave_on_one_line() {
        assert_eq!(
            shutdown_reason(&json!({"reason": "update: build a -> b"})),
            "update: build a -> b"
        );
        assert_eq!(shutdown_reason(&json!({"reason": "two\nlines"})), "two lines");
        assert_eq!(shutdown_reason(&json!({"reason": "x".repeat(500)})).chars().count(), 160);
    }

    #[test]
    fn a_stop_without_a_reason_logs_unspecified() {
        assert_eq!(shutdown_reason(&json!({})), "unspecified");
        assert_eq!(shutdown_reason(&json!({"reason": "  "})), "unspecified");
        assert_eq!(shutdown_reason(&json!({"reason": 7})), "unspecified");
    }
}
