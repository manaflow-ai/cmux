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
//!   row moved. That time is live state: this table keeps each terminal's
//!   newest report time, `history.entries.list` answers from it, and the
//!   journal gets one coalesced row for the whole session at most each 5
//!   minutes (and one at a clean stop), so a reader of the journal alone is
//!   right to 5 minutes. Never a row per report or per terminal.
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
//!   `agent.state.changed`: that hook is delivered every row;
//! - while a client follows the journal live with a kind filter that matches
//!   it (chatmux-relay's forwarder subscribes to `agent.*`), and for
//!   [`FOLLOWER_GRACE`] after the last one left: a follower reads the journal
//!   and nothing else. A bounded read (`follow: false`) does not count;
//! - after a row of the terminal whose result is not known (its append
//!   failed or timed out, or it was a retry the registry answered): the
//!   table no longer knows what the journal holds;
//! - while the projection of an earlier row of the terminal still waits
//!   after the retry this report ran (below).
//!
//! A row's projection can fail and wait for a retry. A row of the terminal
//! runs that retry before its own projection
//! (`reconcile_preceding_agent_hooks`); a report at rest is no row, so it
//! runs the terminal's retry itself, before its answer.
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
/// How long every report stays a row after the last live journal follower
/// of the kind left. A follower that lost its connection comes back with its
/// cursor and must find the rows of the gap: chatmux-relay's forwarder
/// reconnects within its 30 s backoff limit plus its 15 s socket scan. A
/// follower that left for good (one `cmux session journal subscribe` in a
/// shell) costs rows for this long, not until the daemon restarts.
const FOLLOWER_GRACE: Duration = Duration::from_secs(120);

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
    /// Rows of this terminal whose result was not known
    /// (`forget_agent_hook_stored`). A row sent before one of them does not
    /// note its facts after it.
    unknown_results: u64,
    /// The highest sequence noted: commits can finish out of order.
    noted_sequence: u64,
    stored: Option<StoredHookFacts>,
    /// The projection of a journal row of this terminal failed and waits for
    /// a retry (`enqueue_agent_hook_pending`). While set, a report at rest
    /// runs the terminal's retry first and is answered from memory only when
    /// the retry left nothing.
    projection_pending: bool,
    /// How many times a projection of this terminal was noted as waiting. A
    /// retry clears the flag only when none was noted since it read this.
    projection_pending_notes: u64,
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

/// The clients that follow the journal live with a kind filter that matches
/// `agent.state.changed`.
#[derive(Debug, Default)]
struct JournalRowFollowers {
    live: usize,
    /// When the last one left; `None` while none ever followed.
    last_left: Option<Instant>,
}

/// One live journal stream that is sent `agent.state.changed` rows. While it
/// lives, and for [`FOLLOWER_GRACE`] after, every hook report is a row.
#[derive(Debug)]
pub(crate) struct JournalRowFollower {
    followers: Arc<Mutex<JournalRowFollowers>>,
}

impl Drop for JournalRowFollower {
    fn drop(&mut self) {
        let mut followers = self.followers.lock().unwrap_or_else(PoisonError::into_inner);
        followers.live = followers.live.saturating_sub(1);
        followers.last_left = Some(Instant::now());
    }
}

/// Which agent sessions the journal holds, per terminal, and whether a
/// journal hook or a journal follower reads the rows this module leaves out.
/// Memory only.
#[derive(Debug, Default)]
pub(super) struct AgentHooksAtRest {
    terminals: Mutex<HashMap<TerminalPublicId, HookSlot>>,
    /// Whether an enabled journal hook's kind filter matches
    /// `agent.state.changed`; `None` until read, and after a hook changed.
    journal_hook_reads_rows: Mutex<Option<bool>>,
    journal_followers: Arc<Mutex<JournalRowFollowers>>,
    activity: Mutex<AgentActivity>,
    /// The daemon's clock as a test sets it, in Unix milliseconds (0: the
    /// wall clock).
    #[cfg(all(test, unix))]
    clock_ms_for_test: std::sync::atomic::AtomicU64,
}

/// The journal gets at most one agent activity row per this long.
const ACTIVITY_ROW_INTERVAL_MS: u64 = 5 * 60 * 1000;
/// The native event of the coalesced activity row (adapter `cmux`).
pub(crate) const ACTIVITY_NATIVE_EVENT: &str = "AgentActivityObserved";
/// Stamps in one activity row: about 150 bytes each, so a row stays far under
/// the journal's 1 MiB payload limit. A session with more reporting terminals
/// than this writes the rest in the next row.
const ACTIVITY_ROW_STAMPS: usize = 2000;

/// The newest report at rest of one terminal's agent session.
#[derive(Debug)]
struct ActivityStamp {
    provider: String,
    session: String,
    observed_at_ms: u64,
    /// No journal row holds this time yet.
    unsaved: bool,
}

/// One stamp as the activity row carries it.
struct SavedStamp {
    terminal: TerminalPublicId,
    provider: String,
    session: String,
    observed_at_ms: u64,
}

/// Each terminal's newest agent report time, and when the journal last got
/// them.
#[derive(Debug, Default)]
struct AgentActivity {
    stamps: HashMap<TerminalPublicId, ActivityStamp>,
    /// The daemon's time of the last activity row; before the first row, of
    /// the first report at rest.
    last_row_ms: Option<u64>,
}

impl AgentHooksAtRest {
    fn terminals(&self) -> MutexGuard<'_, HashMap<TerminalPublicId, HookSlot>> {
        self.terminals.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn activity(&self) -> MutexGuard<'_, AgentActivity> {
        self.activity.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn forget_terminal(&self, terminal: &TerminalPublicId) {
        self.terminals().remove(terminal);
        self.activity().stamps.remove(terminal);
    }

    /// Notes that the agent session `provider`/`session` of `terminal` was
    /// at work at `observed_at_ms`: O(1), memory only.
    fn note_activity(
        &self,
        terminal: &TerminalPublicId,
        provider: &str,
        session: &str,
        observed_at_ms: u64,
        now_ms: u64,
    ) {
        let mut guard = self.activity();
        let activity = &mut *guard;
        if activity.last_row_ms.is_none() {
            activity.last_row_ms = Some(now_ms);
        }
        let same = activity
            .stamps
            .get_mut(terminal)
            .filter(|stamp| stamp.provider == provider && stamp.session == session);
        if let Some(stamp) = same {
            if observed_at_ms > stamp.observed_at_ms {
                stamp.observed_at_ms = observed_at_ms;
                stamp.unsaved = true;
            }
            return;
        }
        let stamp = ActivityStamp {
            provider: provider.to_owned(),
            session: session.to_owned(),
            observed_at_ms,
            unsaved: true,
        };
        activity.stamps.insert(terminal.clone(), stamp);
    }

    /// The stamps the next activity row carries: none before the interval
    /// since the last row passed (unless `at_stop`), none when no terminal
    /// reported since.
    fn take_unsaved_activity(&self, now_ms: u64, at_stop: bool) -> Vec<SavedStamp> {
        let mut guard = self.activity();
        let activity = &mut *guard;
        let Some(last_row_ms) = activity.last_row_ms else {
            return Vec::new();
        };
        if !at_stop && now_ms.saturating_sub(last_row_ms) < ACTIVITY_ROW_INTERVAL_MS {
            return Vec::new();
        }
        let mut taken = Vec::new();
        for (terminal, stamp) in &mut activity.stamps {
            if stamp.unsaved && taken.len() < ACTIVITY_ROW_STAMPS {
                stamp.unsaved = false;
                taken.push(SavedStamp {
                    terminal: terminal.clone(),
                    provider: stamp.provider.clone(),
                    session: stamp.session.clone(),
                    observed_at_ms: stamp.observed_at_ms,
                });
            }
        }
        if !taken.is_empty() {
            activity.last_row_ms = Some(now_ms);
        }
        taken
    }

    /// The row with `stamps` was not appended: the next row carries them.
    fn keep_unsaved_activity(&self, stamps: &[SavedStamp]) {
        let mut activity = self.activity();
        for saved in stamps {
            if let Some(stamp) = activity.stamps.get_mut(&saved.terminal) {
                stamp.unsaved = true;
            }
        }
    }

    /// The newest report time of each agent session, keyed
    /// `<provider>/<session id>` as the history fold keys its sessions.
    fn activity_times(&self) -> HashMap<String, i64> {
        let activity = self.activity();
        let mut times = HashMap::<String, i64>::new();
        for stamp in activity.stamps.values() {
            let at_ms = i64::try_from(stamp.observed_at_ms).unwrap_or(i64::MAX);
            let time = times.entry(format!("{}/{}", stamp.provider, stamp.session)).or_insert(0);
            *time = (*time).max(at_ms);
        }
        times
    }

    /// Terminals with a table entry.
    #[cfg(all(test, unix))]
    fn slots(&self) -> usize {
        self.terminals().len()
    }

    /// Whether a journal follower reads `agent.state.changed` rows at `now`:
    /// one is connected, or the last one left less than the grace ago.
    fn journal_follower_reads_rows(&self, now: Instant) -> bool {
        let followers = self.journal_followers.lock().unwrap_or_else(PoisonError::into_inner);
        followers.live > 0
            || followers
                .last_left
                .is_some_and(|left| now.saturating_duration_since(left) < FOLLOWER_GRACE)
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
    /// The slot's `unknown_results` when the hook was sent.
    unknown_results: u64,
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
    #[cfg(all(test, unix))]
    pub(crate) fn agent_hook_slots_for_test(&self) -> usize {
        self.agent_hooks_at_rest.slots()
    }

    /// The daemon's clock for the activity row interval.
    fn agent_activity_now_ms(&self) -> u64 {
        #[cfg(all(test, unix))]
        {
            let set = self
                .agent_hooks_at_rest
                .clock_ms_for_test
                .load(std::sync::atomic::Ordering::Relaxed);
            if set != 0 {
                return set;
            }
        }
        crate::workspace_registry::unix_epoch_ms().unwrap_or(0)
    }

    /// Notes in memory that the agent session `provider`/`session` of
    /// `terminal` was at work at `observed_at_ms` (the daemon's clock when
    /// `None`). The one way into the live activity table: no journal row, no
    /// registry lock. History reads it at once; the journal gets it with the
    /// next coalesced row (`save_agent_activity`).
    pub(crate) fn note_agent_activity(
        &self,
        terminal: &TerminalPublicId,
        provider: &str,
        session: &str,
        observed_at_ms: Option<u64>,
    ) {
        let now_ms = self.agent_activity_now_ms();
        self.agent_hooks_at_rest.note_activity(
            terminal,
            provider,
            session,
            observed_at_ms.unwrap_or(now_ms),
            now_ms,
        );
    }

    /// The newest report time of each agent session that reports at rest,
    /// keyed `<provider>/<session id>`: what a reader of History in this
    /// daemon gets on top of the journal's fold.
    pub(crate) fn live_agent_activity(&self) -> HashMap<String, i64> {
        self.agent_hooks_at_rest.activity_times()
    }

    /// Appends the coalesced activity row when it is due: one row for the
    /// whole session with the report times of the terminals that reported
    /// since the last one, at most one per `ACTIVITY_ROW_INTERVAL_MS`, and
    /// one at a clean stop (`at_stop`). No row when no agent reported.
    ///
    /// Called with no lock held, after a report was answered at rest (never
    /// for a report that became a row): the table lock of the answer and the
    /// activity lock are both released before the append, so the registry
    /// commit runs under neither. One commit on that caller, once per
    /// interval. The row asks no roster fold (`fold_agent_roster`), so it
    /// makes no later report a row.
    pub(super) fn save_agent_activity(&self, at_stop: bool) {
        let now_ms = self.agent_activity_now_ms();
        let stamps = self.agent_hooks_at_rest.take_unsaved_activity(now_ms, at_stop);
        if stamps.is_empty() {
            return;
        }
        let ingress = agent_activity_ingress(&stamps);
        let key = format!("agent-activity-{}", crate::workspace_registry::new_uuid_v4());
        if let Err(error) = self.append_journal_ingress(&ingress, "agent-activity", &key) {
            eprintln!("cmux-tui: agent activity times not journaled: {error}");
            self.agent_hooks_at_rest.keep_unsaved_activity(&stamps);
        }
    }

    /// Sets the daemon's clock for the agent activity time, so a test runs
    /// hours of reports with no sleep.
    #[cfg(all(test, unix))]
    pub(crate) fn set_agent_activity_clock_for_test(&self, now_ms: u64) {
        self.agent_hooks_at_rest
            .clock_ms_for_test
            .store(now_ms, std::sync::atomic::Ordering::Relaxed);
    }

    /// Counts a live journal stream as a reader of `agent.state.changed` rows
    /// when its kind filter can match them (`matches_kind`). The stream holds
    /// it for its life: every hook report from here on is a row it can read.
    pub(crate) fn follow_journal_agent_rows(
        &self,
        matches_kind: impl FnOnce(&str) -> bool,
    ) -> Option<JournalRowFollower> {
        if !matches_kind(AT_REST_KIND) {
            return None;
        }
        let followers = self.agent_hooks_at_rest.journal_followers.clone();
        followers.lock().unwrap_or_else(PoisonError::into_inner).live += 1;
        Some(JournalRowFollower { followers })
    }

    /// Live followers of the at-rest rows.
    #[cfg(all(test, unix))]
    pub(crate) fn journal_row_followers_for_test(&self) -> usize {
        let followers = &self.agent_hooks_at_rest.journal_followers;
        followers.lock().unwrap_or_else(PoisonError::into_inner).live
    }

    /// Makes the last follower's leave [`FOLLOWER_GRACE`] older, as if that
    /// time passed.
    #[cfg(all(test, unix))]
    pub(crate) fn pass_journal_follower_grace_for_test(&self) {
        let followers = &self.agent_hooks_at_rest.journal_followers;
        let mut followers = followers.lock().unwrap_or_else(PoisonError::into_inner);
        followers.last_left = followers.last_left.and_then(|left| left.checked_sub(FOLLOWER_GRACE));
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
        if self.journal_hook_reads_at_rest_rows()
            || self.agent_hooks_at_rest.journal_follower_reads_rows(Instant::now())
        {
            return None;
        }
        // The projection of an earlier row of the terminal waits: run its
        // retry now, as the projection of an appended row does. Before the
        // table is held: the projector takes the registry.
        if self.agent_hook_projection_is_pending(&facts.terminal) {
            let _ = self.retry_pending_agent_hooks_for_terminal(&facts.terminal);
        }
        // Held through the presence change: a later row of this terminal (a
        // turn's end) waits here, so its presence change comes after this one.
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let slot = terminals.get_mut(&facts.terminal)?;
        // The retry left a projection waiting: this report is a row, and its
        // projection waits behind that one.
        if slot.projection_pending {
            return None;
        }
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
        if let (Some(provider), Some(session)) = (facts.provider, facts.session) {
            let observed_at_ms = crate::journal_reducers::hook_observed_at_ms(&ingress.payload);
            self.note_agent_activity(&facts.terminal, provider, session, observed_at_ms);
        }
        self.activity.note_agent_action();
        self.apply_live_agent_presence(ingress);
        Some(commit)
    }

    /// The projection of a journal row of the hook producer failed and waits
    /// for a retry. No entry for a terminal that has none: its first report
    /// is a row, and that row's projection runs the retry.
    pub(super) fn note_agent_hook_projection_pending(&self, ingress: &crate::JournalIngress) {
        // Every row of the hook producer is projected, not only a hook
        // helper's report (`HookFacts::of`).
        let Some(terminal) = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
        else {
            return;
        };
        if let Some(slot) = self.agent_hooks_at_rest.terminals().get_mut(&terminal) {
            slot.projection_pending = true;
            slot.projection_pending_notes += 1;
        }
    }

    /// Whether a hook projection of `terminal` waits for a retry.
    fn agent_hook_projection_is_pending(&self, terminal: &TerminalPublicId) -> bool {
        self.agent_hooks_at_rest
            .terminals()
            .get(terminal)
            .is_some_and(|slot| slot.projection_pending)
    }

    /// How many times a projection of `terminal` was noted as waiting. A
    /// retry reads it before it reads the retry table.
    pub(super) fn agent_hook_projection_pending_notes(&self, terminal: &TerminalPublicId) -> u64 {
        self.agent_hooks_at_rest
            .terminals()
            .get(terminal)
            .map_or(0, |slot| slot.projection_pending_notes)
    }

    /// A retry found no hook projection of `terminal` left in the table it
    /// read after `notes`. A projection noted since then (a row of another
    /// thread that failed after that read) keeps the flag.
    pub(super) fn note_no_agent_hook_projection_pending(
        &self,
        terminal: &TerminalPublicId,
        notes: u64,
    ) {
        if let Some(slot) = self.agent_hooks_at_rest.terminals().get_mut(terminal)
            && slot.projection_pending_notes == notes
        {
            slot.projection_pending = false;
        }
    }

    /// Marks a hook report as on its way to the journal until the guard drops.
    pub(super) fn agent_hook_in_flight(
        &self,
        ingress: &crate::JournalIngress,
    ) -> Option<HookInFlight<'_>> {
        let terminal = HookFacts::of(ingress)?.terminal;
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let slot = self.open_terminal_slot(&mut terminals, &terminal)?;
        slot.in_flight += 1;
        let unknown_results = slot.unknown_results;
        drop(terminals);
        Some(HookInFlight { at_rest: &self.agent_hooks_at_rest, terminal, unknown_results })
    }

    /// The table entry of `terminal`, made when the terminal is open. A
    /// closed terminal gets none: its close already ran `forget_terminal`,
    /// and nothing would remove a later entry. The caller holds the table,
    /// so a close that comes now removes the entry after it.
    fn open_terminal_slot<'a>(
        &self,
        terminals: &'a mut HashMap<TerminalPublicId, HookSlot>,
        terminal: &TerminalPublicId,
    ) -> Option<&'a mut HookSlot> {
        if !terminals.contains_key(terminal) && self.terminal_resource_surface(terminal).is_none() {
            return None;
        }
        Some(terminals.entry(terminal.clone()).or_default())
    }

    /// Records how the append of `ingress` (sent as `in_flight`) ended: a
    /// new row notes its facts; an error (the row can still commit after its
    /// producer gave up) or a retry the registry answered (nobody noted its
    /// first result) forgets them.
    pub(super) fn note_agent_hook_result(
        &self,
        ingress: &crate::JournalIngress,
        commit: Option<&crate::JournalAppendCommit>,
        in_flight: Option<&HookInFlight<'_>>,
        origin: &str,
        idempotency_key: &str,
    ) {
        if ingress.producer_id != crate::AGENT_HOOK_PRODUCER_ID {
            return;
        }
        match commit {
            Some(commit) if !commit.replayed => {
                self.activity.note_agent_action();
                self.note_agent_hook_stored(ingress, commit, in_flight, origin, idempotency_key);
            }
            _ => self.forget_agent_hook_stored(ingress),
        }
    }

    /// The journal may hold a row of the terminal this table did not note.
    /// Forget what it holds, so the next report is appended and notes the
    /// facts again.
    fn forget_agent_hook_stored(&self, ingress: &crate::JournalIngress) {
        let Some(facts) = HookFacts::of(ingress) else { return };
        if let Some(slot) = self.agent_hooks_at_rest.terminals().get_mut(&facts.terminal) {
            slot.stored = None;
            slot.unknown_results += 1;
        }
    }

    /// Records what the journal now holds of the terminal's agent session,
    /// after `ingress` (sent as `in_flight`) committed as a new row at
    /// `commit`.
    fn note_agent_hook_stored(
        &self,
        ingress: &crate::JournalIngress,
        commit: &crate::JournalAppendCommit,
        in_flight: Option<&HookInFlight<'_>>,
        origin: &str,
        idempotency_key: &str,
    ) {
        // No entry when the hook was sent: its terminal was closed.
        let Some(in_flight) = in_flight else { return };
        let Some(facts) = HookFacts::of(ingress) else { return };
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let Some(slot) = terminals.get_mut(&facts.terminal) else { return };
        slot.remember(receipt_key(origin, idempotency_key), None);
        // A row with an unknown result came after this one was sent: it can
        // commit after this one, so this one's facts may be old.
        if commit.sequence <= slot.noted_sequence
            || in_flight.unknown_results != slot.unknown_results
        {
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

/// Whether `ingress` is the daemon's coalesced activity row: the roster, the
/// hook projector and presence have nothing to do for it.
pub(super) fn is_agent_activity_row(ingress: &crate::JournalIngress) -> bool {
    ingress.producer_id == crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
        && ingress.kind == AT_REST_KIND
        && ingress.payload.pointer("/adapter/id").and_then(Value::as_str) == Some("cmux")
        && ingress.payload.get("native_event").and_then(Value::as_str)
            == Some(ACTIVITY_NATIVE_EVENT)
        && !ingress.subjects.iter().any(|subject| subject.kind == "terminal")
}

/// The coalesced activity row: the agent hook envelope with the `cmux`
/// adapter (as program status evidence has) and no terminal subject, so the
/// roster, the hook projector and presence pass it by; the history folds
/// read `normalized.activity`. An existing kind and manifest: a daemon or an
/// app from before this row reads it as an `agent.state.changed` row with no
/// session id, which each of them skips.
fn agent_activity_ingress(stamps: &[SavedStamp]) -> crate::JournalIngress {
    let newest = stamps.iter().map(|stamp| stamp.observed_at_ms).max().unwrap_or(0);
    let activity = stamps
        .iter()
        .map(|stamp| {
            serde_json::json!({
                "adapter": stamp.provider,
                "agent_session_id": stamp.session,
                "terminal": stamp.terminal.to_string(),
                "observed_at_ms": stamp.observed_at_ms.to_string(),
            })
        })
        .collect::<Vec<_>>();
    crate::JournalIngress {
        producer_id: crate::agent_hooks::AGENT_HOOK_PRODUCER_ID.into(),
        manifest_version: crate::agent_hooks::AGENT_HOOK_MANIFEST_VERSION,
        kind: AT_REST_KIND.into(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: Vec::new(),
        sensitivity: Some(crate::JournalSensitivity::Sensitive),
        payload: serde_json::json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter": {"id": "cmux", "version": 1},
            "native_event": ACTIVITY_NATIVE_EVENT,
            "normalized": {
                "observed_at_ms": newest.to_string(),
                "activity": activity,
            },
            "native": {},
        }),
        causation_id: None,
        correlation_id: None,
    }
}
