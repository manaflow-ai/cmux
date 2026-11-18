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

    /// Takes `pr` in place of what was known of its URL; its links are those of its body.
    /// A note with no trace ids keeps the ones known (a state change names no body).
    pub(crate) fn put_pr(&mut self, mut pr: PullRequest) -> PullRequest {
        if let Some(old) = self.prs.get(&pr.url) {
            if pr.asks.is_empty() {
                pr.asks = old.asks.clone();
            }
            if pr.repo.is_none() {
                pr.repo = old.repo.clone();
            }
            if pr.number.is_none() {
                pr.number = old.number;
            }
            for id in &old.asks {
                if let Some(urls) = self.by_ask.get_mut(id) {
                    urls.retain(|u| *u != pr.url);
                }
            }
        }
        for id in &pr.asks {
            let urls = self.by_ask.entry(id.clone()).or_default();
            if !urls.contains(&pr.url) {
                urls.push(pr.url.clone());
            }
        }
        self.by_ask.retain(|_, urls| !urls.is_empty());
        self.prs.insert(pr.url.clone(), pr.clone());
        pr
    }

    /// Forgets every ask of `session`.
    pub(crate) fn remove_session(&mut self, session: &str) {
        for id in self.by_session.remove(session).unwrap_or_default() {
            if let Some(ask) = self.asks.remove(&id) {
                self.order.remove(&(ask.ts, ask.id));
            }
        }
    }

    /// The status an ask's pull requests give it.
    fn status(&self, id: &str) -> &'static str {
        let prs: Vec<&PullRequest> =
            self.by_ask.get(id).into_iter().flatten().filter_map(|url| self.prs.get(url)).collect();
        if prs.iter().any(|pr| pr.state == PrState::Merged) {
            "merged"
        } else if prs.is_empty() {
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
        Ok(Self { session_id, limit, before })
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
        Self::open_as(dir, crate::pairing::machine_name())
    }

    pub(crate) fn open_as(dir: Option<PathBuf>, host: String) -> Self {
        let mut state = State::default();
        let spawned = dir.and_then(|dir| {
            let path = dir.join(store::FILE);
            store::fold(&path, &mut state);
            store::spawn_writer(dir, path)
        });
        let (writer, thread) = match spawned {
            Some((tx, thread)) => (Some(tx), Some(thread)),
            None => (None, None),
        };
        Self {
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

    /// Observes one appended record of chat `session`; only the person's `user_message` does
    /// anything. The meta read is one short lock of the chat's own meta.
    pub(crate) fn observe(&self, session: &super::Session, record: &EventRecord) {
        if record.kind != "user_message" || session.purged.load(Ordering::SeqCst) {
            return;
        }
        self.record(&session.id, record, || {
            let m = session.meta.lock().unwrap_or_else(PoisonError::into_inner);
            m.family.clone().filter(|f| !f.is_empty()).unwrap_or_else(|| m.harness.clone())
        });
    }

    /// [`AskLedger::observe`] for chat `id`; `harness` is read only for an ask.
    pub(crate) fn record(&self, id: &str, record: &EventRecord, harness: impl FnOnce() -> String) {
        if record.kind != "user_message" || !is_person_message(&record.msg) {
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
        {
            let s = self.lock();
            if s.purged.contains(id) || s.asks.contains_key(&ask_id) {
                return;
            }
        }
        let ask = Ask {
            id: ask_id,
            ts: record.at,
            text: text.chars().take(MAX_TEXT_CHARS).collect(),
            harness: harness(),
            session_id: id.to_owned(),
            host: self.host.clone(),
            message_id,
        };
        let mut s = self.lock();
        if s.purged.contains(id) {
            return;
        }
        if s.add_ask(ask.clone()) {
            self.emit(&mut s, Line::Ask(ask));
        }
    }

    /// Chat `session` was purged: its asks leave the index now and the file at the writer's
    /// next step. Its pull requests stay (they are another chat's work as much).
    pub fn purge(&self, session: &str) {
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
        let mut s = self.lock();
        let known = s.prs.get(&note.url).cloned();
        let pr = PullRequest {
            url: note.url,
            repo: note.repo,
            number: note.number,
            state: note.state.or(known.as_ref().map(|k| k.state)).unwrap_or_default(),
            asks: note.traces.unwrap_or_default(),
            at,
        };
        let pr = s.put_pr(pr);
        if known.as_ref() != Some(&pr) {
            self.emit(&mut s, Line::Pr(pr.clone()));
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
        if !self.lock().prs.contains_key(url) {
            return;
        }
        let state = if merged { PrState::Merged } else { PrState::Closed };
        let note = PrNote { url: url.to_owned(), state: Some(state), ..Default::default() };
        self.note_pr(note, at);
    }

    /// The `_acpmux/asks` reply: asks newest first, each with its pull requests and status.
    /// `title` names a chat (its meta's title), or `None` when this daemon no longer holds it;
    /// it is asked once the ledger's lock is released (a chat's meta lock is taken before it).
    pub fn query(&self, q: &AsksQuery, title: impl Fn(&str) -> Option<String>) -> Value {
        let mut rows = self.rows(q);
        let more = rows.len() > q.limit;
        rows.truncate(q.limit);
        let next = rows.last().and_then(|r| r.get("ts")).cloned().filter(|_| more);
        for row in &mut rows {
            let named = row.get("sessionId").and_then(Value::as_str).and_then(&title);
            if let (Some(t), Value::Object(map)) = (named, row) {
                map.insert("sessionTitle".into(), json!(t));
            }
        }
        let mut reply = Map::new();
        reply.insert("asks".into(), Value::Array(rows));
        reply.insert("host".into(), json!(self.host));
        if let Some(ts) = next {
            reply.insert("next".into(), ts);
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
            None => Box::new(s.order.iter().rev().filter_map(|(_, id)| s.asks.get(id))),
        };
        ids.filter(|a| q.before.is_none_or(|before| a.ts < before))
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

/// Every ask and pull request in `state`, one line each: the rewritten file.
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
    lines
}

#[cfg(test)]
mod tests;
