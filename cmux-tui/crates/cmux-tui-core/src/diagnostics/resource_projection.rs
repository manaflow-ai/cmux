//! Where a resource topology projection spends its time.
//!
//! Every topology mutation projects the live tree into a durable patch and
//! commits it under the registry -> state writer fence. These spans split
//! that critical section into its parts so `server-stats` can name the part
//! that grows with the session: reading the stored topology, rebuilding the
//! live resource indexes, building the patch, and the registry commit
//! (unchanged-row pruning, row writes, journal append).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use serde::Serialize;

use super::{HistogramSnapshot, LogLinearHistogram};

/// Counters for one daemon's resource projections and their commits.
#[derive(Default)]
pub struct ResourceProjectionStats {
    /// Set by a projection, taken by the next commit: only the commit of a
    /// projected patch counts, not cwd reports or other direct patches.
    projected_pending: AtomicBool,
    projections: AtomicU64,
    read_us: LogLinearHistogram,
    index_us: LogLinearHistogram,
    diff_us: LogLinearHistogram,
    projected_changes: LogLinearHistogram,
    commits: AtomicU64,
    commit_us: LogLinearHistogram,
    commit_prune_us: LogLinearHistogram,
    commit_apply_us: LogLinearHistogram,
    commit_journal_us: LogLinearHistogram,
    written_changes: LogLinearHistogram,
    journaled_changes: LogLinearHistogram,
}

/// The durations of one projection, recorded together.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProjectionSpans {
    /// Reading the stored topology and terminal records.
    pub read: Duration,
    /// Rebuilding the live resource indexes.
    pub index: Duration,
    /// Walking the live tree and diffing it against the stored topology.
    pub diff: Duration,
    /// Durable changes in the projected patch.
    pub changes: usize,
}

/// The durations of one registry commit of a projected patch.
#[derive(Clone, Copy, Debug, Default)]
pub struct CommitSpans {
    /// The whole commit, including the transaction commit.
    pub total: Duration,
    /// Dropping changes whose rows already hold the projected value.
    pub prune: Duration,
    /// Writing the remaining rows.
    pub apply: Duration,
    /// Appending the resource journal record.
    pub journal: Duration,
    /// Changes left after pruning.
    pub written: usize,
    /// Public changes in the journal record.
    pub journaled: usize,
}

impl ResourceProjectionStats {
    pub fn projected(&self, spans: ProjectionSpans) {
        self.projected_pending.store(true, Ordering::Relaxed);
        self.projections.fetch_add(1, Ordering::Relaxed);
        self.read_us.record_duration(spans.read);
        self.index_us.record_duration(spans.index);
        self.diff_us.record_duration(spans.diff);
        self.projected_changes.record(spans.changes as u64);
    }

    /// Record a resource patch commit; it counts only when a projection
    /// produced its patch (callers hold the registry lock across both).
    pub fn committed(&self, spans: CommitSpans) {
        if !self.projected_pending.swap(false, Ordering::Relaxed) {
            return;
        }
        self.commits.fetch_add(1, Ordering::Relaxed);
        self.commit_us.record_duration(spans.total);
        self.commit_prune_us.record_duration(spans.prune);
        self.commit_apply_us.record_duration(spans.apply);
        self.commit_journal_us.record_duration(spans.journal);
        self.written_changes.record(spans.written as u64);
        self.journaled_changes.record(spans.journaled as u64);
    }

    pub fn snapshot(&self) -> ResourceProjectionSnapshot {
        ResourceProjectionSnapshot {
            projections: self.projections.load(Ordering::Relaxed),
            read_us: self.read_us.snapshot(),
            index_us: self.index_us.snapshot(),
            diff_us: self.diff_us.snapshot(),
            projected_changes: self.projected_changes.snapshot(),
            commits: self.commits.load(Ordering::Relaxed),
            commit_us: self.commit_us.snapshot(),
            commit_prune_us: self.commit_prune_us.snapshot(),
            commit_apply_us: self.commit_apply_us.snapshot(),
            commit_journal_us: self.commit_journal_us.snapshot(),
            written_changes: self.written_changes.snapshot(),
            journaled_changes: self.journaled_changes.snapshot(),
        }
    }
}

/// The `resource_projection` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ResourceProjectionSnapshot {
    pub projections: u64,
    pub read_us: HistogramSnapshot,
    pub index_us: HistogramSnapshot,
    pub diff_us: HistogramSnapshot,
    pub projected_changes: HistogramSnapshot,
    pub commits: u64,
    pub commit_us: HistogramSnapshot,
    pub commit_prune_us: HistogramSnapshot,
    pub commit_apply_us: HistogramSnapshot,
    pub commit_journal_us: HistogramSnapshot,
    pub written_changes: HistogramSnapshot,
    pub journaled_changes: HistogramSnapshot,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_commit_after_a_projection_counts() {
        let stats = ResourceProjectionStats::default();
        stats.committed(CommitSpans { written: 1, ..CommitSpans::default() });
        assert_eq!(stats.snapshot().commits, 0, "a direct patch is not a projected commit");
        stats.projected(ProjectionSpans::default());
        stats.committed(CommitSpans::default());
        stats.committed(CommitSpans::default());
        assert_eq!((stats.snapshot().projections, stats.snapshot().commits), (1, 1));
    }

    #[test]
    fn projection_and_commit_spans_accumulate() {
        let stats = ResourceProjectionStats::default();
        stats.projected(ProjectionSpans {
            read: Duration::from_millis(3),
            index: Duration::from_micros(40),
            diff: Duration::from_millis(1),
            changes: 12,
        });
        stats.committed(CommitSpans {
            total: Duration::from_millis(5),
            prune: Duration::from_millis(2),
            apply: Duration::from_micros(300),
            journal: Duration::from_millis(1),
            written: 4,
            journaled: 9,
        });
        let snapshot = stats.snapshot();
        assert_eq!((snapshot.projections, snapshot.commits), (1, 1));
        assert!(snapshot.read_us.max >= 3_000, "{snapshot:?}");
        assert_eq!(snapshot.projected_changes.max, 12);
        assert_eq!(snapshot.written_changes.max, 4);
        assert_eq!(snapshot.journaled_changes.max, 9);
        assert!(snapshot.commit_prune_us.max >= 2_000, "{snapshot:?}");
    }
}
