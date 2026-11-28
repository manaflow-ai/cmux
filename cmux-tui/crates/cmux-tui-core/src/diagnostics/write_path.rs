//! Which thread commits the daemon's durable writes.
//!
//! The journal write path moves request-thread transactions into the journal
//! writer's batch (plans/cmux-tui-journal-write-path.md, PR4..PR7). These
//! counters prove the move at the socket: registry commits (effect receipts,
//! terminal records, workspace registry revisions) carried by writer
//! batches, registry commits that still ran their own transaction on a
//! request thread, and registry or state lock acquisitions on the journal
//! writer thread. The last one must stay zero: a request thread holds the
//! registry lock (and may hold state) while it waits for a writer receipt,
//! so a writer that took either would deadlock until the receipt deadline.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::Serialize;

/// Registry lock, request-side registry connection or mux state lock
/// acquisitions on a journal writer thread, process-wide. Release builds count them; debug
/// builds also assert.
static WRITER_REGISTRY_LOCKS: AtomicU64 = AtomicU64::new(0);

/// Count one registry lock acquisition on a journal writer thread.
pub(crate) fn writer_took_registry_lock() {
    WRITER_REGISTRY_LOCKS.fetch_add(1, Ordering::Relaxed);
}

/// Counters for one daemon's durable write path.
#[derive(Default)]
pub struct WritePathStats {
    effect_intents: AtomicU64,
    effect_intent_failures: AtomicU64,
    effect_intent_batches: AtomicU64,
    request_effect_commits: AtomicU64,
}

impl WritePathStats {
    /// A writer batch committed: `committed` effect intents with a receipt,
    /// `failed` effect intents rolled back to their savepoint with an error.
    pub fn writer_batch_committed(&self, committed: usize, failed: usize) {
        if committed + failed == 0 {
            return;
        }
        self.effect_intent_batches.fetch_add(1, Ordering::Relaxed);
        self.effect_intents.fetch_add(committed as u64, Ordering::Relaxed);
        self.effect_intent_failures.fetch_add(failed as u64, Ordering::Relaxed);
    }

    /// An effect receipt commit ran its own transaction on a request thread.
    pub fn request_effect_committed(&self) {
        self.request_effect_commits.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> WritePathSnapshot {
        WritePathSnapshot {
            effect_intents: self.effect_intents.load(Ordering::Relaxed),
            effect_intent_failures: self.effect_intent_failures.load(Ordering::Relaxed),
            effect_intent_batches: self.effect_intent_batches.load(Ordering::Relaxed),
            request_effect_commits: self.request_effect_commits.load(Ordering::Relaxed),
            writer_registry_locks: WRITER_REGISTRY_LOCKS.load(Ordering::Relaxed),
        }
    }
}

/// The `write_path` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WritePathSnapshot {
    /// Registry commits (effect receipts, terminal records, workspace
    /// registry revisions) applied by the journal writer in its batch.
    pub effect_intents: u64,
    /// Effect intents the writer rolled back to their savepoint; each
    /// request got the error.
    pub effect_intent_failures: u64,
    /// Writer batches that carried at least one effect intent.
    pub effect_intent_batches: u64,
    /// Registry commits that ran their own transaction and fsync on a
    /// request thread: callers that still hold the connection (topology
    /// close patches, borrowed extra rows) and the fallback when the journal
    /// writer is disabled, stopped, or not running.
    pub request_effect_commits: u64,
    /// Registry or state lock acquisitions on a journal writer thread,
    /// process-wide. Always zero; any other value is a lock-order defect.
    pub writer_registry_locks: u64,
}
