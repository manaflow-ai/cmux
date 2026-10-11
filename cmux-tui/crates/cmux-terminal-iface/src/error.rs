//! The interfaces' typed errors (`errors` in the JSON).

use std::fmt;

/// `hostKey.decision`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyRefusal {
    /// No key is pinned for the connection handle.
    Unknown,
    /// A different key is pinned for the connection handle.
    Changed,
}

impl HostKeyRefusal {
    /// The wire name (`unknown`, `changed`).
    pub fn name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Changed => "changed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendError {
    /// `unsupported {}`: the implementation cannot do this.
    Unsupported,
    /// `unavailable {reason, retryable}`: not reachable now.
    Unavailable { reason: String, retryable: bool },
    /// `hostKey {decision, fingerprint}`: typed host key refusal; the host
    /// shows its accept sheet from these fields. Nothing reached the far shell.
    HostKey { decision: HostKeyRefusal, fingerprint: String },
    /// `denied {reason}`: a kind not in `options.kinds`, a refused open
    /// token, a revoked handle, or a failed host check.
    Denied { reason: String },
    /// `invalid {reason}`: a bad argument, or a channel that is not open.
    Invalid { reason: String },
}

impl BackendError {
    pub fn invalid(reason: impl Into<String>) -> Self {
        Self::Invalid { reason: reason.into() }
    }

    pub fn denied(reason: impl Into<String>) -> Self {
        Self::Denied { reason: reason.into() }
    }

    /// The channel is closed, exited or lost. Nothing is queued.
    pub fn not_open() -> Self {
        Self::invalid("the channel is not open")
    }

    /// The wire code (`unsupported`, `unavailable`, `hostKey`, `denied`, `invalid`).
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::Unavailable { .. } => "unavailable",
            Self::HostKey { .. } => "hostKey",
            Self::Denied { .. } => "denied",
            Self::Invalid { .. } => "invalid",
        }
    }

    /// Whether the same call may work later.
    pub fn retryable(&self) -> bool {
        matches!(self, Self::Unavailable { retryable: true, .. })
    }
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => f.write_str("unsupported"),
            Self::Unavailable { reason, .. } => write!(f, "unavailable: {reason}"),
            Self::HostKey { decision, fingerprint } => {
                write!(f, "host key {}: {fingerprint}", decision.name())
            }
            Self::Denied { reason } => write!(f, "denied: {reason}"),
            Self::Invalid { reason } => write!(f, "invalid: {reason}"),
        }
    }
}

impl std::error::Error for BackendError {}
