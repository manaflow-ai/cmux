//! Muse Code (Meta): the data dir (`<XDG_DATA_HOME|~/.local/share>/muse`)
//! keeps one row per session in the SQLite index `session-index.db`
//! (table `sessions`), beside the append-only logs
//! `sessions/YYYY/MM/DD/<id>/session.jsonl`. The index names everything the
//! list needs, so only it is read.
//!
//! Rows with `msp_parent_session_id` or an `msp_kind` other than `root` are
//! subagents and background workers, which never resume on their own; a row
//! with no prompt has nothing to resume. Muse records the canonical folder
//! (`/private/tmp/...` on macOS) in `workspace_root`.

use std::collections::HashSet;
use std::io;
use std::path::Path;

use rusqlite::Connection;
use rusqlite::types::ValueRef;

use super::{PathRole, argv, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::sqlite::{columns, open_read_only};
use crate::text::title_line;

const DB: &str = "session-index.db";

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let db = root.join(DB);
    if !db.is_file() {
        return Ok(Vec::new());
    }
    // A failing index fails the scan: the chat index keeps its last result.
    open_read_only(&db).and_then(|conn| query(&conn, &db)).map_err(io::Error::other)
}

/// `muse resume <id>` reopens the session in the terminal UI. Resume is
/// scoped to the session's workspace, so it runs in the recorded folder.
fn resume(id: &str) -> Resume {
    Resume::Argv { argv: argv(&["muse", "resume", id]), cwd_needed: true }
}

fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
    if cols.contains(name) { name } else { "NULL" }
}

/// A microsecond timestamp cell (`*_at_us`) to milliseconds.
fn micros_to_ms(cell: ValueRef<'_>) -> Option<i64> {
    match cell {
        ValueRef::Integer(value) if value > 0 => Some(value / 1000),
        ValueRef::Real(value) if value > 0.0 => Some((value / 1000.0) as i64),
        _ => None,
    }
}

fn query(conn: &Connection, db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let cols = columns(conn, "sessions")?;
    if !cols.contains("session_id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| pick(&cols, name);
    let mut filters = vec!["session_id IS NOT NULL", "session_id != ''"];
    if cols.contains("msp_parent_session_id") {
        filters.push("(msp_parent_session_id IS NULL OR msp_parent_session_id = '')");
    }
    if cols.contains("msp_kind") {
        filters.push("(msp_kind IS NULL OR msp_kind = 'root')");
    }
    if cols.contains("prompt_count") {
        filters.push("COALESCE(prompt_count, 0) > 0");
    }
    let sql = format!(
        "SELECT session_id, {name}, {title}, {prompt}, {cwd}, {created}, {updated} \
         FROM sessions WHERE {filters}",
        name = col("session_name"),
        title = col("title"),
        prompt = col("first_user_prompt"),
        cwd = col("workspace_root"),
        created = col("created_at_us"),
        updated = col("updated_at_us"),
        filters = filters.join(" AND "),
    );
    let mut stmt = conn.prepare(&sql)?;
    let entries = stmt
        .query_map([], |row| {
            let id: String = row.get(0)?;
            // Only text cells count; any other value reads as no title
            // rather than failing the whole scan.
            let text = |index: usize| -> rusqlite::Result<Option<String>> {
                Ok(match row.get_ref(index)? {
                    ValueRef::Text(text) => std::str::from_utf8(text).ok().and_then(title_line),
                    _ => None,
                })
            };
            let (title, title_source) = match (text(1)?, text(2)?, text(3)?) {
                (Some(name), _, _) => (Some(name), Some(TitleSource::Custom)),
                (None, Some(title), _) => (Some(title), Some(TitleSource::Ai)),
                (None, None, Some(prompt)) => (Some(prompt), Some(TitleSource::Prompt)),
                (None, None, None) => (None, None),
            };
            let cwd = match row.get_ref(4)? {
                ValueRef::Text(text) => std::str::from_utf8(text).ok().map(str::to_owned),
                _ => None,
            };
            let created_ms = micros_to_ms(row.get_ref(5)?);
            let updated_ms = micros_to_ms(row.get_ref(6)?);
            Ok(ChatEntry {
                harness: AdapterKind::Muse,
                title,
                title_source,
                cwd: cwd.filter(|cwd| !cwd.is_empty()),
                created_ms,
                updated_ms: updated_ms.or(created_ms).unwrap_or(0),
                // The index counts prompts only, not messages.
                message_count: None,
                source_path: db.to_path_buf(),
                originator: None,
                archived: false,
                resume: resume(&id),
                session_id: id,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(entries)
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let store = matches!(parts, [name] if *name == DB || *name == "session-index.db-wal");
    role(false, store)
}
