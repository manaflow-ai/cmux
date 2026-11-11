//! One-time, opt-in compaction of the resource records that restate the
//! whole session. Only its names exist so far: the tests of
//! `journal_compact_tests.rs` fail until the compaction is built.

use std::ffi::OsStr;

use super::CleanupMode;

/// Registry meta key set once the compaction swapped.
pub(crate) const DONE_META_KEY: &str = "journal_compact_v1";

/// Whether `value` (of the opt-in variable) asks for the compaction.
pub(crate) fn requested(value: Option<&OsStr>) -> bool {
    value.is_some_and(|value| value == "1")
}

/// The cleanup the owner schedules at start, if any. The compaction is
/// never scheduled yet.
pub(crate) fn scheduled_mode(
    _compact_requested: bool,
    _compact_done: bool,
    output_done: bool,
) -> Option<CleanupMode> {
    (!output_done).then_some(CleanupMode::Output)
}
