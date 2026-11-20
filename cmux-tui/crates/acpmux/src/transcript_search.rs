//! `_acpmux/transcript_search {query, sessionId?, harnessSessionId?, role?, sinceMs?, limit?,
//! context?, host?}` and `acpmux search` (Leo, 2026-11-18: "shouldn't you be able to like have
//! better tools for finding stuff?"): what was said in the Claude Code and Codex transcripts on
//! this machine (and with `host: "all"` its peers'), newest first, from the index
//! `acpmux-transcript-search` keeps at `$ACPMUX_HOME/transcript-search/index-v1.sqlite`.
//!
//! Every session's transcript, not only the chats acpmux runs: a Claude desktop chat, a terminal
//! `claude`, a Codex thread, their subagents, and the turns before a compaction. A search first
//! reads what the transcripts it covers appended since the last one (cost: those bytes), then asks
//! the index. The daemon fills the index for every transcript after it starts and follows the chat
//! index's changes (`warm`), so a search seldom reads anything.
//!
//! Answer: `{hits: [{host, sessionId, harness, path, subagent, turn, line, at, role, snippet,
//! matchStart, matchLen, cutBefore, cutAfter}], files, caughtUpBytes, catchUpMs, queryMs, tookMs,
//! unreached: [{host, error}]}`. `sessionId` is the harness's session id (a Claude Code session, a
//! Codex thread); `snippet` is the text as written (real line breaks), `matchStart`/`matchLen` in
//! bytes within it.
//!
//! What a chat said is its person's: the daemon answers this on its own socket, to the app, and
//! to its peers (the same person's machines) only.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use acpmux_transcript_search as ts;
use serde_json::{Value, json};

pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 200;
pub const DEFAULT_CONTEXT: usize = 300;
const MAX_CONTEXT: usize = 4000;
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
        Ok(Self {
            query,
            session: text("sessionId"),
            harness_session: text("harnessSessionId"),
            role,
            since_ms: v.get("sinceMs").and_then(Value::as_i64),
            limit: limit.clamp(1, MAX_LIMIT),
            context: context.min(MAX_CONTEXT),
            host: text("host"),
        })
    }

    pub fn to_value(&self) -> Value {
        let mut v = json!({"query": self.query, "limit": self.limit, "context": self.context});
        let mut put = |k: &str, x: Value| {
            if !x.is_null() {
                v[k] = x;
            }
        };
        put("sessionId", json!(self.session));
        put("harnessSessionId", json!(self.harness_session));
        put("role", json!(self.role));
        put("sinceMs", json!(self.since_ms));
        put("host", json!(self.host));
        v
    }

    fn query(&self) -> ts::Query {
        let mut q = ts::Query::new(self.query.trim());
        q.sessions = self.harness_session.clone().map(|s| vec![s]);
        q.role = self.role.as_deref().and_then(ts::Role::parse);
        q.since_ms = self.since_ms;
        q.limit = self.limit;
        q.context = self.context;
        q
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
    Ok(json!({
        "hits": hits.iter().map(|h| hit_value(h, host)).collect::<Vec<_>>(),
        "files": done.files,
        "caughtUpBytes": done.caught_up.bytes,
        "catchUpMs": done.catch_up_ms,
        "queryMs": done.query_ms,
        "tookMs": started.elapsed().as_millis() as u64,
        "unreached": [],
    }))
}

fn hit_value(h: &ts::Hit, host: Option<&str>) -> Value {
    json!({
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
    })
}

/// Puts the hits of several answers (this machine's and its peers') in one, newest first.
pub fn merge(mut answers: Vec<Value>, unreached: Vec<Value>, limit: usize, took_ms: u64) -> Value {
    let mut hits: Vec<Value> = answers
        .iter_mut()
        .flat_map(|a| {
            a.get_mut("hits").and_then(Value::as_array_mut).map(std::mem::take).unwrap_or_default()
        })
        .collect();
    hits.sort_by_key(|h| {
        std::cmp::Reverse(h.get("at").and_then(Value::as_i64).unwrap_or(i64::MIN))
    });
    hits.truncate(limit);
    let sum =
        |k: &str| answers.iter().filter_map(|a| a.get(k).and_then(Value::as_u64)).sum::<u64>();
    let max = |k: &str| {
        answers.iter().filter_map(|a| a.get(k).and_then(Value::as_u64)).max().unwrap_or(0)
    };
    let mut unreached = unreached;
    for a in &answers {
        unreached.extend(a.get("unreached").and_then(Value::as_array).cloned().unwrap_or_default());
    }
    json!({
        "hits": hits,
        "files": sum("files"),
        "caughtUpBytes": sum("caughtUpBytes"),
        "catchUpMs": max("catchUpMs"),
        "queryMs": max("queryMs"),
        "tookMs": took_ms,
        "unreached": unreached,
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
