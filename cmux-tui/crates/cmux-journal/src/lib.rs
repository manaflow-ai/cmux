//! One append-only journal per daemon, with group commit and ack after durable
//! (R-DURABILITY, `handoff/rewrites/R-DURABILITY/DESIGN.md`).
//!
//! A daemon appends one record per change ([`Journal::append`]: a memory copy, no I/O, no wait).
//! One writer thread takes every pending record as one batch, writes the batch with one `write`,
//! and, when the batch holds an [`Class::Ack`] record, syncs it once. Then it moves
//! [`Journal::durable_lsn`] and calls the daemon's durable listeners, which release the replies
//! that wait for those records. So a burst of N changes costs one write and one sync per batch,
//! not N, and no reply leaves before its change is on disk.
//!
//! The contract (the rules every user of this crate keeps):
//!
//! - **Ack after durable.** A reply, event or read that tells a client about a change goes out
//!   only when `durable_lsn >= ` the change's LSN.
//! - **One change, one record.** Recovery applies a whole record or none of it.
//! - **Prefix order.** Recovery restores the records in LSN order, and a lost tail is a suffix
//!   (only possible after an OS crash or a power loss), never a hole.
//! - **Streams.** A [`Class::Stream`] record (terminal output, streamed agent tokens) is written in
//!   the next batch, so a kill of every process keeps it, and synced with the next acked batch, or
//!   [`Config::stream_sync_delay`] after its write when no acked batch comes.
//!
//! Sync levels ([`SyncLevel`]): an acked batch is synced with `F_BARRIERFSYNC` on macOS
//! (`fdatasync` on Linux, `FlushFileBuffers` on Windows), so an acknowledged change survives a
//! kill of any process, a daemon crash and a kernel panic. When the last full sync is older than
//! [`Config::full_sync_interval`] (1 s), the batch is synced with `F_FULLFSYNC` instead, so a power
//! loss on macOS takes back at most that interval of acked batches, always a suffix. Rotation,
//! seal and recovery always sync fully.
//!
//! Files (the journal directory): `LOCK` (an exclusive lock held by the one writer), the segments
//! (`<segment number, 20 digits>.seg`: a header, then records and sync markers back to back, see
//! `format.rs`), `quarantine/` for segments recovery could not read past damage that is not a
//! torn tail (named `<segment>.<n>.<floor>`: no LSN at or below `floor` is used again),
//! `FLOOR.<lsn>` (empty: an LSN floor that no segment header carries alone), and `DAMAGE`, the
//! damage earlier opens found, reported at every open until
//! [`Journal::clear_damage`] moves it into `quarantine/`. A segment is only ever appended to. The
//! one exception is the writer's own failed write: it cuts the segment back to its size before
//! that write, so it removes only bytes that were never synced and never acknowledged. Nothing
//! here deletes a segment or shortens one past a synced record, except one:
//! [`Journal::retire_through`] removes the segments that hold no record after the caller's
//! compaction point, and the caller opens the journal from that point later (quarantined segments
//! are never deleted).
//!
//! Recovery ([`Journal::open`]) is the one start path for a clean exit, a crash, a kill -9 and an
//! OS crash: it syncs the last segment, reads the segments in LSN order, checks each record's
//! checksum and LSN, and hands every record after the caller's compaction point to the caller's
//! replay. The records of the last segment after its last sync marker are not known to be on the
//! disk (a sync of them may have failed), so recovery writes them again into a new segment, fully
//! synced before open returns. A torn tail (a write that never completed, so never acked) stays in
//! its file, and the journal goes on in a new segment whose header says where the old one ends.
//!
//! A panic on the writer thread (a durable listener's) closes the journal: appends fail with
//! [`AppendError::Closed`], waits end with [`WaitError::WriterEnded`], and the listeners are
//! dropped. The daemon then stops; recovery runs at its next start.
//!
//! [`Storage`] is the file system seam. [`FsStorage`] is the real one. With the `sim` feature,
//! `SimStorage` simulates a page cache over a disk and an ordered log of names, can fail or crash
//! at any storage operation, and then keeps what a process crash, an OS crash or a power loss
//! would keep.

mod format;
mod journal;
mod recovery;
mod storage;
mod writer;

#[cfg(any(test, feature = "sim"))]
mod sim;

pub use format::{MAX_PAYLOAD_LEN, RECORD_HEADER_LEN};
pub use journal::{AppendError, Journal, JournalStats, OpenError, SealError, WaitError};
pub use recovery::{Damage, OpenReport};
#[cfg(any(test, feature = "sim"))]
pub use sim::{Crash, SIM_PAGE, SimRng, SimStorage};
pub use storage::{FsStorage, OpenMode, Storage, StorageFile, StorageLock, SyncLevel, sync_file};

use std::time::Duration;

/// A record's position in the journal: 1 for the first record ever, +1 for each record after
/// it. 0 means "before every record".
pub type Lsn = u64;

/// What a record's durability serves.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Class {
    /// A change some client is told about: its batch is synced before the writer reports it
    /// durable.
    Ack,
    /// Stream bytes a client already has (terminal output, streamed tokens): written in the next
    /// batch, synced with the next acked batch or after [`Config::stream_sync_delay`].
    Stream,
}

impl Class {
    pub(crate) const fn code(self) -> u8 {
        match self {
            Self::Ack => 1,
            Self::Stream => 2,
        }
    }

    pub(crate) const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Ack),
            2 => Some(Self::Stream),
            _ => None,
        }
    }
}

/// One record, as recovery hands it to the caller's replay. The payload is borrowed from a
/// buffer that the next record reuses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record<'a> {
    pub lsn: Lsn,
    /// The daemon's record kind (its own payload schema; this crate never reads the payload).
    pub kind: u16,
    pub class: Class,
    pub payload: &'a [u8],
}

/// Writer and recovery limits.
#[derive(Clone, Debug)]
pub struct Config {
    /// A segment past this size is closed (fully synced) and the next one starts. A segment can
    /// pass it by one batch.
    pub segment_bytes: u64,
    /// The most encoded bytes that may wait for the writer. Past it, [`Journal::append`] fails with
    /// [`AppendError::Backlog`]: the caller fails its request (an `Ack` change) or asks for a
    /// covering snapshot (a `Stream`), and never waits for the disk.
    pub max_pending_bytes: usize,
    /// The longest time between two full syncs while acked batches come (the power-loss window).
    pub full_sync_interval: Duration,
    /// How long written `Stream` records may stay unsynced when no acked batch comes.
    pub stream_sync_delay: Duration,
    /// After a failed write or sync, the first and the longest wait before the writer tries again.
    pub retry_min: Duration,
    pub retry_max: Duration,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            segment_bytes: 64 * 1024 * 1024,
            max_pending_bytes: 64 * 1024 * 1024,
            full_sync_interval: Duration::from_secs(1),
            stream_sync_delay: Duration::from_secs(1),
            retry_min: Duration::from_millis(100),
            retry_max: Duration::from_secs(5),
        }
    }
}

#[cfg(test)]
mod cmux_journal_tests;
#[cfg(test)]
mod crash_sim_tests;
