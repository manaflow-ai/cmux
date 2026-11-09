//! The background rebuild of a stale agent roster, on the roster's owner.
//!
//! An agent roster reducer version bump used to make the daemon's start fold
//! the whole journal before it served: 26 min on Leo's 59 GB registry
//! (2026-11-08), and 14.0 s on an 8.4 GB generated one. The start now serves
//! the old snapshot through `AgentRoster::migrate`, or an empty roster from
//! the journal head when the old format no longer restores
//! (`agent_roster_restore.rs`), and marks it stale in the registry. The
//! roster's owner then folds the journal from its first record into a
//! separate roster, a slice after each of its passes, while the live roster
//! keeps folding new events. When the rebuild reaches the live cursor it
//! replaces the live roster, saves it, clears the stale mark and reconciles
//! the projections.
//!
//! Every bump so far fixed the fold's logic, so the migrated roster can hold
//! state the current reducer would not have produced until the rebuild
//! replaces it. The rebuild reads only the kinds the roster folds, from the
//! kept reducer records of sealed segments where they exist, so it costs the
//! agent records, not the journal's history. A daemon stopped mid-rebuild
//! keeps the stale mark, and the next start rebuilds again.

use super::*;
use crate::journal_reducers::{
    AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
};
use crate::workspace_registry::session_journal::salvage::{
    SalvagedJournalPage, SkippedJournalRange,
};

/// How long one slice of the rebuild runs after a pass before the owner
/// takes its next requests.
const REBUILD_SLICE: Duration = Duration::from_millis(250);

/// Records per journal page of the rebuild, as the start's fold.
const REBUILD_PAGE: usize = 512;

/// The first retry of a rebuild read that failed; each failure in a row
/// doubles it, up to [`REBUILD_RETRY_LONGEST`].
#[cfg(not(test))]
const REBUILD_RETRY_FIRST: Duration = Duration::from_millis(100);
#[cfg(test)]
const REBUILD_RETRY_FIRST: Duration = Duration::from_millis(5);
#[cfg(not(test))]
const REBUILD_RETRY_LONGEST: Duration = Duration::from_secs(30);
#[cfg(test)]
const REBUILD_RETRY_LONGEST: Duration = Duration::from_millis(20);
/// Failed reads in a row after which the rebuild gives up for this run
/// (about 3 min of retries): the stale mark stays, and the next start
/// rebuilds again.
#[cfg(not(test))]
const REBUILD_READ_ATTEMPTS: u32 = 15;
#[cfg(test)]
const REBUILD_READ_ATTEMPTS: u32 = 4;

/// A roster folded from the first journal record, the ranges the fold
/// skipped because they did not decode, the reads that failed in a row, and
/// the terminals the live roster retired since the rebuild started.
#[derive(Default)]
pub(in crate::mux) struct AgentRosterRebuild {
    host: AgentRosterHost,
    skipped: Vec<SkippedJournalRange>,
    failed_reads: u32,
    retired: Vec<String>,
}

impl Mux {
    /// Hands a stale roster's rebuild to the owner and wakes it.
    pub(in crate::mux) fn start_agent_roster_rebuild(&self) {
        let worker = &self.agent_roster_worker;
        *worker.rebuild.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(AgentRosterRebuild::default());
        worker.stale.store(true, Ordering::Release);
        worker.rebuilding.store(true, Ordering::Release);
        self.continue_agent_roster_rebuild_later();
    }

    /// Terminals a live pass retired, for the rebuild to retire too before
    /// it replaces the live roster. The pass retired them only after its
    /// fold reached a journal head read after their close, and the rebuild
    /// replaces the roster only once it folded through the live cursor, past
    /// that head: none of their events comes after the retirement.
    pub(in crate::mux) fn note_agent_roster_rebuild_retirements(&self, terminals: Vec<String>) {
        if terminals.is_empty() || !self.agent_roster_rebuilding() {
            return;
        }
        let mut slot =
            self.agent_roster_worker.rebuild.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(rebuild) = slot.as_mut() {
            rebuild.retired.extend(terminals);
        }
    }

    /// Whether the roster is stale and its rebuild is not done.
    pub(in crate::mux) fn agent_roster_rebuilding(&self) -> bool {
        self.agent_roster_worker.rebuilding.load(Ordering::Acquire)
    }

    /// Whether the live roster may hold state the current reducer would not
    /// have folded: projections are not reconciled from it. Set until a
    /// rebuild replaces the roster, also after a rebuild that gave up.
    pub(in crate::mux) fn agent_roster_stale(&self) -> bool {
        self.agent_roster_worker.stale.load(Ordering::Acquire)
    }

    /// The version a live pass saves the roster at: the version a stale
    /// roster was migrated from while its stale mark is not written, the
    /// current one otherwise.
    pub(in crate::mux) fn agent_roster_save_version(&self) -> u32 {
        match self.agent_roster_worker.unmarked_from.load(Ordering::Acquire) {
            0 => AGENT_ROSTER_REDUCER_VERSION,
            from_version => from_version,
        }
    }

    /// One slice of the rebuild, on the owner after a pass: fold toward the
    /// live roster's cursor for at most [`REBUILD_SLICE`], and replace the
    /// live roster once there. Only the owner moves the live cursor and this
    /// runs on it, so the cursor holds still for the slice. A read that fails
    /// is tried again after a backoff, with no request needed to wake the
    /// owner, at most [`REBUILD_READ_ATTEMPTS`] times in a row; then the
    /// rebuild ends for this run with the roster still marked stale.
    pub(in crate::mux) fn run_agent_roster_rebuild_slice(&self) {
        if !self.agent_roster_rebuilding() {
            return;
        }
        #[cfg(test)]
        if rebuild_faults::held(&self.session) {
            return;
        }
        let worker = &self.agent_roster_worker;
        let mut fold = worker.fold.lock().unwrap_or_else(PoisonError::into_inner);
        let mut slot = worker.rebuild.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(rebuild) = slot.as_mut() else { return };
        let target = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner).cursor;
        let deadline = Instant::now() + REBUILD_SLICE;
        while rebuild.host.cursor < target {
            if Instant::now() >= deadline {
                drop(slot);
                drop(fold);
                self.continue_agent_roster_rebuild_later();
                return;
            }
            let cursor = rebuild.host.cursor;
            let kinds = AgentRoster::folds_kind;
            #[cfg(test)]
            let injected = rebuild_faults::take_failing_read(&self.session);
            #[cfg(not(test))]
            let injected = false;
            let page = match fold.reader(&self.journal_kernel) {
                _ if injected => Err(anyhow::anyhow!("an injected rebuild read failure")),
                Some(reader) => reader.kinds_after(cursor, target, kinds, REBUILD_PAGE),
                None => self.session_journal_kinds_after(cursor, target, kinds, REBUILD_PAGE),
            };
            if let Ok((records, reached)) = page
                && reached > cursor
            {
                for record in &records {
                    rebuild.host.roster.apply(&RosterEvent::from_record(record));
                }
                rebuild.host.cursor = reached;
                rebuild.failed_reads = 0;
                continue;
            }
            // As the start does: a range that does not decode is skipped.
            let salvaged = if injected {
                Err(anyhow::anyhow!("an injected rebuild read failure"))
            } else {
                self.workspace_registry
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .session_journal_after_salvaging(cursor, REBUILD_PAGE)
            };
            match salvaged {
                Ok(SalvagedJournalPage::Page(page)) => {
                    // A salvaged page can stop short of a range that does
                    // not decode: the next read starts after its last record.
                    let mut reached = None;
                    for record in page.records.iter().take_while(|record| record.sequence <= target)
                    {
                        rebuild.host.roster.apply(&RosterEvent::from_record(record));
                        reached = Some(record.sequence);
                    }
                    rebuild.host.cursor = reached.unwrap_or(target);
                    rebuild.failed_reads = 0;
                }
                Ok(SalvagedJournalPage::Skipped(skip)) => {
                    eprintln!(
                        "cmux-tui: agent roster rebuild skipped journal {}: {}",
                        agent_roster_restore::describe_range(&skip),
                        skip.reason
                    );
                    rebuild.host.cursor = skip.end_sequence.clamp(cursor.saturating_add(1), target);
                    rebuild.skipped.push(skip);
                    rebuild.failed_reads = 0;
                }
                Err(error) => {
                    rebuild.failed_reads += 1;
                    let failed = rebuild.failed_reads;
                    if failed >= REBUILD_READ_ATTEMPTS {
                        *slot = None;
                        worker.rebuilding.store(false, Ordering::Release);
                        drop(slot);
                        drop(fold);
                        eprintln!(
                            "cmux-tui: the agent roster rebuild gave up after {failed} failed \
                             reads: {error:#}; the roster stays stale, its projections are not \
                             reconciled from it, and the next start rebuilds it"
                        );
                        self.report_internal_diagnostic(format!(
                            "agent roster rebuild gave up after {failed} failed reads: {error:#}"
                        ));
                        return;
                    }
                    let delay = REBUILD_RETRY_FIRST
                        .saturating_mul(1 << (failed - 1).min(16))
                        .min(REBUILD_RETRY_LONGEST);
                    eprintln!(
                        "cmux-tui: the agent roster rebuild read failed ({failed} in a row), \
                         retried in {} ms: {error:#}",
                        delay.as_millis()
                    );
                    drop(slot);
                    drop(fold);
                    self.retry_agent_roster_rebuild_after(delay);
                    return;
                }
            }
        }
        let mut rebuilt = std::mem::take(rebuild);
        *slot = None;
        for terminal in &rebuilt.retired {
            rebuilt.host.roster.retire_terminal(terminal);
        }
        let mut problem = None;
        if !rebuilt.skipped.is_empty() {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            agent_roster_restore::neutralize_live_claims(
                &registry,
                &mut rebuilt.host,
                &rebuilt.skipped,
            );
            drop(registry);
            problem = Some(format!(
                "agent roster rebuilt with problems: {}",
                agent_roster_restore::skipped_ranges_problem(&rebuilt.skipped)
            ));
        }
        let (cursor, snapshot) = {
            let mut host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            host.roster = rebuilt.host.roster;
            (host.cursor, host.roster.snapshot().to_string())
        };
        // The current reducer's own fold: saved at the current version from
        // now on, mark or not.
        worker.unmarked_from.store(0, Ordering::Release);
        worker.stale.store(false, Ordering::Release);
        worker.rebuilding.store(false, Ordering::Release);
        // A failed save keeps the stale mark: the next start rebuilds again.
        if let Err(error) = self.registry_connection.finish_journal_reducer_rebuild(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            &snapshot,
        ) {
            eprintln!("cmux-tui: persisting the rebuilt agent roster failed: {error}");
        }
        drop(slot);
        drop(fold);
        eprintln!("cmux-tui: the agent roster rebuild finished at sequence {cursor}");
        // The reconcile the stale roster skipped.
        self.reconcile_agent_roster_projections();
        self.activity.note_roster_changed();
        if let Some(problem) = problem {
            self.report_internal_diagnostic(problem);
        }
    }
}

/// Faults a test puts into one session's rebuild: a held rebuild takes no
/// slice, and a failing read fails the next slices' reads.
#[cfg(test)]
pub(in crate::mux) mod rebuild_faults {
    use std::collections::BTreeMap;
    use std::sync::{Mutex, PoisonError};

    #[derive(Default)]
    struct Faults {
        held: bool,
        failing_reads: u32,
    }

    static FAULTS: Mutex<BTreeMap<String, Faults>> = Mutex::new(BTreeMap::new());

    fn with<T>(session: &str, edit: impl FnOnce(&mut Faults) -> T) -> T {
        let mut faults = FAULTS.lock().unwrap_or_else(PoisonError::into_inner);
        edit(faults.entry(session.to_owned()).or_default())
    }

    pub(in crate::mux) fn hold(session: &str, held: bool) {
        with(session, |faults| faults.held = held);
    }

    pub(in crate::mux) fn fail_reads(session: &str, reads: u32) {
        with(session, |faults| faults.failing_reads = reads);
    }

    pub(super) fn held(session: &str) -> bool {
        with(session, |faults| faults.held)
    }

    pub(super) fn take_failing_read(session: &str) -> bool {
        with(session, |faults| {
            let failing = faults.failing_reads > 0;
            faults.failing_reads = faults.failing_reads.saturating_sub(1);
            failing
        })
    }
}
