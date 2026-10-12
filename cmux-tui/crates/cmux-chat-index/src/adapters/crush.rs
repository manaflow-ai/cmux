//! Charm Crush: one SQLite store per project, `<data dir>/crush.db` (WAL),
//! where the data dir is usually `<project>/.crush`. The global
//! `projects.json` (v0.25.0+) names the data dirs; discovery turns each into
//! a root so guarded folders are refused before any read. Times are Unix
//! seconds. Sub-sessions (titles, tool calls) have a parent.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::sqlite::{columns, open_read_only};
use crate::store_file::read_json_bounded;
use crate::text::{prompt_text, title_line};

const DB: &str = "crush.db";
const INDEX_MAX: u64 = 1 << 20;

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let db = root.join(DB);
    if !db.is_file() {
        return Ok(Vec::new());
    }
    let cwd = (root.file_name().and_then(|name| name.to_str()) == Some(".crush"))
        .then(|| root.parent().map(|dir| dir.display().to_string()))
        .flatten();
    // A failing DB fails the scan: the index keeps its last result.
    open_read_only(&db).and_then(|conn| query(&conn, &db, cwd.as_deref())).map_err(io::Error::other)
}

fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
    if cols.contains(name) { name } else { "NULL" }
}

/// Seconds to milliseconds; a value already in milliseconds is kept.
fn to_ms(value: i64) -> i64 {
    if value > 100_000_000_000 { value } else { value.saturating_mul(1000) }
}

fn query(conn: &Connection, db: &Path, cwd: Option<&str>) -> rusqlite::Result<Vec<ChatEntry>> {
    let cols = columns(conn, "sessions")?;
    if !cols.contains("id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| pick(&cols, name);
    let top_level =
        if cols.contains("parent_session_id") { "parent_session_id IS NULL" } else { "1 = 1" };
    let sql = format!(
        "SELECT id, {title}, {count}, {created}, {updated} FROM sessions WHERE {top_level}",
        title = col("title"),
        count = col("message_count"),
        created = col("created_at"),
        updated = col("updated_at"),
    );
    let message_cols = columns(conn, "messages").unwrap_or_default();
    let has_messages = ["session_id", "role", "parts"].iter().all(|c| message_cols.contains(*c));
    let order = if message_cols.contains("created_at") { "created_at, id" } else { "rowid" };
    let counts =
        if cols.contains("message_count") || !has_messages { None } else { message_counts(conn) };
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
        ))
    })?;
    let mut entries = Vec::new();
    for row in rows {
        let (id, title, count, created, updated) = row?;
        let (title, title_source) = match title.as_deref().and_then(title_line) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => {
                let typed = if has_messages { first_prompt(conn, &id, order) } else { None };
                let source = typed.as_ref().map(|_| TitleSource::Prompt);
                (typed, source)
            }
        };
        let created_ms = created.map(to_ms);
        let count = count
            .and_then(|count| u64::try_from(count).ok())
            .or_else(|| counts.as_ref().map(|counts| counts.get(&id).copied().unwrap_or(0)));
        entries.push(ChatEntry {
            harness: AdapterKind::Crush,
            title,
            title_source,
            cwd: cwd.map(str::to_owned),
            created_ms,
            updated_ms: updated.map(to_ms).or(created_ms).unwrap_or(0),
            message_count: count,
            source_path: db.to_path_buf(),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
            session_id: id,
        });
    }
    Ok(entries)
}

fn message_counts(conn: &Connection) -> Option<HashMap<String, u64>> {
    let mut stmt =
        conn.prepare("SELECT session_id, count(*) FROM messages GROUP BY session_id").ok()?;
    let rows =
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).ok()?;
    rows.map(|row| row.map(|(id, count)| (id, u64::try_from(count).unwrap_or(0))))
        .collect::<Result<_, _>>()
        .ok()
}

/// The first text part (`{"type":"text","data":{"text":...}}`) of the
/// first user message.
fn first_prompt(conn: &Connection, session: &str, order: &str) -> Option<String> {
    let sql = format!(
        "SELECT parts FROM messages WHERE session_id = ?1 AND role = 'user' ORDER BY {order} LIMIT 1"
    );
    let parts: String = conn
        .query_row(&sql, [session], |row| row.get::<_, Option<String>>(0))
        .optional()
        .ok()???;
    let parts: Value = serde_json::from_str(&parts).ok()?;
    parts.as_array()?.iter().find_map(|part| {
        if part.get("type").and_then(Value::as_str) != Some("text")
            || part.pointer("/data/hidden") == Some(&Value::Bool(true))
        {
            return None;
        }
        part.pointer("/data/text").and_then(prompt_text)
    })
}

/// The project data dirs a Crush `projects.json` lists, absolute.
pub(crate) fn project_data_dirs(index: &Path) -> Vec<PathBuf> {
    let Some(file) = read_json_bounded::<Value>(index, INDEX_MAX) else { return Vec::new() };
    let mut out: Vec<PathBuf> = Vec::new();
    for project in file.get("projects").and_then(Value::as_array).into_iter().flatten() {
        let text = |key: &str| {
            project
                .get(key)
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
                .map(PathBuf::from)
        };
        let Some(data_dir) = text("data_dir") else { continue };
        let dir = if data_dir.is_absolute() {
            data_dir
        } else {
            match text("path").filter(|path| path.is_absolute()) {
                Some(path) => path.join(data_dir),
                None => continue,
            }
        };
        if !out.contains(&dir) {
            out.push(dir);
        }
    }
    out
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    role(false, matches!(parts, [name] if *name == DB || *name == "crush.db-wal"))
}
