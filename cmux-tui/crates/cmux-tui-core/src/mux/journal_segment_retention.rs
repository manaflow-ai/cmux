//! The maintenance worker's retention pass over the journal's own tables
//! (`workspace_registry::journal_retention`). Only on the thread
//! `cmux-journal-maintenance`, never on a request thread.

use std::sync::PoisonError;
use std::time::Duration;

use super::Mux;
use super::journal_maintenance::{
    JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS, JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK,
};

/// Sealed segments one tick deletes, each in its own transaction and its
/// own hold of the registry lock (at most 1,024 records: about 1,024 kept
/// reducer rows, event index rows and receipts, and their subject rows).
/// The seal's own bound a tick, so retention keeps up with the fastest
/// sealing and a large old registry drains 8 segments each 30 s.
const JOURNAL_RETENTION_SEGMENTS_PER_TICK: usize = JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK;
/// How long a tick folds the agent history toward the journal head before
/// the pass: the floor waits for that fold, so a daemon where nobody opens
/// History is bounded too. The backfill's slice (200 ms), for the same
/// reason: the tick runs every 30 s and must not hold a core.
const JOURNAL_RETENTION_HISTORY_FOLD_BUDGET: Duration = Duration::from_millis(200);

/// Records the agent history fold may be ahead of its saved cursor: the
/// worker's checkpoint cadence. The floor moves a checkpoint at a time, so
/// a save more often would not move it sooner, and each save writes the
/// whole agent history.
const JOURNAL_RETENTION_HISTORY_SAVE_RECORDS: u64 = JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS;

/// The fold's budget a tick while a rebuild waits for it (see
/// [`Mux::rebuild_takes_the_run`]). The floor of a rebuild is the floor of
/// the whole swap, and the saved agent history cursor is one of its terms:
/// a registry where nobody opened History for a long time (one had 685,892
/// records to fold) would be rebuilt with all of those records in it. One
/// time per registry, on the maintenance thread, one page a lock hold.
const JOURNAL_RETENTION_REBUILD_FOLD_BUDGET: Duration = Duration::from_secs(2);
/// Ticks a rebuild waits for the agent history fold to reach the journal
/// head (10 minutes at the tick's interval). After them the rebuild takes
/// the floor as it is, so a fold that never ends (a commit storm) does not
/// hold the registry at its size.
const JOURNAL_RETENTION_REBUILD_FOLD_TICKS: u32 = 20;

impl Mux {
    /// One retention pass. True while work remains for the next tick.
    pub(super) fn retain_journal(&self) -> anyhow::Result<bool> {
        // The cleanup rebuilds these tables beside the file and swaps it.
        if self.output_cleanup_pending() {
            return Ok(false);
        }
        // While the cleanup worker of this start can rebuild the registry,
        // a run that is worth a rebuild is its work, and its floor waits for
        // the fold below.
        let rebuild_possible = self.journal_rebuild_possible();
        let fold_budget = if rebuild_possible && self.journal_rebuild_fold_waits() > 0 {
            JOURNAL_RETENTION_REBUILD_FOLD_BUDGET
        } else {
            JOURNAL_RETENTION_HISTORY_FOLD_BUDGET
        };
        // A fold that fails holds the floor where it is; it is not work the
        // next tick could finish, so the worker may still settle.
        let folded = crate::history_ops::fold_for_retention(
            self,
            fold_budget,
            JOURNAL_RETENTION_HISTORY_SAVE_RECORDS,
        )
        .unwrap_or_else(|error| {
            eprintln!("cmux-tui: agent history fold before retention failed: {error:#}");
            true
        });
        let floor = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_retention_floor()?;
        if rebuild_possible && self.rebuild_takes_the_run(floor, folded)? {
            // Nothing is deleted in place; the fold may still have work.
            return Ok(!folded);
        }
        let mut pruned = 0;
        while pruned < JOURNAL_RETENTION_SEGMENTS_PER_TICK && !self.journal_maintenance_paused() {
            let deleted = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .prune_oldest_journal_segment(floor)?;
            if !deleted {
                break;
            }
            pruned += 1;
        }
        if pruned > 0 {
            // No request answer follows to flush these commits.
            self.request_registry_flush();
        }
        Ok(!folded || pruned == JOURNAL_RETENTION_SEGMENTS_PER_TICK)
    }

    /// True when this tick deletes nothing in place, because the rebuild
    /// beside the file (`mux/output_cleanup.rs`) removes the run at or below
    /// the floor: deleting 2 million records in place takes hours of ticks
    /// and leaves the file at its size. The rebuild gets its floor here,
    /// once the agent history fold is at the journal head (`folded`) or the
    /// wait for it is over. A run too small for a rebuild is deleted in
    /// place, as before.
    fn rebuild_takes_the_run(&self, floor: u64, folded: bool) -> anyhow::Result<bool> {
        if !folded && self.note_journal_rebuild_fold_wait() <= JOURNAL_RETENTION_REBUILD_FOLD_TICKS
        {
            // The floor still moves with the fold: no rebuild at this one,
            // and no delete in place that the rebuild would do in one swap.
            return Ok(true);
        }
        let owed = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_rebuild_owed(floor)?;
        if owed {
            self.offer_rebuild_floor(floor);
        }
        Ok(owed)
    }

    /// The sequence retention has deleted through: a journal cursor below it
    /// names records that are gone.
    pub(crate) fn journal_pruned_through(&self) -> anyhow::Result<u64> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_pruned_through()
    }
}
