//! One error type with the exit codes of the `cmux server` noun
//! (.cmux-scratch cli-requests/server.md; same codes as the Tasks nouns).

use std::fmt;
use std::io;

/// Exit code classes: 0 ok, 1 internal, 2 usage, 3 not found, 4 rejected,
/// 5 owner unreachable or deadline, 6 idempotency conflict, 7 verification
/// failed (signature, checksum, expiry, downgrade).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitKind {
    Internal = 1,
    Usage = 2,
    NotFound = 3,
    Rejected = 4,
    Unreachable = 5,
    Conflict = 6,
    Verification = 7,
}

impl ExitKind {
    pub fn code(self) -> u8 {
        self as u8
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ExitKind::Internal => "internal",
            ExitKind::Usage => "usage",
            ExitKind::NotFound => "not_found",
            ExitKind::Rejected => "rejected",
            ExitKind::Unreachable => "unreachable",
            ExitKind::Conflict => "conflict",
            ExitKind::Verification => "verification_failed",
        }
    }
}

/// An error with its exit class and a message for people. Messages never
/// carry a secret: callers pass paths, ids and exit statuses only.
#[derive(Debug)]
pub struct Error {
    pub kind: ExitKind,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(kind: ExitKind, message: impl Into<String>) -> Error {
        Error { kind, message: message.into() }
    }

    pub fn internal(message: impl Into<String>) -> Error {
        Error::new(ExitKind::Internal, message)
    }

    pub fn usage(message: impl Into<String>) -> Error {
        Error::new(ExitKind::Usage, message)
    }

    pub fn not_found(message: impl Into<String>) -> Error {
        Error::new(ExitKind::NotFound, message)
    }

    pub fn rejected(message: impl Into<String>) -> Error {
        Error::new(ExitKind::Rejected, message)
    }

    pub fn unreachable(message: impl Into<String>) -> Error {
        Error::new(ExitKind::Unreachable, message)
    }

    pub fn verification(message: impl Into<String>) -> Error {
        Error::new(ExitKind::Verification, message)
    }

    /// An I/O error on `what` (a path or an operation name).
    pub fn io(what: impl fmt::Display, err: io::Error) -> Error {
        Error::internal(format!("{what}: {err}"))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

/// Adds the path or operation to an `io::Result`.
pub trait IoContext<T> {
    fn ctx(self, what: impl fmt::Display) -> Result<T>;
}

impl<T> IoContext<T> for io::Result<T> {
    fn ctx(self, what: impl fmt::Display) -> Result<T> {
        self.map_err(|e| Error::io(what, e))
    }
}
