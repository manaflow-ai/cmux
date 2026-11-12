//! The remote daemon's error, outside the `host` feature: the client half's
//! service endpoints name it, while the daemon itself is host-only.

use std::fmt;

use crate::connection::ConnectionError;
use crate::crypto::CryptoError;
use crate::identity::IdentityError;
use crate::link::LinkError;
use crate::session::SessionError;

#[derive(Debug)]
pub enum DaemonError {
    Crypto(CryptoError),
    Identity(IdentityError),
    Connection(ConnectionError),
    Link(LinkError),
    Session(SessionError),
    Protocol(String),
    Generation { expected: u64, actual: u64 },
    GenerationExhausted,
    HandshakeBusy,
    ApprovalBusy,
    HandshakeTimeout,
    Closed,
}

impl fmt::Display for DaemonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Crypto(error) => error.fmt(formatter),
            Self::Identity(error) => error.fmt(formatter),
            Self::Connection(error) => error.fmt(formatter),
            Self::Link(error) => error.fmt(formatter),
            Self::Session(error) => error.fmt(formatter),
            Self::Protocol(message) => write!(formatter, "daemon protocol failed: {message}"),
            Self::Generation { expected, actual } => {
                write!(
                    formatter,
                    "connection generation {actual} does not match expected {expected}"
                )
            }
            Self::GenerationExhausted => formatter.write_str("connection generation exhausted"),
            Self::HandshakeBusy => formatter.write_str("too many concurrent remote handshakes"),
            Self::ApprovalBusy => formatter.write_str("too many pending enrollment approvals"),
            Self::HandshakeTimeout => formatter.write_str("remote handshake timed out"),
            Self::Closed => formatter.write_str("daemon connection is closed"),
        }
    }
}

impl std::error::Error for DaemonError {}

impl From<CryptoError> for DaemonError {
    fn from(error: CryptoError) -> Self {
        Self::Crypto(error)
    }
}

impl From<IdentityError> for DaemonError {
    fn from(error: IdentityError) -> Self {
        Self::Identity(error)
    }
}

impl From<ConnectionError> for DaemonError {
    fn from(error: ConnectionError) -> Self {
        Self::Connection(error)
    }
}

impl From<LinkError> for DaemonError {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

impl From<SessionError> for DaemonError {
    fn from(error: SessionError) -> Self {
        Self::Session(error)
    }
}
