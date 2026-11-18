//! Counters for the read path.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// A snapshot of the read path's counters since the [`Core`](super::Core) was made.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Reads answered entirely from the cache.
    pub hits: u64,
    /// Reads that needed at least one chunk from the source (or waited on another reader's fetch).
    pub remote_reads: u64,
    /// Chunks a reader got by waiting on a fetch another reader had already started.
    pub shared_waits: u64,
    /// Bytes the source answered with.
    pub bytes_fetched: u64,
    /// Calls to [`Source::fetch`](crate::Source::fetch).
    pub round_trips: u64,
    /// Answers saying a file changed on the Mac.
    pub changed: u64,
    /// Answers saying the Mac was unreachable.
    pub away: u64,
    /// Answers that failed for any other reason.
    pub failed: u64,
}

#[derive(Default)]
pub(crate) struct Counters {
    pub hits: AtomicU64,
    pub remote_reads: AtomicU64,
    pub shared_waits: AtomicU64,
    pub bytes_fetched: AtomicU64,
    pub round_trips: AtomicU64,
    pub changed: AtomicU64,
    pub away: AtomicU64,
    pub failed: AtomicU64,
}

impl Counters {
    pub fn bump(counter: &AtomicU64, n: u64) {
        counter.fetch_add(n, Relaxed);
    }

    pub fn snapshot(&self) -> Stats {
        Stats {
            hits: self.hits.load(Relaxed),
            remote_reads: self.remote_reads.load(Relaxed),
            shared_waits: self.shared_waits.load(Relaxed),
            bytes_fetched: self.bytes_fetched.load(Relaxed),
            round_trips: self.round_trips.load(Relaxed),
            changed: self.changed.load(Relaxed),
            away: self.away.load(Relaxed),
            failed: self.failed.load(Relaxed),
        }
    }
}
