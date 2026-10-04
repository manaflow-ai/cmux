//! Typed op errors. Codes are `cmux.cloud.<reason>`; `message` is display
//! text (the Cloud API's `ui.message` when it sent one).

use serde::Serialize;
use serde_json::Value;

/// Every error code the server answers.
pub mod codes {
    pub const AUTH_REQUIRED: &str = "cmux.cloud.auth_required";
    pub const FORBIDDEN: &str = "cmux.cloud.forbidden";
    pub const NOT_FOUND: &str = "cmux.cloud.not_found";
    pub const CONFLICT: &str = "cmux.cloud.conflict";
    pub const PLAN_LIMIT: &str = "cmux.cloud.plan_limit";
    pub const RATE_LIMITED: &str = "cmux.cloud.rate_limited";
    pub const UNSUPPORTED: &str = "cmux.cloud.unsupported";
    pub const UPSTREAM: &str = "cmux.cloud.upstream_error";
    pub const BAD_RESPONSE: &str = "cmux.cloud.bad_response";
    pub const INVALID_ARGS: &str = "cmux.cloud.invalid_args";
    pub const UNKNOWN_OP: &str = "cmux.cloud.unknown_op";
    pub const ORIGIN_REFUSED: &str = "cmux.cloud.origin_refused";
    pub const IDEMPOTENCY_KEY_REQUIRED: &str = "cmux.cloud.idempotency_key_required";
    pub const IDEMPOTENCY_KEY_FORBIDDEN: &str = "cmux.cloud.idempotency_key_forbidden";
    pub const IDEMPOTENCY_CONFLICT: &str = "cmux.cloud.idempotency_conflict";
    pub const RELAY_UNAVAILABLE: &str = "cmux.cloud.relay_unavailable";
    /// A same-key retry of a create the Cloud API does not dedup, after an
    /// attempt that got no answer: list first, then use a new key.
    pub const OUTCOME_UNKNOWN: &str = "cmux.cloud.outcome_unknown";
}

/// A typed op failure.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CloudError {
    pub code: &'static str,
    pub message: String,
    /// HTTP status of the Cloud API answer, when there was one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    /// The Cloud API's own error code (`error` field or `x-cmux-vm-error`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream_code: Option<String>,
    pub retryable: bool,
}

impl CloudError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), status: None, upstream_code: None, retryable: false }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(codes::INVALID_ARGS, message)
    }

    /// Maps a non-2xx Cloud API answer (`{error, message, ui: {message}}`).
    pub fn from_http(status: u16, body: &Value, header_code: Option<&str>) -> Self {
        let upstream = header_code
            .map(str::to_owned)
            .or_else(|| body.get("error").and_then(Value::as_str).map(str::to_owned));
        let message = body
            .pointer("/ui/message")
            .and_then(Value::as_str)
            .or_else(|| body.get("message").and_then(Value::as_str))
            .map(str::to_owned)
            .unwrap_or_else(|| format!("cmux Cloud answered HTTP {status}"));
        let plan = upstream.as_deref().is_some_and(|c| {
            c.contains("requires_pro") || c.contains("exceeds_plan") || c.contains("limit")
        });
        let code = match status {
            401 => codes::AUTH_REQUIRED,
            402 => codes::PLAN_LIMIT,
            403 if plan => codes::PLAN_LIMIT,
            403 => codes::FORBIDDEN,
            404 => codes::NOT_FOUND,
            409 if plan => codes::PLAN_LIMIT,
            409 => codes::CONFLICT,
            429 => codes::RATE_LIMITED,
            501 => codes::UNSUPPORTED,
            400..=499 => codes::INVALID_ARGS,
            _ => codes::UPSTREAM,
        };
        let retryable = body
            .get("retryable")
            .and_then(Value::as_bool)
            .unwrap_or(matches!(status, 429 | 502..=504));
        Self { code, message, status: Some(status), upstream_code: upstream, retryable }
    }
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for CloudError {}
