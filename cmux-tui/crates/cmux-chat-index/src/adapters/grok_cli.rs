//! superagent-ai grok-cli (`grok-dev`, 1.0.0-rc1+): one SQLite store,
//! `~/.grok/grok.db` (WAL), tables `sessions` and `messages`. Releases
//! before 1.0 kept history in memory only. Times are ISO strings.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::sqlite::{columns, open_read_only};
use crate::text::{prompt_text, title_line};
use crate::time::parse_rfc3339_ms;

const DB: &str = "grok.db";

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let db = root.join(DB);
    if !db.is_file() {
        return Ok(Vec::new());
    }
    // A failing DB fails the scan: the index keeps its last result.
    open_read_only(&db).and_then(|conn| query(&conn, &db)).map_err(io::Error::other)
}

fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
    if cols.contains(name) { name } else { "NULL" }
}

fn query(conn: &Connection, db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let cols = columns(conn, "sessions")?;
    if !cols.contains("id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| pick(&cols, name);
    let sql = format!(
        "SELECT id, {title}, {cwd_last}, {cwd_start}, {created}, {updated} FROM sessions",
        title = col("title"),
        cwd_last = col("cwd_last"),
        cwd_start = col("cwd_at_start"),
        created = col("created_at"),
        updated = col("updated_at"),
    );
    let messages = columns(conn, "messages").unwrap_or_default();
    let has_messages =
        ["session_id", "seq", "role", "message_json"].iter().all(|c| messages.contains(*c));
    let counts = if has_messages { message_counts(conn) } else { None };
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
            row.get::<_, Option<String>>(5)?,
        ))
    })?;
    let mut entries = Vec::new();
    for row in rows {
        let (id, title, cwd_last, cwd_start, created, updated) = row?;
        let (title, title_source) = match title.as_deref().and_then(title_line) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => {
                let typed = if has_messages { first_prompt(conn, &id) } else { None };
                let source = typed.as_ref().map(|_| TitleSource::Prompt);
                (typed, source)
            }
        };
        let created_ms = created.as_deref().and_then(parse_rfc3339_ms);
        let nonempty = |value: Option<String>| value.filter(|value| !value.is_empty());
        entries.push(ChatEntry {
            harness: AdapterKind::GrokCli,
            title,
            title_source,
            cwd: nonempty(cwd_last).or_else(|| nonempty(cwd_start)),
            created_ms,
            updated_ms: updated.as_deref().and_then(parse_rfc3339_ms).or(created_ms).unwrap_or(0),
            message_count: counts.as_ref().map(|counts| counts.get(&id).copied().unwrap_or(0)),
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
    let mut stmt = conn
        .prepare(
            "SELECT session_id, count(*) FROM messages
             WHERE role IN ('user', 'assistant') GROUP BY session_id",
        )
        .ok()?;
    let rows =
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).ok()?;
    rows.map(|row| row.map(|(id, count)| (id, u64::try_from(count).unwrap_or(0))))
        .collect::<Result<_, _>>()
        .ok()
}

/// The first user message (an AI SDK `ModelMessage`) by `seq`.
fn first_prompt(conn: &Connection, session: &str) -> Option<String> {
    let json: String = conn
        .query_row(
            "SELECT message_json FROM messages WHERE session_id = ?1 AND role = 'user'
             ORDER BY seq LIMIT 1",
            [session],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()???;
    let message: Value = serde_json::from_str(&json).ok()?;
    message.get("content").and_then(prompt_text)
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    role(false, matches!(parts, [name] if *name == DB || *name == "grok.db-wal"))
}
