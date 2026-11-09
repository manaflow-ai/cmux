//! The cost ledger (`_acpmux/ledger`): what every turn on this machine cost, whatever harness
//! ran it, indexed so a read never opens a session log.
//!
//! Fed from `Hub::append_record_locked` one record at a time, O(1) each: a prompt (`user_message`
//! that is not a steer) or `turn_started` opens a turn, a `tool_call` counts toward it, and its
//! `turn_result` (with the usage `hub/turn_usage.rs` put on it) closes it into a bucket keyed by
//! UTC day, session, model and price table version. `hub/pull_requests.rs` adds a session's pull
//! requests as they open. A fork's copies of its parent's records count once, in the parent
//! (`suppress`).
//!
//! A turn's cost is what its harness reported (`harnessCostUsd`), else its tokens at the bundled
//! price table (`tableCostUsd`, `crate::pricing`), else it counts in `unpricedTurns`.
//!
//! Persisted append-only to `<home>/ledger/turns.jsonl` by a writer thread, so the append lock
//! never waits on a disk: one `u` line per turn (or, after a compaction, per bucket) and one `s`
//! line whenever a session's descriptive fields change (lines merge; later fields win). Folded
//! once when the hub is built; rewritten as one line per bucket and session when it grows past
//! [`COMPACT_BYTES`]. With no file yet, the first start seeds each loaded session's
//! `SessionMeta::totals` on its `updated_at` day (`seed`).
//!
//! A read folds only the days in its range (`BTreeMap` range): its cost is the session-days in
//! range, never the number of sessions or the length of their logs.

mod query;
mod store;
pub mod waiting_day;

pub use query::{LedgerQuery, LedgerReply, Rollup, Row};

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::{EventRecord, TurnUsage};

/// Whether a chat copy's purged flag is set.
fn is_gone(gone: Option<&AtomicBool>) -> bool {
    gone.is_some_and(|g| g.load(Ordering::SeqCst))
}

pub(crate) const DAY_MS: u64 = 24 * 3_600_000;
/// Past this the writer rewrites the file as aggregated buckets.
pub(crate) const COMPACT_BYTES: u64 = 8 * 1024 * 1024;

/// Spend added up: one turn, one bucket, or a rollup.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Totals {
    pub cost_usd: f64,
    pub harness_cost_usd: f64,
    pub table_cost_usd: f64,
    pub unpriced_turns: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub turns: u64,
    pub tool_calls: u64,
    pub wall_ms: u64,
    /// Distinct sessions; 0 in a bucket.
    pub sessions: u64,
}

impl Totals {
    pub fn add(&mut self, o: &Totals) {
        self.cost_usd += o.cost_usd;
        self.harness_cost_usd += o.harness_cost_usd;
        self.table_cost_usd += o.table_cost_usd;
        self.unpriced_turns += o.unpriced_turns;
        self.input_tokens += o.input_tokens;
        self.output_tokens += o.output_tokens;
        self.cache_read_tokens += o.cache_read_tokens;
        self.cache_write_tokens += o.cache_write_tokens;
        self.turns += o.turns;
        self.tool_calls += o.tool_calls;
        self.wall_ms += o.wall_ms;
    }

    /// One turn's (or a seeded session's) spend: the harness's own cost, else the table's,
    /// else unpriced.
    pub(crate) fn priced(model: &str, usage: &TurnUsage, turns: u64) -> Self {
        let mut t = Totals {
            input_tokens: usage.input_tokens.unwrap_or(0),
            output_tokens: usage.output_tokens.unwrap_or(0),
            cache_read_tokens: usage.cache_read_tokens.unwrap_or(0),
            cache_write_tokens: usage.cache_write_tokens.unwrap_or(0),
            turns,
            ..Default::default()
        };
        if let Some(cost) = usage.cost_usd.filter(|c| c.is_finite() && *c >= 0.0) {
            t.harness_cost_usd = cost;
        } else if let Some(cost) = crate::pricing::table().cost(model, usage) {
            t.table_cost_usd = cost;
        } else {
            t.unpriced_turns = turns;
        }
        t.cost_usd = t.harness_cost_usd + t.table_cost_usd;
        t
    }
}

/// A session's descriptive fields, kept beside its buckets so a read never needs its meta.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub harness: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub pull_requests: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub created_at: u64,
}

impl SessionInfo {
    /// Takes `newer`'s fields that it has; pull requests are a union. True when anything changed.
    fn merge(&mut self, newer: SessionInfo) -> bool {
        let before = self.clone();
        fn take<T>(slot: &mut Option<T>, v: Option<T>) {
            if v.is_some() {
                *slot = v;
            }
        }
        take(&mut self.title, newer.title);
        if !newer.harness.is_empty() {
            self.harness = newer.harness;
        }
        take(&mut self.family, newer.family);
        take(&mut self.workspace_id, newer.workspace_id);
        take(&mut self.branch, newer.branch);
        take(&mut self.account, newer.account);
        take(&mut self.cwd, newer.cwd);
        if newer.created_at != 0 {
            self.created_at = newer.created_at;
        }
        for url in newer.pull_requests {
            if !self.pull_requests.contains(&url) {
                self.pull_requests.push(url);
            }
        }
        // A pull request names the repository; else the folder's origin, once.
        match self.pull_requests.first().and_then(|u| repo_of_pull(u)) {
            Some(repo) => self.repo = Some(repo),
            None => take(&mut self.repo, newer.repo),
        }
        *self != before
    }
}

/// `owner/name` of a `https://github.com/owner/name/pull/N` URL.
pub(crate) fn repo_of_pull(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://github.com/")?;
    let mut parts = rest.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    (parts.next() == Some("pull") && !owner.is_empty() && !name.is_empty())
        .then(|| format!("{owner}/{name}"))
}

/// The vendor a model's spend goes to: from the session's family, else the model's
/// `provider/` prefix or the price table, else the family itself.
pub fn vendor_of(family: &str, model: &str) -> String {
    match family {
        "claude" => return "anthropic".into(),
        "codex" => return "openai".into(),
        "gemini" => return "google".into(),
        _ => {}
    }
    if let Some((provider, _)) = model.split_once('/').filter(|(p, _)| !p.is_empty()) {
        return provider.to_owned();
    }
    if let Some((vendor, _)) = crate::pricing::table().lookup(model) {
        return vendor.to_owned();
    }
    if family.is_empty() { "unknown".into() } else { family.to_owned() }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct BucketKey {
    pub session: Arc<str>,
    pub model: Arc<str>,
    pub price_version: Arc<str>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Bucket {
    pub totals: Totals,
    pub last_at: u64,
}

/// A turn in progress: when it started and the tool calls it made so far.
#[derive(Debug, Default)]
struct Open {
    start: Option<u64>,
    tool_calls: u64,
}

#[derive(Default)]
pub(crate) struct State {
    /// UTC day number -> its buckets.
    pub days: BTreeMap<u64, HashMap<BucketKey, Bucket>>,
    pub sessions: HashMap<Arc<str>, SessionInfo>,
    open: HashMap<Arc<str>, Open>,
    suppressed: HashSet<String>,
    /// Sessions purged this run: no writer adds anything about them again, so a late tool
    /// update or turn result cannot put a purged session's title or pull request back.
    purged: HashSet<String>,
    /// Sessions whose folder's origin remote was asked for already (`Work::Repo`).
    repo_asked: HashSet<Arc<str>>,
    /// Interned model and version strings.
    strings: BTreeSet<Arc<str>>,
    /// Lines handed to the writer so far.
    pub seq: u64,
    /// The file existed when the hub was built (no seed then).
    pub existed: bool,
    pub seeded: bool,
}

impl State {
    pub(crate) fn intern(&mut self, s: &str) -> Arc<str> {
        if let Some(v) = self.strings.get(s) {
            return v.clone();
        }
        let v: Arc<str> = Arc::from(s);
        self.strings.insert(v.clone());
        v
    }

    /// True when nothing about `session` may be recorded (a fork's copies, or purged).
    fn blocked(&self, session: &str) -> bool {
        self.suppressed.contains(session) || self.purged.contains(session)
    }

    fn session_key(&mut self, id: &str) -> Arc<str> {
        match self.sessions.get_key_value(id) {
            Some((k, _)) => k.clone(),
            None => {
                let k: Arc<str> = Arc::from(id);
                self.sessions.insert(k.clone(), SessionInfo::default());
                k
            }
        }
    }

    pub(crate) fn add_bucket(
        &mut self,
        session: &str,
        model: &str,
        version: &str,
        at: u64,
        t: &Totals,
    ) {
        let key = BucketKey {
            session: self.session_key(session),
            model: self.intern(model),
            price_version: self.intern(version),
        };
        let bucket = self.days.entry(at / DAY_MS).or_default().entry(key).or_default();
        bucket.totals.add(t);
        bucket.last_at = bucket.last_at.max(at);
    }

    /// Forgets everything about `session`: its row, its buckets on every day, its open turn.
    pub(crate) fn remove_session(&mut self, session: &str) {
        self.sessions.remove(session);
        self.open.remove(session);
        self.repo_asked.remove(session);
        self.days.retain(|_, buckets| {
            buckets.retain(|key, _| &*key.session != session);
            !buckets.is_empty()
        });
    }

    /// Asks once per session (per run) for its folder's origin remote, when it has none.
    fn wants_repo(&mut self, session: &str) -> bool {
        let Some((key, row)) = self.sessions.get_key_value(session) else { return false };
        if row.repo.is_some() || row.cwd.is_none() {
            return false;
        }
        let key = key.clone();
        self.repo_asked.insert(key)
    }

    /// Merges `info` into the session's row; true when it changed.
    pub(crate) fn merge_session(&mut self, session: &str, info: SessionInfo) -> bool {
        let key = self.session_key(session);
        self.sessions.get_mut(&key).is_some_and(|row| row.merge(info))
    }
}

/// One line of `turns.jsonl`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
pub(crate) enum Line {
    /// A turn, or after a compaction a whole bucket.
    #[serde(rename = "u")]
    Spend {
        sid: String,
        at: u64,
        model: String,
        /// The price table version it was priced with.
        pv: String,
        #[serde(flatten)]
        totals: Totals,
    },
    /// A session's descriptive fields (merged into what came before).
    #[serde(rename = "s")]
    Session {
        sid: String,
        #[serde(flatten)]
        info: SessionInfo,
    },
    /// The session was purged: the fold drops everything before it about `sid`. The writer
    /// compacts right after writing one, so the purged lines leave the file with it.
    #[serde(rename = "p")]
    Purge { sid: String },
}

/// What the writer thread is handed.
pub(crate) enum Work {
    Line(u64, Box<Line>),
    /// Read the folder's origin remote for a session with no repository yet.
    Repo {
        sid: String,
        cwd: PathBuf,
    },
    /// Write the first start's seed, already in the state, as one rewrite of the file.
    Seed,
    #[cfg(test)]
    Flush(std::sync::mpsc::SyncSender<()>),
}

pub struct Ledger {
    pub(crate) state: Arc<Mutex<State>>,
    /// The writer thread's queue; `None` in memory, and once [`Ledger::close`] ran.
    writer: Mutex<Option<std::sync::mpsc::Sender<Work>>>,
    /// The writer thread, and the channel its end closes (`close` waits on it).
    thread: Mutex<Option<store::WriterThread>>,
    /// The person every session on this machine runs for.
    person: String,
    /// When each chat worked or waited on the person, the last two days (`waiting_day.rs`).
    pub(crate) waiting: waiting_day::WaitingDay,
}

impl std::fmt::Debug for Ledger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Ledger").finish_non_exhaustive()
    }
}

/// This machine's person as a stable string: the login and the machine's name.
fn host_person() -> String {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| "person".into());
    format!("{user}@{}", crate::pairing::machine_name())
}

impl Ledger {
    /// A ledger kept in `dir` (`<home>/ledger`), folded from its file now; `None` keeps it in
    /// memory only (a memory store).
    ///
    /// A first start (no ledger file) writes nothing until [`Ledger::seed`]: the hub seeds it
    /// as it loads the store, and lines before that are held in memory for the seed's rewrite.
    pub fn open(dir: Option<PathBuf>) -> Self {
        Self::open_as(dir, COMPACT_BYTES, host_person(), true)
    }

    /// A ledger that writes from the start, seeded or not (tests).
    #[cfg(test)]
    pub(crate) fn open_with(dir: Option<PathBuf>, compact_bytes: u64, person: String) -> Self {
        Self::open_as(dir, compact_bytes, person, false)
    }

    pub(crate) fn open_as(
        dir: Option<PathBuf>,
        compact_bytes: u64,
        person: String,
        hold_for_seed: bool,
    ) -> Self {
        let state = Arc::new(Mutex::new(State::default()));
        let mut repos = Vec::new();
        let waiting_path = dir.as_ref().map(|d| d.join(waiting_day::FILE));
        let waiting = waiting_day::WaitingDay::open(waiting_path, crate::store::now_ms());
        let spawned = dir.and_then(|dir| {
            let path = dir.join(store::FILE);
            let (size, awaiting_seed) = {
                let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
                let size = store::fold(&path, &mut s);
                // Folded sessions with no repository yet: their folder's origin, once.
                let ids: Vec<Arc<str>> = s.sessions.keys().cloned().collect();
                for id in ids {
                    let cwd = s.sessions.get(&id).and_then(|row| row.cwd.clone());
                    if s.wants_repo(&id)
                        && let Some(cwd) = cwd
                    {
                        repos.push(Work::Repo { sid: id.to_string(), cwd: PathBuf::from(cwd) });
                    }
                }
                (size, hold_for_seed && !s.existed)
            };
            store::spawn_writer(dir, path, size, compact_bytes, awaiting_seed, Arc::clone(&state))
        });
        let (writer, thread) = match spawned {
            Some((tx, thread)) => (Some(tx), Some(thread)),
            None => (None, None),
        };
        let (writer, thread) = (Mutex::new(writer), Mutex::new(thread));
        let ledger = Self { state, writer, thread, person, waiting };
        for work in repos {
            ledger.send(work);
        }
        ledger
    }

    /// Shutdown (`Hub::flush`): closes the writer's queue and waits up to `within` for it to
    /// write what it holds and end. True when it ended; later lines are kept in memory only.
    pub fn close(&self, within: std::time::Duration) -> bool {
        // The waiting day, whole, for the next daemon (`waiting_day.rs`).
        self.waiting.save(crate::store::now_ms());
        drop(self.writer.lock().unwrap_or_else(PoisonError::into_inner).take());
        let Some(thread) = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return true;
        };
        thread.join_within(within)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Hands `line` to the writer, under the state lock so lines keep their order.
    fn emit(&self, state: &mut State, line: Line) {
        state.seq += 1;
        self.send(Work::Line(state.seq, Box::new(line)));
    }

    fn send(&self, work: Work) {
        if let Some(tx) = self.writer.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            let _ = tx.send(work);
        }
    }

    pub fn person(&self) -> &str {
        &self.person
    }

    /// A fork's copies of its parent's records are being written into `session`: none counts.
    pub fn suppress(&self, session: &str) {
        self.lock().suppressed.insert(session.to_owned());
    }

    pub fn unsuppress(&self, session: &str) {
        let mut s = self.lock();
        s.suppressed.remove(session);
        s.open.remove(session);
    }

    /// Observes one appended record. Only prompts, turn starts, tool calls and turn results do
    /// anything; the meta read is one short lock of the session's own meta.
    pub(crate) fn observe(&self, session: &super::Session, record: &EventRecord) {
        if session.purged.load(Ordering::SeqCst) {
            return;
        }
        // The chat's own flag is read again under the ledger's lock: a purge sets it before it
        // drops the chat's rows (`Hub::kill`), so a record counted first is the purge's to drop,
        // and one that comes later adds nothing, even once a new chat has taken the id.
        self.record_as(&session.id, Some(&session.purged), record, || {
            TurnContext::of(&session.meta.lock().unwrap_or_else(PoisonError::into_inner))
        });
        // The waiting day's marks, O(1); a sub-session waits on the session above it.
        if record.dir == "mux"
            && matches!(record.kind.as_str(), "status" | "turn_started")
            && !session.purged.load(Ordering::SeqCst)
            && session.meta.lock().unwrap_or_else(PoisonError::into_inner).subsession.is_none()
        {
            self.waiting.record(&session.id, record);
        }
    }

    /// [`Ledger::observe`] for session `id`, with no chat copy's flag (tests); `ctx` is read
    /// only for a turn result.
    #[cfg(test)]
    pub(crate) fn record(&self, id: &str, record: &EventRecord, ctx: impl FnOnce() -> TurnContext) {
        self.record_as(id, None, record, ctx);
    }

    /// One record of chat `id`, for one copy of it: once `gone` (that copy's purged flag) is
    /// set, its records add nothing. `ctx` is read only for a turn result.
    pub(crate) fn record_as(
        &self,
        id: &str,
        gone: Option<&AtomicBool>,
        record: &EventRecord,
        ctx: impl FnOnce() -> TurnContext,
    ) {
        match (record.dir.as_str(), record.kind.as_str()) {
            (_, "user_message") => {
                if record.msg.get("steer").and_then(Value::as_bool) == Some(true) {
                    return;
                }
                self.open_turn(id, record.at, false, gone);
            }
            ("mux", "turn_started") => self.open_turn(id, record.at, true, gone),
            ("in", "tool_call") => {
                let mut s = self.lock();
                if s.blocked(id) || is_gone(gone) {
                    return;
                }
                let key = s.session_key_open(id);
                s.open.entry(key).or_default().tool_calls += 1;
            }
            ("mux", "turn_result") => self.close_turn(id, record, ctx(), gone),
            _ => {}
        }
    }

    fn open_turn(&self, session: &str, at: u64, started: bool, gone: Option<&AtomicBool>) {
        let mut s = self.lock();
        if s.blocked(session) || is_gone(gone) {
            return;
        }
        let key = s.session_key_open(session);
        let open = s.open.entry(key).or_default();
        // `turn_started` moves the start to when the agent began (queue time is not work);
        // a prompt while a turn is open does not.
        if started || open.start.is_none() {
            open.start = Some(at);
        }
    }

    fn close_turn(
        &self,
        session: &str,
        record: &EventRecord,
        ctx: TurnContext,
        gone: Option<&AtomicBool>,
    ) {
        let msg = &record.msg;
        let model = msg
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| ctx.model.clone())
            .unwrap_or_else(|| "unknown".into());
        let usage = TurnUsage {
            cost_usd: msg.get("costUsd").and_then(Value::as_f64),
            input_tokens: msg.get("inputTokens").and_then(Value::as_u64),
            output_tokens: msg.get("outputTokens").and_then(Value::as_u64),
            cache_read_tokens: msg.get("cacheReadTokens").and_then(Value::as_u64),
            cache_write_tokens: msg.get("cacheWriteTokens").and_then(Value::as_u64),
        };
        let mut totals = Totals::priced(&model, &usage, 1);
        let version = crate::pricing::table().version.clone();
        let cwd = ctx.info.cwd.clone();
        let mut s = self.lock();
        if s.blocked(session) || is_gone(gone) {
            return;
        }
        let open = s.open.remove(session).unwrap_or_default();
        totals.tool_calls = open.tool_calls;
        totals.wall_ms = open.start.map_or(0, |start| record.at.saturating_sub(start));
        let new_session = !s.sessions.contains_key(session);
        let changed = s.merge_session(session, ctx.info);
        let needs_repo = s.wants_repo(session);
        if changed || new_session {
            let info = s.sessions.get(session).cloned().unwrap_or_default();
            self.emit(&mut s, Line::Session { sid: session.to_owned(), info });
        }
        s.add_bucket(session, &model, &version, record.at, &totals);
        let line =
            Line::Spend { sid: session.to_owned(), at: record.at, model, pv: version, totals };
        self.emit(&mut s, line);
        drop(s);
        if needs_repo && let Some(cwd) = cwd {
            self.send(Work::Repo { sid: session.to_owned(), cwd: PathBuf::from(cwd) });
        }
    }

    /// `session` was purged (`_acpmux/workspace_purge`, `Hub::kill(.., true)`): its spend,
    /// title, folder, workspace and pull requests leave the index now and the file at the
    /// writer's next step (a tombstone, then a compaction). A queued repository lookup for it
    /// finds no row and adds nothing.
    pub fn purge(&self, session: &str) {
        let mut s = self.lock();
        let known = s.sessions.contains_key(session) || s.open.contains_key(session);
        s.purged.insert(session.to_owned());
        s.remove_session(session);
        self.waiting.forget(session);
        if known {
            self.emit(&mut s, Line::Purge { sid: session.to_owned() });
        }
    }

    /// A chat was created under `session` (`Hub::new_session_with_id`): a purge of that id this
    /// run no longer blocks it, so the new chat's turns count.
    pub fn reopen(&self, session: &str) {
        self.lock().purged.remove(session);
    }

    /// A pull request `session` opened (`hub/pull_requests.rs`).
    pub fn note_pull_request(&self, session: &str, url: &str) {
        let mut s = self.lock();
        if s.blocked(session) {
            return;
        }
        let info = SessionInfo { pull_requests: vec![url.to_owned()], ..Default::default() };
        if s.merge_session(session, info) {
            let info = s.sessions.get(session).cloned().unwrap_or_default();
            self.emit(&mut s, Line::Session { sid: session.to_owned(), info });
        }
    }

    /// `session`'s meta changed (`session_info_update`: title, branch, workspace, account).
    /// Updates a session the ledger already holds and writes a line only when a ledgered field
    /// changed; a session with no turn yet gets its fields at its first turn.
    pub fn note_session_info(&self, session: &str, info: SessionInfo) {
        let mut s = self.lock();
        if s.blocked(session) || !s.sessions.contains_key(session) {
            return;
        }
        if s.merge_session(session, info) {
            let info = s.sessions.get(session).cloned().unwrap_or_default();
            self.emit(&mut s, Line::Session { sid: session.to_owned(), info });
        }
    }

    /// First start with no ledger file: each loaded session's running totals, on the day it was
    /// last active. Sessions the ledger already holds are left alone. Runs once.
    /// True until [`Ledger::seed`] has run or a ledger file was found.
    pub(crate) fn wants_seed(&self) -> bool {
        let s = self.lock();
        !s.existed && !s.seeded
    }

    pub(crate) fn seed(&self, sessions: impl IntoIterator<Item = Seed>) {
        let mut s = self.lock();
        if s.existed || s.seeded {
            return;
        }
        s.seeded = true;
        let version = crate::pricing::table().version.clone();
        let mut repos = Vec::new();
        for seed in sessions {
            // A session with turns and no reported usage counts them as unpriced.
            if s.sessions.contains_key(seed.id.as_str()) || seed.turns == 0 || s.blocked(&seed.id) {
                continue;
            }
            let model = seed.ctx.model.clone().unwrap_or_else(|| "unknown".into());
            let totals = Totals::priced(&model, &seed.totals, seed.turns);
            let cwd = seed.ctx.info.cwd.clone();
            s.merge_session(&seed.id, seed.ctx.info);
            if s.wants_repo(&seed.id)
                && let Some(cwd) = cwd
            {
                repos.push(Work::Repo { sid: seed.id.clone(), cwd: PathBuf::from(cwd) });
            }
            s.add_bucket(&seed.id, &model, &version, seed.at, &totals);
        }
        drop(s);
        // One rewrite, not a line per row: a crash part way through a seed of appended lines left
        // a file that read as a ledger, and the sessions after the crash were never seeded. Sent
        // even with nothing seeded: it ends the writer's hold on lines from before it.
        self.send(Work::Seed);
        for work in repos {
            self.send(work);
        }
    }

    /// The `_acpmux/ledger` reply for `q`.
    pub fn query(&self, q: &LedgerQuery) -> LedgerReply {
        query::fold(&self.lock(), q, &self.person).0
    }

    /// Waits until the writer has written everything handed to it.
    #[cfg(test)]
    pub(crate) fn flush(&self) {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        if self.writer.lock().unwrap_or_else(PoisonError::into_inner).is_some() {
            self.send(Work::Flush(tx));
            let _ = rx.recv();
        }
    }
}

impl State {
    fn session_key_open(&mut self, id: &str) -> Arc<str> {
        match self.open.get_key_value(id) {
            Some((k, _)) => k.clone(),
            None => Arc::from(id),
        }
    }
}

/// What a turn's session says about itself, read under its meta lock.
pub(crate) struct TurnContext {
    pub model: Option<String>,
    pub info: SessionInfo,
}

impl TurnContext {
    pub(crate) fn of(m: &crate::store::SessionMeta) -> Self {
        let info = SessionInfo {
            title: m.title.clone().filter(|t| !t.is_empty()).or_else(|| Some(m.name.clone())),
            harness: m.harness.clone(),
            family: m.family.clone(),
            workspace_id: m.workspace_id.clone(),
            repo: None,
            branch: m.git_branch.clone(),
            pull_requests: m.pull_requests.clone(),
            account: m.claude_profile.clone().or_else(|| m.preset.clone()),
            cwd: Some(m.cwd.to_string_lossy().into_owned()),
            created_at: m.created_at,
        };
        Self { model: super::current_model(m), info }
    }
}

/// One loaded session for [`Ledger::seed`].
pub(crate) struct Seed {
    pub id: String,
    pub at: u64,
    pub turns: u64,
    pub totals: TurnUsage,
    pub ctx: TurnContext,
}

impl Seed {
    /// `own_turns`: a fork's turns since it was made (its meta's count includes the parent's
    /// turns it copied, which count once, in the parent); None counts the meta's.
    pub(crate) fn of(m: &crate::store::SessionMeta, own_turns: Option<u64>) -> Self {
        Self {
            id: m.id.clone(),
            at: m.updated_at,
            turns: own_turns.unwrap_or(m.turn_count),
            totals: m.totals.clone().unwrap_or_default(),
            ctx: TurnContext::of(m),
        }
    }
}

#[cfg(test)]
mod tests;
