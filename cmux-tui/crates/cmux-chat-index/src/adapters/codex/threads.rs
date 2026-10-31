//! The `threads` table of a Codex state database, read again only where it changed.
//!
//! Every running Codex writes the database about once a second, and each write is a store change
//! for the index (`ChatIndex::paths_changed`). A thread row holds its first prompt three times
//! (`title`, `preview`, `first_user_message`), before the columns the index reads after them, so
//! one read of the whole table reads every prompt: 391 MB and ~200 ms for 3,268 threads on
//! a lane VM (2026-10-31), about every 2 s, while about two rows had changed.
//!
//! So each read first takes every row's key: its `updated_at_ms`, which Codex's own index covers,
//! and the byte length of each text column the index reads with the 0/1 flags, which SQLite
//! answers from the row's header without reading the text (7 MB and 6 ms on that database). Only
//! rows whose key changed are read whole. Codex writes `name` and `title` without a time bump
//! (`UPDATE threads SET name = ? WHERE id = ?`); their length changes with them, `session_index.jsonl`
//! (read on every scan) carries the names too, and the whole table is read again at least every
//! [`FULL_AFTER`], so a rewrite to the same length shows by then. Spawn edges (a small table) are
//! read every time.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use rusqlite::types::Value;
use rusqlite::{Connection, Row};

use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::sqlite::{columns, open_read_only};
use crate::text::title_line;

/// The longest a same-length rewrite without a time bump goes unseen while Codex writes.
const FULL_AFTER: Duration = Duration::from_secs(300);

/// Text columns whose byte length is part of a row's key: every one the query reads or filters on.
const KEYED_TEXT: &[&str] = &[
    "name",
    "title",
    "preview",
    "first_user_message",
    "cwd",
    "originator",
    "rollout_path",
    "thread_source",
    "agent_nickname",
    "agent_role",
];

/// Small integer columns in a row's key (0 and 1 are stored in the row's header).
const KEYED_FLAGS: &[&str] = &["has_user_event", "archived"];

/// Ids per `WHERE id IN (...)` read, under SQLite's variable limit.
const IDS_PER_READ: usize = 500;

/// A row's key: its update time, then the length or value of each keyed column.
type Key = Vec<Value>;

/// The last read of one Codex home's database.
struct Known {
    db: PathBuf,
    /// The database file (device, inode): a replaced file is read whole.
    file: (u64, u64),
    /// The row query: a schema change is read whole.
    sql: String,
    /// When the whole table was last read.
    full_at: Instant,
    /// Every thread row by id, with the entry it gives (None: not a chat).
    rows: HashMap<String, (Key, Option<ChatEntry>)>,
}

static KNOWN: LazyLock<Mutex<HashMap<PathBuf, Known>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The queries for one schema.
struct Query {
    /// Every column an entry needs, then the columns of the row filters ([`passes`]). The filters
    /// are applied in Rust, not SQL: SQLite reads each prompt again for an expression column.
    sql: String,
    /// The table has `has_user_event`, so a chat needs the flag or user text.
    user_event: bool,
    /// Each row's key in two reads: its update time (an index covers it), then its lengths and
    /// flags (the row's header holds them).
    updated: String,
    lengths: String,
    /// The child column of `thread_spawn_edges`, when the table has one.
    child: Option<&'static str>,
}

impl Query {
    fn new(conn: &Connection) -> rusqlite::Result<Self> {
        let cols = columns(conn, "threads")?;
        if !cols.contains("id") {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let col =
            |name: &str| if cols.contains(name) { name.to_owned() } else { "NULL".to_owned() };
        let millis = |name: &str| {
            if cols.contains(&format!("{name}_ms")) {
                format!("{name}_ms")
            } else if cols.contains(name) {
                format!("{name} * 1000")
            } else {
                "NULL".to_owned()
            }
        };
        let sql = format!(
            "SELECT id, {name}, {title}, {preview}, {first}, {cwd}, {created}, {updated}, {archived}, {originator}, {rollout},
                    {user_event}, {source}, {nickname}, {role}
             FROM threads",
            name = col("name"),
            title = col("title"),
            preview = col("preview"),
            first = col("first_user_message"),
            cwd = col("cwd"),
            created = millis("created_at"),
            updated = millis("updated_at"),
            archived = col("archived"),
            originator = col("originator"),
            rollout = col("rollout_path"),
            user_event = col("has_user_event"),
            source = col("thread_source"),
            nickname = col("agent_nickname"),
            role = col("agent_role"),
        );
        let keyed: Vec<String> = KEYED_TEXT
            .iter()
            .filter(|name| cols.contains(**name))
            .map(|name| format!("octet_length({name})"))
            .chain(KEYED_FLAGS.iter().filter(|name| cols.contains(**name)).map(|n| n.to_string()))
            .collect();
        let lengths = if keyed.is_empty() {
            "SELECT id FROM threads".to_owned()
        } else {
            format!("SELECT id, {} FROM threads", keyed.join(", "))
        };
        let updated = format!("SELECT id, {} FROM threads", millis("updated_at"));
        let user_event = cols.contains("has_user_event");
        Ok(Self { sql, user_event, updated, lengths, child: spawn_child_column(conn) })
    }

    /// Every row's key.
    fn keys(&self, conn: &Connection) -> rusqlite::Result<HashMap<String, Key>> {
        let mut keys: HashMap<String, Key> = HashMap::new();
        let mut stmt = conn.prepare(&self.updated)?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            keys.insert(row.get(0)?, vec![row.get(1)?]);
        }
        let mut stmt = conn.prepare(&self.lengths)?;
        let width = stmt.column_count();
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            // A row the first read did not see is not keyed: it is read whole.
            let Some(key) = keys.get_mut(&id) else { continue };
            for at in 1..width {
                key.push(row.get(at)?);
            }
        }
        keys.retain(|_, key| key.len() == width);
        Ok(keys)
    }

    /// The ids of threads another thread spawned (not chats of their own).
    fn children(&self, conn: &Connection) -> rusqlite::Result<HashSet<String>> {
        let Some(child) = self.child else { return Ok(HashSet::new()) };
        let sql = format!("SELECT {child} FROM thread_spawn_edges WHERE {child} IS NOT NULL");
        let mut stmt = conn.prepare(&sql)?;
        let ids = stmt.query_map([], |row| row.get::<_, String>(0))?;
        ids.collect()
    }
}

fn spawn_child_column(conn: &Connection) -> Option<&'static str> {
    let cols = columns(conn, "thread_spawn_edges").ok()?;
    ["child_thread_id", "child_id"].into_iter().find(|name| cols.contains(*name))
}

/// The chats of the `threads` table of `db`.
pub(super) fn query_threads(db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let root = db.parent().unwrap_or(db).to_path_buf();
    let real_root = fs::canonicalize(&root).unwrap_or_else(|_| root.clone());
    let file = file_id(db).ok_or(rusqlite::Error::InvalidQuery)?;
    let conn = open_read_only(db)?;
    let query = Query::new(&conn)?;
    // One snapshot for the keys and the rows: a write between them is read on its own burst.
    let snapshot = conn.unchecked_transaction()?;
    let keys = query.keys(&conn)?;
    let children = query.children(&conn)?;
    let known = KNOWN.lock().ok().and_then(|mut known| known.remove(&root)).filter(|known| {
        known.db == db
            && known.file == file
            && known.sql == query.sql
            && known.full_at.elapsed() < FULL_AFTER
    });
    let mut full_at = known.as_ref().map(|known| known.full_at);
    let mut rows = known.map(|known| known.rows).unwrap_or_default();
    rows.retain(|id, (key, _)| keys.get(id) == Some(key));
    let read_row = |row: &Row<'_>| entry(row, query.user_event, db, &root, &real_root);
    if rows.is_empty() {
        full_at = Some(Instant::now());
        let mut stmt = conn.prepare(&query.sql)?;
        let read = stmt.query_map([], &read_row)?;
        keep(&mut rows, &keys, read)?;
    } else {
        let changed: Vec<&String> = keys.keys().filter(|id| !rows.contains_key(*id)).collect();
        for ids in changed.chunks(IDS_PER_READ) {
            let marks = vec!["?"; ids.len()].join(", ");
            let mut stmt = conn.prepare(&format!("{} WHERE id IN ({marks})", query.sql))?;
            let read = stmt.query_map(rusqlite::params_from_iter(ids), &read_row)?;
            keep(&mut rows, &keys, read)?;
        }
    }
    drop(snapshot);
    let mut entries: Vec<ChatEntry> = rows
        .values()
        .filter_map(|(_, entry)| entry.clone())
        .filter(|entry| !children.contains(&entry.session_id))
        .collect();
    entries.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    if let Ok(mut known) = KNOWN.lock() {
        let full_at = full_at.unwrap_or_else(Instant::now);
        let db = db.to_path_buf();
        known.insert(root, Known { db, file, sql: query.sql, full_at, rows });
    }
    Ok(entries)
}

/// Keeps each read row with its key; a row with no key (added after the keys were read in the
/// same snapshot, which cannot happen) is left for the next read.
fn keep(
    rows: &mut HashMap<String, (Key, Option<ChatEntry>)>,
    keys: &HashMap<String, Key>,
    read: impl Iterator<Item = rusqlite::Result<(String, Option<ChatEntry>)>>,
) -> rusqlite::Result<()> {
    for row in read {
        let (id, entry) = row?;
        if let Some(key) = keys.get(&id) {
            rows.insert(id, (key.clone(), entry));
        }
    }
    Ok(())
}

/// Whether a row of [`Query::sql`] is a person's chat, as these SQL filters said it:
/// `has_user_event = 1 OR coalesce(<prompt column>, '') <> ''` (when the table has the flag),
/// `coalesce(thread_source, '') <> 'subagent'`, and `agent_nickname IS NULL OR agent_nickname = ''`
/// (the same for `agent_role`). As in SQLite, a value of another type never equals a text, and
/// a missing column reads NULL.
fn passes(row: &Row<'_>, user_event: bool) -> rusqlite::Result<bool> {
    let empty = Value::Text(String::new());
    let value = |index: usize| row.get::<_, Value>(index);
    let blank = |value: &Value| *value == Value::Null || *value == empty;
    if user_event {
        let flag = value(11)?;
        let mut chat = flag == Value::Integer(1) || flag == Value::Real(1.0);
        for prompt in 1..=4 {
            chat = chat || !blank(&value(prompt)?);
        }
        if !chat {
            return Ok(false);
        }
    }
    Ok(value(12)? != Value::Text("subagent".to_owned()) && blank(&value(13)?) && blank(&value(14)?))
}

/// One row of [`Query::sql`]: its id, and its entry when it passes the row filters.
fn entry(
    row: &Row<'_>,
    user_event: bool,
    db: &Path,
    root: &Path,
    real_root: &Path,
) -> rusqlite::Result<(String, Option<ChatEntry>)> {
    let id: String = row.get(0)?;
    if !passes(row, user_event)? {
        return Ok((id, None));
    }
    let text = |index: usize| row.get::<_, Option<String>>(index);
    let candidates = [
        (text(1)?, TitleSource::Custom),
        (text(2)?, TitleSource::Ai),
        (text(3)?, TitleSource::Prompt),
        (text(4)?, TitleSource::Prompt),
    ];
    let (title, title_source) = candidates
        .into_iter()
        .find_map(|(value, source)| {
            value.as_deref().and_then(title_line).map(|title| (Some(title), Some(source)))
        })
        .unwrap_or((None, None));
    let created_ms = row.get::<_, Option<i64>>(6)?;
    let entry = ChatEntry {
        harness: AdapterKind::Codex,
        session_id: id.clone(),
        title,
        title_source,
        cwd: text(5)?.filter(|cwd| !cwd.is_empty()),
        created_ms,
        updated_ms: row.get::<_, Option<i64>>(7)?.or(created_ms).unwrap_or(0),
        message_count: None,
        // A recorded path outside the home is not followed (it could be
        // anywhere, guarded folders included).
        source_path: text(10)?
            .map(PathBuf::from)
            .filter(|path| {
                path.is_absolute() && (path.starts_with(root) || path.starts_with(real_root))
            })
            .unwrap_or_else(|| db.to_path_buf()),
        originator: text(9)?,
        archived: row.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
        resume: Resume::Adopt,
    };
    Ok((id, Some(entry)))
}

/// The file at `path` (device, inode); (0, 0) where the system has no inodes.
fn file_id(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some((meta.dev(), meta.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        Some((0, 0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(db: &Path) -> Vec<Option<String>> {
        query_threads(db).unwrap().into_iter().map(|entry| entry.title).collect()
    }

    /// A rewrite to the same length with no time bump is the one change a row's key misses: the
    /// whole table is read again once [`FULL_AFTER`] has passed since the last whole read.
    #[test]
    fn a_same_length_rewrite_shows_after_the_full_read_bound() {
        let home = tempfile::tempdir().unwrap();
        let db = home.path().join("state_5.sqlite");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "create table threads (id text primary key, title text, updated_at_ms integer);
             insert into threads values ('a', 'first title', 1);",
        )
        .unwrap();
        assert_eq!(titles(&db), vec![Some("first title".to_owned())]);
        conn.execute("update threads set title = 'other title'", []).unwrap();
        assert_eq!(titles(&db), vec![Some("first title".to_owned())], "the key did not change");

        let root = db.parent().unwrap().to_path_buf();
        if let Some(known) = KNOWN.lock().unwrap().get_mut(&root) {
            known.full_at = Instant::now().checked_sub(FULL_AFTER).unwrap();
        }
        assert_eq!(titles(&db), vec![Some("other title".to_owned())]);
    }

    /// [`passes`] keeps exactly the rows the SQL filters it replaced kept, values of every type.
    #[test]
    fn the_row_filter_keeps_what_the_sql_kept() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "create table threads (id text primary key, name, title, preview, first_user_message,
                has_user_event, thread_source, agent_nickname, agent_role, updated_at_ms integer)",
        )
        .unwrap();
        let values = ["NULL", "''", "'x'", "0", "1", "1.0", "2", "x''", "'subagent'", "'1'"];
        let mut n = 0;
        for (a, flag) in values.iter().enumerate() {
            for prompt in &values {
                for source in &values {
                    for agent in &values {
                        n += 1;
                        let role = if a % 2 == 0 { *agent } else { "NULL" };
                        conn.execute(
                            &format!(
                                "insert into threads values ('{n}', NULL, {prompt}, NULL, NULL,
                                    {flag}, {source}, {agent}, {role}, 1)"
                            ),
                            [],
                        )
                        .unwrap();
                    }
                }
            }
        }
        let sql_kept: HashSet<String> = conn
            .prepare(
                "SELECT id FROM threads WHERE 1 = 1
                 AND (has_user_event = 1 OR coalesce(first_user_message, '') <> ''
                      OR coalesce(title, '') <> '' OR coalesce(preview, '') <> ''
                      OR coalesce(name, '') <> '')
                 AND coalesce(thread_source, '') <> 'subagent'
                 AND (agent_nickname IS NULL OR agent_nickname = '')
                 AND (agent_role IS NULL OR agent_role = '')",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        let query = Query::new(&conn).unwrap();
        let mut stmt = conn.prepare(&query.sql).unwrap();
        let kept: HashSet<String> = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, passes(row, query.user_event)?)))
            .unwrap()
            .map(Result::unwrap)
            .filter_map(|(id, pass)| pass.then_some(id))
            .collect();
        assert!(!sql_kept.is_empty() && sql_kept.len() < n);
        assert_eq!(kept, sql_kept);
    }
}
