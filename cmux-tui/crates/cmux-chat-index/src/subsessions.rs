//! A chat's sub-sessions: the agents it started that run inside its harness (Claude Code's Task
//! subagents, Codex's spawned threads), read from the harness's own store, at any depth, so the
//! sidebar can list them under the chat (`sidebar.nestedSessions`). Metadata only: an id, the
//! agent's parent, a short title, its kind and where it stands; never a transcript.
//!
//! - Claude Code (2.1.2+): `<session>/subagents/agent-<id>.meta.json` beside
//!   `agent-<id>.jsonl`. The meta names the task (`description`), the agent type, the agent that
//!   started it (`parentAgentId`; none at depth 1, the chat itself) and `finished`. The transcript's
//!   modification time says when it last moved.
//! - Codex: `thread_spawn_edges (parent_thread_id, child_thread_id, status)` in the home's newest
//!   `state_<n>.sqlite`, walked down from the chat's thread; each child's `threads` row gives its
//!   name or nickname and when it last moved.
//!
//! Other harnesses keep no sub-session store this reads; their chats have none here.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::entry::{AdapterKind, ChatEntry};
use crate::sqlite::{columns, open_read_only};
use crate::text::title_line;

/// A sub-session whose store moved this recently, and that has not said it finished, is running.
pub const RUNNING_WITHIN_MS: i64 = 120_000;
/// Most sub-sessions one read returns: the ones that moved last. A coordinator chat can hold
/// thousands (one on this team's Mac held 1,527); the sidebar lists the newest.
pub const MAX_SUBSESSIONS: usize = 200;
/// Deepest nesting walked below the chat (`agents.subsessions.maxDepth`'s default).
pub const MAX_DEPTH: usize = 10;
/// Characters of a Codex thread's title read (`title_line` then cuts it to a title).
const TITLE_CHARS: usize = 400;

/// Where a sub-session stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SubSessionState {
    /// Its store moved within [`RUNNING_WITHIN_MS`] and it has not finished.
    Running,
    /// It said it finished.
    Done,
    /// Its harness recorded a failure.
    Failed,
    /// Neither running nor known finished: stopped, or from a harness version that does not say.
    Idle,
}

/// One sub-session of a chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubSession {
    /// The harness's id for it (Claude Code's agent id, Codex's thread id).
    pub id: String,
    /// The sub-session that started it; `None` when the chat itself did.
    pub parent_id: Option<String>,
    /// What it was asked to do, one line (Claude Code's task description, Codex's thread name).
    pub title: Option<String>,
    /// Its kind (Claude Code's agent type, Codex's agent role), when the harness names one.
    pub kind: Option<String>,
    pub state: SubSessionState,
    /// How deep below the chat: 1 for one the chat started.
    pub depth: u32,
    /// When it last moved, in milliseconds since the epoch.
    pub updated_ms: i64,
}

/// The sub-sessions of `chat`, newest first, at most [`MAX_SUBSESSIONS`]; `now_ms` decides which
/// run. Empty for a harness without a sub-session store, or when the store cannot be read. A
/// parent the list leaves out (past the cap) leaves its child at the chat (`parent_id: None`), so
/// every listed sub-session hangs under something listed.
pub fn subsessions(chat: &ChatEntry, now_ms: i64) -> Vec<SubSession> {
    let mut found = match chat.harness {
        AdapterKind::ClaudeCode => claude(&chat.source_path, now_ms).unwrap_or_default(),
        AdapterKind::Codex => {
            codex(&chat.source_path, &chat.session_id, now_ms).unwrap_or_default()
        }
        _ => Vec::new(),
    };
    found.sort_by(|a, b| b.updated_ms.cmp(&a.updated_ms).then_with(|| a.id.cmp(&b.id)));
    found.truncate(MAX_SUBSESSIONS);
    let listed: HashSet<String> = found.iter().map(|s| s.id.clone()).collect();
    for sub in &mut found {
        if sub.parent_id.as_ref().is_some_and(|parent| !listed.contains(parent)) {
            sub.parent_id = None;
        }
    }
    found
}

fn state(finished: bool, failed: bool, updated_ms: i64, now_ms: i64) -> SubSessionState {
    if failed {
        SubSessionState::Failed
    } else if finished {
        SubSessionState::Done
    } else if now_ms.saturating_sub(updated_ms) <= RUNNING_WITHIN_MS {
        SubSessionState::Running
    } else {
        SubSessionState::Idle
    }
}

fn short(text: &str) -> Option<String> {
    title_line(text)
}

fn mtime_ms(meta: &fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Claude Code: `<session>.jsonl` keeps its subagents in `<session>/subagents/`.
fn claude(transcript: &Path, now_ms: i64) -> io::Result<Vec<SubSession>> {
    let dir = transcript.with_extension("").join("subagents");
    // Every agent's newest time first (a stat each), then the meta of the newest only.
    let mut agents: Vec<(String, i64, PathBuf)> = Vec::new();
    for child in fs::read_dir(&dir)?.flatten() {
        let name = child.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_prefix("agent-")?.strip_suffix(".meta.json"))
            .map(str::to_owned)
        else {
            continue;
        };
        let meta_time = child.metadata().map(|m| mtime_ms(&m)).unwrap_or(0);
        let log_time =
            fs::metadata(dir.join(format!("agent-{id}.jsonl"))).map(|m| mtime_ms(&m)).unwrap_or(0);
        agents.push((id, meta_time.max(log_time), child.path()));
    }
    agents.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    agents.truncate(MAX_SUBSESSIONS);
    let mut found = Vec::with_capacity(agents.len());
    for (id, updated_ms, path) in agents {
        let Ok(text) = fs::read(&path) else { continue };
        let Ok(meta) = serde_json::from_slice::<Value>(&text) else { continue };
        let str_of = |key: &str| meta.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
        let finished = meta.get("finished").and_then(Value::as_bool).unwrap_or(false);
        let failed = meta.get("failed").and_then(Value::as_bool).unwrap_or(false)
            || str_of("error").is_some();
        let depth = meta
            .get("spawnDepth")
            .and_then(Value::as_u64)
            .and_then(|d| u32::try_from(d).ok())
            .filter(|d| *d >= 1)
            .unwrap_or(1);
        found.push(SubSession {
            parent_id: str_of("parentAgentId").filter(|p| *p != id).map(str::to_owned),
            title: str_of("description").and_then(short),
            kind: str_of("agentType").map(str::to_owned),
            state: state(finished, failed, updated_ms, now_ms),
            depth,
            updated_ms,
            id,
        });
    }
    Ok(found)
}

/// The Codex home that holds `path`: the nearest folder above it with a `state_<n>.sqlite` (a
/// rollout sits at `<home>/sessions/<y>/<m>/<d>/`; a thread without one names the database).
fn codex_db(path: &Path) -> Option<PathBuf> {
    if path.extension().is_some_and(|ext| ext == "sqlite") && path.is_file() {
        return Some(path.to_path_buf());
    }
    path.ancestors()
        .skip(1)
        .take(6)
        .find_map(|dir| crate::adapters::newest_state_db(dir).ok().flatten())
}

fn codex(source: &Path, thread: &str, now_ms: i64) -> rusqlite::Result<Vec<SubSession>> {
    let Some(db) = codex_db(source) else { return Ok(Vec::new()) };
    let conn = open_read_only(&db)?;
    let edges = columns(&conn, "thread_spawn_edges")?;
    if !edges.contains("parent_thread_id") || !edges.contains("child_thread_id") {
        return Ok(Vec::new());
    }
    let have = columns(&conn, "threads")?;
    let column = |name: &str| {
        if have.contains(name) { format!("t.{name}") } else { "NULL".to_owned() }
    };
    let updated = if have.contains("updated_at_ms") {
        "t.updated_at_ms".to_owned()
    } else if have.contains("updated_at") {
        "t.updated_at * 1000".to_owned()
    } else {
        "NULL".to_owned()
    };
    let status = if edges.contains("status") { "e.status" } else { "NULL" };
    // The edges under `thread`, breadth first, each once (UNION drops a repeat, so a cycle ends).
    let sql = format!(
        "WITH RECURSIVE tree(parent, child, status, depth) AS (
             SELECT e.parent_thread_id, e.child_thread_id, {status}, 1
               FROM thread_spawn_edges e WHERE e.parent_thread_id = ?1
             UNION
             SELECT e.parent_thread_id, e.child_thread_id, {status}, tree.depth + 1
               FROM thread_spawn_edges e JOIN tree ON e.parent_thread_id = tree.child
              WHERE tree.depth < {MAX_DEPTH}
         )
         SELECT tree.parent, tree.child, tree.status, tree.depth, {name}, {nickname}, {role},
                substr({title}, 1, {TITLE_CHARS}), {updated}
           FROM tree LEFT JOIN threads t ON t.id = tree.child",
        name = column("name"),
        nickname = column("agent_nickname"),
        role = column("agent_role"),
        title = column("title"),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([thread], |row| {
        let text = |i: usize| -> rusqlite::Result<Option<String>> {
            Ok(row.get::<_, Option<String>>(i)?.filter(|s| !s.is_empty()))
        };
        Ok((
            text(0)?.unwrap_or_default(),
            text(1)?.unwrap_or_default(),
            text(2)?,
            row.get::<_, Option<i64>>(3)?.unwrap_or(1),
            [text(4)?, text(5)?, text(7)?],
            text(6)?,
            row.get::<_, Option<i64>>(8)?.unwrap_or(0),
        ))
    })?;
    let mut seen: HashMap<String, SubSession> = HashMap::new();
    for row in rows {
        let (parent, child, status, depth, titles, role, updated_ms) = row?;
        if child.is_empty() || child == thread || seen.contains_key(&child) {
            continue;
        }
        let status = status.unwrap_or_default().to_ascii_lowercase();
        let failed = status.contains("fail") || status.contains("error");
        let finished = !failed && !status.is_empty() && status != "open" && status != "running";
        seen.insert(
            child.clone(),
            SubSession {
                parent_id: (parent != thread).then_some(parent),
                title: titles.into_iter().flatten().find_map(|t| short(&t)),
                kind: role,
                state: state(finished, failed, updated_ms, now_ms),
                depth: u32::try_from(depth.max(1)).unwrap_or(1),
                updated_ms,
                id: child,
            },
        );
    }
    Ok(seen.into_values().collect())
}

#[cfg(test)]
#[path = "subsessions_tests.rs"]
mod tests;
