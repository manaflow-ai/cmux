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

use super::{AgentRosterHost, WorkspaceRegistry};
use crate::workspace_registry::session_journal::salvage::{
    SalvagedJournalPage, SkippedJournalRange,
};

/// Ranges listed by name in the diagnostic; the rest are counted.
const LISTED_SKIPPED_RANGES: usize = 4;

/// Roster states that claim the agent is active right now.
const LIVE_STATES: [&str; 2] = ["working", "blocked"];
/// The spec's neutral agent state; every agents view hides it.
const NEUTRAL_STATE: &str = "unknown";

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
                    skip.reason
                );
                host.cursor = host.cursor.max(skip.end_sequence);
                skipped.push(skip);
            }
        }
    }
    if !skipped.is_empty() {
        neutralize_live_claims(registry, &mut host, &skipped);
        problems.push(skipped_ranges_problem(&skipped));
    }
    if needs_repair || host.cursor != started_at {
        // The in-memory roster is already correct. A failed write only means
        // the next start folds this tail again.
        if registry
            .put_journal_reducer_state(
                AGENT_ROSTER_REDUCER_ID,
                AGENT_ROSTER_REDUCER_VERSION,
                host.cursor,
                &host.roster.snapshot().to_string(),
            )
            .is_err()
        {
            eprintln!("cmux-tui: persisting the restored agent roster failed");
            problems.push("its snapshot was not saved".to_owned());
        }
    }
    let diagnostic = (!problems.is_empty())
        .then(|| format!("agent roster restored with problems: {}", problems.join("; ")));
    Ok(RestoredAgentRoster { host, diagnostic })
}

/// Entries whose terminal has records in a skipped range may be stale: the
/// range can hold the event that ended their live state. The subject index
/// names those terminals without decoding the range; if it cannot be read,
/// every live entry is treated as affected.
fn neutralize_live_claims(
    registry: &WorkspaceRegistry,
    host: &mut AgentRosterHost,
    skipped: &[SkippedJournalRange],
) {
    let mut affected = std::collections::HashSet::new();
    let mut all = false;
    for skip in skipped {
        match registry.journal_subject_ids_in_range(
            "terminal",
            skip.start_sequence,
            skip.end_sequence,
        ) {
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
