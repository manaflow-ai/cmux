//! `_acpmux/transcript_search {query, sessionId?, harnessSessionId?, role?, sinceMs?, limit?,
//! context?, host?, order?, window?, offset?}` and `acpmux search` (Leo, 2026-11-18: "shouldn't
//! you be able to like have better tools for finding stuff?"): what was said in the Claude Code
//! and Codex transcripts on this machine (and with `host: "all"` its peers'), from the index
//! `acpmux-transcript-search` keeps at `$ACPMUX_HOME/transcript-search/index-v1.sqlite`.
//!
//! `order`: `"newest"` (the default: newest first) or `"transcript"` (oldest first by place: the
//! transcript's path, then its line). `window: {fromMs, toMs}`: the hits written within it come
//! first, each with `inWindow: true`, then the rest in `order` (Find in Chat passes the span of
//! the rows on screen). `offset`: skips that many hits, to page past `limit`.
//!
//! Every session's transcript, not only the chats acpmux runs: a Claude desktop chat, a terminal
//! `claude`, a Codex thread, their subagents, and the turns before a compaction. A search first
//! reads what the transcripts it covers appended since the last one (cost: those bytes), then asks
//! the index. The daemon fills the index for every transcript after it starts and follows the chat
//! index's changes (`warm`), so a search seldom reads anything.
//!
//! Answer: `{hits: [{host, sessionId, harness, path, subagent, turn, line, at, role, snippet,
//! matchStart, matchLen, cutBefore, cutAfter, matches, messageId?, seq?, inWindow?}], total?,
//! files, caughtUpBytes, catchUpMs, queryMs, tookMs, unreached: [{host, error}]}`. `sessionId` is
//! the harness's session id (a Claude Code session, a Codex thread); `snippet` is the text as
//! written (real line breaks), `matchStart`/`matchLen` in bytes within it; `matches` how many times
//! the message holds the query. `total`: every hit in the query's scope, not only this page's,
//! when the index counted them (up to `acpmux_transcript_search::EXACT_DOCS`; past it, and when a
//! peer gave none, it is left out).
//!
//! `messageId`: the harness's id of the reply the hit is in, the `agent_message_chunk.messageId`
//! acpmux reports on its chunks and a `cmux://agent/...?message=<id>` link carries (Claude Code's
//! `msg_...`); a prompt or a tool call has none. `seq`: with `sessionId` naming an acpmux session,
//! the record of that session's log where the hit's message starts (`_acpmux/session_search`'s
//! seq; a pane's `loadThrough(seq)` reads down to it), for a hit of this machine in the session's
//! own transcript whose text the log holds within an hour of the hit's time ([`place`]). Left out
//! otherwise: a page of an adopted chat's native history (never logged), a turn from before
//! acpmux ran the chat, a subagent's, a peer's.
//!
//! What a chat said is its person's: the daemon answers this on its own socket, to the app, and
//! to its peers (the same person's machines) only.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use acpmux_transcript_search as ts;
use serde_json::{Value, json};

use crate::json_put::put;

pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 200;
pub const DEFAULT_CONTEXT: usize = 300;
const MAX_CONTEXT: usize = 4000;
/// The furthest a search pages: past it, `offset` is this.
pub const MAX_OFFSET: usize = 100_000;
/// How long a peer gets to answer.
pub const PEER_DEADLINE: Duration = Duration::from_secs(10);

/// One search, as the wire names it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Params {
    pub query: String,
    /// An acpmux session (id, name): the daemon finds its harness session.
    pub session: Option<String>,
    /// A harness session id (a Claude Code session, a Codex thread) itself.
    pub harness_session: Option<String>,
    pub role: Option<String>,
    pub since_ms: Option<i64>,
    pub limit: usize,
    pub context: usize,
    /// `"all"`: this machine and every peer; a peer's name: that peer only; none: here.
    pub host: Option<String>,
    pub order: ts::Order,
    /// `(fromMs, toMs)`: the hits written within it first.
    pub window: Option<(i64, i64)>,
    pub offset: usize,
}

impl Params {
    pub fn from_value(v: &Value) -> Result<Self, String> {
        let text = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        let query = v
            .get("query")
            .and_then(Value::as_str)
            .filter(|q| !q.trim().is_empty())
            .ok_or("query is required")?
            .to_owned();
        let role = text("role");
        if let Some(r) = &role
            && ts::Role::parse(r).is_none()
        {
            return Err(format!("role {r:?} is not user, assistant or tool"));
        }
        let limit = v.get("limit").and_then(Value::as_u64).map_or(DEFAULT_LIMIT, |n| n as usize);
        let context =
            v.get("context").and_then(Value::as_u64).map_or(DEFAULT_CONTEXT, |n| n as usize);
        let order = match text("order") {
            None => ts::Order::Newest,
            Some(o) => ts::Order::parse(&o)
                .ok_or_else(|| format!("order {o:?} is not newest or transcript"))?,
        };
        let window = match v.get("window") {
            None | Some(Value::Null) => None,
            Some(w) => {
                let end = |k: &str| w.get(k).and_then(Value::as_i64);
                match (end("fromMs"), end("toMs")) {
                    (Some(from), Some(to)) if from <= to => Some((from, to)),
                    _ => return Err("window must be {fromMs, toMs} with fromMs <= toMs".into()),
                }
            }
        };
        let offset = v.get("offset").and_then(Value::as_u64).map_or(0, |n| n as usize);
        Ok(Self {
            query,
            session: text("sessionId"),
            harness_session: text("harnessSessionId"),
            role,
            since_ms: v.get("sinceMs").and_then(Value::as_i64),
            limit: limit.clamp(1, MAX_LIMIT),
            context: context.min(MAX_CONTEXT),
            host: text("host"),
            order,
            window,
            offset: offset.min(MAX_OFFSET),
        })
    }

    pub fn to_value(&self) -> Value {
        let mut v = json!({"query": self.query, "limit": self.limit, "context": self.context});
        let mut set = |k: &str, x: Value| {
            if !x.is_null() {
                put(&mut v, k, x);
            }
        };
        set("sessionId", json!(self.session));
        set("harnessSessionId", json!(self.harness_session));
        set("role", json!(self.role));
        set("sinceMs", json!(self.since_ms));
        set("host", json!(self.host));
        if self.order != ts::Order::Newest {
            put(&mut v, "order", json!(self.order.as_str()));
        }
        if let Some((from, to)) = self.window {
            put(&mut v, "window", json!({"fromMs": from, "toMs": to}));
        }
        if self.offset > 0 {
            put(&mut v, "offset", json!(self.offset));
        }
        v
    }

    fn query(&self) -> ts::Query {
        let mut q = ts::Query::new(self.query.trim());
        q.sessions = self.harness_session.clone().map(|s| vec![s]);
        q.role = self.role.as_deref().and_then(ts::Role::parse);
        q.since_ms = self.since_ms;
        q.limit = self.limit;
        q.context = self.context;
        q.order = self.order;
        q.window = self.window;
        q.offset = self.offset;
        q
    }

    /// What each machine is asked when several answer one search: from the first hit, deep
    /// enough for this page (the merge skips `offset` of their hits put together). Paging past
    /// [`MAX_LIMIT`] hits of several machines reaches as far as each one's first [`MAX_LIMIT`].
    pub fn for_merge(&self) -> Self {
        let limit = self.offset.saturating_add(self.limit).min(MAX_LIMIT);
        Self { offset: 0, limit, ..self.clone() }
    }
}

pub fn index_path() -> PathBuf {
    crate::config::home().join("transcript-search").join("index-v1.sqlite")
}

/// `~/.claude/projects`, `~/.codex` and the dirs `CLAUDE_CONFIG_DIR` and `CODEX_HOME` name.
pub fn default_roots() -> ts::Roots {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    ts::Roots::default_for(&home, |k| std::env::var(k).ok())
}

/// The default roots and every Claude Code and Codex root the chat index found (profiles' own
/// config dirs, subrouter account homes, roots the person added).
pub fn roots(chats: Option<&crate::chats::ChatService>) -> ts::Roots {
    let mut roots = default_roots();
    if let Some(chats) = chats {
        for (harness, path) in chats.transcript_roots() {
            match harness {
                ts::Harness::Claude => roots.add_claude(path),
                ts::Harness::Codex => roots.add_codex(path),
            }
        }
    }
    roots
}

/// This process's index connection, opened on first use.
static INDEX: Mutex<Option<ts::Index>> = Mutex::new(None);

/// One search of this machine's transcripts. Blocking: a first search of a large transcript
/// reads it whole.
pub fn search_here(p: &Params, roots: &ts::Roots, host: Option<&str>) -> Result<Value, String> {
    let started = Instant::now();
    let sources = match &p.harness_session {
        Some(id) => roots.session(id),
        None => roots.all(),
    };
    let mut guard = INDEX.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(ts::Index::open(&index_path()).map_err(|e| e.to_string())?);
    }
    let Some(index) = guard.as_ref() else { return Err("transcript index: not open".into()) };
    let (hits, done) = ts::search(index, &sources, &p.query()).map_err(|e| e.to_string())?;
    drop(guard);
    let mut answer = json!({
        "hits": hits.iter().map(|h| hit_value(h, host)).collect::<Vec<_>>(),
        "files": done.files,
        "caughtUpBytes": done.caught_up.bytes,
        "catchUpMs": done.catch_up_ms,
        "queryMs": done.query_ms,
        "tookMs": started.elapsed().as_millis() as u64,
        "unreached": [],
    });
    if let Some(total) = done.total {
        put(&mut answer, "total", json!(total));
    }
    Ok(answer)
}

fn hit_value(h: &ts::Hit, host: Option<&str>) -> Value {
    let mut v = json!({
        "host": host,
        "sessionId": h.session,
        "harness": h.harness.as_str(),
        "path": h.path,
        "subagent": h.subagent,
        "turn": h.turn,
        "line": h.line,
        "at": h.at_ms,
        "role": h.role.as_str(),
        "snippet": h.snippet,
        "matchStart": h.match_start,
        "matchLen": h.match_len,
        "cutBefore": h.cut_before,
        "cutAfter": h.cut_after,
        "matches": h.matches,
    });
    if let Some(id) = &h.message_id {
        put(&mut v, "messageId", json!(id));
    }
    if h.in_window {
        put(&mut v, "inWindow", json!(true));
    }
    v
}

/// Puts the hits of several answers (this machine's and its peers') in one: those `inWindow`
/// first, then the rest, each in `p.order` (newest: by `at`; transcript: by `path`, `line`, then
/// `matchStart`); `skip` of them skipped, then at most `p.limit`. `total` is the answers' sum when
/// every one has it.
pub fn merge(
    mut answers: Vec<Value>,
    unreached: Vec<Value>,
    p: &Params,
    skip: usize,
    took_ms: u64,
) -> Value {
    let mut hits: Vec<Value> = answers
        .iter_mut()
        .flat_map(|a| {
            a.get_mut("hits").and_then(Value::as_array_mut).map(std::mem::take).unwrap_or_default()
        })
        .collect();
    let outside = |h: &Value| h.get("inWindow").and_then(Value::as_bool) != Some(true);
    match p.order {
        ts::Order::Newest => hits.sort_by_key(|h| {
            (outside(h), std::cmp::Reverse(h.get("at").and_then(Value::as_i64).unwrap_or(i64::MIN)))
        }),
        ts::Order::Transcript => hits.sort_by(|a, b| {
            let key = |h: &Value| {
                (
                    outside(h),
                    h.get("path").and_then(Value::as_str).unwrap_or_default().to_owned(),
                    h.get("line").and_then(Value::as_u64).unwrap_or(0),
                    h.get("matchStart").and_then(Value::as_u64).unwrap_or(0),
                )
            };
            key(a).cmp(&key(b))
        }),
    }
    let hits: Vec<Value> = hits.into_iter().skip(skip).take(p.limit).collect();
    // No answer at all (every machine unreached) counts nothing.
    let totals: Option<u64> = (!answers.is_empty())
        .then(|| answers.iter().map(|a| a.get("total").and_then(Value::as_u64)).sum())
        .flatten();
    let sum =
        |k: &str| answers.iter().filter_map(|a| a.get(k).and_then(Value::as_u64)).sum::<u64>();
    let max = |k: &str| {
        answers.iter().filter_map(|a| a.get(k).and_then(Value::as_u64)).max().unwrap_or(0)
    };
    let mut unreached = unreached;
    for a in &answers {
        unreached.extend(a.get("unreached").and_then(Value::as_array).cloned().unwrap_or_default());
    }
    let mut merged = json!({
        "hits": hits,
        "files": sum("files"),
        "caughtUpBytes": sum("caughtUpBytes"),
        "catchUpMs": max("catchUpMs"),
        "queryMs": max("queryMs"),
        "tookMs": took_ms,
        "unreached": unreached,
    });
    if let Some(total) = totals {
        put(&mut merged, "total", json!(total));
    }
    merged
}

/// How far a hit's time may be from its message's in the log: a reply is logged as it starts
/// streaming and written to the transcript when it is whole.
pub const PLACE_SLACK_MS: i64 = 60 * 60 * 1000;
/// With no logged message holding the query (a message past the log's 64 KiB text bound), a hit
/// takes the nearest one of its role this close.
const PLACE_NEAR_MS: i64 = 2 * 60 * 1000;

/// Gives each hit of `hits` that `ours` passes the `seq` of the message in acpmux session `id`'s
/// log that holds it: the message of the hit's role (prompt, reply, tool call) whose text holds
/// `query` (as the index finds it: any case for ASCII letters) nearest the hit's time, within
/// [`PLACE_SLACK_MS`]; with none, the nearest of its role within [`PLACE_NEAR_MS`]. A hit with no
/// time, or none near, gets no `seq`. Reads the log's text copies once (`store/text_index.rs`, as
/// `_acpmux/session_search` does), never the whole log again, and only lowercases the messages
/// within the hits' span.
pub fn place(
    store: &dyn crate::store::Store,
    id: &str,
    query: &str,
    hits: &mut [Value],
    ours: &dyn Fn(&Value) -> bool,
) -> anyhow::Result<()> {
    use crate::session_search::Role;
    let role_of = |h: &Value| match h.get("role").and_then(Value::as_str) {
        Some("user") => Some(Role::User),
        Some("assistant") => Some(Role::Assistant),
        Some("tool") => Some(Role::Tool),
        _ => None,
    };
    let wanted: Vec<(usize, i64, Role)> = hits
        .iter()
        .enumerate()
        .filter(|(_, h)| ours(h))
        .filter_map(|(i, h)| Some((i, h.get("at").and_then(Value::as_i64)?, role_of(h)?)))
        .collect();
    let (Some(lo), Some(hi)) = (wanted.iter().map(|w| w.1).min(), wanted.iter().map(|w| w.1).max())
    else {
        return Ok(());
    };
    let (lo, hi) = (lo.saturating_sub(PLACE_SLACK_MS), hi.saturating_add(PLACE_SLACK_MS));
    let lower = query.trim().to_ascii_lowercase();
    // (at, seq, role, holds the query)
    let mut near: Vec<(i64, u64, Role, bool)> = Vec::new();
    store.text_entries(id, &mut |entry| {
        let at = i64::try_from(entry.at).unwrap_or(i64::MAX);
        if at < lo || at > hi {
            return;
        }
        let holds =
            memchr::memmem::find(entry.text.to_ascii_lowercase().as_bytes(), lower.as_bytes())
                .is_some();
        near.push((at, entry.seq, entry.role, holds));
    })?;
    for (i, at, role) in wanted {
        let nearest = |holds: bool, slack: i64| {
            near.iter()
                .filter(|n| n.2 == role && (n.3 || !holds) && (n.0 - at).abs() <= slack)
                .min_by_key(|n| ((n.0 - at).abs(), n.1))
                .map(|n| n.1)
        };
        if let Some(seq) = nearest(true, PLACE_SLACK_MS).or_else(|| nearest(false, PLACE_NEAR_MS))
            && let Some(hit) = hits.get_mut(i)
        {
            hit["seq"] = json!(seq);
        }
    }
    Ok(())
}

/// The chats windows' search of what was said past each chat's held text (`chats/deep.rs`): each
/// session's newest prompt or answer holding every word, from the index as the background read
/// keeps it (no transcript is read first: a keystroke never waits on a read). Its own connection,
/// opened on first use, so a long `_acpmux/transcript_search` never holds it up.
pub fn chat_search() -> crate::chats::deep::Search {
    let index: Mutex<Option<ts::Index>> = Mutex::new(None);
    Box::new(move |words| {
        let mut held = index.lock().unwrap_or_else(|e| e.into_inner());
        if held.is_none() {
            match ts::Index::open(&index_path()) {
                Ok(opened) => *held = Some(opened),
                Err(error) => {
                    tracing::warn!(%error, "transcript index: not opened for the chats search");
                    return None;
                }
            }
        }
        let index = held.as_ref()?;
        let t = Instant::now();
        match index.chats(words, crate::chats::deep::SCAN, crate::chats::deep::CONTEXT) {
            Ok(found) => {
                tracing::debug!(
                    chats = found.len(),
                    ms = t.elapsed().as_millis() as u64,
                    "transcript index: chats search"
                );
                Some(found)
            }
            Err(error) => {
                tracing::warn!(%error, "transcript index: chats search failed");
                None
            }
        }
    })
}

/// Keeps the index current in the background: every transcript once after the daemon starts,
/// then the ones the chat index says changed. Its own connection, so a search waits for it at
/// most one step (`STEP_BYTES` of one transcript).
pub fn warm(chats: Arc<crate::chats::ChatService>) {
    let mut changes = chats.subscribe();
    let service = Arc::downgrade(&chats);
    drop(chats);
    // task-owner: the chat service; ends when it is dropped (its change channel closes).
    let started = std::thread::Builder::new().name("acpmux-transcript-index".into()).spawn(move || {
        let index = match ts::Index::open(&index_path()) {
            Ok(index) => index,
            Err(error) => {
                tracing::warn!(%error, "transcript index: not opened");
                return;
            }
        };
        loop {
            let Some(live) = service.upgrade() else { return };
            let roots = roots(Some(&live));
            drop(live);
            let t = Instant::now();
            let mut done = ts::CatchUp::default();
            for source in roots.all() {
                match index.catch_up(&source) {
                    Ok(step) => {
                        done.bytes += step.bytes;
                        done.docs += step.docs;
                    }
                    Err(error) => tracing::debug!(%error, path = %source.path.display(), "transcript index: skipped"),
                }
            }
            if done.bytes > 0 {
                tracing::info!(bytes = done.bytes, docs = done.docs, ms = t.elapsed().as_millis() as u64, "transcript index: caught up");
            }
            match changes.blocking_recv() {
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
            }
            // A burst of changes (a turn writes many lines) settles into one pass.
            std::thread::sleep(Duration::from_secs(2));
            while matches!(
                changes.try_recv(),
                Ok(_) | Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_))
            ) {}
        }
    });
    if let Err(error) = started {
        tracing::warn!(%error, "transcript index: thread not started");
    }
}

#[cfg(test)]
#[path = "transcript_search_tests.rs"]
mod tests;
