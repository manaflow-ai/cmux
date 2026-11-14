use super::*;

#[test]
fn a_tagged_platform_error_keeps_its_tag_code_and_message() {
    let e = ApiError::from_status(
        409,
        br#"{"_tag":"MachineConflict","code":"machine.capacity","message":"no room"}"#,
    );
    assert_eq!(e.tag.as_deref(), Some("MachineConflict"));
    assert_eq!(e.code.as_deref(), Some("machine.capacity"));
    assert_eq!(e.message, "no room");
    assert!(!e.retryable);
    assert_eq!(e.to_string(), "HTTP 409 machine.capacity: no room");
}

#[test]
fn a_wire_error_body_reads_the_same_way() {
    let e = ApiError::from_status(
        503,
        br#"{"error":{"code":"cloud.provider.unavailable","message":"later"}}"#,
    );
    assert_eq!(e.code.as_deref(), Some("cloud.provider.unavailable"));
    assert!(e.retryable);
}

/// Every code of cmux-platform's refusal table (cmux-platform#1192), as #1192 answers it:
/// the body's `retryable` decides, not the status (a busy machine's 409 is retried, a final
/// 503 is not, a cap's 403 never).
#[test]
fn every_platform_refusal_is_retried_as_its_body_says() {
    use cmux_cloud_machine::refusals::{Handling, PLATFORM};
    for refusal in PLATFORM {
        let body = serde_json::json!({
            "_tag": "MachineRefusal", "code": refusal.code, "message": "m",
            "retryable": refusal.retryable,
        });
        let e = ApiError::from_status(refusal.status, body.to_string().as_bytes());
        assert_eq!(
            e.retryable,
            refusal.handling() != Handling::Final,
            "{} {}",
            refusal.status,
            refusal.code
        );
    }
    let limited = ApiError::from_answer(
            429,
            Some("7"),
            br#"{"_tag":"MachineRateLimited","code":"cloud.rate_limited","retryable":true,"retryAfterSeconds":42}"#,
        );
    assert_eq!(limited.retry_after, Some(std::time::Duration::from_secs(42)));
    let header_only = ApiError::from_answer(429, Some("7"), b"");
    assert_eq!(header_only.retry_after, Some(std::time::Duration::from_secs(7)));
    assert!(header_only.retryable, "no body: the status decides");
    let busy = ApiError::from_status(409, br#"{"code":"cloud.machine.busy","retryable":true}"#);
    assert_eq!(busy.retry_after, None, "only a rate limit waits a window");
    // A 503 that says it is final.
    let e = ApiError::from_status(
        503,
        br#"{"code":"machine.placement_unavailable","retryable":false,"cause":"x: y"}"#,
    );
    assert!(!e.retryable);
}

#[test]
fn an_html_proxy_page_is_not_shown_as_the_message() {
    let e = ApiError::from_status(502, b"<html>bad gateway</html>");
    assert_eq!(e.message, "the Cloud API answered HTTP 502");
    assert!(e.retryable);
    assert_eq!(e.code, None);
}
