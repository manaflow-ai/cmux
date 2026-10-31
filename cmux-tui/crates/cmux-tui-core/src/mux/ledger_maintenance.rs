//! The mutation ledgers' share of the journal maintenance worker: bounded
//! retention batches on every tick, then a background integrity scan once
//! the ledgers are within their bounds. See
//! `workspace_registry::mutation_ledger_retention`.

use super::*;
use crate::workspace_registry::history_check::scan_background_checked_tables;
use crate::workspace_registry::mutation_ledger_retention::scan_mutation_ledgers;

/// Retention batches per tick, each under its own registry lock, so a 1 GB
/// ledger's rows drain within about an hour without one long stall.
const LEDGER_PRUNE_BATCHES_PER_TICK: usize = 8;
/// A scan reads every ledger page, so it runs once retention has drained the
/// ledgers after start, then at this interval, and at once after a prune hits
/// a corrupt page.
pub(super) const LEDGER_SCAN_INTERVAL: Duration = Duration::from_secs(60 * 60);

/// The worker's scan state; it lives on the worker thread.
#[derive(Default)]
pub(super) struct LedgerMaintenance {
    last_scan: Option<Instant>,
}

impl Mux {
    /// One tick's share; true while work remains (a ledger over its bound,
    /// a corrupt ledger, a pause or an error to retry).
    pub(super) fn run_ledger_maintenance(&self, state: &mut LedgerMaintenance) -> bool {
        match self.try_ledger_maintenance(state) {
            Ok(remains) => remains,
            Err(error) => {
                eprintln!("cmux-tui: mutation ledger maintenance deferred: {error:#}");
                true
            }
        }
    }

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
        Ok(corrupt || !drained)
    }

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
        self.check_background_checked_tables(&database)
    }

    /// The full check of the tables the open only touches the tail of
    /// (`workspace_registry::history_check`). A damaged one makes the next
    /// open check every state table in full, as every open did before.
    fn check_background_checked_tables(&self, database: &Path) -> anyhow::Result<()> {
        if self.journal_maintenance_paused() {
            return Ok(());
        }
        for (table, report) in scan_background_checked_tables(database)? {
            self.workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .require_full_open_check(table, &report)?;
            eprintln!(
                "cmux-tui: {table} failed its integrity check ({report}); the next start \
                 checks the whole registry"
            );
            self.report_internal_diagnostic(format!(
                "{table} failed its integrity check; the next start checks the whole registry"
            ));
        }
        Ok(())
    }
}
