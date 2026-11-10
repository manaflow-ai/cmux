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
//!   `agent.state.changed`: that hook is delivered every row;
//! - while a client follows the journal live with a filter that lets the row
//!   through (chatmux-relay's forwarder subscribes to `agent.*` at the
//!   `sensitive` limit), for [`FOLLOWER_GRACE`] after the last one left, and
//!   for the same time after the daemon became ready (a follower of the last
//!   run comes back with its cursor): a follower reads the journal and
//!   nothing else. A bounded read (`follow: false`) does not count, and
//!   neither does a follower whose sensitivity limit is below the row's
//!   (the default limit is `metadata`, and a remote client has no other): it
//!   is never sent the row;
//! - after a row of the terminal whose result is not known (its append
//!   failed or timed out, or it was a retry the registry answered): the
//!   table no longer knows what the journal holds;
//! - while the projection of an earlier row of the terminal waits for a
//!   retry: the next row's projection runs that retry.
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
/// of the kind left, and after the daemon became ready. A follower that lost
/// its connection (or its daemon, at a restart) comes back with its cursor
/// and must find the rows of the gap: chatmux-relay's forwarder reconnects
/// within its 30 s backoff limit plus its 15 s socket scan. A follower that
/// left for good (one `cmux session journal subscribe` in a shell) costs rows
/// for this long, not until the daemon restarts.
const FOLLOWER_GRACE: Duration = Duration::from_secs(120);
/// The sensitivity of every row this module and
/// `agent_plugin_reports_at_rest.rs` leave out, but a plugin's own row: the
/// hook producer's events and the `agent.report` projection row are
/// `sensitive`. A stream with a lower limit is never sent one.
const AT_REST_SENSITIVITY: crate::JournalSensitivity = crate::JournalSensitivity::Sensitive;

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
    /// A journal row of this terminal waits for its projection
    /// (`enqueue_agent_hook_pending`). Until a retry finds none left, no
    /// report of the terminal is answered from memory: each one goes the
    /// path that runs the retry.
    projection_pending: bool,
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

/// Followers that left and are still inside their grace, at most. Past it
/// (a client that opens and closes streams in a loop) they fold into
/// `keep_all_until`: every row is kept until the last of them is out.
const MAX_LEFT_FOLLOWERS: usize = 64;

/// Whether a stream's filter lets through a record of a kind at a
/// sensitivity (`JournalStreamFilter::may_send`). The other filters
/// (subjects, classes, a regex) are not asked: they can only keep fewer rows.
type RowGate = Box<dyn Fn(&str, crate::JournalSensitivity) -> bool + Send + Sync>;

/// What one live journal stream asked for, for the follower diagnostic.
#[derive(Clone, Debug)]
pub(crate) struct JournalFollowerFilter {
    pub(crate) client: u64,
    pub(crate) stream_id: String,
    /// The client is not on the local socket: its limit is `metadata`.
    pub(crate) remote: bool,
    /// The kind filter as sent (`agent.*`); empty for every kind.
    pub(crate) kinds: Vec<String>,
    /// `None`: no limit.
    pub(crate) max_sensitivity: Option<crate::JournalSensitivity>,
}

struct Follower {
    filter: JournalFollowerFilter,
    since: Instant,
    /// When its stream ended; it can come back with its cursor until the
    /// grace is over.
    left: Option<Instant>,
    reads: RowGate,
}

impl Follower {
    fn in_grace(&self, now: Instant) -> bool {
        self.left.is_none_or(|left| now.saturating_duration_since(left) < FOLLOWER_GRACE)
    }
}

/// The clients that follow the journal live, and those that left less than
/// [`FOLLOWER_GRACE`] ago. A row left out at rest is appended while one of
/// them is sent rows of its kind and sensitivity.
#[derive(Default)]
struct JournalRowFollowers {
    next_id: u64,
    followers: HashMap<u64, Follower>,
    /// Every row is kept until here, whatever its kind: the grace after the
    /// daemon became ready (a follower of the last run comes back with a
    /// saved cursor, and its filter is not known), or after more followers
    /// left than the table holds.
    keep_all_until: Option<Instant>,
}

impl std::fmt::Debug for JournalRowFollowers {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("JournalRowFollowers")
            .field("followers", &self.followers.len())
            .field("keep_all_until", &self.keep_all_until)
            .finish()
    }
}

impl JournalRowFollowers {
    /// Whether a follower is sent a row of `kind` at `sensitivity` at `now`.
    fn reads(&self, kind: &str, sensitivity: crate::JournalSensitivity, now: Instant) -> bool {
        self.keeps_all(now)
            || self
                .followers
                .values()
                .any(|follower| follower.in_grace(now) && (follower.reads)(kind, sensitivity))
    }

    fn keeps_all(&self, now: Instant) -> bool {
        self.keep_all_until.is_some_and(|until| now < until)
    }

    fn keep_all_until(&mut self, until: Instant) {
        self.keep_all_until = Some(self.keep_all_until.map_or(until, |kept| kept.max(until)));
    }

    /// Drops the followers whose grace is over, and folds the ones that left
    /// into `keep_all_until` when there are too many.
    fn prune(&mut self, now: Instant) {
        self.followers.retain(|_, follower| follower.in_grace(now));
        let left = self.followers.values().filter_map(|follower| follower.left);
        if left.clone().count() <= MAX_LEFT_FOLLOWERS {
            return;
        }
        if let Some(last) = left.max() {
            self.keep_all_until(last + FOLLOWER_GRACE);
        }
        self.followers.retain(|_, follower| follower.left.is_none());
    }
}

/// One live journal stream, counted as a journal follower for its life and
/// for [`FOLLOWER_GRACE`] after.
#[derive(Debug)]
pub(crate) struct JournalRowFollower {
    followers: Arc<Mutex<JournalRowFollowers>>,
    id: u64,
}

impl Drop for JournalRowFollower {
    fn drop(&mut self) {
        let mut followers = self.followers.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        if let Some(follower) = followers.followers.get_mut(&self.id) {
            follower.left = Some(now);
        }
        followers.prune(now);
    }
}

/// One journal follower in [`JournalFollowersSnapshot`].
#[derive(Clone, Debug, serde::Serialize)]
pub struct JournalFollowerSnapshot {
    pub client: u64,
    pub stream_id: String,
    pub remote: bool,
    /// The kind filter as sent; empty for every kind.
    pub kinds: Vec<String>,
    /// `None`: no limit.
    pub max_sensitivity: Option<crate::JournalSensitivity>,
    pub connected_ms: u64,
    /// `None` while the stream is live; else how long ago it ended (it still
    /// keeps rows until the grace is over).
    pub left_ms: Option<u64>,
    /// It is sent the hook rows (`agent.state.changed`, `sensitive`), so
    /// every hook report is a row.
    pub keeps_hook_rows: bool,
    /// It is sent `agent.report` rows, so every plugin report is a row.
    pub keeps_report_rows: bool,
}

/// The `journal_followers` section of `server-stats`: who follows the journal
/// live, and why a report that changes nothing is still a row.
#[derive(Clone, Debug, serde::Serialize)]
pub struct JournalFollowersSnapshot {
    pub grace_ms: u64,
    /// What is left of the time in which every row is kept, whatever its
    /// kind (after the daemon became ready); 0 when it is over.
    pub keep_all_ms: u64,
    /// An enabled journal hook's kind filter matches a row left out at rest.
    /// `None`: not read since the daemon started or the hooks changed (the
    /// next report reads it; this section never reads the registry).
    pub journal_hook_keeps_rows: Option<bool>,
    /// Every hook report is a row now.
    pub hook_rows_kept: bool,
    /// Every plugin report is a row now (a follower of the plugin's own kind
    /// keeps them too; it shows in `followers` with its `kinds`).
    pub report_rows_kept: bool,
    pub followers: Vec<JournalFollowerSnapshot>,
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
}

impl AgentHooksAtRest {
    fn terminals(&self) -> MutexGuard<'_, HashMap<TerminalPublicId, HookSlot>> {
        self.terminals.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn forget_terminal(&self, terminal: &TerminalPublicId) {
        self.terminals().remove(terminal);
    }

    /// Whether a hook report of `terminal` is on its way to the journal.
    pub(super) fn hook_in_flight(&self, terminal: &TerminalPublicId) -> bool {
        self.terminals().get(terminal).is_some_and(|slot| slot.in_flight > 0)
    }

    /// Terminals with a table entry.
    #[cfg(all(test, unix))]
    fn slots(&self) -> usize {
        self.terminals().len()
    }

    fn followers(&self) -> MutexGuard<'_, JournalRowFollowers> {
        self.journal_followers.lock().unwrap_or_else(PoisonError::into_inner)
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

/// The projection row of a plugin report (`agent_plugin_reports_at_rest.rs`).
const REPORT_KIND: &str = "agent.report";
/// The namespace of every plugin's kinds (`plugin.<producer>.agent.state.changed`).
const PLUGIN_NAMESPACE: &str = "plugin";

/// Whether a journal hook's kind filter matches a row the daemon leaves out
/// at rest: `agent.state.changed`, and the two rows of a plugin report that
/// repeats the roster (its own kind under `plugin.`, and `agent.report`).
/// One rule for the three kinds: a reader of one keeps the rows of all.
fn kind_filter_matches_at_rest_kind(kinds: &[String]) -> bool {
    kinds.is_empty()
        || kinds.iter().any(|kind| match kind.strip_suffix(".*") {
            Some(prefix) => {
                [AT_REST_KIND, REPORT_KIND].iter().any(|at_rest| {
                    at_rest.strip_prefix(prefix).is_some_and(|rest| rest.starts_with('.'))
                }) || prefix == PLUGIN_NAMESPACE
                    || prefix
                        .strip_prefix(PLUGIN_NAMESPACE)
                        .is_some_and(|rest| rest.starts_with('.'))
            }
            None => {
                kind == AT_REST_KIND
                    || kind == REPORT_KIND
                    || kind.strip_prefix(PLUGIN_NAMESPACE).is_some_and(|rest| rest.starts_with('.'))
            }
        })
}

/// The terminal a row of the hook producer is about.
fn hook_row_terminal(ingress: &crate::JournalIngress) -> Option<TerminalPublicId> {
    if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID {
        return None;
    }
    ingress
        .subjects
        .iter()
        .find(|subject| subject.kind == "terminal")
        .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
}

impl Mux {
    #[cfg(all(test, unix))]
    pub(crate) fn agent_hook_slots_for_test(&self) -> usize {
        self.agent_hooks_at_rest.slots()
    }

    /// Counts a live journal stream as a journal follower; the stream holds
    /// the guard for its life. `reads` says whether its filter lets through a
    /// record of a kind at a sensitivity. From here on, and for
    /// [`FOLLOWER_GRACE`] after the guard drops, a report whose row it would
    /// be sent is appended.
    pub(crate) fn follow_journal(
        &self,
        filter: JournalFollowerFilter,
        reads: impl Fn(&str, crate::JournalSensitivity) -> bool + Send + Sync + 'static,
    ) -> JournalRowFollower {
        let now = Instant::now();
        let mut followers = self.agent_hooks_at_rest.followers();
        followers.prune(now);
        followers.next_id += 1;
        let id = followers.next_id;
        followers
            .followers
            .insert(id, Follower { filter, since: now, left: None, reads: Box::new(reads) });
        JournalRowFollower { followers: self.agent_hooks_at_rest.journal_followers.clone(), id }
    }

    /// The daemon serves from now (`mark_server_lifecycle_ready`). A follower
    /// of its last run comes back with a saved cursor and must find the rows
    /// of the gap, and its filter is not known: every report is a row for
    /// [`FOLLOWER_GRACE`].
    pub(super) fn start_journal_follower_grace(&self) {
        self.agent_hooks_at_rest.followers().keep_all_until(Instant::now() + FOLLOWER_GRACE);
    }

    /// The journal followers and what keeps the rows left out at rest
    /// (`server-stats`, section `journal_followers`). Memory only: two short
    /// locks, no registry read.
    pub fn journal_followers_stats(&self) -> JournalFollowersSnapshot {
        let journal_hook_keeps_rows = *self
            .agent_hooks_at_rest
            .journal_hook_reads_rows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let hook_keeps_rows = journal_hook_keeps_rows == Some(true);
        let now = Instant::now();
        let table = self.agent_hooks_at_rest.followers();
        let millis = |duration: Duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX);
        let mut followers = table
            .followers
            .values()
            .filter(|follower| follower.in_grace(now))
            .map(|follower| JournalFollowerSnapshot {
                client: follower.filter.client,
                stream_id: follower.filter.stream_id.clone(),
                remote: follower.filter.remote,
                kinds: follower.filter.kinds.clone(),
                max_sensitivity: follower.filter.max_sensitivity,
                connected_ms: millis(now.saturating_duration_since(follower.since)),
                left_ms: follower.left.map(|left| millis(now.saturating_duration_since(left))),
                keeps_hook_rows: (follower.reads)(AT_REST_KIND, AT_REST_SENSITIVITY),
                keeps_report_rows: (follower.reads)(REPORT_KIND, AT_REST_SENSITIVITY),
            })
            .collect::<Vec<_>>();
        followers.sort_by(|a, b| (a.client, &a.stream_id).cmp(&(b.client, &b.stream_id)));
        JournalFollowersSnapshot {
            grace_ms: millis(FOLLOWER_GRACE),
            keep_all_ms: table
                .keep_all_until
                .map_or(0, |until| millis(until.saturating_duration_since(now))),
            journal_hook_keeps_rows,
            hook_rows_kept: hook_keeps_rows || table.reads(AT_REST_KIND, AT_REST_SENSITIVITY, now),
            report_rows_kept: hook_keeps_rows || table.reads(REPORT_KIND, AT_REST_SENSITIVITY, now),
            followers,
        }
    }

    /// Live journal followers.
    #[cfg(all(test, unix))]
    pub(crate) fn journal_row_followers_for_test(&self) -> usize {
        let followers = self.agent_hooks_at_rest.followers();
        followers.followers.values().filter(|follower| follower.left.is_none()).count()
    }

    /// Makes each follower's leave and the start of the daemon's grace
    /// [`FOLLOWER_GRACE`] older, as if that time passed.
    #[cfg(all(test, unix))]
    pub(crate) fn pass_journal_follower_grace_for_test(&self) {
        let mut followers = self.agent_hooks_at_rest.followers();
        followers.keep_all_until =
            followers.keep_all_until.and_then(|until| until.checked_sub(FOLLOWER_GRACE));
        followers.followers.retain(|_, follower| match follower.left {
            None => true,
            Some(left) => {
                follower.left = left.checked_sub(FOLLOWER_GRACE);
                follower.left.is_some()
            }
        });
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
        let sensitivity = ingress.sensitivity.unwrap_or(AT_REST_SENSITIVITY);
        if self.journal_reader_keeps_row(AT_REST_KIND, sensitivity) {
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
        let stored =
            slot.stored.as_ref().filter(|_| slot.in_flight == 0 && !slot.projection_pending)?;
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

    /// Whether a journal hook or a journal follower reads a row of `kind` at
    /// `sensitivity` that would be left out at rest (module doc): an enabled
    /// hook's kind filter matches a kind left out at rest, a follower that is
    /// sent the row is connected or left less than [`FOLLOWER_GRACE`] ago, or
    /// the daemon became ready less than that ago. While it does, the report
    /// is a row.
    pub(super) fn journal_reader_keeps_row(
        &self,
        kind: &str,
        sensitivity: crate::JournalSensitivity,
    ) -> bool {
        self.journal_hook_reads_at_rest_rows()
            || self.agent_hooks_at_rest.followers().reads(kind, sensitivity, Instant::now())
    }

    /// The same for the two rows of a plugin report that repeats the roster
    /// (`agent_plugin_reports_at_rest.rs`): the plugin's own row, and the
    /// `agent.report` projection row (always `sensitive`). The plugin's
    /// manifest sets the sensitivity of its own row when the report names
    /// none; it is not read here, so the lowest one stands for it: a follower
    /// of the kind keeps the row at any limit.
    pub(super) fn journal_reader_keeps_plugin_rows(&self, ingress: &crate::JournalIngress) -> bool {
        let own = ingress.sensitivity.unwrap_or(crate::JournalSensitivity::Public);
        self.journal_reader_keeps_row(&ingress.kind, own)
            || self.journal_reader_keeps_row(REPORT_KIND, AT_REST_SENSITIVITY)
    }

    /// The projection of a journal row of the hook producer failed and waits
    /// for a retry. The retry runs when a later row of the terminal is
    /// projected (`reconcile_preceding_agent_hooks`) and after a report that
    /// reaches the registry (`retry_pending_agent_hooks_for_terminal`); an
    /// answer from memory runs neither. So no report of the terminal is
    /// answered from memory until a retry finds nothing left.
    pub(super) fn note_agent_hook_projection_pending(&self, ingress: &crate::JournalIngress) {
        let Some(terminal) = hook_row_terminal(ingress) else { return };
        let mut terminals = self.agent_hooks_at_rest.terminals();
        let Some(slot) = self.open_terminal_slot(&mut terminals, &terminal) else { return };
        slot.stored = None;
        slot.unknown_results += 1;
        slot.projection_pending = true;
    }

    /// Whether a hook projection of `terminal` waits for a retry.
    pub(super) fn agent_hook_projection_is_pending(&self, terminal: &TerminalPublicId) -> bool {
        self.agent_hooks_at_rest
            .terminals()
            .get(terminal)
            .is_some_and(|slot| slot.projection_pending)
    }

    /// A retry found no hook projection of `terminal` left.
    pub(super) fn note_no_agent_hook_projection_pending(&self, terminal: &TerminalPublicId) {
        if let Some(slot) = self.agent_hooks_at_rest.terminals().get_mut(terminal) {
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
            // The row can be in the journal with its projection not done
            // (its commit seeds the retry row): the next row runs the retry.
            slot.projection_pending = true;
        }
    }

    /// After a row of the hook producer was projected: when a projection of
    /// its terminal waits for a retry, run the terminal's retry now, which
    /// ends the wait when it finds none left. One memory lock for a terminal
    /// with nothing pending.
    pub(super) fn retry_flagged_agent_hook_projections(&self, ingress: &crate::JournalIngress) {
        let Some(terminal) = hook_row_terminal(ingress) else { return };
        if self.agent_hook_projection_is_pending(&terminal) {
            let _ = self.retry_pending_agent_hooks_for_terminal(&terminal);
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
