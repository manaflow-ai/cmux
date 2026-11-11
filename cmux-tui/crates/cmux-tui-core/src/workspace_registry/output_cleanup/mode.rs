//! Which transformation a staging file applies.

/// The transformation one staging file applies to the journal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CleanupMode {
    /// Drops stored terminal output and superseded session puts (the
    /// `output_cleanup` module docs).
    Output,
    /// Keeps every record and removes the upserts a resource record
    /// restates. Not built yet: the tests of `journal_compact_tests.rs`
    /// fail until it is.
    Compact,
}
