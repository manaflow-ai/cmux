//! [`ConnectionError`]: what a client connection fails with, and which of those a redial retries.

use super::*;

#[derive(Debug)]
pub enum ConnectionError {
    Provider(ProviderError),
    Crypto(CryptoError),
    Link(LinkError),
    Session(SessionError),
    Protocol(String),
    GenerationExhausted,
    GenerationChanged {
        expected: u64,
        actual: u64,
    },
    ReconnectExhausted {
        attempts: u32,
        last: String,
    },
    ReconnectAttemptTimedOut {
        timeout: Duration,
    },
    ReconnectDeadlineExceeded {
        attempts: u32,
    },
    ShutdownTimedOut,
    Closed,
    /// The daemon refused the reconnect because it no longer has the logical
    /// session: it outlived the daemon's resume lease, or the daemon closed
    /// it. Not retryable: nothing can resume it, so the caller should stop
    /// redialing and offer a new session.
    SessionUnavailable,
    /// The daemon refused a new session because it already serves its limit
    /// of logical client sessions (`limit`, when the daemon named it).
    /// Retryable: a slot frees when another client disconnects.
    DaemonAtCapacity {
        limit: Option<usize>,
    },
}

impl ConnectionError {
    /// Whether the error represents an unavailable carrier rather than a
    /// rejected identity, invalid configuration, or protocol violation.
    pub fn is_retryable_carrier_failure(&self) -> bool {
        match self {
            Self::Provider(error) => error.is_retryable_carrier_failure(),
            Self::Crypto(CryptoError::LinkError(
                LinkError::Closed | LinkError::Transport(_) | LinkError::Refused(_),
            ))
            | Self::Crypto(CryptoError::UnexpectedEof)
            | Self::Crypto(CryptoError::HandshakeTimeout { .. })
            | Self::Link(LinkError::Closed | LinkError::Transport(_) | LinkError::Refused(_))
            | Self::Session(SessionError::Link(
                LinkError::Closed | LinkError::Transport(_) | LinkError::Refused(_),
            ))
            | Self::Session(SessionError::LinkMessage(_))
            | Self::Session(SessionError::SchedulerClosed)
            | Self::ReconnectAttemptTimedOut { .. }
            | Self::DaemonAtCapacity { .. } => true,
            _ => false,
        }
    }

    /// The far side's refusal, when a dial ended on one no redial cures
    /// ([`LinkError::Refused`]).
    pub fn refusal(&self) -> Option<&crate::link::Refusal> {
        match self {
            Self::Provider(error) => error.refusal(),
            Self::Link(error)
            | Self::Crypto(CryptoError::LinkError(error))
            | Self::Session(SessionError::Link(error)) => error.refusal(),
            _ => None,
        }
    }
}

impl fmt::Display for ConnectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Provider(error) => error.fmt(formatter),
            Self::Crypto(error) => error.fmt(formatter),
            Self::Link(error) => error.fmt(formatter),
            Self::Session(error) => error.fmt(formatter),
            Self::Protocol(message) => write!(formatter, "connection protocol failed: {message}"),
            Self::GenerationExhausted => formatter.write_str("connection generation exhausted"),
            Self::GenerationChanged { expected, actual } => {
                write!(formatter, "connection generation changed from {expected} to {actual}")
            }
            // retry-prompt-ok: reports the automatic reconnect loop giving up, not a prompt
            Self::ReconnectExhausted { attempts, last } => {
                write!(formatter, "reconnect failed after {attempts} attempts: {last}")
            }
            // retry-prompt-ok: reports the automatic reconnect loop giving up, not a prompt
            Self::ReconnectAttemptTimedOut { timeout } => {
                write!(formatter, "reconnect attempt timed out after {}ms", timeout.as_millis())
            }
            // retry-prompt-ok: reports the automatic reconnect loop giving up, not a prompt
            Self::ReconnectDeadlineExceeded { attempts } => {
                write!(formatter, "reconnect deadline expired after {attempts} attempts")
            }
            Self::ShutdownTimedOut => formatter.write_str("connection shutdown timed out"),
            Self::Closed => formatter.write_str("connection is closed"),
            Self::SessionUnavailable => formatter.write_str(
                "daemon no longer has the requested logical session (it expired or was closed)",
            ),
            Self::DaemonAtCapacity { limit: Some(limit) } => write!(
                formatter,
                "too many connected clients: the daemon serves its limit of {limit}; \
                 close other clients or raise the daemon's open-file limit"
            ),
            Self::DaemonAtCapacity { limit: None } => formatter.write_str(
                "too many connected clients: the daemon serves its limit; \
                 close other clients or raise the daemon's open-file limit",
            ),
        }
    }
}

pub(super) fn reconnectable_session_error(error: &SessionError) -> bool {
    matches!(
        error,
        SessionError::Link(LinkError::Closed | LinkError::Transport(_))
            | SessionError::LinkMessage(_)
            | SessionError::SchedulerClosed
    )
}

pub(super) fn retryable_connection_error(error: &ConnectionError) -> bool {
    error.is_retryable_carrier_failure()
}

impl std::error::Error for ConnectionError {}

impl From<ProviderError> for ConnectionError {
    fn from(error: ProviderError) -> Self {
        Self::Provider(error)
    }
}

impl From<CryptoError> for ConnectionError {
    fn from(error: CryptoError) -> Self {
        Self::Crypto(error)
    }
}

impl From<LinkError> for ConnectionError {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

impl From<SessionError> for ConnectionError {
    fn from(error: SessionError) -> Self {
        Self::Session(error)
    }
}
