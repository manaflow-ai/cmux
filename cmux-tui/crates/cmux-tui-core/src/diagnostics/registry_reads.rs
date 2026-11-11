//! Lists that could not answer from their lock-free read.
//!
//! A `terminal.list` with no scope reads the stored rows on the registry's
//! read-only connection and the live terminals under the state lock: two
//! cuts, with no registry lock (#40709). When the read of the rows fails, or
//! a terminal ended between the two cuts, the list reads the two as one cut
//! under the registry and state locks. That answer is right, but it is the
//! slow path that the lock-free read replaced: it waits for each writer that
//! holds the registry lock. These counters show at the socket how often the
//! daemon took it, so a daemon that takes it for each list does not look the
//! same as one that never does.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::Serialize;

/// Counters of one registry's lock-free list reads that fell back.
#[derive(Default)]
pub struct RegistryReadStats {
    list_fallbacks: AtomicU64,
    committed_read_failures: AtomicU64,
    fallback_failures: AtomicU64,
}

impl RegistryReadStats {
    /// A list reads again under the registry and state locks, because its
    /// committed read failed (`committed_read_failed`) or because its two
    /// cuts did not agree. Returns the number of fallbacks so far, this one
    /// included.
    pub fn list_fell_back(&self, committed_read_failed: bool) -> u64 {
        if committed_read_failed {
            self.committed_read_failures.fetch_add(1, Ordering::Relaxed);
        }
        self.list_fallbacks.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// The read under the locks failed too: the request got the error.
    pub fn fallback_failed(&self) {
        self.fallback_failures.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> RegistryReadsSnapshot {
        RegistryReadsSnapshot {
            list_fallbacks: self.list_fallbacks.load(Ordering::Relaxed),
            committed_read_failures: self.committed_read_failures.load(Ordering::Relaxed),
            fallback_failures: self.fallback_failures.load(Ordering::Relaxed),
        }
    }
}

/// The `registry_reads` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RegistryReadsSnapshot {
    /// `terminal.list` requests with no scope that read again under the
    /// registry and state locks, for either cause.
    pub list_fallbacks: u64,
    /// Of those, the ones whose lock-free read of the stored rows returned
    /// an error. The others had two cuts that did not agree (a terminal
    /// ended between them).
    pub committed_read_failures: u64,
    /// Fallbacks whose read under the locks failed too: the client got
    /// `operation.failed`.
    pub fallback_failures: u64,
}
