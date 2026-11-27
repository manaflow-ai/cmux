//! Driver protocol values shared by every driver.
//!
//! The contract is `docs/browser-repl/driver-protocol.md` from PR #15570:
//! methods take and return JSON, errors are `{ code, message }`, and events
//! carry a `targetId`. This module holds the typed pieces that drivers and the
//! provider connection share.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use std::time::Duration;

/// Default deadline for one driver call when the caller passes no `timeoutMs`.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Error codes of the driver protocol, plus the host's own codes
/// (`forbidden` for policy refusals, `ambiguous` for input whose result was
/// lost and must not be replayed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    NotFound,
    Stale,
    Timeout,
    Unsupported,
    Invalid,
    Closed,
    Evaluation,
    Forbidden,
    Ambiguous,
    /// The host stopped the call (a fetch whose cell timed out, or whose
    /// session ended): classic main's `cancelled`.
    Cancelled,
    /// A code this build does not know (a newer peer's): decoding never
    /// fails on one, so adding a code breaks no older reader of this enum.
    #[serde(other)]
    Unknown,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::NotFound => "not_found",
            ErrorCode::Stale => "stale",
            ErrorCode::Timeout => "timeout",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::Invalid => "invalid",
            ErrorCode::Closed => "closed",
            ErrorCode::Evaluation => "evaluation",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::Ambiguous => "ambiguous",
            ErrorCode::Cancelled => "cancelled",
            ErrorCode::Unknown => "unknown",
        }
    }
}

/// A driver error as it crosses every boundary (`{ code, message, errorName?, data? }`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DriverError {
    pub code: ErrorCode,
    pub message: String,
    #[serde(rename = "errorName", default, skip_serializing_if = "Option::is_none")]
    pub error_name: Option<String>,
    /// Structured detail for a refusal (for example `{reason, extensions}`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl DriverError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        DriverError { code, message: message.into(), error_name: None, data: None }
    }

    pub fn unsupported_method(method: &str) -> Self {
        DriverError::new(ErrorCode::Unsupported, format!("Unsupported driver method {method}"))
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        DriverError::new(ErrorCode::Invalid, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        DriverError::new(ErrorCode::NotFound, message)
    }

    pub fn closed(message: impl Into<String>) -> Self {
        DriverError::new(ErrorCode::Closed, message)
    }

    pub fn cancelled(message: impl Into<String>) -> Self {
        DriverError::new(ErrorCode::Cancelled, message)
    }

    pub fn timeout(message: impl Into<String>) -> Self {
        DriverError::new(ErrorCode::Timeout, message)
    }

    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

impl fmt::Display for DriverError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for DriverError {}

/// One driver event (`driver.on(name, handler)`); the payload carries `targetId`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DriverEvent {
    pub name: String,
    #[serde(default)]
    pub payload: Value,
}

/// `waitUntil` of navigation methods.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitUntil {
    Commit,
    DomContentLoaded,
    Load,
    NetworkIdle,
}

impl WaitUntil {
    /// Parses the protocol value; absent means `load`, as Playwright.
    pub fn parse(value: Option<&str>) -> Result<Self, DriverError> {
        match value {
            None | Some("load") => Ok(WaitUntil::Load),
            Some("commit") => Ok(WaitUntil::Commit),
            Some("domcontentloaded") => Ok(WaitUntil::DomContentLoaded),
            Some("networkidle") => Ok(WaitUntil::NetworkIdle),
            Some(other) => Err(DriverError::invalid(format!(
                "waitUntil: expected one of \"commit\", \"domcontentloaded\", \"load\", \"networkidle\", got {other:?}"
            ))),
        }
    }
}

/// Reads `timeoutMs` from params, else the default deadline.
/// `timeoutMs: 0` means no timeout, as in Playwright; it is capped here so
/// deadline arithmetic cannot overflow.
pub const NO_TIMEOUT: Duration = Duration::from_secs(24 * 60 * 60);

pub fn timeout_of(params: &Value) -> Duration {
    match params.get("timeoutMs").and_then(Value::as_f64).filter(|ms| ms.is_finite() && *ms >= 0.0)
    {
        Some(0.0) => NO_TIMEOUT,
        Some(ms) => Duration::from_millis(ms as u64).min(NO_TIMEOUT),
        None => DEFAULT_TIMEOUT,
    }
}

/// A required string parameter.
pub fn required_str<'a>(params: &'a Value, name: &str) -> Result<&'a str, DriverError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| DriverError::invalid(format!("{name}: expected a string")))
}

/// A required number parameter.
pub fn required_f64(params: &Value, name: &str) -> Result<f64, DriverError> {
    params
        .get(name)
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite())
        .ok_or_else(|| DriverError::invalid(format!("{name}: expected a number")))
}

#[cfg(test)]
mod tests {
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
}
