//! Error replies of `cloud-conversations-v1` (home-cloud-proxy.md section 6).

use std::fmt;

/// Why a cloud command failed. `BadRequest` is a parameter shape error and
/// carries no `error_code`, like the local owner's `bad request: …` errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloudError {
    /// The owner (or the Worker, or the daemon for its own reasons) decided
    /// and refused the request. `code` is the stable reason.
    Rejected {
        code: String,
        message: String,
        retryable: bool,
    },
    /// No session lease; nothing was sent.
    SignedOut,
    /// The lease expired; nothing was sent.
    SessionExpired,
    /// The cloud refused the bearer token (HTTP 401).
    Unauthenticated,
    /// Transport failure, timeout, 5xx or a malformed reply. For a mutation
    /// the outcome is unknown: retry with the same idempotency key.
    Unavailable(String),
    BadRequest(String),
}

impl CloudError {
    pub const REJECTED: &'static str = "cloud_conversation_rejected";

    pub(crate) fn daemon_reject(code: &str, message: impl Into<String>) -> Self {
        Self::Rejected { code: code.to_string(), message: message.into(), retryable: false }
    }

    /// The reply's `error_code`, when the error has one.
    pub fn error_code(&self) -> Option<&'static str> {
        match self {
            Self::Rejected { .. } => Some(Self::REJECTED),
            Self::SignedOut => Some("cloud_signed_out"),
            Self::SessionExpired => Some("cloud_session_expired"),
            Self::Unauthenticated => Some("cloud_unauthenticated"),
            Self::Unavailable(_) => Some("cloud_unavailable"),
            Self::BadRequest(_) => None,
        }
    }

    /// The reply's stable `reason`.
    pub fn reason(&self) -> Option<String> {
        match self {
            Self::Rejected { code, .. } => Some(code.clone()),
            Self::SignedOut => Some("missing".into()),
            Self::SessionExpired => Some("expired".into()),
            Self::Unauthenticated => Some("unauthenticated".into()),
            Self::Unavailable(_) => Some("unavailable".into()),
            Self::BadRequest(_) => None,
        }
    }

    /// The reply's `retryable` flag.
    pub fn retryable(&self) -> Option<bool> {
        match self {
            Self::Rejected { retryable, .. } => Some(*retryable),
            Self::SignedOut => Some(false),
            Self::SessionExpired | Self::Unauthenticated | Self::Unavailable(_) => Some(true),
            Self::BadRequest(_) => None,
        }
    }
}

impl fmt::Display for CloudError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Rejected { code, message, .. } if message.is_empty() || message == code => write!(
                formatter,
                "cmux Cloud conversation request failed ({code}); retry the command",
            ),
            Self::Rejected { code, message, .. } => write!(
                formatter,
                "cmux Cloud conversation request failed: {message} ({code}); retry the command",
            ),
            Self::SignedOut => formatter.write_str(
                "cmux Cloud conversation request failed: not signed in; run `cmux cloud sign-in`",
            ),
            Self::SessionExpired => formatter.write_str(
                "cmux Cloud conversation request failed: the session expired; run `cmux cloud sign-in`",
            ),
            Self::Unauthenticated => formatter.write_str(
                "cmux Cloud conversation request failed: the session was refused; run `cmux cloud sign-in`",
            ),
            Self::Unavailable(detail) => write!(
                formatter,
                "cmux Cloud conversation request failed: {detail}; retry the command or run `cmux cloud diagnostics`",
            ),
            Self::BadRequest(detail) => write!(
                formatter,
                "cmux Cloud conversation request had invalid arguments: {detail}; retry with valid arguments",
            ),
        }
    }
}

impl std::error::Error for CloudError {}
