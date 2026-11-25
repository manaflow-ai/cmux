use std::fmt;

/// Why a bundle step failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A wire form of a version this build does not know: fall back to a plain transfer.
    Version(u8),
    /// A malformed message or manifest.
    Malformed(&'static str),
    /// A sealed chunk that does not open under the pair's key, or opens to bytes of another id.
    Seal,
    /// A chunk the manifest names is missing from the store.
    Missing(crate::ChunkId),
    /// A store's I/O error.
    Io(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Version(v) => write!(f, "bundle wire version {v} is not known here"),
            Self::Malformed(what) => write!(f, "malformed bundle {what}"),
            Self::Seal => f.write_str("a sealed chunk did not open to its id"),
            Self::Missing(id) => write!(f, "chunk {} is missing", crate::hex(id)),
            Self::Io(e) => write!(f, "chunk store: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

/// A bundle result.
pub type Result<T> = std::result::Result<T, Error>;
