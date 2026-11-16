//! A few named rows of a Codex home's `threads` table, for a reader that already knows which
//! threads it wants (acpmux's desktop bridge: the threads whose writer lock is held now) and
//! needs the fields Codex keeps only there, chiefly `originator`, the client that started the
//! thread (`codex_desktop` for the Codex desktop app).
//!
//! The prompt columns are read cut to their first line's worth: a row holds its first prompt
//! three times, and a reader of a handful of rows needs none of it whole (`threads.rs`).

use std::path::Path;

use rusqlite::Row;

use crate::sqlite::{columns, open_read_only};

/// Most ids one read takes; the rest of a longer list is left out.
const MAX_IDS: usize = 256;
/// Characters of the title kept.
const TITLE_CHARS: i64 = 200;

/// One thread row, as Codex wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexThreadRow {
    pub id: String,
    /// The client that started the thread (`codex_desktop`, `codex_exec`, ...); `None` on a
    /// database older than the column.
    pub originator: Option<String>,
    pub cwd: Option<String>,
    /// The name the person gave the thread.
    pub name: Option<String>,
    /// Its title (the first prompt, cut).
    pub title: Option<String>,
    pub cli_version: Option<String>,
    pub archived: bool,
}

/// The rows of `ids` in the newest `state_<n>.sqlite` of the Codex home `root`; empty when the
/// database is missing, locked past its deadline, or has no `threads` table.
pub fn thread_rows(root: &Path, ids: &[String]) -> Vec<CodexThreadRow> {
    let ids: Vec<&String> = ids.iter().take(MAX_IDS).collect();
    if ids.is_empty() {
        return Vec::new();
    }
    let Ok(Some(db)) = super::newest_state_db(root) else { return Vec::new() };
    read(&db, &ids).unwrap_or_default()
}

fn read(db: &Path, ids: &[&String]) -> rusqlite::Result<Vec<CodexThreadRow>> {
    let conn = open_read_only(db)?;
    let have = columns(&conn, "threads")?;
    if !have.contains("id") {
        return Ok(Vec::new());
    }
    // A column a database is too old for reads as NULL.
    let column = |name: &str| if have.contains(name) { name.to_owned() } else { "NULL".to_owned() };
    let title = if have.contains("title") {
        format!("substr(title, 1, {TITLE_CHARS})")
    } else {
        "NULL".to_owned()
    };
    let marks = vec!["?"; ids.len()].join(", ");
    let sql = format!(
        "SELECT id, {}, {}, {}, {title}, {}, {} FROM threads WHERE id IN ({marks})",
        column("originator"),
        column("cwd"),
        column("name"),
        column("cli_version"),
        column("archived"),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter()), row)?;
    rows.collect()
}

fn row(row: &Row<'_>) -> rusqlite::Result<CodexThreadRow> {
    let text = |i: usize| -> rusqlite::Result<Option<String>> {
        Ok(row.get::<_, Option<String>>(i)?.filter(|s| !s.is_empty()))
    };
    Ok(CodexThreadRow {
        id: row.get(0)?,
        originator: text(1)?,
        cwd: text(2)?,
        name: text(3)?,
        title: text(4)?,
        cli_version: text(5)?,
        archived: row.get::<_, Option<i64>>(6)?.unwrap_or(0) != 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_rows_are_read_with_their_originator() {
        let dir = tempfile::tempdir().unwrap();
        let conn = rusqlite::Connection::open(dir.path().join("state_5.sqlite")).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0, cli_version TEXT NOT NULL DEFAULT '',
                name TEXT, originator TEXT);
             INSERT INTO threads VALUES ('t1', '/w', 'fix it', 0, '0.164.0', NULL, 'codex_desktop');
             INSERT INTO threads VALUES ('t2', '/w', 'other', 1, '', 'named', 'codex_exec');",
        )
        .unwrap();
        drop(conn);
        let rows = thread_rows(dir.path(), &["t1".into(), "t2".into(), "gone".into()]);
        let t1 = rows.iter().find(|r| r.id == "t1").unwrap();
        assert_eq!(t1.originator.as_deref(), Some("codex_desktop"));
        assert_eq!(t1.cwd.as_deref(), Some("/w"));
        assert_eq!(t1.title.as_deref(), Some("fix it"));
        assert_eq!(t1.cli_version.as_deref(), Some("0.164.0"));
        assert!(!t1.archived);
        let t2 = rows.iter().find(|r| r.id == "t2").unwrap();
        assert_eq!(t2.name.as_deref(), Some("named"));
        assert_eq!((t2.cli_version.as_deref(), t2.archived), (None, true));
        assert_eq!(rows.len(), 2);
    }

    #[test]
    fn a_database_older_than_the_originator_column_reads_it_as_none() {
        let dir = tempfile::tempdir().unwrap();
        let conn = rusqlite::Connection::open(dir.path().join("state_5.sqlite")).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL);
             INSERT INTO threads VALUES ('t1', '/w', 'x');",
        )
        .unwrap();
        drop(conn);
        let rows = thread_rows(dir.path(), &["t1".into()]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].originator, None);
        assert!(thread_rows(dir.path(), &[]).is_empty());
        assert!(thread_rows(&dir.path().join("missing"), &["t1".into()]).is_empty());
    }
}
