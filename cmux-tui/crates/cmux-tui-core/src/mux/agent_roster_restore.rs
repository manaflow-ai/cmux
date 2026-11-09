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
    /// The roster is stale (migrated from an older reducer version, or empty
    /// from the head): the roster's owner folds the whole journal again in
    /// the background and replaces it (`agent_roster_rebuild.rs`).
    pub(super) rebuild: bool,
}

/// Restore the roster from its persisted snapshot and fold the journal tail
/// committed after the cursor. A snapshot that does not parse, or unreadable
/// reducer state, discards the snapshot and re-folds from the journal head.
/// A reducer-version mismatch does not: the start never folds the journal
/// from its first record for a bump (26 min on a 59 GB registry, 2026-11-08).
/// It serves the old snapshot through [`AgentRoster::migrate`] from its own
/// cursor, or an empty roster from the head when the old format no longer
/// restores, marked stale, and the roster's owner rebuilds it from the whole
/// journal in the background. A migrated roster can be wrong until then:
/// every bump so far fixed the fold's logic. Deltas produced here are dropped
/// deliberately: their projection commits and change broadcasts already
/// happened when the events first committed, and the durable projection
/// restores itself independently.
pub(super) fn restore_agent_roster(
    registry: &WorkspaceRegistry,
) -> anyhow::Result<RestoredAgentRoster> {
    use crate::journal_reducers::{
        AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
    };
    crate::restore_progress::enter(crate::restore_progress::RestorePhase::AgentRoster);
    crate::restore_progress::test_delay();
    let mut problems = Vec::new();
    let state = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap_or_else(|_| {
        eprintln!("cmux-tui: agent roster snapshot is unreadable; rebuilding it from the journal");
        problems.push("its snapshot was unreadable".to_owned());
        Some((0, 0, String::new()))
    });
    let head = registry.session_journal_head()?;
    // A stale roster an earlier start served and did not finish rebuilding.
    let pending = registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).ok().flatten();
    let mut rebuild_from = pending;
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
        Some((version, cursor, snapshot)) => {
            rebuild_from = Some(version);
            match AgentRoster::migrate(version, &snapshot) {
                Some(roster) if cursor <= head => {
                    eprintln!(
                        "cmux-tui: agent roster reducer version {version} -> \
                         {AGENT_ROSTER_REDUCER_VERSION}: serving the migrated snapshot while it \
                         rebuilds in the background"
                    );
                    (AgentRosterHost { roster, cursor }, true)
                }
                _ => {
                    eprintln!(
                        "cmux-tui: agent roster reducer version {version} -> \
                         {AGENT_ROSTER_REDUCER_VERSION}: the old snapshot does not restore; \
                         serving live events while it rebuilds in the background"
                    );
                    (AgentRosterHost { roster: AgentRoster::default(), cursor: head }, true)
                }
            }
        }
        None => (AgentRosterHost::default(), false),
    };
    // A cursor beyond the current journal head cannot describe a retained
    // snapshot boundary. Treat it like any other rejected checkpoint so a
    // metadata write or journal repair cannot make startup fail permanently.
    if host.cursor > head {
        host = AgentRosterHost::default();
        needs_repair = true;
    }
    let started_at = host.cursor;
    // A fold from the first record is itself the rebuild.
    if started_at == 0 {
        rebuild_from = None;
    }
    let mut skipped = Vec::new();
    // Journal rows this fold covers, for `identify` while the owner restores
    // (a reducer version change folds the whole journal).
    let fold_total = Some(head.saturating_sub(started_at));
    loop {
        crate::restore_progress::advance(host.cursor.saturating_sub(started_at), fold_total);
        if host.cursor >= head {
            break;
        }
        // The roster folds only agent kinds ([`AgentRoster::folds_kind`]);
        // the rest can be nearly the whole tail (terminal output, session
        // churn: 12M rows on a 59 GB registry): the indexed read visits only
        // the agent records. A read error, or
        // one that makes no progress, falls back to the salvaging read below,
        // which skips the range that does not decode.
        if let Ok((records, reached)) =
            registry.session_journal_kinds_after(host.cursor, head, AgentRoster::folds_kind, 512)
            && reached > host.cursor
        {
            for record in &records {
                host.roster.apply(&RosterEvent::from_record(record));
            }
            host.cursor = reached;
            continue;
        }
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
    // A migrated snapshot is saved together with its stale mark, in one
    // transaction: saved at the current version without it, the snapshot
    // would pass for the current reducer's fold at every later start. When
    // that save fails, the old version's state stays, and the next start
    // migrates it again. An earlier start's mark still stands, so a later
    // save of the stale roster needs none; the mark goes with the save of a
    // full fold.
    let first_mark = rebuild_from.filter(|_| pending.is_none());
    let finished = pending.is_some() && rebuild_from.is_none();
    if needs_repair || finished || first_mark.is_some() || host.cursor != started_at {
        // The in-memory roster is already what this start serves. A failed
        // write only means the next start folds this tail again.
        let snapshot = host.roster.snapshot().to_string();
        let saved = if finished {
            registry.finish_journal_reducer_rebuild(
                AGENT_ROSTER_REDUCER_ID,
                AGENT_ROSTER_REDUCER_VERSION,
                host.cursor,
                &snapshot,
            )
        } else if let Some(from_version) = first_mark {
            registry.start_journal_reducer_rebuild(
                AGENT_ROSTER_REDUCER_ID,
                from_version,
                AGENT_ROSTER_REDUCER_VERSION,
                host.cursor,
                &snapshot,
            )
        } else {
            registry.put_journal_reducer_state(
                AGENT_ROSTER_REDUCER_ID,
                AGENT_ROSTER_REDUCER_VERSION,
                host.cursor,
                &snapshot,
            )
        };
        if saved.is_err() {
            eprintln!("cmux-tui: persisting the restored agent roster failed");
            problems.push("its snapshot was not saved".to_owned());
        }
    }
    let diagnostic = (!problems.is_empty())
        .then(|| format!("agent roster restored with problems: {}", problems.join("; ")));
    Ok(RestoredAgentRoster { host, diagnostic, rebuild: rebuild_from.is_some() })
}

/// Entries whose terminal has records in a skipped range may be stale: the
/// range can hold the event that ended their live state. The subject index
/// names those terminals without decoding the range; if it cannot be read,
/// every live entry is treated as affected.
pub(super) fn neutralize_live_claims(
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

pub(super) fn describe_range(skip: &SkippedJournalRange) -> String {
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

pub(super) fn skipped_ranges_problem(skipped: &[SkippedJournalRange]) -> String {
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
