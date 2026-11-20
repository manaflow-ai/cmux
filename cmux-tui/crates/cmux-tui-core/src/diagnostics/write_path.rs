//! Which thread commits the daemon's durable writes.
//!
//! Registry commits (effect receipts, terminal records, workspace registry
//! revisions) run on their request thread (`registry_intent`); the journal
//! writer commits terminal, frontend and producer events. These counters
//! show it at the socket: registry commits on request threads, and registry
//! or state lock acquisitions on the journal writer thread. The last one
//! must stay zero: a request thread holds the registry lock while it waits
//! for the connection, so a writer that took it would deadlock.

use std::cell::Cell;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::Serialize;

/// Who makes a commit of the registry's file: a fixed table, one row each in
/// `write_path.commits_by_writer`, in this order. A site names its commits
/// with [`CommitWriter::scope`]; a commit that no site named is `Other`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum CommitWriter {
    /// A commit that no site below named.
    #[default]
    Other,
    /// A batch of the journal writer thread, and each other commit it makes.
    JournalWriter,
    /// The projection of one agent report (`agent.report`), with the
    /// notification of the same hook when it has one.
    AgentReport,
    /// A save of the agent roster's snapshot row.
    AgentRosterSave,
    /// A write of a hook's retry row or apply cursor outside the journal
    /// writer.
    AgentHookRetry,
    /// An effect receipt: prepared, marked executing, committed or closed.
    EffectReceipt,
    /// A notification's read mark, clear or prune.
    Notification,
    /// A resource patch with its ledger row.
    ResourcePatch,
    /// A frontend's projection revision with its journal row
    /// (`commit_resource_projection`).
    FrontendProjection,
    /// A registry intent in its own transaction on its request thread: a
    /// terminal's records, a workspace registry revision (`registry_intent`).
    RegistryIntent,
    /// A terminal's relaunch record: its command, directory or agent.
    TerminalRelaunch,
    /// A commit of the mux state store.
    StateMutation,
    /// The feed's local rows.
    Feed,
    /// The journal maintenance worker: ledgers, checkpoints, seals.
    JournalMaintenance,
    /// A frontend's document saved by `put-frontend-projection`, with its
    /// ledger row.
    FrontendDocument,
    /// The archives of closed terminals: their last screen and program.
    TerminalArchive,
}

/// The rows of [`CommitWriter`]: a writer's row is at [`CommitWriter::row`].
pub(crate) const COMMIT_WRITERS: [CommitWriter; 16] = [
    CommitWriter::Other,
    CommitWriter::JournalWriter,
    CommitWriter::AgentReport,
    CommitWriter::AgentRosterSave,
    CommitWriter::AgentHookRetry,
    CommitWriter::EffectReceipt,
    CommitWriter::Notification,
    CommitWriter::ResourcePatch,
    CommitWriter::FrontendProjection,
    CommitWriter::RegistryIntent,
    CommitWriter::TerminalRelaunch,
    CommitWriter::StateMutation,
    CommitWriter::Feed,
    CommitWriter::JournalMaintenance,
    CommitWriter::FrontendDocument,
    CommitWriter::TerminalArchive,
];

// A commit's counts are at `writer.row()` in an array of the table's length.
// Each row of the table is at the index that its writer's arm gives: a row
// or an arm that moves alone does not compile. A new writer does not compile
// before it has an arm in `row`; its row goes into the table at that index.
// A writer with an arm and no row compiles: its commits count as `other`.
// The loop takes the rows by a slice pattern: it has no index into the table.
const _: () = {
    let mut rows: &[CommitWriter] = &COMMIT_WRITERS;
    let mut index = 0;
    while let [writer, rest @ ..] = rows {
        assert!(writer.row() == index);
        rows = rest;
        index += 1;
    }
};

thread_local! {
    /// The writer that this thread's commits count under.
    static COMMIT_WRITER: Cell<CommitWriter> = const { Cell::new(CommitWriter::Other) };
}

impl CommitWriter {
    /// The row's `writer` in `write_path.commits_by_writer`.
    pub(crate) const fn name(self) -> &'static str {
        match self {
            Self::Other => "other",
            Self::JournalWriter => "journal_writer",
            Self::AgentReport => "agent_report",
            Self::AgentRosterSave => "agent_roster_save",
            Self::AgentHookRetry => "agent_hook_retry",
            Self::EffectReceipt => "effect_receipt",
            Self::Notification => "notification",
            Self::ResourcePatch => "resource_patch",
            Self::FrontendProjection => "frontend_projection",
            Self::RegistryIntent => "registry_intent",
            Self::TerminalRelaunch => "terminal_relaunch",
            Self::StateMutation => "state_mutation",
            Self::Feed => "feed",
            Self::JournalMaintenance => "journal_maintenance",
            Self::FrontendDocument => "frontend_document",
            Self::TerminalArchive => "terminal_archive",
        }
    }

    /// The index of this writer's row in [`COMMIT_WRITERS`] and in a
    /// registry's counts. One arm for each writer, with no wildcard arm: a
    /// new writer does not compile before it has an arm here.
    pub(crate) const fn row(self) -> usize {
        match self {
            Self::Other => 0,
            Self::JournalWriter => 1,
            Self::AgentReport => 2,
            Self::AgentRosterSave => 3,
            Self::AgentHookRetry => 4,
            Self::EffectReceipt => 5,
            Self::Notification => 6,
            Self::ResourcePatch => 7,
            Self::FrontendProjection => 8,
            Self::RegistryIntent => 9,
            Self::TerminalRelaunch => 10,
            Self::StateMutation => 11,
            Self::Feed => 12,
            Self::JournalMaintenance => 13,
            Self::FrontendDocument => 14,
            Self::TerminalArchive => 15,
        }
    }

    /// The writer that a commit of this thread counts under now.
    pub(crate) fn current() -> Self {
        COMMIT_WRITER.with(Cell::get)
    }

    /// Count this thread's commits under this writer until the scope drops.
    /// The scope that holds at a `COMMIT` names it: an inner scope wins over
    /// an outer one, but no scope takes a commit from the journal writer
    /// thread. It is one thread-local write: no lock and no allocation.
    pub(crate) fn scope(self) -> CommitWriterScope {
        let previous = Self::current();
        if previous != Self::JournalWriter {
            COMMIT_WRITER.with(|writer| writer.set(self));
        }
        CommitWriterScope { previous, _not_send: PhantomData }
    }
}

/// Puts back the writer that held before [`CommitWriter::scope`].
#[must_use = "the scope names commits only while it lives"]
pub(crate) struct CommitWriterScope {
    previous: CommitWriter,
    /// The drop writes `previous` to the thread that drops the scope, so
    /// the scope stays on the thread that made it: it is not `Send`.
    _not_send: PhantomData<*const ()>,
}

impl Drop for CommitWriterScope {
    fn drop(&mut self) {
        COMMIT_WRITER.with(|writer| writer.set(self.previous));
    }
}

/// One row of `write_path.commits_by_writer`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WriterCommits {
    /// The writer's name: one of a fixed table.
    pub writer: &'static str,
    /// Registry commits that wrote a WAL frame under this name.
    pub commits: u64,
    /// The WAL frames that those commits appended.
    pub wal_frames: u64,
}

/// (commits, WAL frames) for each row of [`COMMIT_WRITERS`].
pub(crate) type CommitsByWriter = [(u64, u64); COMMIT_WRITERS.len()];

/// The section's rows from a registry's counts: each writer of the table, in
/// its order, also one with no commit.
pub(crate) fn writer_commit_rows(counts: &CommitsByWriter) -> Vec<WriterCommits> {
    COMMIT_WRITERS
        .iter()
        .zip(counts)
        .map(|(writer, &(commits, wal_frames))| WriterCommits {
            writer: writer.name(),
            commits,
            wal_frames,
        })
        .collect()
}

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
            commits_by_writer: writer_commit_rows(&CommitsByWriter::default()),
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
    /// `wal_commits` and the frames of `registry_wal_frame_bytes` by the writer of each commit: one row for
    /// each writer of a fixed table ([`CommitWriter`]), also one with no commit. The rows' `commits` sum to
    /// `wal_commits`; their `wal_frames`, each a 24-byte header and one page, to `registry_wal_frame_bytes`.
    pub commits_by_writer: Vec<WriterCommits>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_of_writers_is_in_the_order_of_its_rows_and_each_name_is_one_row() {
        for (index, writer) in COMMIT_WRITERS.iter().enumerate() {
            assert_eq!(writer.row(), index, "{writer:?} is not at the index of its arm");
        }
        let names: std::collections::BTreeSet<_> =
            COMMIT_WRITERS.iter().map(|writer| writer.name()).collect();
        assert_eq!(names.len(), COMMIT_WRITERS.len(), "two writers have one name");
        assert_eq!(CommitWriter::default(), CommitWriter::Other);
    }
}
