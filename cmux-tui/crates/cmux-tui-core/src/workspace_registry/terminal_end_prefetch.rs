//! Warms the index pages that recording a terminal's end writes, while the
//! daemon is still starting. Not yet: the startup reads nothing ahead.

use rusqlite::Connection;

/// One index probe: a journal subject `(kind, id)`, or a terminal's event log
/// (`("terminal_events", terminal_id)`).
pub(crate) type PrefetchKey = (String, String);

/// The pages a live terminal's end writes that the startup reads first:
/// none yet.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn terminal_end_prefetch_keys(
    _connection: &Connection,
) -> anyhow::Result<Vec<PrefetchKey>> {
    Ok(Vec::new())
}
