//! Agent roster restore at daemon start.
//!
//! Daemon start must not depend on decoding every historical journal
//! segment (cx-6b12). The roster folds what decodes; a range that does not
//! decode is skipped, logged with its range and error, and reported once to
//! the frontend diagnostic sink. The fold never invents entries: it applies
//! only decoded records. An agent with events in a skipped range is missing
//! or shows its last decoded state until it reports again.

use super::{AgentRosterHost, WorkspaceRegistry};
use crate::workspace_registry::session_journal::salvage::{
    SalvagedJournalPage, SkippedJournalRange,
};

/// Ranges listed by name in the diagnostic; the rest are counted.
const LISTED_SKIPPED_RANGES: usize = 4;

pub(super) struct RestoredAgentRoster {
    pub(super) host: AgentRosterHost,
    /// A non-fatal startup problem for the frontend diagnostic sink.
    pub(super) diagnostic: Option<String>,
}

/// Restore the roster from its persisted snapshot and fold the journal tail
/// committed after the cursor. A reducer-version mismatch, a snapshot that
/// does not parse, or unreadable reducer state discards the snapshot and
/// re-folds from the journal head. Deltas produced here are dropped
/// deliberately: their projection commits and change broadcasts already
/// happened when the events first committed, and the durable projection
/// restores itself independently.
pub(super) fn restore_agent_roster(
    registry: &WorkspaceRegistry,
) -> anyhow::Result<RestoredAgentRoster> {
    use crate::journal_reducers::{
        AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
    };
    let mut problems = Vec::new();
    let state = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap_or_else(|error| {
        eprintln!("cmux-tui: agent roster snapshot is unreadable, rebuilding it: {error:#}");
        problems.push(format!("its snapshot was unreadable ({error:#})"));
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
    if host.cursor > 0 {
        let journal_head = registry.session_journal_head()?;
        if host.cursor > journal_head {
            host = AgentRosterHost::default();
            needs_repair = true;
        }
    }
    let started_at = host.cursor;
    let mut skipped = Vec::new();
    loop {
        match registry.session_journal_after_salvaging(host.cursor, 512)? {
            SalvagedJournalPage::Page(page) => {
                if page.records.is_empty() {
                    break;
                }
                for record in &page.records {
                    host.roster.apply(&RosterEvent::from_record(record));
                    host.cursor = host.cursor.max(record.sequence);
                }
            }
            SalvagedJournalPage::Skipped(skip) => {
                eprintln!(
                    "cmux-tui: agent roster restore skipped journal {}: {}",
                    describe_range(&skip),
                    skip.error
                );
                host.cursor = host.cursor.max(skip.end_sequence);
                skipped.push(skip);
            }
        }
    }
    if !skipped.is_empty() {
        problems.push(skipped_ranges_problem(&skipped));
    }
    if needs_repair || host.cursor != started_at {
        // The in-memory roster is already correct. A failed write only means
        // the next start folds this tail again.
        if let Err(error) = registry.put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            host.cursor,
            &host.roster.snapshot().to_string(),
        ) {
            eprintln!("cmux-tui: persisting the restored agent roster failed: {error:#}");
            problems.push(format!("its snapshot was not saved ({error:#})"));
        }
    }
    let diagnostic = (!problems.is_empty())
        .then(|| format!("agent roster restored with problems: {}", problems.join("; ")));
    Ok(RestoredAgentRoster { host, diagnostic })
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
        .map(|skip| format!("{}: {}", describe_range(skip), skip.error))
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
