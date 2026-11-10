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

impl Mux {
    /// One retention pass. True while work remains for the next tick.
    pub(super) fn retain_journal(&self) -> anyhow::Result<bool> {
        // The cleanup rebuilds these tables beside the file and swaps it.
        if self.output_cleanup_pending() {
            return Ok(false);
        }
        // A fold that fails holds the floor where it is; it is not work the
        // next tick could finish, so the worker may still settle.
        let folded = crate::history_ops::fold_for_retention(
            self,
            JOURNAL_RETENTION_HISTORY_FOLD_BUDGET,
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

    /// The sequence retention has deleted through: a journal cursor below it
    /// names records that are gone.
    pub(crate) fn journal_pruned_through(&self) -> anyhow::Result<u64> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_pruned_through()
    }
}
