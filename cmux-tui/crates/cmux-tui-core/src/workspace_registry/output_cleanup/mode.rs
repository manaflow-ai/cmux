//! Which transformation a staging file applies.

use rusqlite::{Connection, OptionalExtension as _};

/// The transformation one staging file applies to the journal. A staging
/// file keeps the mode it was created with (`output_cleanup_state` key
/// `mode`), so the build and the swap at a later start apply the same one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CleanupMode {
    /// Drops stored terminal output and superseded session puts (the
    /// `output_cleanup` module docs).
    Output,
    /// Keeps every record and removes the upserts a resource record
    /// restates (`journal_compact.rs`). Opt-in only.
    Compact,
}

impl CleanupMode {
    /// The value of the staging state key `mode`.
    pub(super) fn state_value(self) -> &'static str {
        match self {
            Self::Output => "",
            Self::Compact => "compact",
        }
    }

    /// The mode `staging` was created with. A staging file of a build
    /// before the key is an output cleanup.
    pub(super) fn of(staging: &Connection) -> anyhow::Result<Self> {
        let value = staging
            .query_row("SELECT value FROM output_cleanup_state WHERE key = 'mode'", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;
        Ok(match value.as_deref() {
            Some("compact") => Self::Compact,
            _ => Self::Output,
        })
    }
}
