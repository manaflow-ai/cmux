//! The `threads` table of a Codex state database, read again only where it changed.
//!
//! Every running Codex writes the database about once a second, and each write is a store change
//! for the index (`ChatIndex::paths_changed`). A thread row holds its first prompt three times
//! (`title`, `preview`, `first_user_message`), so one read of the whole table reads every prompt:
//! 392 MB and ~100 ms for 3,285 threads on a lane VM (2026-10-31), about every 2 s, while about
//! two rows had changed.
//!
//! So each read first takes every row's key ([`Query::keys`]): its times, the value of every
//! small column the query reads or filters on, and only the byte length of the three prompt
//! columns, which SQLite answers from the row's header without reading the text (Codex's database
//! has `auto_vacuum` on, so its pointer map also lets SQLite pass the prompts' overflow pages to
//! the small columns stored after them: 25 MB on that database). Rows whose key
//! changed, or whose spawn edge came or went, are read again with the same SQL filters as a whole
//! read. A rewrite of a prompt column to the same length with no time bump is the one change a key
//! misses; the whole table is read again at least every [`FULL_AFTER`], so it shows by then.

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

/// The longest a same-length prompt rewrite without a time bump goes unseen while Codex writes.
const FULL_AFTER: Duration = Duration::from_secs(300);

/// Columns whose value is part of a row's key: every small one the query reads or filters on.
const KEYED_VALUES: &[&str] = &[
    "name",
    "cwd",
    "originator",
    "rollout_path",
    "archived",
    "has_user_event",
    "thread_source",
    "agent_nickname",
    "agent_role",
];

/// Columns whose byte length is part of a row's key: the prompts, too long to read every time.
const KEYED_LENGTHS: &[&str] = &["title", "preview", "first_user_message"];

/// Ids per `WHERE id IN (...)` read, under SQLite's variable limit.
const IDS_PER_READ: usize = 500;

/// Codex homes whose last read is kept; past it every one is read whole again.
const MAX_HOMES: usize = 16;

/// A row's key: its times, then the value or length of each keyed column.
type Key = Vec<Value>;

/// The last read of one Codex home's database.
struct Known {
    db: PathBuf,
    /// The database file's identity: a replaced file is read whole.
    file: (u64, u64),
    /// The tables' schema (`sqlite_master`, collations and defaults included): a change is read
    /// whole.
    schema: String,
    /// When the whole table was last read.
    full_at: Instant,
    /// Every thread row by id, with the entry it gives (None: filtered out, or spawned).
    rows: HashMap<String, (Key, Option<ChatEntry>)>,
    /// The ids spawn edges named then.
    children: HashSet<String>,
}

static KNOWN: LazyLock<Mutex<HashMap<PathBuf, Known>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Forgets the last read of the Codex home `root`: its next read reads the whole table. For tests
/// that compare an incremental read with a whole one.
#[doc(hidden)]
pub fn forget(root: &Path) {
    if let Ok(mut known) = KNOWN.lock() {
        known.remove(root);
    }
}

/// The queries for one schema.
struct Query {
    /// Every column an entry needs.
    sql: String,
    /// The row filters: a person's thread, not a subagent's, and not one a spawn edge names.
    filters: String,
    /// Each row's key.
    keys: String,
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
        let mut filters = vec!["1 = 1".to_owned()];
        // `has_user_event` is only a hint: Codex 0.159+ leaves it 0 on every
        // thread. A thread is a chat when it has the flag or any user text.
        let texts: Vec<String> = ["first_user_message", "title", "preview", "name"]
            .into_iter()
            .filter(|name| cols.contains(*name))
            .map(|name| format!("coalesce({name}, '') <> ''"))
            .collect();
        if cols.contains("has_user_event") {
            let mut any = vec!["has_user_event = 1".to_owned()];
            any.extend(texts);
            filters.push(format!("({})", any.join(" OR ")));
        }
        if cols.contains("thread_source") {
            filters.push("coalesce(thread_source, '') <> 'subagent'".to_owned());
        }
        for agent_col in ["agent_nickname", "agent_role"] {
            if cols.contains(agent_col) {
                filters.push(format!("({agent_col} IS NULL OR {agent_col} = '')"));
            }
        }
        let child = spawn_child_column(conn);
        if let Some(child) = child {
            filters.push(format!(
                "id NOT IN (SELECT {child} FROM thread_spawn_edges WHERE {child} IS NOT NULL)"
            ));
        }
        let sql = format!(
            "SELECT id, {name}, {title}, {preview}, {first}, {cwd}, {created}, {updated}, {archived}, {originator}, {rollout}
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
        );
        let keyed: Vec<String> = [millis("created_at"), millis("updated_at")]
            .into_iter()
            .chain(KEYED_VALUES.iter().map(|name| col(name)))
            .chain(KEYED_LENGTHS.iter().map(|name| format!("octet_length({})", col(name))))
            .collect();
        let keys = format!("SELECT id, {} FROM threads", keyed.join(", "));
        Ok(Self { sql, filters: filters.join(" AND "), keys, child })
    }

    /// Every row's key. A row whose id is not text is never a chat a read can return.
    fn keys(&self, conn: &Connection) -> rusqlite::Result<HashMap<String, Key>> {
        let mut stmt = conn.prepare(&self.keys)?;
        let width = stmt.column_count();
        let mut rows = stmt.query([])?;
        let mut keys = HashMap::new();
        while let Some(row) = rows.next()? {
            let Value::Text(id) = row.get(0)? else { continue };
            let key = (1..width).map(|at| row.get(at)).collect::<rusqlite::Result<Key>>()?;
            keys.insert(id, key);
        }
        Ok(keys)
    }

    /// The threads a spawn edge names (the filters leave those out), matched by SQLite's own
    /// `IN`, with the column affinity the filter's `NOT IN` uses.
    fn children(&self, conn: &Connection) -> rusqlite::Result<HashSet<String>> {
        let Some(child) = self.child else { return Ok(HashSet::new()) };
        let sql = format!(
            "SELECT id FROM threads
             WHERE id IN (SELECT {child} FROM thread_spawn_edges WHERE {child} IS NOT NULL)"
        );
        let mut stmt = conn.prepare(&sql)?;
        let ids = stmt.query_map([], |row| row.get::<_, Value>(0))?;
        let mut children = HashSet::new();
        for id in ids {
            if let Value::Text(id) = id? {
                children.insert(id);
            }
        }
        Ok(children)
    }

    /// The tables' schema as SQLite keeps it: the text of every table and index on them, the
    /// names matched without case as SQLite resolves them.
    fn schema(conn: &Connection) -> rusqlite::Result<String> {
        let mut stmt = conn.prepare(
            "SELECT group_concat(coalesce(sql, ''), char(10)) FROM (SELECT sql FROM sqlite_master
             WHERE lower(tbl_name) IN ('threads', 'thread_spawn_edges') ORDER BY type, name)",
        )?;
        stmt.query_row([], |row| row.get::<_, Option<String>>(0)).map(Option::unwrap_or_default)
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
    // Taken out for this read: a read that fails leaves none, and the next one reads whole.
    let known = KNOWN.lock().ok().and_then(|mut known| known.remove(&root));
    let conn = open_read_only(db)?;
    // One snapshot for the schema, the queries built from it, the keys and the rows: a write
    // between them is read on its own burst.
    let snapshot = conn.unchecked_transaction()?;
    let schema = Query::schema(&conn)?;
    let query = Query::new(&conn)?;
    let keys = query.keys(&conn)?;
    let children = query.children(&conn)?;
    let known = known.filter(|known| {
        known.db == db
            && known.file == file
            && known.schema == schema
            && known.full_at.elapsed() < FULL_AFTER
    });
    let mut full_at = known.as_ref().map(|known| known.full_at);
    let (mut rows, spawned) = known.map(|known| (known.rows, known.children)).unwrap_or_default();
    // A row is read again when its key changed or a spawn edge naming it came or went.
    rows.retain(|id, (key, _)| {
        keys.get(id) == Some(key) && children.contains(id) == spawned.contains(id)
    });
    let whole = rows.is_empty();
    let unread: Vec<(&String, &Key)> =
        keys.iter().filter(|(id, _)| !rows.contains_key(*id)).collect();
    // Every unread row is filtered out unless the filtered read returns it.
    for (id, key) in &unread {
        rows.insert((*id).clone(), ((*key).clone(), None));
    }
    let read_row = |row: &Row<'_>| entry(row, db, &root, &real_root);
    if whole {
        full_at = Some(Instant::now());
        let mut stmt = conn.prepare(&format!("{} WHERE {}", query.sql, query.filters))?;
        let read = stmt.query_map([], &read_row)?;
        keep(&mut rows, &keys, read)?;
    } else {
        for ids in unread.chunks(IDS_PER_READ) {
            let marks = vec!["?"; ids.len()].join(", ");
            let sql = format!("{} WHERE id IN ({marks}) AND {}", query.sql, query.filters);
            let mut stmt = conn.prepare(&sql)?;
            let ids = ids.iter().map(|(id, _)| *id);
            let read = stmt.query_map(rusqlite::params_from_iter(ids), &read_row)?;
            keep(&mut rows, &keys, read)?;
        }
    }
    drop(snapshot);
    let mut entries: Vec<ChatEntry> =
        rows.values().filter_map(|(_, entry)| entry.clone()).collect();
    entries.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    if let Ok(mut known) = KNOWN.lock() {
        if known.len() >= MAX_HOMES {
            known.clear();
        }
        let full_at = full_at.unwrap_or_else(Instant::now);
        let db = db.to_path_buf();
        known.insert(root, Known { db, file, schema, full_at, rows, children });
    }
    Ok(entries)
}

/// Keeps each read row's entry under its key; a row the keys did not see (none can, in one
/// snapshot) is left for the next read.
fn keep(
    rows: &mut HashMap<String, (Key, Option<ChatEntry>)>,
    keys: &HashMap<String, Key>,
    read: impl Iterator<Item = rusqlite::Result<ChatEntry>>,
) -> rusqlite::Result<()> {
    for entry in read {
        let entry = entry?;
        if let Some(key) = keys.get(&entry.session_id) {
            rows.insert(entry.session_id.clone(), (key.clone(), Some(entry)));
        }
    }
    Ok(())
}

/// One row of [`Query::sql`] the filters passed.
fn entry(row: &Row<'_>, db: &Path, root: &Path, real_root: &Path) -> rusqlite::Result<ChatEntry> {
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
    Ok(ChatEntry {
        harness: AdapterKind::Codex,
        session_id: row.get(0)?,
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
    })
}

/// The file at `path`: its device and inode on Unix, its creation time elsewhere.
fn file_id(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some((meta.dev(), meta.ino()))
    }
    #[cfg(not(unix))]
    {
        let created = meta.created().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
        Some((created.as_secs(), u64::from(created.subsec_nanos())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(db: &Path) -> Vec<Option<String>> {
        query_threads(db).unwrap().into_iter().map(|entry| entry.title).collect()
    }

    /// A prompt rewritten to the same length with no time bump is the one change a row's key
    /// misses: the whole table is read again once [`FULL_AFTER`] has passed since the last whole
    /// read.
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
}
