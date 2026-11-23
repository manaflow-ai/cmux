//! A plugin report that repeats what the roster holds from it is live state,
//! not journal.
//!
//! The screen-detection plugin sends its `blocked` state again each 800 ms
//! while a dialog is visible (`STABLE_BLOCKER_REFRESH_MS`). On Lawrence's
//! daemon, 2026-11-10, 6 % of the journal rows were
//! `plugin.<producer>.agent.state.changed` and 6 % were `agent.report`. While
//! the plugin owns the terminal's roster row, each refresh was one plugin row
//! and one projection commit, and both moved only a time:
//!
//! - durable: the producer, its child generation, the state and the process
//!   (`source_session`). A report that changes one of them is a row;
//! - live: `observed_at_ms` of a report equal in all four while the plugin
//!   owns the row (`AgentRoster::plugin_report_moves_only_its_time`).
//!
//! So the ingress decides before the append, for any plugin producer. The
//! plugin still gets a receipt: the one of its last row of the terminal,
//! marked `replayed` because this report added nothing to it. No journal row
//! and no registry commit; in memory, but for the journal hook list, which
//! the first report after a start or a hook change reads from the registry.
//!
//! A report is still appended:
//!
//! - when it changes a durable fact, or the roster row is not the plugin's
//!   (on a hook's row the report is evidence ordered by its time);
//! - the first one of a terminal in this daemon run (the table is memory);
//! - while a report of the terminal (the plugin's or a hook's) is on its way
//!   to the journal, or the roster has not folded every row asked of it;
//! - after a row of the terminal whose result is not known;
//! - while a journal hook or a live journal follower reads the kind or
//!   `agent.report` (`Mux::journal_reader_keeps_plugin_rows`).
//!
//! What a reader sees change: the entry's `updated_at_ms` stays at the first
//! report of the state while the state holds. Its `since_ms`, state, source
//! and session are the same.

use std::collections::VecDeque;

use super::*;

/// Idempotency keys remembered per terminal, so a retry gets its first answer.
const MAX_RECENT_KEYS: usize = 16;

/// The plugin's last journal row of a terminal.
#[derive(Debug)]
struct StoredPluginRow {
    producer: String,
    sequence: u64,
    event_id: String,
}

#[derive(Debug, Default)]
struct PluginSlot {
    /// Plugin reports of this terminal on their way to the journal.
    in_flight: u32,
    stored: Option<StoredPluginRow>,
    /// The reports answered from memory, by origin and idempotency key.
    recent: VecDeque<(String, crate::JournalAppendCommit)>,
}

/// The last journal row of each terminal's plugin. Memory only.
#[derive(Debug, Default)]
pub(super) struct AgentPluginReportsAtRest {
    terminals: Mutex<HashMap<TerminalPublicId, PluginSlot>>,
}

impl AgentPluginReportsAtRest {
    fn terminals(&self) -> MutexGuard<'_, HashMap<TerminalPublicId, PluginSlot>> {
        self.terminals.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn forget_terminal(&self, terminal: &TerminalPublicId) {
        self.terminals().remove(terminal);
    }

    /// The answer a report with `key` of `terminal` got at rest before. The
    /// table lock is taken and released here.
    fn recent_answer(
        &self,
        terminal: &TerminalPublicId,
        key: &str,
    ) -> Option<crate::JournalAppendCommit> {
        let terminals = self.terminals();
        let slot = terminals.get(terminal)?;
        slot.recent.iter().find(|(recent, _)| recent == key).map(|(_, answer)| answer.clone())
    }
}

/// One plugin report on its way to the journal.
pub(super) struct PluginReportInFlight<'a> {
    at_rest: &'a AgentPluginReportsAtRest,
    terminal: TerminalPublicId,
}

impl Drop for PluginReportInFlight<'_> {
    fn drop(&mut self) {
        if let Some(slot) = self.at_rest.terminals().get_mut(&self.terminal) {
            slot.in_flight = slot.in_flight.saturating_sub(1);
        }
    }
}

/// The terminal an agent plugin's report is about; `None` for other rows.
fn plugin_report_terminal(ingress: &crate::JournalIngress) -> Option<TerminalPublicId> {
    if ingress.producer_id == crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
        || ingress.payload.get("format").and_then(Value::as_str)
            != Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
    {
        return None;
    }
    ingress
        .subjects
        .iter()
        .find(|subject| subject.kind == "terminal")
        .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
}

impl Mux {
    /// The answer to a plugin report that repeats what the roster holds from
    /// the same plugin child; `None` when the report must be appended (module
    /// doc). No journal row and no commit. In memory, with one exception: the
    /// first call after a start or a journal hook change reads the hook list
    /// from the registry (`journal_reader_keeps_plugin_rows`).
    pub(super) fn answer_agent_plugin_report_at_rest(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> Option<crate::JournalAppendCommit> {
        let terminal = plugin_report_terminal(ingress)?;
        // A retry gets its first answer. Before the reader check: the registry
        // holds no receipt of a report answered here, so a reader that came
        // since would get the retry as a second row.
        let key = format!("{origin}\n{idempotency_key}");
        if let Some(answer) = self.agent_plugin_reports_at_rest.recent_answer(&terminal, &key) {
            return Some(answer);
        }
        if self.journal_reader_keeps_plugin_rows(ingress) {
            return None;
        }
        // Held through the roster read: a report of this terminal that is
        // sent meanwhile waits here, then finds this one answered.
        let mut terminals = self.agent_plugin_reports_at_rest.terminals();
        let slot = terminals.get_mut(&terminal)?;
        // Again under this lock: the same key can have got its answer since
        // the read above, which did not hold it.
        if let Some((_, answer)) = slot.recent.iter().find(|(recent, _)| *recent == key) {
            return Some(answer.clone());
        }
        if slot.in_flight > 0 {
            return None;
        }
        let stored =
            slot.stored.as_ref().filter(|stored| stored.producer == ingress.producer_id)?;
        // A hook row on its way can take the terminal's roster row.
        if self.agent_hooks_at_rest.hook_in_flight(&terminal) {
            return None;
        }
        let now_ms = crate::workspace_registry::unix_epoch_ms().ok()?;
        let wanted = self.wanted_roster_sequence();
        let repeats = {
            let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            host.cursor >= wanted
                && host.cursor >= stored.sequence
                && host.roster.plugin_report_moves_only_its_time(
                    &crate::journal_reducers::RosterEvent {
                        producer_id: &ingress.producer_id,
                        kind: &ingress.kind,
                        subjects: &ingress.subjects,
                        payload: &ingress.payload,
                        sequence: host.cursor,
                        committed_at_ms: now_ms,
                    },
                )
        };
        if !repeats {
            return None;
        }
        let commit = crate::JournalAppendCommit {
            sequence: stored.sequence,
            event_id: stored.event_id.clone(),
            replayed: true,
        };
        if slot.recent.len() >= MAX_RECENT_KEYS {
            slot.recent.pop_front();
        }
        slot.recent.push_back((key, commit.clone()));
        Some(commit)
    }

    /// Marks a plugin report as on its way to the journal until the guard
    /// drops. A terminal that is not open gets no table entry: its close
    /// already ran `forget_terminal`, and nothing would remove a later one.
    pub(super) fn agent_plugin_report_in_flight(
        &self,
        ingress: &crate::JournalIngress,
    ) -> Option<PluginReportInFlight<'_>> {
        let terminal = plugin_report_terminal(ingress)?;
        let mut terminals = self.agent_plugin_reports_at_rest.terminals();
        if !terminals.contains_key(&terminal) && self.terminal_resource_surface(&terminal).is_none()
        {
            return None;
        }
        terminals.entry(terminal.clone()).or_default().in_flight += 1;
        drop(terminals);
        Some(PluginReportInFlight { at_rest: &self.agent_plugin_reports_at_rest, terminal })
    }

    /// Records how the append of a plugin report (sent as `in_flight`) ended:
    /// a new row is the terminal's stored row; an error (the row can still
    /// commit after its producer gave up) or a retry the registry answered
    /// forgets it, so the next report is appended.
    pub(super) fn note_agent_plugin_report_result(
        &self,
        ingress: &crate::JournalIngress,
        commit: Option<&crate::JournalAppendCommit>,
        in_flight: Option<&PluginReportInFlight<'_>>,
    ) {
        let Some(in_flight) = in_flight else { return };
        let mut terminals = self.agent_plugin_reports_at_rest.terminals();
        let Some(slot) = terminals.get_mut(&in_flight.terminal) else { return };
        match commit {
            Some(commit) if !commit.replayed => {
                if slot.stored.as_ref().is_none_or(|stored| stored.sequence < commit.sequence) {
                    slot.stored = Some(StoredPluginRow {
                        producer: ingress.producer_id.clone(),
                        sequence: commit.sequence,
                        event_id: commit.event_id.clone(),
                    });
                }
            }
            _ => slot.stored = None,
        }
    }
}
