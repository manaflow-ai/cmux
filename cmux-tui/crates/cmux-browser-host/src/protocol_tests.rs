use super::*;
use serde_json::json;

/// FETCH-CANCEL-CODE compatibility: a decoder never fails on a code it
/// does not know (an older or newer peer's); `cancelled` round-trips.
#[test]
fn error_codes_round_trip_and_unknown_codes_still_decode() {
    let cancelled = DriverError::new(ErrorCode::Cancelled, "fetch: cancelled");
    let text = cancelled.to_json().to_string();
    assert!(text.contains(r#""code":"cancelled""#), "{text}");
    let back: DriverError = serde_json::from_str(&text).unwrap();
    assert_eq!(back.code, ErrorCode::Cancelled);
    let future: Result<DriverError, _> =
        serde_json::from_value(json!({"code": "some_future_code", "message": "m"}));
    let future = future.expect("an unknown code decodes");
    assert_eq!(future.message, "m");
}

#[test]
fn errors_serialize_with_protocol_codes() {
    let mut error = DriverError::new(ErrorCode::NotFound, "no tab");
    assert_eq!(error.to_json(), json!({"code": "not_found", "message": "no tab"}));
    error.error_name = Some("TypeError".into());
    assert_eq!(error.to_json()["errorName"], "TypeError");
    let back: DriverError = serde_json::from_value(error.to_json()).unwrap();
    assert_eq!(back, error);
}

#[test]
fn wait_until_parses_protocol_values() {
    assert_eq!(WaitUntil::parse(None).unwrap(), WaitUntil::Load);
    assert_eq!(WaitUntil::parse(Some("commit")).unwrap(), WaitUntil::Commit);
    assert_eq!(WaitUntil::parse(Some("networkidle")).unwrap(), WaitUntil::NetworkIdle);
    assert_eq!(WaitUntil::parse(Some("nope")).unwrap_err().code, ErrorCode::Invalid);
}

#[test]
fn timeout_defaults_and_reads_milliseconds() {
    assert_eq!(timeout_of(&json!({})), DEFAULT_TIMEOUT);
    assert_eq!(timeout_of(&json!({"timeoutMs": 250})), Duration::from_millis(250));
    assert_eq!(timeout_of(&json!({"timeoutMs": -1})), DEFAULT_TIMEOUT);
    assert_eq!(timeout_of(&json!({"timeoutMs": 0})), NO_TIMEOUT);
}
