//! Errors of an RFB session.

use std::fmt;
use std::io;

/// Why a connection or a session ended.
#[derive(Debug)]
pub enum VncError {
    /// The socket or the proxy command failed, or the server closed it.
    Io(io::Error),
    /// The server sent bytes this client cannot accept (a bad version, an
    /// unknown message, a rectangle outside the framebuffer, a size past a
    /// limit). A hostile or broken server ends here, never in a panic.
    Protocol(String),
    /// The server offers no security type this client can use.
    UnsupportedSecurity(Vec<u8>),
    /// The server needs credentials that were not given. `username` is true
    /// when it needs a user name too (Apple DH, VeNCrypt plain).
    CredentialsRequired { username: bool },
    /// The server refused the credentials or the connection, with its reason.
    AuthFailed(String),
}

impl VncError {
    pub(crate) fn protocol(message: impl Into<String>) -> Self {
        Self::Protocol(message.into())
    }

    /// True when retrying with the same credentials cannot succeed, so a
    /// reconnect loop should stop and ask the person instead.
    pub fn is_auth(&self) -> bool {
        matches!(
            self,
            Self::AuthFailed(_) | Self::CredentialsRequired { .. } | Self::UnsupportedSecurity(_)
        )
    }
}

impl fmt::Display for VncError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                f.write_str("the server closed the connection")
            }
            Self::Io(error) => write!(f, "{error}"),
            Self::Protocol(message) => write!(f, "protocol error: {message}"),
            Self::UnsupportedSecurity(types) => {
                write!(f, "the server offers no supported security type (offered {types:?})")
            }
            Self::CredentialsRequired { username: true } => {
                f.write_str("the server needs a user name and password")
            }
            Self::CredentialsRequired { username: false } => {
                f.write_str("the server needs a password")
            }
            Self::AuthFailed(reason) if reason.is_empty() => f.write_str("authentication failed"),
            Self::AuthFailed(reason) => write!(f, "authentication failed: {reason}"),
        }
    }
}

impl std::error::Error for VncError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for VncError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub type Result<T> = std::result::Result<T, VncError>;
