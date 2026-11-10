//! An agent hook that changes no durable state is live state, not journal.
//!
//! Lawrence's daemon, 2026-11-10 (826 workspaces, 170 agents): 64 % of the
//! journal rows were `agent.state.changed` (a tool call, a notification, a
//! hook cmux has no name for), 3.3 a second, each one a registry commit and
//! two more lock takes for retry bookkeeping. Such a row moves nothing a
//! reader of the journal keeps:
//!
//! - the roster reducer returns before it reads a fence (`hook_roster_state`
//!   is `None`), and the hook projector returns before it commits;
//! - the history fold (`cmux-history::fold_agent`, and its Swift twin) keeps a
//!   session's provider, id, directory and terminal, which an earlier row of
//!   the session already gave it. Its last-activity time is the one thing the
//!   row moved; that time now moves with the turn and session rows.
//!
//! So the ingress decides before the append. The hook still does its live
//! work from memory (presence with the tool's target, the activity stream)
//! and its caller still gets a receipt: the one of the journal row that holds
//! the session's durable facts, marked `replayed` because this report added
//! nothing to it. A retry (the same origin and idempotency key) gets its first
//! answer again and has no second effect.
//!
//! A row is still appended when it carries something durable:
//!
//! - the first report of a terminal in this daemon run, a new agent session,
//!   a new directory, a new agent-tree subject, or the first report after the
//!   session ended (the history fold opens the session again from it);
//! - a completed tool call while the agent is blocked (it resumes the agent);
//! - while another hook of the terminal is still on its way to the journal
//!   (the row keeps its place in their order);
//! - while an enabled journal hook's kind filter matches
//!   `agent.state.changed`: that hook is delivered every row.
//!
//! The table is memory only. After a restart the first report of each
//! terminal is appended again, and the roster folds to the same state because
//! the rows left out never changed it.

use std::collections::{HashSet, VecDeque};

use super::*;

/// The journal kind of a hook that names no lifecycle step.
const AT_REST_KIND: &str = "agent.state.changed";
/// Subject lists kept per terminal (one per agent-tree node that reported).
const MAX_SUBJECT_LISTS: usize = 512;
/// Idempotency keys remembered per terminal, so a hook's retry is told apart
/// from a new report.
const MAX_RECENT_KEYS: usize = 64;

/// What the journal already holds of the agent session in one terminal.
#[derive(Debug)]
struct StoredHookFacts {
    provider: Option<String>,
    session: Option<String>,
    cwd: Option<String>,
    subject_lists: HashSet<String>,
    /// The receipt of the latest row that holds these facts.
    sequence: u64,
    event_id: String,
}

#[derive(Debug, Default)]
struct HookSlot {
    /// Hooks of this terminal on their way to the journal.
    in_flight: u32,
    /// The highest sequence noted: commits can finish out of order.
    noted_sequence: u64,
    stored: Option<StoredHookFacts>,
    /// The latest reports by origin and idempotency key, with the answer of
    /// each one that got no row (`None`: the report was appended, and the
    /// registry holds its receipt).
    recent: VecDeque<(String, Option<crate::JournalAppendCommit>)>,
}

impl HookSlot {
    fn remember(&mut self, key: String, answer: Option<crate::JournalAppendCommit>) {
        if self.recent.len() >= MAX_RECENT_KEYS {
            self.recent.pop_front();
        }
        self.recent.push_back((key, answer));
    }
}

fn receipt_key(origin: &str, idempotency_key: &str) -> String {
    format!("{origin}\n{idempotency_key}")
}

/// The durable facts one hook report carries for the history fold.
struct HookFacts<'a> {
    terminal: TerminalPublicId,
    provider: Option<&'a str>,
    session: Option<&'a str>,
    cwd: Option<&'a str>,
    subject_list: String,
}

impl<'a> HookFacts<'a> {
    /// The facts of a report an agent's hook helper sent; `None` for every
    /// other row of the hook producer (a socket report's echo, program status
    /// evidence, screen detection, a plugin's exit).
    fn of(ingress: &'a crate::JournalIngress) -> Option<Self> {
        use crate::journal_reducers as reducers;
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
            || reducers::is_program_status_evidence(&ingress.producer_id, &ingress.payload)
        {
            return None;
        }
        let text = |pointer: &str| {
            ingress.payload.pointer(pointer).and_then(Value::as_str).filter(|text| !text.is_empty())
        };
        let provider = text("/adapter/id");
        let native_event = text("/native_event");
        if provider == Some(reducers::SOCKET_REPORT_ADAPTER)
            || native_event == Some(reducers::LEGACY_SCREEN_DETECT_NATIVE_EVENT)
            || native_event == Some(crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT)
        {
            return None;
        }
        let terminal = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())?;
        let mut subject_list = String::new();
        for subject in &ingress.subjects {
            subject_list.push_str(&subject.kind);
            subject_list.push('=');
            subject_list.push_str(&subject.id);
            subject_list.push('\n');
        }
        Some(Self {
            terminal,
            provider,
            session: text("/normalized/agent_session_id")
                .or_else(|| text("/normalized/root_agent_session_id")),
            cwd: text("/normalized/cwd"),
            subject_list,
        })
    }
}

impl StoredHookFacts {
    fn same_session(&self, facts: &HookFacts<'_>) -> bool {
        self.provider.as_deref() == facts.provider
            && (facts.session.is_none() || self.session.as_deref() == facts.session)
    }

    /// Whether a row with `facts` would tell a journal reader nothing new.
    fn holds(&self, facts: &HookFacts<'_>) -> bool {
        self.same_session(facts)
            && (facts.cwd.is_none() || self.cwd.as_deref() == facts.cwd)
            && self.subject_lists.contains(&facts.subject_list)
    }
}

/// Which agent sessions the journal holds, per terminal, and whether a
/// journal hook reads the rows this module leaves out. Memory only.
#[derive(Debug, Default)]
pub(super) struct AgentHooksAtRest {
    terminals: Mutex<HashMap<TerminalPublicId, HookSlot>>,
    /// Whether an enabled journal hook's kind filter matches
    /// `agent.state.changed`; `None` until read, and after a hook changed.
    journal_hook_reads_rows: Mutex<Option<bool>>,
}

impl AgentHooksAtRest {
    fn terminals(&self) -> MutexGuard<'_, HashMap<TerminalPublicId, HookSlot>> {
        self.terminals.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn forget_terminal(&self, terminal: &TerminalPublicId) {
        self.terminals().remove(terminal);
    }

    /// Terminals with a table entry.
    #[cfg(test)]
    fn slots(&self) -> usize {
        self.terminals().len()
    }

    /// The installed journal hooks are about to change. Hold the guard
    /// through the change: a hook report that comes meanwhile waits, then
    /// reads the new hooks, so a hook installed now misses no row.
    pub(super) fn journal_hooks_changing(&self) -> MutexGuard<'_, Option<bool>> {
        let mut reads_rows =
            self.journal_hook_reads_rows.lock().unwrap_or_else(PoisonError::into_inner);
        *reads_rows = None;
        reads_rows
    }
}

/// One hook on its way to the journal; reports of its terminal that come
/// meanwhile are appended too, so they keep their place after it.
pub(super) struct HookInFlight<'a> {
    at_rest: &'a AgentHooksAtRest,
    terminal: TerminalPublicId,
}

impl Drop for HookInFlight<'_> {
    fn drop(&mut self) {
        if let Some(slot) = self.at_rest.terminals().get_mut(&self.terminal) {
            slot.in_flight = slot.in_flight.saturating_sub(1);
        }
    }
}

fn kind_filter_matches_at_rest_kind(kinds: &[String]) -> bool {
    kinds.is_empty()
        || kinds.iter().any(|kind| match kind.strip_suffix(".*") {
            Some(prefix) => {
                AT_REST_KIND.strip_prefix(prefix).is_some_and(|rest| rest.starts_with('.'))
            }
            None => kind == AT_REST_KIND,
        })
}

impl Mux {
    #[cfg(test)]
    pub(crate) fn agent_hook_slots_for_test(&self) -> usize {
        self.agent_hooks_at_rest.slots()
    }

    /// The answer to a hook report that changes no durable state, with its
    /// live effects applied; `None` when the report must be appended (module
    /// doc). In memory: no registry lock, no journal row, no commit.
    pub(super) fn answer_agent_hook_at_rest(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> Option<crate::JournalAppendCommit> {
        if ingress.kind != AT_REST_KIND {
            return None;
        }
        let facts = HookFacts::of(ingress)?;
        let native_event =
            ingress.payload.get("native_event").and_then(Value::as_str).unwrap_or_default();
        if crate::agent_hooks::is_tool_completion(native_event)
            && self.tool_completion_may_resume_agent(&facts.terminal)
        {
            return None;
        }
        if self.journal_hook_reads_at_rest_rows() {
            return None;
        }
        // Held through the presence change: a later row of this terminal (a
        // turn's end) waits here, so its presence change comes after this one.
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let slot = terminals.get_mut(&facts.terminal)?;
        // A retry gets its first answer and has no second effect; the retry
        // of an appended report goes to the registry, which holds its receipt.
        let key = receipt_key(origin, idempotency_key);
        if let Some((_, answer)) = slot.recent.iter().find(|(recent, _)| *recent == key) {
            return answer.clone();
        }
        let stored = slot.stored.as_ref().filter(|_| slot.in_flight == 0)?;
        if !stored.holds(&facts) {
            return None;
        }
        let commit = crate::JournalAppendCommit {
            sequence: stored.sequence,
            event_id: stored.event_id.clone(),
            replayed: true,
        };
        slot.remember(key, Some(commit.clone()));
        self.activity.note_agent_action();
        self.apply_live_agent_presence(ingress);
        Some(commit)
    }

    /// Marks a hook report as on its way to the journal until the guard drops.
    pub(super) fn agent_hook_in_flight(
        &self,
        ingress: &crate::JournalIngress,
    ) -> Option<HookInFlight<'_>> {
        let terminal = HookFacts::of(ingress)?.terminal;
        self.agent_hooks_at_rest.terminals().entry(terminal.clone()).or_default().in_flight += 1;
        Some(HookInFlight { at_rest: &self.agent_hooks_at_rest, terminal })
    }

    /// Records what the journal now holds of the terminal's agent session,
    /// after `ingress` committed as a new row at `commit`.
    pub(super) fn note_agent_hook_stored(
        &self,
        ingress: &crate::JournalIngress,
        commit: &crate::JournalAppendCommit,
        origin: &str,
        idempotency_key: &str,
    ) {
        let Some(facts) = HookFacts::of(ingress) else { return };
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let slot = terminals.entry(facts.terminal.clone()).or_default();
        slot.remember(receipt_key(origin, idempotency_key), None);
        if commit.sequence <= slot.noted_sequence {
            return;
        }
        slot.noted_sequence = commit.sequence;
        if ingress.kind == "agent.session.ended" {
            // The history fold opens an ended session again from the next
            // row of it, so that row must be appended.
            slot.stored = None;
            return;
        }
        match slot.stored.as_mut().filter(|stored| stored.same_session(&facts)) {
            Some(stored) => {
                if let Some(cwd) = facts.cwd {
                    stored.cwd = Some(cwd.to_owned());
                }
                if stored.subject_lists.len() >= MAX_SUBJECT_LISTS {
                    stored.subject_lists.clear();
                }
                stored.subject_lists.insert(facts.subject_list);
                stored.sequence = commit.sequence;
                stored.event_id.clone_from(&commit.event_id);
            }
            None => {
                slot.stored = Some(StoredHookFacts {
                    provider: facts.provider.map(str::to_owned),
                    session: facts.session.map(str::to_owned),
                    cwd: facts.cwd.map(str::to_owned),
                    subject_lists: HashSet::from([facts.subject_list]),
                    sequence: commit.sequence,
                    event_id: commit.event_id.clone(),
                });
            }
        }
    }

    /// Whether a completed tool call can move the terminal's agent out of
    /// `blocked` (`hook_roster_state`): the projector's record or the roster
    /// says blocked, or the roster has not folded every row asked of it yet.
    fn tool_completion_may_resume_agent(&self, terminal: &TerminalPublicId) -> bool {
        let projected_blocked = self
            .agent_records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(terminal)
            .is_some_and(|record| record.state == AgentState::Blocked);
        if projected_blocked {
            return true;
        }
        let wanted = self.wanted_roster_sequence();
        let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
        host.cursor < wanted
            || host
                .roster
                .entries
                .get(terminal.as_str())
                .is_some_and(|entry| entry.state == "blocked")
    }

    /// Whether an enabled journal hook is delivered `agent.state.changed`
    /// rows. Read from the registry once after a start or a hook change.
    fn journal_hook_reads_at_rest_rows(&self) -> bool {
        let mut cached = self
            .agent_hooks_at_rest
            .journal_hook_reads_rows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(reads) = *cached {
            return reads;
        }
        // An unreadable hook list keeps the rows: a hook must not miss one.
        let Ok(states) = self.journal_hook_states() else { return true };
        let reads = states.iter().any(|state| {
            state.enabled && kind_filter_matches_at_rest_kind(&state.manifest.filter.kinds)
        });
        *cached = Some(reads);
        reads
    }
}
