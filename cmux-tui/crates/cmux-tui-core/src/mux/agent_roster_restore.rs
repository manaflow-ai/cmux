//! Agent roster restore at daemon start.
//!
//! Daemon start must not depend on decoding every historical journal
//! segment (cx-6b12). The roster folds what decodes; a range that does not
//! decode is skipped, logged with its range and segment id (never record
//! contents or decode error text), and reported once to the frontend
//! diagnostic sink. The fold never invents entries: it applies only decoded
//! records. An agent with events in a skipped range keeps its last decoded
//! state, except that a live claim (working, blocked) becomes `unknown`, so
//! no view says a stopped agent is working. Its next report corrects it.

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use super::{AgentRosterHost, WorkspaceRegistry};
use crate::journal_reducers::AgentRoster;
use crate::workspace_registry::SessionJournalRecord;
use crate::workspace_registry::session_journal::salvage::{
    SalvagedJournalPage, SkippedJournalRange,
};

/// Ranges listed by name in the diagnostic; the rest are counted.
const LISTED_SKIPPED_RANGES: usize = 4;

/// How the restore fold reads and checkpoints the journal tail.
#[derive(Clone, Copy)]
pub(crate) struct RosterFoldLimits {
    /// Records per journal page.
    pub(super) page: usize,
    /// Pages between saves of the roster and its cursor. A replay from zero
    /// on a large registry takes minutes; saving along the way lets a daemon
    /// stopped partway resume where it was at its next start instead of
    /// replaying the whole journal again.
    pub(super) save_every_pages: usize,
    /// Test only: stop after this many pages, as a daemon killed mid-fold.
    pub(super) stop_after_pages: Option<usize>,
}

impl RosterFoldLimits {
    const STARTUP: Self = Self { page: 512, save_every_pages: 64, stop_after_pages: None };
}

/// How long the daemon's start folds the roster before it serves. A start
/// after the last save folds a few records in milliseconds; a replay from
/// zero (a reducer version bump, a lost snapshot) folds the whole journal,
/// which took 26-30 min on a 59 GB registry (2026-11-08) while the app
/// waited. Past this budget the replay goes on in the roster's owner thread
/// after the daemon accepts clients (`AgentRosterReplay`), so start time does
/// not grow with the journal.
pub(in crate::mux) const STARTUP_BUDGET: Duration = Duration::from_millis(1_000);

/// How long one pass of the roster's owner spends on a background replay
/// before it gives its other work (a request's fold, a maintenance tick's
/// wait) a turn.
pub(super) const BACKGROUND_SLICE: Duration = Duration::from_millis(250);

/// Roster states that claim the agent is active right now.
const LIVE_STATES: [&str; 2] = ["working", "blocked"];
/// The spec's neutral agent state; every agents view hides it.
const NEUTRAL_STATE: &str = "unknown";

pub(super) struct RestoredAgentRoster {
    pub(super) host: AgentRosterHost,
    /// A non-fatal startup problem for the frontend diagnostic sink.
    pub(super) diagnostic: Option<String>,
    /// The replay the start's budget did not finish: the roster's owner
    /// finishes it in the background.
    pub(super) replay: Option<AgentRosterReplay>,
}

/// A roster replay from the cursor through `through`, the journal head when
/// the daemon started. Its records committed before this start, so their
/// projection commits and broadcasts already happened: the replay applies no
/// deltas, and the startup projection reconcile waits until it is done.
pub(super) struct AgentRosterReplay {
    through: u64,
    saved_at: u64,
    pages: usize,
    needs_repair: bool,
    skipped: Vec<SkippedJournalRange>,
    problems: Vec<String>,
    limits: RosterFoldLimits,
}

/// How a slice of the replay ended.
pub(super) enum ReplayProgress {
    /// It folded through the start's head: the roster is current.
    Done { diagnostic: Option<String> },
    /// Its budget ran out first.
    Paused,
}

/// Where the replay reads the journal and saves the roster.
pub(super) trait RosterJournal {
    /// The records the roster folds ([`AgentRoster::folds_kind`]) in
    /// `(cursor, through]`, and the sequence the read covered through.
    fn kinds_after(
        &self,
        cursor: u64,
        through: u64,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)>;
    fn after_salvaging(&self, cursor: u64, limit: usize) -> anyhow::Result<SalvagedJournalPage>;
    fn subject_ids_in_range(&self, kind: &str, start: u64, end: u64)
    -> anyhow::Result<Vec<String>>;
    fn save(&self, cursor: u64, snapshot: &str) -> anyhow::Result<()>;
}

impl RosterJournal for WorkspaceRegistry {
    fn kinds_after(
        &self,
        cursor: u64,
        through: u64,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
        self.session_journal_kinds_after(cursor, through, AgentRoster::folds_kind, limit)
    }

    fn after_salvaging(&self, cursor: u64, limit: usize) -> anyhow::Result<SalvagedJournalPage> {
        self.session_journal_after_salvaging(cursor, limit)
    }

    fn subject_ids_in_range(
        &self,
        kind: &str,
        start: u64,
        end: u64,
    ) -> anyhow::Result<Vec<String>> {
        self.journal_subject_ids_in_range(kind, start, end)
    }

    fn save(&self, cursor: u64, snapshot: &str) -> anyhow::Result<()> {
        use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
        self.put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            snapshot,
        )
    }
}

/// The roster the replay folds into: the start's own, or the daemon's
/// shared one, taken for one page at a time.
pub(super) trait RosterTarget {
    fn with<R>(&mut self, apply: impl FnOnce(&mut AgentRosterHost) -> R) -> R;
}

impl RosterTarget for &mut AgentRosterHost {
    fn with<R>(&mut self, apply: impl FnOnce(&mut AgentRosterHost) -> R) -> R {
        apply(self)
    }
}

impl RosterTarget for &Mutex<AgentRosterHost> {
    fn with<R>(&mut self, apply: impl FnOnce(&mut AgentRosterHost) -> R) -> R {
        apply(&mut self.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// Restore the roster from its persisted snapshot and fold the journal tail
/// committed after the cursor, for at most `STARTUP_BUDGET`. A
/// reducer-version mismatch, a snapshot that does not parse, or unreadable
/// reducer state discards the snapshot and re-folds from the journal head;
/// what the budget leaves is returned as `replay`. Deltas produced here are
/// dropped deliberately: their projection commits and change broadcasts
/// already happened when the events first committed, and the durable
/// projection restores itself independently.
pub(super) fn restore_agent_roster(
    registry: &WorkspaceRegistry,
) -> anyhow::Result<RestoredAgentRoster> {
    #[cfg(test)]
    let budget = STARTUP_BUDGET_FOR_TEST.with(std::cell::Cell::get).unwrap_or(STARTUP_BUDGET);
    #[cfg(not(test))]
    let budget = STARTUP_BUDGET;
    #[allow(unused_mut)]
    let mut limits = RosterFoldLimits::STARTUP;
    #[cfg(test)]
    if let Some(page) = PAGE_FOR_TEST.with(std::cell::Cell::get) {
        limits.page = page;
    }
    restore_agent_roster_within(registry, limits, Some(budget))
}

#[cfg(test)]
thread_local! {
    /// Test seam: the start's roster budget on this thread.
    pub(crate) static STARTUP_BUDGET_FOR_TEST: std::cell::Cell<Option<Duration>> =
        const { std::cell::Cell::new(None) };
    /// Test seam: the start's roster page size on this thread.
    pub(crate) static PAGE_FOR_TEST: std::cell::Cell<Option<usize>> =
        const { std::cell::Cell::new(None) };
    /// Test seam: a mux opened on this thread hands its background replay a
    /// gate. Before each slice the owner signals the first end and waits on
    /// the second, and each slice folds one page. A dropped end opens it.
    pub(crate) static REPLAY_GATE_FOR_TEST: std::cell::RefCell<
        Option<(std::sync::mpsc::SyncSender<()>, std::sync::mpsc::Receiver<()>)>,
    > = const { std::cell::RefCell::new(None) };
}

/// `restore_agent_roster` with no time budget: the whole tail is folded.
#[cfg(test)]
pub(super) fn restore_agent_roster_with(
    registry: &WorkspaceRegistry,
    limits: RosterFoldLimits,
) -> anyhow::Result<RestoredAgentRoster> {
    restore_agent_roster_within(registry, limits, None)
}

pub(super) fn restore_agent_roster_within(
    registry: &WorkspaceRegistry,
    limits: RosterFoldLimits,
    budget: Option<Duration>,
) -> anyhow::Result<RestoredAgentRoster> {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    let mut problems = Vec::new();
    let state = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap_or_else(|_| {
        eprintln!("cmux-tui: agent roster snapshot is unreadable; rebuilding it from the journal");
        problems.push("its snapshot was unreadable".to_owned());
        Some((0, 0, String::new()))
    });
    let (mut host, mut needs_repair) = match state {
        Some((version, cursor, snapshot)) if version == AGENT_ROSTER_REDUCER_VERSION => {
            match AgentRoster::restore(&snapshot) {
                Some(roster) => (AgentRosterHost { roster, cursor }, false),
                // The cursor is meaningful only with the snapshot that was
                // captured at the same fold boundary. Replaying from zero
                // is the safe recovery path for malformed persisted state.
                None => (AgentRosterHost::default(), true),
            }
        }
        Some(_) => (AgentRosterHost::default(), true),
        None => (AgentRosterHost::default(), false),
    };
    // A cursor beyond the current journal head cannot describe a retained
    // snapshot boundary. Treat it like any other rejected checkpoint so a
    // metadata write or journal repair cannot make startup fail permanently.
    let head = registry.session_journal_head()?;
    if host.cursor > head {
        host = AgentRosterHost::default();
        needs_repair = true;
    }
    let mut replay = AgentRosterReplay {
        through: head,
        saved_at: host.cursor,
        pages: 0,
        needs_repair,
        skipped: Vec::new(),
        problems,
        limits,
    };
    let deadline = budget.map(|budget| Instant::now() + budget);
    let progress = replay.fold(registry, &mut &mut host, deadline)?;
    Ok(match progress {
        ReplayProgress::Done { diagnostic } => {
            RestoredAgentRoster { host, diagnostic, replay: None }
        }
        ReplayProgress::Paused => {
            eprintln!(
                "cmux-tui: agent roster replay continues in the background at sequence {} of {}",
                host.cursor, replay.through
            );
            RestoredAgentRoster { host, diagnostic: None, replay: Some(replay) }
        }
    })
}

impl AgentRosterReplay {
    /// Test seam: the next fold stops after one more page.
    #[cfg(test)]
    pub(super) fn stop_after_next_page(&mut self) {
        self.limits.stop_after_pages = Some(self.pages + 1);
    }

    /// Test seam: the fold runs on with no page limit.
    #[cfg(test)]
    pub(super) fn run_on(&mut self) {
        self.limits.stop_after_pages = None;
    }

    /// Folds the journal from the roster's cursor through the start's head,
    /// until `deadline`. Saves the roster and its cursor every
    /// `save_every_pages` pages, and once at the end when anything changed.
    pub(super) fn fold(
        &mut self,
        journal: &impl RosterJournal,
        target: &mut impl RosterTarget,
        deadline: Option<Instant>,
    ) -> anyhow::Result<ReplayProgress> {
        let limits = self.limits;
        loop {
            let cursor = target.with(|host| host.cursor);
            if cursor >= self.through {
                break;
            }
            // Checkpoint a long replay. Not after a skipped range: the roster
            // marks live claims in it unknown only once the fold ends, and a
            // cursor saved before that would skip the marking at the next start.
            if self.pages > 0
                && self.pages.is_multiple_of(limits.save_every_pages)
                && self.skipped.is_empty()
                && cursor != self.saved_at
            {
                let snapshot = target.with(|host| host.roster.snapshot().to_string());
                if journal.save(cursor, &snapshot).is_ok() {
                    self.saved_at = cursor;
                }
            }
            if limits.stop_after_pages == Some(self.pages)
                || deadline.is_some_and(|deadline| Instant::now() >= deadline)
            {
                return Ok(ReplayProgress::Paused);
            }
            self.pages += 1;
            // The roster folds only agent kinds ([`AgentRoster::folds_kind`]);
            // the rest can be nearly the whole tail (terminal output, session
            // churn: 12M rows on a 59 GB registry): the indexed read visits only
            // the agent records. A read error, or one that makes no progress,
            // falls back to the salvaging read below, which skips the range
            // that does not decode.
            if let Ok((records, reached)) = journal.kinds_after(cursor, self.through, limits.page)
                && reached > cursor
            {
                target.with(|host| {
                    apply_records(host, &records);
                    host.cursor = reached;
                });
                continue;
            }
            match journal.after_salvaging(cursor, limits.page)? {
                SalvagedJournalPage::Page(page) => {
                    if page.records.is_empty() {
                        break;
                    }
                    target.with(|host| {
                        for record in &page.records {
                            apply_records(host, std::slice::from_ref(record));
                            host.cursor = host.cursor.max(record.sequence);
                        }
                    });
                }
                SalvagedJournalPage::Skipped(skip) => {
                    eprintln!(
                        "cmux-tui: agent roster restore skipped journal {}: {}",
                        describe_range(&skip),
                        skip.reason
                    );
                    target.with(|host| host.cursor = host.cursor.max(skip.end_sequence));
                    self.skipped.push(skip);
                }
            }
        }
        if !self.skipped.is_empty() {
            target.with(|host| neutralize_live_claims(journal, host, &self.skipped));
            self.problems.push(skipped_ranges_problem(&self.skipped));
        }
        let (cursor, snapshot) =
            target.with(|host| (host.cursor, host.roster.snapshot().to_string()));
        if self.needs_repair || cursor != self.saved_at {
            // The in-memory roster is already correct. A failed write only means
            // the next start folds this tail again.
            if journal.save(cursor, &snapshot).is_err() {
                eprintln!("cmux-tui: persisting the restored agent roster failed");
                self.problems.push("its snapshot was not saved".to_owned());
            } else {
                self.saved_at = cursor;
            }
        }
        let diagnostic = (!self.problems.is_empty())
            .then(|| format!("agent roster restored with problems: {}", self.problems.join("; ")));
        Ok(ReplayProgress::Done { diagnostic })
    }
}

fn apply_records(host: &mut AgentRosterHost, records: &[SessionJournalRecord]) {
    use crate::journal_reducers::RosterEvent;
    for record in records {
        host.roster.apply(&RosterEvent::from_record(record));
    }
}

/// Entries whose terminal has records in a skipped range may be stale: the
/// range can hold the event that ended their live state. The subject index
/// names those terminals without decoding the range; if it cannot be read,
/// every live entry is treated as affected.
fn neutralize_live_claims(
    registry: &impl RosterJournal,
    host: &mut AgentRosterHost,
    skipped: &[SkippedJournalRange],
) {
    let mut affected = std::collections::HashSet::new();
    let mut all = false;
    for skip in skipped {
        match registry.subject_ids_in_range("terminal", skip.start_sequence, skip.end_sequence) {
            Ok(ids) => affected.extend(ids),
            Err(_) => all = true,
        }
    }
    for (terminal_id, entry) in &mut host.roster.entries {
        if LIVE_STATES.contains(&entry.state.as_str()) && (all || affected.contains(terminal_id)) {
            eprintln!(
                "cmux-tui: agent roster marks terminal {terminal_id} {NEUTRAL_STATE}: its events \
                 overlap a skipped journal range"
            );
            entry.state = NEUTRAL_STATE.to_owned();
        }
    }
}

fn describe_range(skip: &SkippedJournalRange) -> String {
    let range = if skip.start_sequence == skip.end_sequence {
        format!("sequence {}", skip.start_sequence)
    } else {
        format!("sequences {}-{}", skip.start_sequence, skip.end_sequence)
    };
    match &skip.segment_id {
        Some(segment_id) => format!("{range} (sealed segment {segment_id})"),
        None => range,
    }
}

fn skipped_ranges_problem(skipped: &[SkippedJournalRange]) -> String {
    let mut listed = skipped
        .iter()
        .take(LISTED_SKIPPED_RANGES)
        .map(|skip| format!("{}: {}", describe_range(skip), skip.reason))
        .collect::<Vec<_>>();
    if skipped.len() > LISTED_SKIPPED_RANGES {
        listed.push(format!("{} more", skipped.len() - LISTED_SKIPPED_RANGES));
    }
    format!(
        "undecodable journal ranges were skipped; agents with events there may be missing or out \
         of date until they report again ({})",
        listed.join(", ")
    )
}
