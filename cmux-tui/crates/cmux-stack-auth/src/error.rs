//! How a Stack call fails (the SDK's `StackAuthError`, `OAuthError` and `UserNotSignedInError`).
//! Each failure keeps the SDK's `code`, which the display-safe mapping and the sign-in screen
//! read. None carries a token, a URL or a server message body in its `Display`.

use crate::wire::BodyKind;

/// One 429 from Stack, reduced to what is safe to report.
#[derive(Clone, Debug, PartialEq)]
pub struct RateLimit {
    /// The path with ids replaced by `ID` ([`crate::redacted_endpoint`]).
    pub endpoint: String,
    pub body_kind: BodyKind,
    /// The server's `Retry-After`, when it sent one (at most a day).
    pub retry_after_s: Option<f64>,
    pub request_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum StackError {
    /// HTTP 429. The edge can answer with an HTML page, so this is read from the status alone.
    RateLimited(RateLimit),
    /// A Stack error the server named (`x-hexclave-known-error`), such as `INVALID_TOTP_CODE`.
    Known {
        code: String,
        /// The body's `message` or `error`; for a screen that localizes by code, not for logs.
        message: String,
        http_status: u16,
        request_id: Option<String>,
        /// The body's `details`, when it has them (`attempt_code` of an MFA requirement).
        details: Option<serde_json::Value>,
    },
    /// A non-2xx answer with no known error.
    Http { status: u16, request_id: Option<String> },
    /// The OAuth token endpoint refused a code exchange: its `error` (`invalid_grant`, ...), or
    /// `token_exchange_failed` with no readable one.
    OAuth { code: String, status: u16 },
    /// No answer: connect, DNS, TLS or a broken-off body, after any retries.
    Network(&'static str),
    /// No answer by the request's deadline, after any retries.
    TimedOut,
    /// A 2xx answer this client could not read.
    Parse(&'static str),
    /// The call needs a signed-in session and there is none (or it could not be refreshed).
    NotSignedIn,
    /// The configuration cannot make a request (a base URL that does not parse).
    Client(&'static str),
}

impl StackError {
    /// The SDK's error code for this failure.
    pub fn code(&self) -> &str {
        match self {
            StackError::RateLimited(_) => "RATE_LIMITED",
            StackError::Known { code, .. } | StackError::OAuth { code, .. } => code,
            StackError::Http { .. } => "http_error",
            StackError::Network(_) | StackError::TimedOut => "network_error",
            StackError::Parse(_) => "parse_error",
            StackError::NotSignedIn => "USER_NOT_SIGNED_IN",
            StackError::Client(_) => "invalid_url",
        }
    }

    /// The HTTP status, when the server answered.
    pub fn http_status(&self) -> Option<u16> {
        match self {
            StackError::RateLimited(_) => Some(429),
            StackError::Known { http_status, .. } => Some(*http_status),
            StackError::Http { status, .. } | StackError::OAuth { status, .. } => Some(*status),
            _ => None,
        }
    }

    /// Stack's request id, when the answer had one (for a person to report).
    pub fn request_id(&self) -> Option<&str> {
        match self {
            StackError::RateLimited(limit) => limit.request_id.as_deref(),
            StackError::Known { request_id, .. } | StackError::Http { request_id, .. } => {
                request_id.as_deref()
            }
            _ => None,
        }
    }
}

/// The code, the status and what went wrong in fixed words.
impl std::fmt::Display for StackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())?;
        if let Some(status) = self.http_status() {
            write!(f, " (HTTP {status})")?;
        }
        match self {
            StackError::Network(words) | StackError::Parse(words) | StackError::Client(words) => {
                write!(f, ": {words}")
            }
            StackError::TimedOut => f.write_str(": timed out"),
            _ => Ok(()),
        }
    }
}

impl std::error::Error for StackError {}
