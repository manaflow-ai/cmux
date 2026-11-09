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

/// A roster folded from the first journal record, and the ranges the fold
/// skipped because they did not decode.
#[derive(Default)]
pub(in crate::mux) struct AgentRosterRebuild {
    host: AgentRosterHost,
    skipped: Vec<SkippedJournalRange>,
}

impl Mux {
    /// Hands a stale roster's rebuild to the owner and wakes it.
    pub(in crate::mux) fn start_agent_roster_rebuild(&self) {
        let worker = &self.agent_roster_worker;
        *worker.rebuild.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(AgentRosterRebuild::default());
        worker.rebuilding.store(true, Ordering::Release);
        self.continue_agent_roster_rebuild_later();
    }

    /// Whether the roster is stale and its rebuild is not done.
    pub(in crate::mux) fn agent_roster_rebuilding(&self) -> bool {
        self.agent_roster_worker.rebuilding.load(Ordering::Acquire)
    }

    /// One slice of the rebuild, on the owner after a pass: fold toward the
    /// live roster's cursor for at most [`REBUILD_SLICE`], and replace the
    /// live roster once there. Only the owner moves the live cursor and this
    /// runs on it, so the cursor holds still for the slice. A read that fails
    /// is tried again after the next pass.
    pub(in crate::mux) fn run_agent_roster_rebuild_slice(&self) {
        if !self.agent_roster_rebuilding() {
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
            let page = match fold.reader(&self.journal_kernel) {
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
                continue;
            }
            // As the start does: a range that does not decode is skipped.
            let salvaged = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .session_journal_after_salvaging(cursor, REBUILD_PAGE);
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
                }
                Ok(SalvagedJournalPage::Skipped(skip)) => {
                    eprintln!(
                        "cmux-tui: agent roster rebuild skipped journal {}: {}",
                        agent_roster_restore::describe_range(&skip),
                        skip.reason
                    );
                    rebuild.host.cursor = skip.end_sequence.clamp(cursor.saturating_add(1), target);
                    rebuild.skipped.push(skip);
                }
                Err(error) => {
                    eprintln!("cmux-tui: the agent roster rebuild read failed: {error}");
                    return;
                }
            }
        }
        let mut rebuilt = std::mem::take(rebuild);
        *slot = None;
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
