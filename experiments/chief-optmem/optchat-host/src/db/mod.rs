//! The memory store (section 2), one SQLite file per Chief home:
//! `messages` (the log), `nodes` (the tree), `state` (the host's durable
//! state) and full-text indexes over both texts. One process writes it (the
//! chat's single-writer lock), through one connection behind the chat's
//! mutex; readers (`export`, `search`, stats) open read-only connections.
//!
//! Durability: WAL with `synchronous=FULL` and `fullfsync=ON` (F_FULLFSYNC
//! on Apple platforms), so a commit is on the disk when it returns, as each
//! fsynced JSON line was before. A batch of messages and the state that
//! must move with it commit together (`append`), which the old line store
//! could not do.
//!
//! Memory: nothing is indexed in memory. A message or a node is read by its
//! primary key; the start reads the node sizes the core folds the view from
//! (`nodes_size` covers them) and the largest message id.

mod export;
mod legacy;
mod schema;

use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use optchat_core::{Kind, NodeId, Store};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};

use crate::fault::fault;
use crate::lines;

pub use export::{export_text, ExportStats, Exporter};
pub use legacy::{
    has_legacy, import_legacy, migrate_legacy, Built, Imported, Marker, MIGRATION_KEY,
};
pub use schema::VERSION as SCHEMA_VERSION;

/// How long a connection waits for a lock another connection holds (a
/// reader's checkpoint, an export) before it fails.
const BUSY: Duration = Duration::from_secs(10);

/// Mode of the database file (and, as SQLite copies it, its -wal and -shm):
/// the memory keeps everything the user pasted.
const FILE_MODE: u32 = 0o600;

pub(crate) fn sql(e: rusqlite::Error) -> io::Error {
    io::Error::other(e)
}

/// One message to log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewMessage<'a> {
    pub kind: Kind,
    pub text: &'a str,
    /// The conversation message it came from (`<conversation>#<seq>`): a
    /// message whose key is already logged is not logged again.
    pub key: Option<String>,
}

impl<'a> NewMessage<'a> {
    pub fn new(kind: Kind, text: &'a str) -> NewMessage<'a> {
        NewMessage {
            kind,
            text,
            key: None,
        }
    }
}

/// One state write: a key and its new JSON value, or None to delete it.
pub type StateWrite = (String, Option<String>);

/// What `append` logged, in the order of its messages.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Appended {
    /// Each message's id (an already-logged key's id for a repeat).
    pub ids: Vec<u64>,
    /// Whether each message was logged now (false: its key was logged before).
    pub fresh: Vec<bool>,
    /// Each message's stored ISO date.
    pub stamps: Vec<String>,
}

/// The writer: the chat's one connection.
pub struct Db {
    conn: Connection,
    path: PathBuf,
    t: u64,
    node_count: usize,
}

/// Creates `dir` (and its parents) and makes it 0700: the memory holds
/// everything the user ever pasted, secrets included, and other accounts on
/// a shared Mac must not read it. An existing directory is tightened too.
pub fn private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn private_file(path: &Path) -> io::Result<()> {
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(FILE_MODE)
        .open(path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(FILE_MODE))
}

fn writer_pragmas(conn: &Connection) -> rusqlite::Result<()> {
    conn.busy_timeout(BUSY)?;
    let mode: String = conn.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(rusqlite::Error::InvalidParameterName(format!(
            "journal_mode stayed {mode}"
        )));
    }
    // Every commit reaches the disk (F_FULLFSYNC on Apple platforms, where
    // a plain fsync stops at the drive's cache), checkpoints too.
    // The WAL file shrinks back to 64 MiB after a checkpoint (a big import
    // would otherwise leave it at its largest size for good).
    conn.execute_batch(
        "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; \
         PRAGMA journal_size_limit=67108864;",
    )
}

/// A read-only connection: export, search, stats and the app's debug view
/// read while the host writes (WAL keeps them out of each other's way).
pub struct ReadOnly(Connection);

impl ReadOnly {
    pub fn open(path: &Path) -> io::Result<ReadOnly> {
        open_read_only(path).map(ReadOnly)
    }

    pub fn connection(&self) -> &Connection {
        &self.0
    }

    pub fn counts(&self) -> io::Result<Counts> {
        counts(&self.0)
    }

    pub fn search(&self, query: &str, limit: usize) -> io::Result<Vec<Hit>> {
        search(&self.0, query, limit)
    }

    pub fn export_text(&self, dir: &Path) -> io::Result<ExportStats> {
        export_text(&self.0, dir)
    }

    pub fn state(&self, key: &str) -> io::Result<Option<String>> {
        state(&self.0, key)
    }

    /// Kind and text of message `id`, if it exists.
    pub fn message(&self, id: u64) -> io::Result<Option<(String, String)>> {
        self.0
            .prepare_cached("SELECT kind, text FROM messages WHERE id = ?1")
            .and_then(|mut s| {
                s.query_row([id as i64], |r| Ok((r.get(0)?, r.get(1)?)))
                    .optional()
            })
            .map_err(sql)
    }
}

fn open_read_only(path: &Path) -> io::Result<Connection> {
    if !path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("no memory database at {}", path.display()),
        ));
    }
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(sql)?;
    conn.busy_timeout(BUSY).map_err(sql)?;
    conn.execute_batch("PRAGMA query_only=ON;").map_err(sql)?;
    Ok(conn)
}

impl Db {
    /// Opens (creating, 0600) the database at `path` and brings its schema
    /// up to date. Returns the built nodes with their text sizes, for
    /// `Memory::load`.
    pub fn open(path: &Path) -> io::Result<(Db, Vec<(NodeId, usize)>)> {
        if let Some(dir) = path.parent() {
            private_dir(dir)?;
        }
        private_file(path)?;
        let mut conn = Connection::open(path).map_err(sql)?;
        writer_pragmas(&conn).map_err(sql)?;
        schema::migrate(&mut conn).map_err(sql)?;
        let t: i64 = conn
            .query_row("SELECT COALESCE(MAX(id) + 1, 0) FROM messages", [], |r| {
                r.get(0)
            })
            .map_err(sql)?;
        let built = {
            let mut stmt = conn
                .prepare("SELECT level, idx, bytes FROM nodes INDEXED BY nodes_size")
                .map_err(sql)?;
            let rows = stmt
                .query_map([], |r| {
                    let (l, i, bytes): (i64, i64, i64) = (r.get(0)?, r.get(1)?, r.get(2)?);
                    Ok((NodeId::new(l as u32, i as u64), bytes as usize))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<Vec<_>>>().map_err(sql)?
        };
        let db = Db {
            conn,
            path: path.to_owned(),
            t: t as u64,
            node_count: built.len(),
        };
        Ok((db, built))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Number of messages, T.
    pub fn len(&self) -> u64 {
        self.t
    }

    pub fn is_empty(&self) -> bool {
        self.t == 0
    }

    /// Number of stored nodes.
    pub fn node_count(&self) -> usize {
        self.node_count
    }

    pub(crate) fn conn_mut(&mut self) -> &mut Connection {
        &mut self.conn
    }

    /// After a bulk import: the WAL copied into the database and truncated,
    /// then the counts again.
    pub(crate) fn reload_counts(&mut self) -> io::Result<Vec<(NodeId, usize)>> {
        self.conn
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
            .map_err(sql)?;
        let (db, built) = Db::open(&self.path.clone())?;
        *self = db;
        Ok(built)
    }

    /// Logs `messages` and writes the state `state` returns, in ONE
    /// transaction: either all of it is on disk or none of it is. `state`
    /// sees the ids and dates (a reply key needs the first one's). A message
    /// whose key is already logged keeps its id and is not logged again.
    pub fn append(
        &mut self,
        messages: &[NewMessage<'_>],
        state: impl FnOnce(&Appended) -> Vec<StateWrite>,
    ) -> io::Result<Appended> {
        let mut out = Appended::default();
        let mut t = self.t;
        let tx = self.conn.transaction().map_err(sql)?;
        {
            let mut find = tx
                .prepare_cached("SELECT id, date FROM messages WHERE conv_msg = ?1")
                .map_err(sql)?;
            let mut insert = tx
                .prepare_cached(
                    "INSERT INTO messages (id, kind, date, day, text, conv_msg) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(sql)?;
            for m in messages {
                if let Some(key) = &m.key {
                    let found: Option<(i64, String)> = find
                        .query_row([key], |r| Ok((r.get(0)?, r.get(1)?)))
                        .optional()
                        .map_err(sql)?;
                    if let Some((id, date)) = found {
                        out.ids.push(id as u64);
                        out.fresh.push(false);
                        out.stamps.push(date);
                        continue;
                    }
                }
                let date = lines::now_iso();
                let day = lines::day_of(&date);
                insert
                    .execute(params![t as i64, m.kind.as_str(), date, day, m.text, m.key])
                    .map_err(sql)?;
                out.ids.push(t);
                out.fresh.push(true);
                out.stamps.push(date);
                t += 1;
            }
        }
        fault("append:after-messages");
        write_state(&tx, &state(&out))?;
        fault("append:before-commit");
        tx.commit().map_err(sql)?;
        self.t = t;
        Ok(out)
    }

    /// Stores built nodes in one transaction.
    pub fn append_nodes(&mut self, nodes: &[(NodeId, &str)]) -> io::Result<()> {
        if nodes.is_empty() {
            return Ok(());
        }
        let day = lines::today();
        let tx = self.conn.transaction().map_err(sql)?;
        let mut added = 0;
        {
            let mut insert = tx
                .prepare_cached(
                    "INSERT INTO nodes (level, idx, bytes, day, text) VALUES (?1, ?2, ?3, ?4, ?5) \
                     ON CONFLICT (level, idx) DO NOTHING",
                )
                .map_err(sql)?;
            for (node, text) in nodes {
                added += insert
                    .execute(params![
                        node.l as i64,
                        node.i as i64,
                        text.len() as i64,
                        day,
                        text
                    ])
                    .map_err(sql)?;
            }
        }
        fault("node:before-commit");
        tx.commit().map_err(sql)?;
        self.node_count += added;
        Ok(())
    }

    /// Writes state keys in one transaction.
    pub fn put_state(&mut self, writes: &[StateWrite]) -> io::Result<()> {
        if writes.is_empty() {
            return Ok(());
        }
        let tx = self.conn.transaction().map_err(sql)?;
        write_state(&tx, writes)?;
        fault("state:before-commit");
        tx.commit().map_err(sql)
    }

    pub fn state(&self, key: &str) -> io::Result<Option<String>> {
        state(&self.conn, key)
    }

    /// Every state key that starts with `prefix`, in key order.
    pub fn state_prefix(&self, prefix: &str) -> io::Result<Vec<(String, String)>> {
        state_prefix(&self.conn, prefix)
    }

    /// The stored ISO date of message `i`.
    pub fn date(&self, i: u64) -> Option<String> {
        if i >= self.t {
            return None;
        }
        self.conn
            .prepare_cached("SELECT date FROM messages WHERE id = ?1")
            .and_then(|mut s| s.query_row([i as i64], |r| r.get(0)))
            // crash-allow: a committed row that cannot be read means the disk is failing (see `message`).
            .unwrap_or_else(|e| panic!("optchat: cannot read message {i}: {e}"))
    }
}

fn write_state(conn: &Connection, writes: &[StateWrite]) -> io::Result<()> {
    let mut put = conn
        .prepare_cached(
            "INSERT INTO state (key, value) VALUES (?1, ?2) \
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        )
        .map_err(sql)?;
    let mut delete = conn
        .prepare_cached("DELETE FROM state WHERE key = ?1")
        .map_err(sql)?;
    for (key, value) in writes {
        match value {
            Some(v) => put.execute(params![key, v]).map_err(sql)?,
            None => delete.execute([key]).map_err(sql)?,
        };
    }
    Ok(())
}

pub fn state(conn: &Connection, key: &str) -> io::Result<Option<String>> {
    conn.prepare_cached("SELECT value FROM state WHERE key = ?1")
        .and_then(|mut s| s.query_row([key], |r| r.get(0)).optional())
        .map_err(sql)
}

pub fn state_prefix(conn: &Connection, prefix: &str) -> io::Result<Vec<(String, String)>> {
    let mut stmt = conn
        .prepare_cached("SELECT key, value FROM state WHERE substr(key, 1, ?2) = ?1 ORDER BY key")
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![prefix, prefix.len() as i64], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .map_err(sql)?;
    rows.collect::<rusqlite::Result<Vec<_>>>().map_err(sql)
}

// The core's Store contract is infallible. A row that was committed but
// cannot be read back means the disk is failing; going on would write
// summaries of garbage into the permanent tree, so stop loudly.
impl Store for Db {
    fn message(&self, i: u64) -> (Kind, String) {
        let row: rusqlite::Result<(String, String)> = self
            .conn
            .prepare_cached("SELECT kind, text FROM messages WHERE id = ?1")
            .and_then(|mut s| s.query_row([i as i64], |r| Ok((r.get(0)?, r.get(1)?))));
        match row {
            Ok((kind, text)) => match Kind::parse(&kind) {
                Some(kind) => (kind, text),
                // crash-allow: see the comment above the impl.
                None => panic!("optchat: message {i} has an unknown kind {kind:?}"),
            },
            // crash-allow: see the comment above the impl.
            Err(e) => panic!("optchat: cannot read message {i}: {e}"),
        }
    }

    fn node(&self, id: NodeId) -> Option<String> {
        self.conn
            .prepare_cached("SELECT text FROM nodes WHERE level = ?1 AND idx = ?2")
            .and_then(|mut s| {
                s.query_row(params![id.l as i64, id.i as i64], |r| r.get(0))
                    .optional()
            })
            // crash-allow: see the comment above the impl.
            .unwrap_or_else(|e| panic!("optchat: cannot read node {}: {e}", id.name()))
    }
}

/// Counts of a memory database, for stats and the migration check.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub messages: u64,
    pub nodes: u64,
}

pub fn counts(conn: &Connection) -> io::Result<Counts> {
    let messages: i64 = conn
        .query_row("SELECT COALESCE(MAX(id) + 1, 0) FROM messages", [], |r| {
            r.get(0)
        })
        .map_err(sql)?;
    let nodes: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM nodes INDEXED BY nodes_size",
            [],
            |r| r.get(0),
        )
        .map_err(sql)?;
    Ok(Counts {
        messages: messages as u64,
        nodes: nodes as u64,
    })
}

/// One full-text match.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Hit {
    Message {
        id: u64,
        kind: String,
        snippet: String,
    },
    Node {
        node: NodeId,
        snippet: String,
    },
}

/// `text` as an FTS5 query that matches rows holding every word: each word
/// becomes a quoted string, so `-`, `:`, `*` and quotes are plain text.
pub fn plain_query(text: &str) -> String {
    text.split_whitespace()
        .map(|w| format!("\"{}\"", w.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Full-text search over messages and summaries: rows holding every word
/// of `text` (`plain_query`), best matches first, at most `limit` of each.
pub fn search(conn: &Connection, text: &str, limit: usize) -> io::Result<Vec<Hit>> {
    let query = plain_query(text);
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let query = query.as_str();
    let mut out = Vec::new();
    let mut stmt = conn
        .prepare(
            "SELECT m.id, m.kind, snippet(messages_fts, 0, '[', ']', '...', 16) \
             FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid \
             WHERE messages_fts MATCH ?1 ORDER BY rank LIMIT ?2",
        )
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![query, limit as i64], |r| {
            Ok(Hit::Message {
                id: r.get::<_, i64>(0)? as u64,
                kind: r.get(1)?,
                snippet: r.get(2)?,
            })
        })
        .map_err(sql)?;
    for row in rows {
        out.push(row.map_err(sql)?);
    }
    let mut stmt = conn
        .prepare(
            "SELECT n.level, n.idx, snippet(nodes_fts, 0, '[', ']', '...', 16) \
             FROM nodes_fts JOIN nodes n ON n.rowid = nodes_fts.rowid \
             WHERE nodes_fts MATCH ?1 ORDER BY rank LIMIT ?2",
        )
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![query, limit as i64], |r| {
            Ok(Hit::Node {
                node: NodeId::new(r.get::<_, i64>(0)? as u32, r.get::<_, i64>(1)? as u64),
                snippet: r.get(2)?,
            })
        })
        .map_err(sql)?;
    for row in rows {
        out.push(row.map_err(sql)?);
    }
    Ok(out)
}
