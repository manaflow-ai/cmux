//! OpenCode: one SQLite DB per channel in the data dir (`opencode.db`,
//! `opencode-<channel>.db`). Top-level sessions only; a placeholder title
//! ("New session - <ISO time>") gives way to the first user text part.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};

use super::argv;
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::sqlite::{columns, open_read_only};
use crate::text::title_line;

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let mut dbs: Vec<PathBuf> = fs::read_dir(root)?
        .flatten()
        .map(|child| child.path())
        .filter(|path| {
            path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
                name.ends_with(".db") && (name == "opencode.db" || name.starts_with("opencode-"))
            })
        })
        .collect();
    dbs.sort();
    let mut entries = Vec::new();
    for db in dbs {
        // One unreadable channel DB does not hide the others.
        if let Ok(mut found) = query_sessions(&db) {
            entries.append(&mut found);
        }
    }
    Ok(entries)
}

fn query_sessions(db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let conn = open_read_only(db)?;
    let cols = columns(&conn, "session")?;
    if !cols.contains("id") {
        return Ok(Vec::new());
    }
    fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
        if cols.contains(name) { name } else { "NULL" }
    }
    let col = |name: &'static str| pick(&cols, name);
    let top_level = if cols.contains("parent_id") { "parent_id IS NULL" } else { "1 = 1" };
    let sql = format!(
        "SELECT id, {title}, {directory}, {created}, {updated}, {archived} FROM session WHERE {top_level}",
        title = col("title"),
        directory = col("directory"),
        created = col("time_created"),
        updated = col("time_updated"),
        archived = col("time_archived"),
    );
    let counts = message_counts(&conn);
    let first_text = FirstUserText::prepare(&conn);
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<i64>>(5)?,
        ))
    })?;
    let mut entries = Vec::new();
    for row in rows {
        let (id, title, directory, created_ms, updated_ms, archived_ms) = row?;
        let (title, title_source) =
            match title.as_deref().filter(|title| !is_placeholder(title)).and_then(title_line) {
                Some(title) => (Some(title), Some(TitleSource::Ai)),
                None => {
                    let typed = first_text.as_ref().and_then(|query| query.get(&conn, &id));
                    let source = typed.as_ref().map(|_| TitleSource::Prompt);
                    (typed, source)
                }
            };
        entries.push(ChatEntry {
            harness: AdapterKind::OpenCode,
            title,
            title_source,
            cwd: directory.filter(|dir| !dir.is_empty()),
            created_ms,
            updated_ms: updated_ms.or(created_ms).unwrap_or(0),
            message_count: counts.as_ref().map(|counts| counts.get(&id).copied().unwrap_or(0)),
            source_path: db.to_path_buf(),
            originator: None,
            archived: archived_ms.is_some(),
            resume: Resume::Argv { argv: argv(&["opencode", "-s", &id]), cwd_needed: true },
            session_id: id,
        });
    }
    Ok(entries)
}

/// `New session - 2026-10-01T10:00:00.000Z`: the name OpenCode gives before
/// it generates a title.
fn is_placeholder(title: &str) -> bool {
    title
        .strip_prefix("New session - ")
        .is_some_and(|rest| rest.as_bytes().first().is_some_and(u8::is_ascii_digit))
}

fn message_counts(conn: &Connection) -> Option<HashMap<String, u64>> {
    if !columns(conn, "message").ok()?.contains("session_id") {
        return None;
    }
    let mut stmt =
        conn.prepare("SELECT session_id, count(*) FROM message GROUP BY session_id").ok()?;
    let rows =
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).ok()?;
    rows.map(|row| row.map(|(id, count)| (id, u64::try_from(count).unwrap_or(0))))
        .collect::<Result<_, _>>()
        .ok()
}

/// The first text part of the first user message of a session.
struct FirstUserText;

impl FirstUserText {
    const SQL: &str =
        "SELECT json_extract(p.data, '$.text') FROM part p JOIN message m ON p.message_id = m.id
        WHERE m.session_id = ?1 AND json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
        ORDER BY m.time_created, m.id, p.id LIMIT 1";

    fn prepare(conn: &Connection) -> Option<Self> {
        let need = |table: &str, wanted: &[&str]| {
            columns(conn, table)
                .is_ok_and(|cols: HashSet<String>| wanted.iter().all(|name| cols.contains(*name)))
        };
        (need("message", &["id", "session_id", "time_created", "data"])
            && need("part", &["id", "message_id", "data"]))
        .then_some(Self)
    }

    fn get(&self, conn: &Connection, session: &str) -> Option<String> {
        let text: Option<Option<String>> =
            conn.query_row(Self::SQL, [session], |row| row.get(0)).optional().ok()?;
        text.flatten().as_deref().and_then(title_line)
    }
}
