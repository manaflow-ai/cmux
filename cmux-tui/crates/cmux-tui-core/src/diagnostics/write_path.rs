//! Which thread commits the daemon's durable writes.
//!
//! Registry commits (effect receipts, terminal records, workspace registry
//! revisions) run on their request thread (`registry_intent`); the journal
//! writer commits terminal, frontend and producer events. These counters
//! show it at the socket: registry commits on request threads, and registry
//! or state lock acquisitions on the journal writer thread. The last one
//! must stay zero: a request thread holds the registry lock while it waits
//! for the connection, so a writer that took it would deadlock.

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
    request_effect_commits: AtomicU64,
}

impl WritePathStats {
    /// An effect receipt commit ran its own transaction on a request thread.
    pub fn request_effect_committed(&self) {
        self.request_effect_commits.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> WritePathSnapshot {
        WritePathSnapshot {
            effect_intents: 0,
            effect_intent_failures: 0,
            effect_intent_batches: 0,
            request_effect_commits: self.request_effect_commits.load(Ordering::Relaxed),
            writer_registry_locks: WRITER_REGISTRY_LOCKS.load(Ordering::Relaxed),
            wal_commits: 0,
            wal_synced_commits: 0,
            registry_wal_frame_bytes: 0,
            registry_wal_file_bytes: 0,
            registry_wal_file_high_water_bytes: 0,
        }
    }
}

/// The `write_path` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WritePathSnapshot {
    /// Always 0: registry commits no longer ride the journal writer's batch
    /// (`registry_intent`, PL-daemon b5). Kept for the protocol.
    pub effect_intents: u64,
    /// Always 0 (see `effect_intents`).
    pub effect_intent_failures: u64,
    /// Always 0 (see `effect_intents`).
    pub effect_intent_batches: u64,
    /// Registry commits (effect receipts, terminal records, workspace
    /// registry revisions), each in its own transaction on its request
    /// thread.
    pub request_effect_commits: u64,
    /// Registry or state lock acquisitions on a journal writer thread,
    /// process-wide. Always zero; any other value is a lock-order defect.
    pub writer_registry_locks: u64,
    /// Registry commits written to the WAL (`synchronous=NORMAL`).
    pub wal_commits: u64,
    /// Of those, the commits the WAL syncer has flushed to disk
    /// (`workspace_registry::wal_durability`); it trails by at most one flush.
    pub wal_synced_commits: u64,
    /// Bytes of the WAL frames those commits appended (a 24-byte header and one page each): what the
    /// registry's writes put on the disk, so a test can tell a change's bytes from the session's size (#32408).
    /// Two cases are not exact. The first commit after a WAL restart counts only the frames past the old WAL's
    /// count when it writes more frames than the old WAL held (a commit over about 4 MiB, the checkpoint size).
    /// Frames another connection appends to the same database count toward the next commit of this one.
    pub registry_wal_frame_bytes: u64,
    /// The registry's WAL file size now. It shrinks to 64 MiB at the first commit after a checkpoint copied the
    /// whole WAL and the last reader of the old WAL ended: a read transaction still open after the checkpoint
    /// delays it (`workspace_registry::wal_durability`). An idle registry keeps its size.
    pub registry_wal_file_bytes: u64,
    /// The largest registry WAL file size seen since the daemon started.
    pub registry_wal_file_high_water_bytes: u64,
}
