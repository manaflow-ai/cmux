//! The mutation ledgers' share of the journal maintenance worker: bounded
//! retention batches on every tick, then a background integrity scan once
//! the ledgers are within their bounds. See
//! `workspace_registry::mutation_ledger_retention`.

use super::*;
use crate::workspace_registry::mutation_ledger_retention::scan_mutation_ledgers;

/// Retention batches per tick, each under its own registry lock, so a 1 GB
/// ledger's rows drain within about an hour without one long stall.
const LEDGER_PRUNE_BATCHES_PER_TICK: usize = 8;
/// A scan reads every ledger page, so it runs once retention has drained the
/// ledgers after start, then at this interval, and at once after a prune hits
/// a corrupt page.
const LEDGER_SCAN_INTERVAL: Duration = Duration::from_secs(60 * 60);

/// The worker's scan state; it lives on the worker thread.
#[derive(Default)]
pub(super) struct LedgerMaintenance {
    last_scan: Option<Instant>,
}

impl Mux {
    /// One ledger step; true when rows are left for another pass (retention
    /// has not drained, a pause, or a failure to retry).
    #[track_caller]
    pub(super) fn run_ledger_maintenance(&self, state: &mut LedgerMaintenance) -> bool {
        self.try_ledger_maintenance(state).unwrap_or_else(|error| {
            eprintln!("cmux-tui: mutation ledger maintenance deferred: {error:#}");
            true
        })
    }

    #[track_caller]
    fn try_ledger_maintenance(&self, state: &mut LedgerMaintenance) -> anyhow::Result<bool> {
        let mut drained = false;
        let mut corrupt = false;
        for _ in 0..LEDGER_PRUNE_BATCHES_PER_TICK {
            if self.journal_maintenance_paused() {
                return Ok(true);
            }
            let prune = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .prune_mutation_ledgers()?;
            corrupt = !prune.corrupt.is_empty();
            drained = prune.deleted == 0;
            if corrupt || drained {
                break;
            }
        }
        let due = corrupt
            || (drained
                && state.last_scan.is_none_or(|scanned| scanned.elapsed() >= LEDGER_SCAN_INTERVAL));
        if due {
            self.scan_and_quarantine_ledgers(state)?;
        }
        Ok(!drained && !corrupt)
    }

    #[track_caller]
    fn scan_and_quarantine_ledgers(&self, state: &mut LedgerMaintenance) -> anyhow::Result<()> {
        let Some(database) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_database_path()
        else {
            return Ok(());
        };
        let corrupt = scan_mutation_ledgers(&database)?;
        state.last_scan = Some(Instant::now());
        for (table, report) in corrupt {
            if self.journal_maintenance_paused() {
                return Ok(());
            }
            let aside = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .quarantine_mutation_ledger(table)?;
            eprintln!(
                "cmux-tui: mutation ledger {table} failed its integrity check ({report}); \
                 moved it to {aside} and recreated it empty"
            );
            self.report_internal_diagnostic(format!(
                "mutation ledger {table} was corrupt; it was set aside and recreated empty"
            ));
        }
        Ok(())
    }
}
