//! Why a call to the store failed.

use std::fmt;

use crate::wire::{ErrorCode, ErrorEnvelope, SessionView};

/// A failed call. It keeps the `auto.*` code, tells an answer from no answer, and says whether
/// the same call can be sent again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutoCloudError {
    /// The store answered with an error.
    Http {
        status: u16,
        /// The `auto.*` code, when the error is one.
        code: Option<ErrorCode>,
        /// The code as the store wrote it (`validation.invalid`, `not_found`); empty when the
        /// body was no error envelope.
        raw_code: String,
        message: String,
        /// The chat as it is now, on a refusal about a chat the caller may see.
        session: Option<Box<SessionView>>,
        /// `auto.seq_gap`: the last seq the store has.
        last_seq: Option<u64>,
        /// `auto.snapshot_incomplete`: the chunks the store does not have.
        missing: Vec<String>,
    },
    /// No answer arrived: no network, a timeout, a dropped connection.
    Transport { message: String },
    /// An answer arrived that this build cannot read.
    Decoding { message: String },
}

impl AutoCloudError {
    /// A refusal with an `auto.*` code, at the status the store uses for it.
    pub fn refused(code: ErrorCode, message: impl Into<String>) -> AutoCloudError {
        AutoCloudError::Http {
            status: code.status(),
            code: Some(code),
            raw_code: code.as_str().to_owned(),
            message: message.into(),
            session: None,
            last_seq: None,
            missing: Vec::new(),
        }
    }

    /// The same error, carrying the chat as it is now.
    #[must_use]
    pub fn with_session(mut self, view: SessionView) -> AutoCloudError {
        if let AutoCloudError::Http { session, .. } = &mut self {
            *session = Some(Box::new(view));
        }
        self
    }

    /// An error answer with a code that is not `auto.*`.
    pub fn http(status: u16, code: &str, message: impl Into<String>) -> AutoCloudError {
        AutoCloudError::Http {
            status,
            code: ErrorCode::parse(code),
            raw_code: code.to_owned(),
            message: message.into(),
            session: None,
            last_seq: None,
            missing: Vec::new(),
        }
    }

    pub fn transport(message: impl Into<String>) -> AutoCloudError {
        AutoCloudError::Transport { message: message.into() }
    }

    pub fn decoding(message: impl Into<String>) -> AutoCloudError {
        AutoCloudError::Decoding { message: message.into() }
    }

    /// Reads an error answer: its status and its body, an error envelope or not.
    pub fn from_response(status: u16, body: &[u8]) -> AutoCloudError {
        match serde_json::from_slice::<ErrorEnvelope>(body) {
            Ok(envelope) => AutoCloudError::Http {
                status,
                code: envelope.code(),
                raw_code: envelope.error.code,
                message: envelope.error.message,
                session: envelope.session.map(Box::new),
                last_seq: envelope.last_seq,
                missing: envelope.missing,
            },
            Err(_) => AutoCloudError::Http {
                status,
                code: None,
                raw_code: String::new(),
                message: format!("HTTP {status}"),
                session: None,
                last_seq: None,
                missing: Vec::new(),
            },
        }
    }

    /// The chat as the store has it now, when the refusal carried it.
    pub fn session(&self) -> Option<&SessionView> {
        match self {
            AutoCloudError::Http { session, .. } => session.as_deref(),
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => None,
        }
    }

    /// The `auto.*` code of an error answer.
    pub fn code(&self) -> Option<ErrorCode> {
        match self {
            AutoCloudError::Http { code, .. } => *code,
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => None,
        }
    }

    /// The status of an error answer; None when no answer arrived or it could not be read.
    pub fn status(&self) -> Option<u16> {
        match self {
            AutoCloudError::Http { status, .. } => Some(*status),
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => None,
        }
    }

    /// No answer arrived.
    pub fn is_transport(&self) -> bool {
        matches!(self, AutoCloudError::Transport { .. })
    }

    /// The same call may succeed later as it is: no answer arrived, or the store answered 408,
    /// 425, 429 or 5xx. An `auto.*` refusal is never retryable as it is.
    pub fn retryable(&self) -> bool {
        match self {
            AutoCloudError::Transport { .. } => true,
            AutoCloudError::Http { status, code, .. } => {
                code.is_none() && (matches!(status, 408 | 425 | 429) || *status >= 500)
            }
            AutoCloudError::Decoding { .. } => false,
        }
    }

    /// `auto.seq_gap`'s `lastSeq`.
    pub fn last_seq(&self) -> Option<u64> {
        match self {
            AutoCloudError::Http { last_seq, .. } => *last_seq,
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => None,
        }
    }

    /// `auto.snapshot_incomplete`'s missing chunks.
    pub fn missing(&self) -> &[String] {
        match self {
            AutoCloudError::Http { missing, .. } => missing,
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => &[],
        }
    }

    /// The error as the store would answer it: the status and the envelope. None when no answer
    /// arrived or it could not be read.
    pub fn envelope(&self) -> Option<(u16, ErrorEnvelope)> {
        match self {
            AutoCloudError::Http {
                status, raw_code, message, session, last_seq, missing, ..
            } => {
                let mut envelope = ErrorEnvelope::new(raw_code, message.clone());
                envelope.session = session.as_deref().cloned();
                envelope.last_seq = *last_seq;
                envelope.missing = missing.clone();
                Some((*status, envelope))
            }
            AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => None,
        }
    }
}

impl fmt::Display for AutoCloudError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AutoCloudError::Http { status, raw_code, message, .. } if raw_code.is_empty() => {
                write!(f, "the Cloud answered {status}: {message}")
            }
            AutoCloudError::Http { status, raw_code, message, .. } => {
                write!(f, "the Cloud answered {status} {raw_code}: {message}")
            }
            AutoCloudError::Transport { message } => {
                write!(f, "the Cloud did not answer: {message}")
            }
            AutoCloudError::Decoding { message } => {
                write!(f, "the Cloud's answer could not be read: {message}")
            }
        }
    }
}

impl std::error::Error for AutoCloudError {}
