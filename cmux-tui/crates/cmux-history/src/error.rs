use std::fmt;

/// A failure of the visit store. Pure functions in this crate do not fail.
#[derive(Debug)]
pub enum HistoryError {
    /// SQLite refused an open, a statement or a step.
    Sqlite(rusqlite::Error),
    /// The store directory or a database file could not be made or read.
    Io(std::io::Error),
}

impl fmt::Display for HistoryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(f, "history store: sqlite: {error}"),
            Self::Io(error) => write!(f, "history store: io: {error}"),
        }
    }
}

impl std::error::Error for HistoryError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Sqlite(error) => Some(error),
            Self::Io(error) => Some(error),
        }
    }
}

impl From<rusqlite::Error> for HistoryError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<std::io::Error> for HistoryError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
