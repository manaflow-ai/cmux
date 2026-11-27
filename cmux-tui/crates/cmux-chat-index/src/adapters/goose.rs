//! goose: the sessions dir (`<XDG data>/goose/sessions`, Windows
//! `%APPDATA%\Block\goose\data\sessions`) holds two generations side by side.
//!
//! - SQLite `sessions.db` (v1.10.0+): tables `sessions` and `messages`.
//! - Legacy `<id>.jsonl` (up to v1.9.x): line 1 is metadata
//!   (`description`, `message_count`, `working_dir`; v1.0.11+), then messages.
//!   The DB import keeps the files, so a DB row wins over a file of the same id.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use super::{PathRole, argv, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_first_record;
use crate::scan::AdapterConfig;
use crate::sqlite::{columns, open_read_only};
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field, title_line};
use crate::time::parse_rfc3339_ms;

const DB: &str = "sessions.db";

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let db = root.join(DB);
    let mut entries = if db.is_file() {
        // A failing DB fails the scan: the index keeps its last result.
        open_read_only(&db).and_then(|conn| query(&conn, &db)).map_err(io::Error::other)?
    } else {
        Vec::new()
    };
    let known: HashSet<String> = entries.iter().map(|entry| entry.session_id.clone()).collect();
    for path in legacy_files(root)? {
        let Some(id) = file_stem(&path) else { continue };
        if known.contains(&id) {
            continue;
        }
        if let Some(entry) = read_legacy(&path, id) {
            entries.push(entry);
        }
    }
    Ok(entries)
}

fn resume(id: &str) -> Resume {
    Resume::Argv {
        argv: argv(&["goose", "session", "--resume", "--session-id", id]),
        cwd_needed: true,
    }
}

fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
    if cols.contains(name) { name } else { "NULL" }
}

/// A `TIMESTAMP` cell: `YYYY-MM-DD HH:MM:SS` (UTC), RFC 3339, or a number
/// (seconds, or milliseconds above 1e11).
fn time_ms(cell: ValueRef<'_>) -> Option<i64> {
    match cell {
        ValueRef::Text(text) => std::str::from_utf8(text).ok().and_then(parse_rfc3339_ms),
        ValueRef::Integer(value) => {
            Some(if value > 100_000_000_000 { value } else { value.saturating_mul(1000) })
        }
        _ => None,
    }
}

struct Row {
    id: String,
    name: Option<String>,
    description: Option<String>,
    cwd: Option<String>,
    created_ms: Option<i64>,
    updated_ms: Option<i64>,
    archived: bool,
}

fn query(conn: &Connection, db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let cols = columns(conn, "sessions")?;
    if !cols.contains("id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| pick(&cols, name);
    let mut filters = vec!["1 = 1"];
    if cols.contains("parent_session_id") {
        filters.push("(parent_session_id IS NULL OR parent_session_id = '')");
    }
    if cols.contains("session_type") {
        filters.push("(session_type IS NULL OR session_type IN ('', 'user'))");
    }
    let sql = format!(
        "SELECT id, {name}, {description}, {cwd}, {created}, {updated}, {archived} FROM sessions WHERE {filters}",
        name = col("name"),
        description = col("description"),
        cwd = col("working_dir"),
        created = col("created_at"),
        updated = col("updated_at"),
        archived = col("archived_at"),
        filters = filters.join(" AND "),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows: Vec<Row> = stmt
        .query_map([], |row| {
            Ok(Row {
                id: row.get(0)?,
                name: row.get(1)?,
                description: row.get(2)?,
                cwd: row.get(3)?,
                created_ms: time_ms(row.get_ref(4)?),
                updated_ms: time_ms(row.get_ref(5)?),
                archived: !matches!(row.get_ref(6)?, ValueRef::Null),
            })
        })?
        .collect::<rusqlite::Result<_>>()?;
    let message_cols = columns(conn, "messages").unwrap_or_default();
    let has_messages =
        ["session_id", "role", "content_json"].iter().all(|c| message_cols.contains(*c));
    let counts = if has_messages { message_counts(conn, &message_cols) } else { None };
    let order =
        if message_cols.contains("created_timestamp") { "created_timestamp, id" } else { "id" };
    Ok(rows
        .into_iter()
        .map(|row| {
            let named = row.name.as_deref().and_then(title_line);
            let described = row.description.as_deref().and_then(title_line);
            let (title, title_source) = match (named, described) {
                (Some(name), _) => (Some(name), Some(TitleSource::Custom)),
                (None, Some(description)) => (Some(description), Some(TitleSource::Ai)),
                (None, None) => {
                    let typed =
                        if has_messages { first_prompt(conn, &row.id, order) } else { None };
                    let source = typed.as_ref().map(|_| TitleSource::Prompt);
                    (typed, source)
                }
            };
            ChatEntry {
                harness: AdapterKind::Goose,
                title,
                title_source,
                cwd: row.cwd.filter(|cwd| !cwd.is_empty()),
                created_ms: row.created_ms,
                updated_ms: row.updated_ms.or(row.created_ms).unwrap_or(0),
                message_count: counts
                    .as_ref()
                    .map(|counts| counts.get(&row.id).copied().unwrap_or(0)),
                source_path: db.to_path_buf(),
                originator: None,
                archived: row.archived,
                resume: resume(&row.id),
                session_id: row.id,
            }
        })
        .collect())
}

/// Visible messages per session (`metadata_json.userVisible` not false).
fn message_counts(conn: &Connection, cols: &HashSet<String>) -> Option<HashMap<String, u64>> {
    let visible = if cols.contains("metadata_json") {
        "WHERE CASE WHEN json_valid(metadata_json)
           THEN coalesce(json_extract(metadata_json, '$.userVisible'), 1) ELSE 1 END != 0"
    } else {
        ""
    };
    let sql = format!("SELECT session_id, count(*) FROM messages {visible} GROUP BY session_id");
    let mut stmt = conn.prepare(&sql).ok()?;
    let rows =
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).ok()?;
    rows.map(|row| row.map(|(id, count)| (id, u64::try_from(count).unwrap_or(0))))
        .collect::<Result<_, _>>()
        .ok()
}

/// The text of the first user message (`content_json` is the content array).
fn first_prompt(conn: &Connection, session: &str, order: &str) -> Option<String> {
    let sql = format!(
        "SELECT content_json FROM messages WHERE session_id = ?1 AND role = 'user' ORDER BY {order} LIMIT 1"
    );
    let content: String = conn
        .query_row(&sql, [session], |row| row.get::<_, Option<String>>(0))
        .optional()
        .ok()???;
    prompt_text(&serde_json::from_str::<Value>(&content).ok()?)
}

/// Legacy `<id>.jsonl` files directly in the root, newest first, bounded.
fn legacy_files(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut files: Vec<(PathBuf, i64)> = fs::read_dir(root)?
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
        .filter_map(|path| {
            let mtime = FileStamp::of(&fs::metadata(&path).ok()?).mtime_ms;
            Some((path, mtime))
        })
        .collect();
    files.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    files.truncate(AdapterConfig::DEFAULT_MAX_FILES);
    Ok(files.into_iter().map(|(path, _)| path).collect())
}

fn read_legacy(path: &Path, id: String) -> Option<ChatEntry> {
    let stamp = FileStamp::of(&fs::metadata(path).ok()?);
    let first = read_first_record(path).ok().flatten();
    let first = first.as_ref().filter(|record| record.is_object());
    let (title, title_source, cwd, count) = match first {
        // Files from before v1.0.11 start with a message, not metadata.
        Some(message) if message.get("role").is_some() => {
            let prompt = (message.get("role").and_then(Value::as_str) == Some("user"))
                .then(|| message.get("content").and_then(prompt_text))
                .flatten();
            let source = prompt.as_ref().map(|_| TitleSource::Prompt);
            (prompt, source, None, None)
        }
        Some(meta) => {
            let description = title_field(meta.get("description"));
            let source = description.as_ref().map(|_| TitleSource::Ai);
            let cwd = meta
                .get("working_dir")
                .and_then(Value::as_str)
                .filter(|cwd| !cwd.is_empty())
                .map(str::to_owned);
            (description, source, cwd, meta.get("message_count").and_then(Value::as_u64))
        }
        None => (None, None, None, None),
    };
    Some(ChatEntry {
        harness: AdapterKind::Goose,
        title,
        title_source,
        cwd,
        created_ms: id_time_ms(&id),
        updated_ms: stamp.mtime_ms,
        message_count: count,
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: resume(&id),
        session_id: id,
    })
}

/// `20261008_120000` (local time, read as UTC) to milliseconds.
fn id_time_ms(id: &str) -> Option<i64> {
    let bytes = id.as_bytes();
    if bytes.len() != 15 || bytes[8] != b'_' {
        return None;
    }
    if !bytes.iter().enumerate().all(|(at, byte)| at == 8 || byte.is_ascii_digit()) {
        return None;
    }
    let iso = format!(
        "{}-{}-{}T{}:{}:{}Z",
        id.get(0..4)?,
        id.get(4..6)?,
        id.get(6..8)?,
        id.get(9..11)?,
        id.get(11..13)?,
        id.get(13..15)?
    );
    parse_rfc3339_ms(&iso)
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let store = matches!(parts, [name]
        if *name == DB || *name == "sessions.db-wal" || name.ends_with(".jsonl"));
    role(false, store)
}
