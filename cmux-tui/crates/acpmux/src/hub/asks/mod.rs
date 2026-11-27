//! The Ask ledger (`_acpmux/asks`, `_acpmux/asks_link_pr`): every message the person typed
//! into a chat on this machine, each with a stable id the work it led to can carry, linked to
//! its chat and to the pull requests that name it.
//!
//! - An ask is a `user_message` record the daemon admitted as the person's own: no
//!   `_meta.provenance` (another agent's or session's message, a tool's notice, a trigger's
//!   delivery, an unverified program and another person's prompt all carry one) and
//!   `_meta.origin {actor: "person"}` (`prompt_provenance::marked`). A record with neither, as
//!   a watched desktop turn's, is never one. Steers count: they are the person's words too.
//! - Its id is `ask-` and the first 10 hex digits of the SHA-256 of its chat's id, a newline and
//!   its message id (the record's `promptId`, else `seq-N`), so the same message gives the same
//!   id on every read, after a restart and when a moved chat's log is replayed: a second record
//!   of a known id adds nothing.
//! - A chat lists its asks (`sessionId` on `_acpmux/asks`), and an ask names its chat. A fork's
//!   copies of its parent's prompts are not asks of the fork, and a purged chat's asks leave with
//!   it: both read the cost ledger's own fence (`Ledger::blocks`).
//! - A pull request links to every ask whose id its body carries, as `Leo-Ask-Trace: ask-…`
//!   (one or more, comma separated) or as a bare `ask-…` token ([`trace_ids`]). The daemon feeds
//!   it from what it already sees: a chat's `gh pr create` call (its command holds the body
//!   given inline) and its `gh pr merge` or `gh pr close` (`hub/pull_requests.rs`). A client that
//!   knows more (its own pull request cache) attaches one with `_acpmux/asks_link_pr`. Nothing
//!   here asks GitHub.
//! - An ask's status is `open` (no pull request names it), `pr` (one does) or `merged` (one
//!   that names it merged).
//!
//! Persisted append-only to `<home>/asks/asks.jsonl` by a writer thread, so the append lock
//! never waits on a disk; folded once when the hub is built and rewritten whole after a purge.
//! An ask keeps at most [`MAX_TEXT_CHARS`] of its text: the chat's log holds the rest.

mod store;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{LazyLock, Mutex, PoisonError};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::store::EventRecord;

/// The longest text an ask keeps, in characters.
pub const MAX_TEXT_CHARS: usize = 1000;
/// Most trace ids one pull request body links.
pub const MAX_TRACES_PER_PR: usize = 32;
/// Default and largest page of `_acpmux/asks`.
pub const DEFAULT_LIMIT: usize = 200;
pub const MAX_LIMIT: usize = 2000;

static TRACE_ID: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"\bask-[0-9a-f]{10}\b").ok());

/// The ask id of message `message_id` in chat `session_id`: stable for the same pair.
pub fn ask_id(session_id: &str, message_id: &str) -> String {
    let digest = crate::sha256::sha256_hex(format!("{session_id}\n{message_id}").as_bytes());
    // A sha256 hex digest is 64 characters, all ASCII.
    format!("ask-{}", digest.get(..10).unwrap_or(&digest))
}

/// The ask ids `text` carries (a pull request body), once each, in the order they appear.
/// `Leo-Ask-Trace: ask-a, ask-b` and a bare `ask-…` token both count; a longer hex run or a
/// token glued to other word characters does not.
pub fn trace_ids(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Some(pattern) = TRACE_ID.as_ref() else { return out };
    for found in pattern.find_iter(text) {
        let id = found.as_str();
        if !out.iter().any(|known| known == id) {
            out.push(id.to_owned());
            if out.len() == MAX_TRACES_PER_PR {
                break;
            }
        }
    }
    out
}

/// Whether a `user_message` record is the person's own words: no provenance, and the daemon's
/// positive `_meta.origin` mark.
pub fn is_person_message(msg: &Value) -> bool {
    let meta = msg.get("_meta");
    let provenance = meta.and_then(|m| m.get("provenance")).is_some_and(|p| !p.is_null());
    let person = meta
        .and_then(|m| m.get(crate::prompt_provenance::ORIGIN))
        .and_then(|o| o.get("actor"))
        .and_then(Value::as_str)
        == Some("person");
    !provenance && person
}

/// Classifies a person's words at capture time. Short acknowledgements are replies, explicit
/// approvals and shipping decisions are decisions, and all other non-empty messages are asks.
pub fn classify(text: &str) -> AskKind {
    let normalized = text.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return AskKind::Reply;
    }
    if matches!(
        normalized.as_str(),
        "yes" | "y" | "no" | "n" | "nope" | "ok" | "okay" | "thanks" | "thank you" | "lol"
    ) {
        return AskKind::Reply;
    }
    if normalized.contains("go ahead")
        || normalized.contains("ship it")
        || normalized.contains("approved")
        || normalized.contains("approve")
        || normalized.starts_with("decide ")
        || normalized.starts_with("decision ")
    {
        return AskKind::Decision;
    }
    AskKind::Ask
}

/// One message the person sent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ask {
    pub id: String,
    /// Unix ms the daemon recorded it.
    pub ts: u64,
    pub text: String,
    /// The chat's harness family (`claude`, `codex`, ...), else its harness name.
    pub harness: String,
    pub session_id: String,
    /// The machine whose daemon recorded it.
    pub host: String,
    /// The record's `promptId`, else `seq-N`.
    pub message_id: String,
    /// The capture-time classification used by the Next list.
    #[serde(default)]
    pub kind: AskKind,
}

/// A person's captured message classification. Replies remain in the append-only event log but
/// are omitted from the board, so capture never has to guess a durable owner or status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum AskKind {
    #[default]
    Ask,
    Decision,
    Reply,
}

impl AskKind {
    fn on_board(self) -> bool {
        matches!(self, Self::Ask | Self::Decision)
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Decision => "decision",
            Self::Reply => "reply",
        }
    }
}

/// An append-only fact about a captured ask. The current board status is derived from these
/// events and the current PR links, while old `Ask` lines remain readable for compatibility.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskEvent {
    pub ask: String,
    pub ts: u64,
    pub kind: String,
    pub by: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

/// A pull request's state, as far as the daemon heard it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum PrState {
    #[default]
    Open,
    Merged,
    Closed,
}

impl PrState {
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "open" | "draft" => Some(Self::Open),
            "merged" => Some(Self::Merged),
            "closed" => Some(Self::Closed),
            _ => None,
        }
    }
}

/// A pull request that names one or more asks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u64>,
    pub state: PrState,
    /// The ask ids its body carries.
    #[serde(default)]
    pub asks: Vec<String>,
    /// Unix ms it was last noted.
    pub at: u64,
}

/// `owner/name` and the number of a `https://github.com/owner/name/pull/N` URL.
pub fn parse_pull_url(url: &str) -> Option<(String, u64)> {
    let rest = url.strip_prefix("https://github.com/")?;
    let mut parts = rest.split('/');
    let (owner, name, pull, number) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    if pull != "pull" || owner.is_empty() || name.is_empty() || parts.next().is_some() {
        return None;
    }
    Some((format!("{owner}/{name}"), number.parse().ok()?))
}

/// One line of `asks.jsonl`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
pub(crate) enum Line {
    #[serde(rename = "a")]
    Ask(Ask),
    /// A pull request as last noted (later lines replace earlier ones of the same URL).
    #[serde(rename = "pr")]
    Pr(PullRequest),
    /// An append-only capture or lifecycle fact. The derived indexes are rebuilt from these lines.
    #[serde(rename = "e")]
    Event(AskEvent),
    /// The chat was purged: every ask of it before this line is dropped.
    #[serde(rename = "p")]
    Purge { sid: String },
}

#[derive(Default)]
pub(crate) struct State {
    asks: HashMap<String, Ask>,
    /// `(ts, id)` of every ask, for newest-first pages.
    order: BTreeSet<(u64, String)>,
    by_session: HashMap<String, Vec<String>>,
    prs: HashMap<String, PullRequest>,
    /// Append-only events, retained in capture order for lifecycle queries and duress inspection.
    events: Vec<AskEvent>,
    /// Event ids already folded, so replaying a capture source is idempotent.
    event_keys: HashSet<(String, String, u64, Option<String>)>,
    /// Event indexes keep each row and status lookup proportional to its ask/PR history.
    events_by_ask: HashMap<String, Vec<usize>>,
    events_by_target: HashMap<String, Vec<usize>>,
    /// Ask id -> the pull request URLs naming it.
    by_ask: HashMap<String, Vec<String>>,
    /// Chats purged this run: none of their late records adds an ask.
    purged: HashSet<String>,
    /// Lines handed to the writer so far.
    seq: u64,
}

impl State {
    /// Adds `ask`; false when its id is known already.
    pub(crate) fn add_ask(&mut self, ask: Ask) -> bool {
        if self.asks.contains_key(&ask.id) {
            return false;
        }
        self.order.insert((ask.ts, ask.id.clone()));
        self.by_session.entry(ask.session_id.clone()).or_default().push(ask.id.clone());
        self.asks.insert(ask.id.clone(), ask);
        true
    }

    pub(crate) fn add_event(&mut self, event: AskEvent) -> bool {
        let key = (event.ask.clone(), event.kind.clone(), event.ts, event.target.clone());
        if !self.event_keys.insert(key) {
            return false;
        }
        let index = self.events.len();
        self.events_by_ask.entry(event.ask.clone()).or_default().push(index);
        if let Some(target) = &event.target {
            self.events_by_target.entry(target.clone()).or_default().push(index);
        }
        self.events.push(event);
        true
    }

    fn rebuild_event_indexes(&mut self) {
        self.event_keys.clear();
        self.events_by_ask.clear();
        self.events_by_target.clear();
        for (index, event) in self.events.iter().enumerate() {
            self.event_keys.insert((
                event.ask.clone(),
                event.kind.clone(),
                event.ts,
                event.target.clone(),
            ));
            self.events_by_ask.entry(event.ask.clone()).or_default().push(index);
            if let Some(target) = &event.target {
                self.events_by_target.entry(target.clone()).or_default().push(index);
            }
        }
    }

    /// Takes `pr` in place of what was known of its URL; its links are those of its body.
    pub(crate) fn put_pr(&mut self, mut pr: PullRequest) -> PullRequest {
        let old = self.prs.get(&pr.url);
        if let Some(old) = old {
            if pr.repo.is_none() {
                pr.repo = old.repo.clone();
            }
            if pr.number.is_none() {
                pr.number = old.number;
            }
        }
        // State-only and duplicate observations do not change the reverse index. For a
        // changed body, touch only this PR's removed/added links, never the whole ledger.
        if old.is_none_or(|old| old.asks != pr.asks) {
            for id in old.into_iter().flat_map(|old| &old.asks) {
                if pr.asks.contains(id) {
                    continue;
                }
                let empty = self.by_ask.get_mut(id).is_some_and(|urls| {
                    urls.retain(|url| *url != pr.url);
                    urls.is_empty()
                });
                if empty {
                    self.by_ask.remove(id);
                }
            }
            for id in &pr.asks {
                if old.is_some_and(|old| old.asks.contains(id)) {
                    continue;
                }
                let urls = self.by_ask.entry(id.clone()).or_default();
                if !urls.contains(&pr.url) {
                    urls.push(pr.url.clone());
                }
            }
        }
        self.prs.insert(pr.url.clone(), pr.clone());
        pr
    }

    /// Forgets every ask of `session`.
    pub(crate) fn remove_session(&mut self, session: &str) {
        let ids = self.by_session.remove(session).unwrap_or_default();
        let removed: HashSet<String> = ids.iter().cloned().collect();
        self.events.retain(|event| !removed.contains(&event.ask));
        self.rebuild_event_indexes();
        for id in ids {
            if let Some(ask) = self.asks.remove(&id) {
                self.order.remove(&(ask.ts, ask.id));
            }
        }
    }

    /// The status an ask's lifecycle events give it, with the old PR index as a compatibility
    /// fallback for ledgers written before event lines existed.
    fn status(&self, id: &str) -> &'static str {
        let mut has_pr = false;
        let mut merged = false;
        for url in self.by_ask.get(id).into_iter().flatten() {
            let Some(pr) = self.prs.get(url) else { continue };
            has_pr = true;
            let latest = self
                .events_by_target
                .get(url)
                .into_iter()
                .flatten()
                .filter_map(|index| self.events.get(*index))
                .max_by_key(|event| event.ts);
            merged |=
                latest.is_some_and(|event| event.kind == "prMerged") || pr.state == PrState::Merged;
        }
        if merged {
            "merged"
        } else if !has_pr {
            "open"
        } else {
            "pr"
        }
    }

    fn row(&self, ask: &Ask) -> Value {
        let prs: Vec<Value> = self
            .by_ask
            .get(&ask.id)
            .into_iter()
            .flatten()
            .filter_map(|url| self.prs.get(url))
            .map(|pr| {
                let mut v = Map::new();
                v.insert("url".into(), json!(pr.url));
                v.insert("state".into(), json!(pr.state));
                if let Some(repo) = &pr.repo {
                    v.insert("repo".into(), json!(repo));
                }
                if let Some(n) = pr.number {
                    v.insert("number".into(), json!(n));
                }
                Value::Object(v)
            })
            .collect();
        let mut row = match serde_json::to_value(ask) {
            Ok(Value::Object(map)) => map,
            _ => Map::new(),
        };
        row.insert("status".into(), json!(self.status(&ask.id)));
        row.insert("kind".into(), json!(ask.kind));
        row.insert(
            "events".into(),
            Value::Array(
                self.events_by_ask
                    .get(&ask.id)
                    .into_iter()
                    .flatten()
                    .filter_map(|index| self.events.get(*index))
                    .filter_map(|event| serde_json::to_value(event).ok())
                    .collect(),
            ),
        );
        row.insert("prs".into(), Value::Array(prs));
        Value::Object(row)
    }
}

/// A `_acpmux/asks` read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AsksQuery {
    /// Only this chat's asks.
    pub session_id: Option<String>,
    pub limit: usize,
    /// Only asks recorded before this (Unix ms): the next page's cursor.
    pub before: Option<u64>,
    /// Tie breaker for asks recorded in the same millisecond.
    pub before_id: Option<String>,
    /// The Next board view excludes captured replies. The default is also board-safe so older
    /// clients never receive a reply row they cannot render.
    pub next: bool,
}

impl AsksQuery {
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let session_id = match params.get("sessionId") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            Some(_) => return Err("sessionId must be a non-empty string".into()),
        };
        let limit = match params.get("limit") {
            None | Some(Value::Null) => DEFAULT_LIMIT,
            Some(v) => match v.as_u64() {
                Some(n) if n > 0 => usize::try_from(n).unwrap_or(MAX_LIMIT).min(MAX_LIMIT),
                _ => return Err("limit must be a positive integer".into()),
            },
        };
        let before = match params.get("before") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_u64().ok_or("before must be Unix ms")?),
        };
        let before_id = match params.get("beforeId") {
            None | Some(Value::Null) => None,
            Some(Value::String(id)) if before.is_some() => Some(id.clone()),
            _ => return Err("beforeId requires before and a string id".into()),
        };
        let next = match params.get("view") {
            None | Some(Value::Null) => false,
            Some(Value::String(view)) if view == "next" => true,
            Some(Value::String(_)) => return Err("view must be next".into()),
            Some(_) => return Err("view must be a string".into()),
        };
        Ok(Self { session_id, limit, before, before_id, next })
    }
}

/// A `_acpmux/asks_link_pr` note: a pull request and, when known, its body.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PrNote {
    pub url: String,
    pub repo: Option<String>,
    pub number: Option<u64>,
    pub state: Option<PrState>,
    /// The ask ids its body carries; `None` when no body was given (the known links stay).
    pub traces: Option<Vec<String>>,
}

impl PrNote {
    /// From `{url?, repo?, number?, state?, body?}`: a URL, or a repository and a number.
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
        let number = params.get("number").and_then(Value::as_u64);
        let (url, repo, number) = match text("url") {
            Some(url) => {
                let (repo, n) = parse_pull_url(url)
                    .ok_or("url must be https://github.com/OWNER/NAME/pull/N")?;
                (url.to_owned(), Some(repo), Some(n))
            }
            None => {
                let repo = text("repo").ok_or("url, or repo and number, is required")?;
                let number = number.ok_or("url, or repo and number, is required")?;
                if repo.split('/').count() != 2 || repo.split('/').any(str::is_empty) {
                    return Err("repo must be OWNER/NAME".into());
                }
                (
                    format!("https://github.com/{repo}/pull/{number}"),
                    Some(repo.to_owned()),
                    Some(number),
                )
            }
        };
        let state = match text("state") {
            None => None,
            Some(s) => Some(PrState::parse(s).ok_or("state must be open, merged or closed")?),
        };
        let traces = params.get("body").and_then(Value::as_str).map(trace_ids);
        Ok(Self { url, repo, number, state, traces })
    }
}

pub struct AskLedger {
    enabled: bool,
    pub(crate) state: Mutex<State>,
    writer: Mutex<Option<std::sync::mpsc::Sender<store::Work>>>,
    thread: Mutex<Option<store::WriterThread>>,
    host: String,
}

impl std::fmt::Debug for AskLedger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AskLedger").finish_non_exhaustive()
    }
}

impl AskLedger {
    /// A ledger kept in `dir` (`<home>/asks`), folded from its file now; `None` keeps it in
    /// memory only (a memory store).
    pub fn open(dir: Option<PathBuf>) -> Self {
        Self::open_configured(dir, crate::pairing::machine_name(), &crate::user_settings::read())
    }

    fn open_configured(
        dir: Option<PathBuf>,
        host: String,
        settings: &crate::user_settings::Settings,
    ) -> Self {
        let enabled = match settings {
            crate::user_settings::Settings::Parsed(doc) => {
                crate::user_settings::value(doc, "labs.askLedger") == Some(Value::Bool(true))
            }
            _ => false,
        };
        Self::open_enabled(dir, host, enabled)
    }

    #[cfg(test)]
    pub(crate) fn open_as(dir: Option<PathBuf>, host: String) -> Self {
        Self::open_enabled(dir, host, true)
    }

    fn open_enabled(dir: Option<PathBuf>, host: String, enabled: bool) -> Self {
        let mut state = State::default();
        let spawned = dir.and_then(|dir| {
            let path = dir.join(store::FILE);
            // Off creates no store or writer. Previously captured asks remain private and
            // hidden, but still participate in chat deletion while the experiment is off.
            if !enabled && !path.exists() {
                return None;
            }
            store::fold(&path, &mut state);
            store::spawn_writer(dir, path)
        });
        let (writer, thread) = match spawned {
            Some((tx, thread)) => (Some(tx), Some(thread)),
            None => (None, None),
        };
        Self {
            enabled,
            state: Mutex::new(state),
            writer: Mutex::new(writer),
            thread: Mutex::new(thread),
            host,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Hands `line` to the writer, under the state lock so lines keep their order.
    fn emit(&self, state: &mut State, line: Line) {
        state.seq = state.seq.wrapping_add(1);
        let rewrite = matches!(line, Line::Purge { .. });
        if let Some(tx) = self.writer.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            let _ = tx.send(store::Work::Line(Box::new(line)));
            if rewrite {
                // The purged chat's asks leave the file now: one rewrite of what is left.
                let _ = tx.send(store::Work::Rewrite(snapshot(state)));
            }
        }
    }

    /// Observes one appended record of chat `session`. The daemon's provenance mark decides
    /// whether it is a person's capture, then classification happens before anything is stored.
    pub(crate) fn observe(&self, session: &super::Session, record: &EventRecord) {
        if !self.enabled || record.kind != "user_message" || session.purged.load(Ordering::SeqCst) {
            return;
        }
        self.record(&session.id, record, || {
            let m = session.meta.lock().unwrap_or_else(PoisonError::into_inner);
            m.family.clone().filter(|f| !f.is_empty()).unwrap_or_else(|| m.harness.clone())
        });
    }

    /// [`AskLedger::observe`] for chat `id`; `harness` is read only for a person's capture.
    pub(crate) fn record(&self, id: &str, record: &EventRecord, harness: impl FnOnce() -> String) {
        if !self.enabled || record.kind != "user_message" || !is_person_message(&record.msg) {
            return;
        }
        let Some(text) = record.msg.get("text").and_then(Value::as_str) else { return };
        if text.trim().is_empty() {
            return;
        }
        let message_id = record
            .msg
            .get("promptId")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
            .map_or_else(|| format!("seq-{}", record.seq), str::to_owned);
        let ask_id = ask_id(id, &message_id);
        let kind = classify(text);
        let ask = Ask {
            id: ask_id.clone(),
            ts: record.at,
            text: crate::secret_scan::mask(text).chars().take(MAX_TEXT_CHARS).collect(),
            harness: harness(),
            session_id: id.to_owned(),
            host: self.host.clone(),
            message_id,
            kind,
        };
        let mut event = AskEvent {
            ask: ask_id.clone(),
            ts: record.at,
            kind: "captured".into(),
            by: "person".into(),
            target: Some(kind.as_str().into()),
        };
        let mut s = self.lock();
        if s.purged.contains(id) {
            return;
        }
        if s.add_ask(ask.clone()) {
            self.emit(&mut s, Line::Ask(ask));
        } else if let Some(existing) = s.asks.get(&ask_id) {
            // A crash can leave the ask line durable while its following event line is not.
            // Replay the source record to repair that suffix without changing the ask itself.
            event.ts = existing.ts;
            event.target = Some(existing.kind.as_str().into());
        }
        if s.add_event(event.clone()) {
            self.emit(&mut s, Line::Event(event));
        }
    }

    /// Chat `session` was purged: its asks leave the index now and the file at the writer's
    /// next step. Its pull requests stay (they are another chat's work as much).
    pub fn purge(&self, session: &str) {
        if !self.enabled && self.writer.lock().unwrap_or_else(PoisonError::into_inner).is_none() {
            return;
        }
        let mut s = self.lock();
        s.purged.insert(session.to_owned());
        let known = s.by_session.contains_key(session);
        s.remove_session(session);
        if known {
            self.emit(&mut s, Line::Purge { sid: session.to_owned() });
        }
    }

    /// A chat was created under `session` again this run: its asks count again.
    pub fn reopen(&self, session: &str) {
        self.lock().purged.remove(session);
    }

    /// Notes a pull request; returns it as now known, with the asks it links that this
    /// ledger holds.
    pub fn note_pr(&self, note: PrNote, at: u64) -> Value {
        if !self.enabled {
            return json!({"enabled": false, "linked": []});
        }
        let mut s = self.lock();
        let known = s.prs.get(&note.url).cloned();
        let pr = PullRequest {
            url: note.url,
            repo: note.repo,
            number: note.number,
            state: note.state.or(known.as_ref().map(|k| k.state)).unwrap_or_default(),
            asks: note
                .traces
                .unwrap_or_else(|| known.as_ref().map(|pr| pr.asks.clone()).unwrap_or_default()),
            at,
        };
        let pr = s.put_pr(pr);
        let changed = known.as_ref().is_none_or(|old| {
            old.repo != pr.repo
                || old.number != pr.number
                || old.state != pr.state
                || old.asks != pr.asks
        });
        let state_changed = known.as_ref().is_none_or(|old| old.state != pr.state);
        if changed {
            self.emit(&mut s, Line::Pr(pr.clone()));
        }
        if state_changed || known.as_ref().is_some_and(|old| old.asks != pr.asks) {
            let event_kind = match pr.state {
                PrState::Merged => "prMerged",
                PrState::Open => "prOpened",
                PrState::Closed => "prClosed",
            };
            for ask in &pr.asks {
                let newly_linked =
                    known.as_ref().is_none_or(|old| !old.asks.iter().any(|id| id == ask));
                if !state_changed && !newly_linked {
                    continue;
                }
                let event = AskEvent {
                    ask: ask.clone(),
                    ts: at,
                    kind: event_kind.into(),
                    by: "daemon".into(),
                    target: Some(pr.url.clone()),
                };
                if s.add_event(event.clone()) {
                    self.emit(&mut s, Line::Event(event));
                }
            }
        }
        let linked: Vec<&String> = pr.asks.iter().filter(|id| s.asks.contains_key(*id)).collect();
        json!({"url": pr.url, "state": pr.state, "traceIds": pr.asks, "linked": linked})
    }

    /// A chat's `gh pr create` printed `url`; `traces` are the ask ids its command carried.
    pub fn note_created(&self, url: &str, traces: Vec<String>, at: u64) {
        if traces.is_empty() {
            return;
        }
        let (repo, number) = parse_pull_url(url).map_or((None, None), |(r, n)| (Some(r), Some(n)));
        let note = PrNote {
            url: url.to_owned(),
            repo,
            number,
            state: Some(PrState::Open),
            traces: Some(traces),
        };
        self.note_pr(note, at);
    }

    /// A chat's `gh pr merge` (`merged`) or `gh pr close` settled `url`: only a pull request
    /// this ledger links changes.
    pub fn note_settled(&self, url: &str, merged: bool, at: u64) {
        if !self.enabled || !self.lock().prs.contains_key(url) {
            return;
        }
        let state = if merged { PrState::Merged } else { PrState::Closed };
        let note = PrNote { url: url.to_owned(), state: Some(state), ..Default::default() };
        self.note_pr(note, at);
    }

    /// The `_acpmux/asks` reply: Next rows newest first, each with its pull requests and derived
    /// status. `view: "next"` is accepted explicitly for the new board while older clients can
    /// keep calling the original method with an empty parameter object.
    /// `title` names a chat (its meta's title), or `None` when this daemon no longer holds it;
    /// it is asked once the ledger's lock is released (a chat's meta lock is taken before it).
    pub fn query(&self, q: &AsksQuery, title: impl Fn(&str) -> Option<String>) -> Value {
        if !self.enabled {
            return json!({"enabled": false, "asks": []});
        }
        let mut rows = self.rows(q);
        let more = rows.len() > q.limit;
        rows.truncate(q.limit);
        let next = rows.last().filter(|_| more).map(|r| (r["ts"].clone(), r["id"].clone()));
        for row in &mut rows {
            let named = row.get("sessionId").and_then(Value::as_str).and_then(&title);
            if let (Some(t), Value::Object(map)) = (named, row) {
                map.insert("sessionTitle".into(), json!(t));
            }
        }
        let mut reply = Map::new();
        reply.insert("enabled".into(), json!(true));
        reply.insert("asks".into(), Value::Array(rows));
        reply.insert("host".into(), json!(self.host));
        if q.next {
            reply.insert("view".into(), json!("next"));
        }
        if let Some((ts, id)) = next {
            reply.insert("next".into(), ts);
            reply.insert("nextId".into(), id);
        }
        Value::Object(reply)
    }

    /// Up to `q.limit + 1` rows, newest first: one past the page says another follows.
    fn rows(&self, q: &AsksQuery) -> Vec<Value> {
        let s = self.lock();
        let ids: Box<dyn Iterator<Item = &Ask>> = match &q.session_id {
            Some(sid) => {
                let mut asks: Vec<&Ask> = s
                    .by_session
                    .get(sid)
                    .into_iter()
                    .flatten()
                    .filter_map(|id| s.asks.get(id))
                    .collect();
                asks.sort_by(|a, b| (b.ts, &b.id).cmp(&(a.ts, &a.id)));
                Box::new(asks.into_iter())
            }
            None => match q.before {
                Some(before) => {
                    let bound = (before, q.before_id.clone().unwrap_or_default());
                    Box::new(s.order.range(..bound).rev().filter_map(|(_, id)| s.asks.get(id)))
                }
                None => Box::new(s.order.iter().rev().filter_map(|(_, id)| s.asks.get(id))),
            },
        };
        ids.filter(|a| {
            // Replies are captured and durable, but the board is intentionally limited to asks
            // and decisions until the event detail view lands.
            a.kind.on_board()
        })
        .filter(|a| {
            q.before.is_none_or(|before| {
                a.ts < before
                    || (a.ts == before && q.before_id.as_ref().is_some_and(|id| &a.id < id))
            })
        })
        .take(q.limit.saturating_add(1))
        .map(|ask| s.row(ask))
        .collect()
    }

    /// Shutdown (`Hub::flush`): closes the writer's queue and waits up to `within` for it to
    /// write what it holds. True when it ended.
    pub fn close(&self, within: std::time::Duration) -> bool {
        drop(self.writer.lock().unwrap_or_else(PoisonError::into_inner).take());
        let Some(thread) = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return true;
        };
        match thread.join_within(within) {
            Ok(()) => true,
            Err(thread) => {
                *self.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
                false
            }
        }
    }

    /// Closes the writer's queue and waits for the writer to end, however long that takes.
    pub fn wait_closed(&self) {
        drop(self.writer.lock().unwrap_or_else(PoisonError::into_inner).take());
        let thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(thread) = thread {
            thread.join();
        }
    }

    /// Waits until the writer has written everything handed to it.
    #[cfg(test)]
    pub(crate) fn flush(&self) {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let sent = self
            .writer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .is_some_and(|w| w.send(store::Work::Flush(tx)).is_ok());
        if sent {
            let _ = rx.recv();
        }
    }
}

impl super::Hub {
    /// `_acpmux/asks`: the person's asks, newest first, each with its chat's title when this
    /// daemon holds the chat.
    pub fn asks_read(&self, params: &Value) -> Result<Value, String> {
        let q = AsksQuery::from_params(params)?;
        Ok(self.asks.query(&q, |sid| {
            let session = self.session_by_id(sid)?;
            let m = session.meta.lock().unwrap_or_else(PoisonError::into_inner);
            m.title.clone().filter(|t| !t.is_empty()).or_else(|| Some(m.name.clone()))
        }))
    }

    /// `_acpmux/asks_link_pr`: a pull request a client knows (its body, its state) links the asks
    /// its body names.
    pub fn asks_link_pr(&self, params: &Value) -> Result<Value, String> {
        let note = PrNote::from_params(params)?;
        Ok(self.asks.note_pr(note, crate::store::now_ms()))
    }
}

/// Every ask, event and pull request in `state`, one line each: the rewritten file.
fn snapshot(state: &State) -> Vec<Line> {
    let mut lines: Vec<Line> = state
        .order
        .iter()
        .filter_map(|(_, id)| state.asks.get(id))
        .cloned()
        .map(Line::Ask)
        .collect();
    let mut prs: Vec<&PullRequest> = state.prs.values().collect();
    prs.sort_by(|a, b| a.url.cmp(&b.url));
    lines.extend(prs.into_iter().cloned().map(Line::Pr));
    lines.extend(state.events.iter().cloned().map(Line::Event));
    lines
}

#[cfg(test)]
mod tests;
