//! Error taxonomy for the relay CLI: fatal errors end the process with a
//! message (the JS relay's `FatalRelayError`), pairing expiry re-issues a
//! fresh approval link, and transient errors ride the reconnect backoff.

#[derive(Debug)]
pub enum RelayError {
    /// Print the message and exit with `exit_code`; reconnecting cannot help.
    Fatal { message: String, exit_code: i32 },
    /// The 10-minute approval window lapsed; issue a fresh link and keep
    /// waiting rather than dying on a slow first setup.
    PairingExpired { message: String },
    /// Socket loss, network failure: print and reconnect with backoff.
    Transient { message: String },
}

impl RelayError {
    pub fn fatal(message: impl Into<String>) -> RelayError {
        RelayError::Fatal { message: message.into(), exit_code: 1 }
    }

    pub fn transient(message: impl Into<String>) -> RelayError {
        RelayError::Transient { message: message.into() }
    }

    pub fn message(&self) -> &str {
        match self {
            RelayError::Fatal { message, .. }
            | RelayError::PairingExpired { message }
            | RelayError::Transient { message } => message,
        }
    }
}

impl std::fmt::Display for RelayError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for RelayError {}
