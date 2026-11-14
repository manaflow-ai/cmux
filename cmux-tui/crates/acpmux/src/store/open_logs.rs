//! How many chat logs the store holds open (`LocalStore::append_line`). Past that many, each
//! append to a chat whose log is closed first closes the least recently written log, and that
//! close syncs the log under the store-wide writers' lock (and, in the journal store, its order
//! lock), so every chat's appends wait on the disk meanwhile. With more chats streaming than logs
//! open, almost every streamed record evicted one: on a fleet Mac a sync takes 5-10 ms (p50), so
//! the whole daemon wrote one record per sync.
//!
//! The bound exists for the open-file limit (cmux16, 2026-10-22: a daemon held one descriptor per
//! chat it had written, 193 of its 256, and every agent start failed with "Too many open files").
//! So it follows that limit: a sixteenth of the soft limit this process runs under, never fewer
//! than [`MIN`] (at launchd's 256 that keeps 192 descriptors for everything else, as before) and
//! never more than [`MAX`]. The daemon raises its soft limit before it opens the store
//! (`daemon/open_file_limit.rs`), usually to 10,240 or more on macOS: then [`MAX`] chats stream
//! with no eviction.

/// The fewest logs held open, whatever the limit: the bound before it followed the limit.
const MIN: usize = 64;
/// The most logs held open, whatever the limit.
const MAX: usize = 512;

/// The logs held open under a soft open-file limit of `soft` (None: unknown).
pub(super) fn for_limit(soft: Option<u64>) -> usize {
    soft.map_or(MIN, |soft| usize::try_from(soft / 16).unwrap_or(MAX).clamp(MIN, MAX))
}

/// The logs a store opened now holds open: [`for_limit`] of this process's soft open-file limit.
pub fn now() -> usize {
    for_limit(soft_limit())
}

#[cfg(unix)]
fn soft_limit() -> Option<u64> {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit writes only into the local struct it is given.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } != 0 {
        return None;
    }
    #[allow(clippy::useless_conversion)]
    Some(u64::from(lim.rlim_cur))
}

#[cfg(not(unix))]
fn soft_limit() -> Option<u64> {
    None
}

#[cfg(test)]
impl super::LocalStore {
    /// This store holding at most `logs` logs open, whatever the open-file limit.
    pub(super) fn with_open_logs(mut self, logs: usize) -> Self {
        self.open_logs = logs;
        self
    }
}

#[cfg(test)]
mod tests;
