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
            Self::Rejected { code, message, retryable } => {
                write!(formatter, "cmux Cloud conversation request failed ({code})")?;
                if !message.is_empty() && message != code {
                    write!(formatter, ": {message}")?;
                }
                if *retryable {
                    formatter.write_str(
                        "; retry the request; if it keeps failing, run `cmux cloud diagnostics`",
                    )
                } else {
                    formatter.write_str("; run `cmux cloud diagnostics`")
                }
            }
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
                "cmux Cloud conversation request failed: {detail}; a change may have gone through, so check the conversation before resending; if it keeps failing, run `cmux cloud diagnostics`",
            ),
            Self::BadRequest(detail) => write!(
                formatter,
                "bad request: {detail}; check the arguments with `cmux --help`",
            ),
        }
    }
}

impl std::error::Error for CloudError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_names_the_next_step_and_retries_only_retryable_failures() {
        for error in
            [CloudError::SignedOut, CloudError::SessionExpired, CloudError::Unauthenticated]
        {
            assert!(error.to_string().contains("cmux cloud sign-in"));
        }
        for retryable in [false, true] {
            let error = CloudError::Rejected {
                code: "denied".into(),
                message: "scope is missing".into(),
                retryable,
            };
            let message = error.to_string();
            assert!(message.contains("scope is missing"));
            assert!(message.contains("cmux cloud diagnostics"));
            assert_eq!(message.contains("retry"), retryable, "{message}");
        }
        let rate_limited = CloudError::Rejected {
            code: "rate_limited".into(),
            message: "HTTP 429".into(),
            retryable: true,
        };
        assert!(rate_limited.to_string().contains("retry the request"));
        // The outcome of a mutation is unknown: never advise a blind resend.
        let unavailable = CloudError::Unavailable("timeout".into()).to_string();
        assert!(!unavailable.contains("retry"), "{unavailable}");
        assert!(unavailable.contains("check the conversation before resending"));
        assert!(unavailable.contains("cmux cloud diagnostics"));
        assert!(CloudError::BadRequest("missing id".into()).to_string().contains("cmux --help"));
    }
}
