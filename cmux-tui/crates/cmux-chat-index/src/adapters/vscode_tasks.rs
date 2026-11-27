//! Cline and its forks (Roo Code, the Kilo Code extension): task stores in a
//! VS Code globalStorage dir (`<UserData>/User/globalStorage/<extension>`)
//! or a CLI data dir (`~/.cline/data`, `~/.kilocode/cli/global`). Every
//! generation can be on disk at once; a task id seen in an earlier source
//! wins, in this order:
//!
//! 1. Cline SDK (CLI 3.x, extension 4.x): `db/sessions.db`, table `sessions`.
//! 2. Cline 3.28-3.89 and its CLI: `state/taskHistory.json` (`HistoryItem[]`).
//! 3. Roo Code 3.49+: `tasks/_index.json` and `tasks/<id>/history_item.json`.
//! 4. Kilo Code CLI 0.x: `global-state.json` key `taskHistory`.
//! 5. Any `tasks/<id>/` dir left (Cline before 3.28 and every extension
//!    whose index is only in VS Code's `state.vscdb`, which is never opened):
//!    the first entry of `ui_messages.json` (`claude_messages.json` before
//!    Cline 2.2) names the task.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::scan::AdapterConfig;
use crate::sqlite::{columns, open_read_only};
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field, title_line};
use crate::time::parse_rfc3339_ms;

pub(super) fn read_store(kind: AdapterKind, root: &Path) -> io::Result<Vec<ChatEntry>> {
    let mut found = Found { kind, seen: HashSet::new(), entries: Vec::new() };
    let db = root.join("db/sessions.db");
    if db.is_file() {
        // A failing DB fails the scan: the index keeps its last result.
        let sessions = open_read_only(&db)
            .and_then(|conn| sdk_sessions(kind, &conn, &db))
            .map_err(io::Error::other)?;
        for entry in sessions {
            found.push(entry);
        }
    }
    let history = root.join("state/taskHistory.json");
    if let Ok(Some(items)) = read_whole_json(&history) {
        found.history(items.as_array().map(Vec::as_slice), &history);
    }
    let tasks = task_dirs(&root.join("tasks"));
    let roo_index = root.join("tasks/_index.json");
    if let Ok(Some(index)) = read_whole_json(&roo_index) {
        let entries = index.get("entries").and_then(Value::as_array);
        found.history(entries.map(Vec::as_slice), &roo_index);
    }
    for dir in &tasks {
        let path = dir.join("history_item.json");
        if let Ok(Some(item)) = read_whole_json(&path) {
            found.history(Some(std::slice::from_ref(&item)), &path);
        }
    }
    let kilo = root.join("global-state.json");
    if let Ok(Some(state)) = read_whole_json(&kilo) {
        found.history(state.get("taskHistory").and_then(Value::as_array).map(Vec::as_slice), &kilo);
    }
    for dir in &tasks {
        let Some(id) = dir.file_name().and_then(|name| name.to_str()) else { continue };
        if !found.seen.contains(id)
            && let Some(entry) = task_dir_entry(kind, id, dir)
        {
            found.push(entry);
        }
    }
    Ok(found.entries)
}

struct Found {
    kind: AdapterKind,
    seen: HashSet<String>,
    entries: Vec<ChatEntry>,
}

impl Found {
    fn push(&mut self, entry: ChatEntry) {
        if self.seen.insert(entry.session_id.clone()) {
            self.entries.push(entry);
        }
    }

    /// `HistoryItem {id, ts, task, cwdOnTaskInitialization | workspace,
    /// parentTaskId}`; subtasks are not listed.
    fn history(&mut self, items: Option<&[Value]>, source: &Path) {
        for item in items.into_iter().flatten() {
            let Some(id) = item.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())
            else {
                continue;
            };
            if item.get("parentTaskId").is_some_and(|parent| !parent.is_null()) {
                continue;
            }
            let title = item.get("task").and_then(prompt_text);
            let cwd = ["cwdOnTaskInitialization", "workspace"]
                .iter()
                .find_map(|key| item.get(*key).and_then(Value::as_str))
                .filter(|cwd| !cwd.is_empty())
                .map(str::to_owned);
            let updated_ms = item.get("ts").and_then(Value::as_i64).unwrap_or(0);
            let entry = entry(self.kind, id, title, cwd, None, updated_ms, source);
            self.push(entry);
        }
    }
}

fn entry(
    kind: AdapterKind,
    id: &str,
    title: Option<String>,
    cwd: Option<String>,
    created_ms: Option<i64>,
    updated_ms: i64,
    source: &Path,
) -> ChatEntry {
    ChatEntry {
        harness: kind,
        session_id: id.to_owned(),
        title_source: title.as_ref().map(|_| TitleSource::Prompt),
        title,
        cwd,
        created_ms,
        updated_ms,
        message_count: None,
        source_path: source.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::ReadOnly,
    }
}

/// The Cline SDK session table; subagent runs are left out.
fn sdk_sessions(
    kind: AdapterKind,
    conn: &Connection,
    db: &Path,
) -> rusqlite::Result<Vec<ChatEntry>> {
    let cols = columns(conn, "sessions")?;
    if !cols.contains("session_id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| if cols.contains(name) { name } else { "NULL" };
    let mut filters = vec!["1 = 1"];
    if cols.contains("parent_session_id") {
        filters.push("parent_session_id IS NULL");
    }
    if cols.contains("is_subagent") {
        filters.push("coalesce(is_subagent, 0) = 0");
    }
    let title = if cols.contains("metadata_json") {
        "CASE WHEN json_valid(metadata_json) THEN json_extract(metadata_json, '$.title') END"
    } else {
        "NULL"
    };
    let sql = format!(
        "SELECT session_id, {title}, {prompt}, {cwd}, {root}, {started}, {updated}, {ended}
         FROM sessions WHERE {filters}",
        prompt = col("prompt"),
        cwd = col("cwd"),
        root = col("workspace_root"),
        started = col("started_at"),
        updated = col("updated_at"),
        ended = col("ended_at"),
        filters = filters.join(" AND "),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        // A column of another type reads as missing, not as an error.
        let text = |index: usize| row.get::<_, Option<String>>(index).ok().flatten();
        let time = |index: usize| text(index).as_deref().and_then(parse_rfc3339_ms);
        let id: String = row.get(0)?;
        let (title, source) = match text(1).as_deref().and_then(title_line) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => {
                let prompt = text(2).map(Value::String).as_ref().and_then(prompt_text);
                let source = prompt.as_ref().map(|_| TitleSource::Prompt);
                (prompt, source)
            }
        };
        let cwd = text(3).filter(|cwd| !cwd.is_empty()).or_else(|| text(4));
        let cwd = cwd.filter(|cwd| !cwd.is_empty());
        let created_ms = time(5);
        let updated_ms = time(6).or_else(|| time(7)).or(created_ms).unwrap_or(0);
        let mut chat = entry(kind, &id, title, cwd, created_ms, updated_ms, db);
        chat.title_source = source;
        Ok(chat)
    })?;
    Ok(rows.flatten().collect())
}

/// Task dirs under `tasks/`, newest first, at most the per-root file bound.
fn task_dirs(tasks: &Path) -> Vec<PathBuf> {
    let Ok(children) = fs::read_dir(tasks) else { return Vec::new() };
    let mut dirs: Vec<(PathBuf, i64)> = children
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter(|child| {
            child.file_name().to_str().is_some_and(|name| !name.starts_with(['_', '.']))
        })
        .map(|child| {
            let mtime = child.metadata().map(|meta| FileStamp::of(&meta).mtime_ms).unwrap_or(0);
            (child.path(), mtime)
        })
        .collect();
    dirs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    dirs.truncate(AdapterConfig::DEFAULT_MAX_FILES);
    dirs.into_iter().map(|(dir, _)| dir).collect()
}

/// A task with no index entry: its first UI message `{ts, say: "task", text}`.
fn task_dir_entry(kind: AdapterKind, id: &str, dir: &Path) -> Option<ChatEntry> {
    let file = ["ui_messages.json", "claude_messages.json"]
        .iter()
        .map(|name| dir.join(name))
        .find(|path| path.is_file())?;
    let updated_ms = fs::metadata(&file).map(|meta| FileStamp::of(&meta).mtime_ms).unwrap_or(0);
    // Only the head: the first messages name the task, and the file grows
    // with the whole transcript.
    let messages = crate::lines::read_array_head(&file, 256 * 1024, 8).unwrap_or_default();
    let first = messages.first();
    let created_ms = first.and_then(|message| message.get("ts")).and_then(Value::as_i64);
    let title = messages.iter().find_map(|message| {
        let is_task = message.get("say").and_then(Value::as_str) == Some("task");
        is_task.then(|| title_field(message.get("text"))).flatten()
    });
    let title = title.or_else(|| first.and_then(|message| title_field(message.get("text"))));
    Some(entry(kind, id, title, None, created_ms, updated_ms.max(created_ms.unwrap_or(0)), &file))
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let store = match parts {
        ["db", name] => matches!(*name, "sessions.db" | "sessions.db-wal"),
        ["state", "taskHistory.json"] | ["tasks", "_index.json"] | ["global-state.json"] => true,
        // A new task dir; its message files change on every streamed token
        // and are left to the next scan.
        ["tasks", _] => true,
        ["tasks", _, name] => matches!(*name, "history_item.json" | "task_metadata.json"),
        _ => false,
    };
    role(false, store)
}
