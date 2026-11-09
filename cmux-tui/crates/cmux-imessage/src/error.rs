use std::fmt;
use std::path::PathBuf;

/// Why the mirror could not read the Messages database.
#[derive(Debug)]
pub enum MirrorError {
    /// macOS refused the read: the process lacks Full Disk Access. The UI asks Leo for the grant.
    NotPermitted(PathBuf),
    /// There is no Messages database at the path (Messages never set up on this Mac).
    Missing(PathBuf),
    /// The database is not shaped like a Messages database this reader knows.
    Schema(String),
    /// SQLite refused a statement or a step.
    Sqlite(rusqlite::Error),
}

impl MirrorError {
    /// A stable, machine-readable code for the wire (`not_permitted`, `missing`, ...).
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotPermitted(_) => "not_permitted",
            Self::Missing(_) => "missing",
            Self::Schema(_) => "schema",
            Self::Sqlite(_) => "sqlite",
        }
    }
}

impl fmt::Display for MirrorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotPermitted(path) => write!(
                f,
                "messages mirror: no permission to read {} (grant Full Disk Access)",
                path.display()
            ),
            Self::Missing(path) => write!(f, "messages mirror: no database at {}", path.display()),
            Self::Schema(message) => write!(f, "messages mirror: unexpected schema: {message}"),
            Self::Sqlite(error) => write!(f, "messages mirror: sqlite: {error}"),
        }
    }
}

impl std::error::Error for MirrorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Sqlite(error) => Some(error),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for MirrorError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}
