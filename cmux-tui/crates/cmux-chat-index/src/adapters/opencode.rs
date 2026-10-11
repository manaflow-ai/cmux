//! OpenCode, every store generation side by side in one data dir
//! (`<XDG data>/opencode`). Migrations copy and never delete, so all of them
//! can be on disk at once; a session id seen in a newer store wins.
//!
//! - S2 (2.x): `opencode*.db`, tables `session_v2` + `session_message`.
//! - S1 (1.2+): the same DB files, tables `session` + `message` + `part`.
//! - J1 (0.6-1.1): `storage/session/<project>/<id>.json`,
//!   `storage/message/<id>/<msg>.json`, `storage/part/<msg>/<part>.json`.
//! - J0 (0.0.53-0.5): `project/<slug>/storage/session/info/<id>.json`,
//!   `.../session/message/<id>/<msg>.json` (parts inline or under
//!   `.../session/part/<id>/<msg>/`); 0.0.53-0.0.55 nested the storage dir
//!   under the absolute repo path (`<data>/Users/me/app/storage`).
//!
//! Top-level sessions only; a placeholder title ("New session - <ISO>")
//! gives way to the first user text.
//!
//! The Kilo CLI is an OpenCode fork with the same store: `kilo.db` (1.x
//! S1, v7.0.26+) and J1 JSON (v1.0.9-v1.0.25) under `<XDG data>/kilo`.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use super::{PathRole, argv, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::scan::AdapterConfig;
use crate::sqlite::{columns, open_read_only};
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_line};

/// Messages read per JSON session to find the first prompt and folder.
const MESSAGE_PROBE: usize = 24;
/// Directories visited when looking for 0.0.53-0.0.55 nested storage.
const LEGACY_WALK_MAX: usize = 2000;

/// OpenCode itself or its Kilo fork: same tables, other names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Flavor {
    OpenCode,
    Kilo,
}

impl Flavor {
    fn kind(self) -> AdapterKind {
        match self {
            Self::OpenCode => AdapterKind::OpenCode,
            Self::Kilo => AdapterKind::Kilo,
        }
    }

    fn binary(self) -> &'static str {
        match self {
            Self::OpenCode => "opencode",
            Self::Kilo => "kilo",
        }
    }

    /// `opencode.db`, `opencode-<channel>.db`; `kilo.db`, `kilo-<channel>.db`.
    fn is_db_name(self, name: &str) -> bool {
        let base = self.binary();
        name.strip_suffix(".db").is_some_and(|stem| {
            stem == base || stem.strip_prefix(base).is_some_and(|rest| rest.starts_with('-'))
        })
    }

    fn is_db_or_wal(self, name: &str) -> bool {
        self.is_db_name(name) || name.strip_suffix("-wal").is_some_and(|db| self.is_db_name(db))
    }

    fn resume(self, id: &str) -> Resume {
        Resume::Argv { argv: argv(&[self.binary(), "-s", id]), cwd_needed: true }
    }
}

pub(super) fn read_store(root: &Path, flavor: Flavor) -> io::Result<Vec<ChatEntry>> {
    let mut store = Merged::default();
    let dbs = db_files(root, flavor)?;
    // A DB that fails (busy, mid-checkpoint, past the deadline) fails the
    // scan, so the index keeps its last result instead of dropping chats.
    let conns = dbs
        .iter()
        .map(|db| open_read_only(db).map(|conn| (conn, db)))
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(io::Error::other)?;
    // Newest generation first across every channel DB, then 1.x rows.
    for (conn, db) in &conns {
        store.extend(query_v2(conn, db, flavor).map_err(io::Error::other)?);
    }
    for (conn, db) in &conns {
        store.extend(query_v1(conn, db, flavor).map_err(io::Error::other)?);
    }
    // JSON sessions a DB never imported (a jump from 1.1 to 1.16+) cannot
    // be resumed by an OpenCode that has a DB.
    let json_resume = dbs.is_empty();
    let max = AdapterConfig::DEFAULT_MAX_FILES;
    let json = |storage: &Path, layout| json_sessions(storage, layout, flavor, json_resume, max);
    store.extend(json(&root.join("storage"), Layout::Global));
    if flavor == Flavor::OpenCode {
        for storage in legacy_storage_dirs(root) {
            store.extend(json(&storage, Layout::PerProject));
        }
    }
    Ok(store.entries)
}

pub(super) fn classify(parts: &[&str], flavor: Flavor) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let json = name.ends_with(".json");
    let store = match parts {
        [_] => flavor.is_db_or_wal(name),
        // J1 session file.
        ["storage", "session", _, _] => json,
        // J0 session info file.
        ["project", _, "storage", "session", "info", _] => json && flavor == Flavor::OpenCode,
        _ => false,
    };
    role(false, store)
}

/// Entries in priority order; a later copy of a known id is dropped.
#[derive(Default)]
struct Merged {
    seen: HashSet<String>,
    entries: Vec<ChatEntry>,
}

impl Merged {
    fn extend(&mut self, entries: Vec<ChatEntry>) {
        for entry in entries {
            if self.seen.insert(entry.session_id.clone()) {
                self.entries.push(entry);
            }
        }
    }
}

fn db_files(root: &Path, flavor: Flavor) -> io::Result<Vec<PathBuf>> {
    let mut dbs: Vec<PathBuf> = fs::read_dir(root)?
        .flatten()
        .map(|child| child.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| flavor.is_db_name(name))
        })
        .filter(|path| path.is_file())
        .collect();
    dbs.sort();
    Ok(dbs)
}

fn pick<'a>(cols: &HashSet<String>, name: &'a str) -> &'a str {
    if cols.contains(name) { name } else { "NULL" }
}

/// One `SELECT` row of a session table.
struct Row {
    id: String,
    title: Option<String>,
    directory: Option<String>,
    created_ms: Option<i64>,
    updated_ms: Option<i64>,
    archived_ms: Option<i64>,
}

fn session_rows(conn: &Connection, table: &str) -> rusqlite::Result<Vec<Row>> {
    let cols = columns(conn, table)?;
    if !cols.contains("id") {
        return Ok(Vec::new());
    }
    let col = |name: &'static str| pick(&cols, name);
    let top_level = if cols.contains("parent_id") { "parent_id IS NULL" } else { "1 = 1" };
    let sql = format!(
        "SELECT id, {title}, {directory}, {created}, {updated}, {archived} FROM {table} WHERE {top_level}",
        title = col("title"),
        directory = col("directory"),
        created = col("time_created"),
        updated = col("time_updated"),
        archived = col("time_archived"),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        Ok(Row {
            id: row.get(0)?,
            title: row.get(1)?,
            directory: row.get(2)?,
            created_ms: row.get(3)?,
            updated_ms: row.get(4)?,
            archived_ms: row.get(5)?,
        })
    })?;
    rows.collect()
}

fn db_entry(
    row: Row,
    db: &Path,
    flavor: Flavor,
    count: Option<u64>,
    first_text: impl FnOnce(&str) -> Option<String>,
) -> ChatEntry {
    let (title, title_source) =
        match row.title.as_deref().filter(|title| !is_placeholder(title)).and_then(title_line) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => {
                let typed = first_text(&row.id);
                let source = typed.as_ref().map(|_| TitleSource::Prompt);
                (typed, source)
            }
        };
    ChatEntry {
        harness: flavor.kind(),
        title,
        title_source,
        cwd: row.directory.filter(|dir| !dir.is_empty()),
        created_ms: row.created_ms,
        updated_ms: row.updated_ms.or(row.created_ms).unwrap_or(0),
        message_count: count,
        source_path: db.to_path_buf(),
        originator: None,
        archived: row.archived_ms.is_some(),
        resume: flavor.resume(&row.id),
        session_id: row.id,
    }
}

/// OpenCode 2.x: `session_v2` and the `session_message` log.
fn query_v2(conn: &Connection, db: &Path, flavor: Flavor) -> rusqlite::Result<Vec<ChatEntry>> {
    let rows = session_rows(conn, "session_v2")?;
    if rows.is_empty() {
        return Ok(Vec::new());
    }
    let has_log = columns(conn, "session_message")
        .is_ok_and(|cols| ["session_id", "type", "seq", "data"].iter().all(|c| cols.contains(*c)));
    let counts = has_log
        .then(|| {
            grouped_counts(
                conn,
                "SELECT session_id, count(*) FROM session_message
                 WHERE type IN ('user', 'assistant') GROUP BY session_id",
            )
        })
        .flatten();
    let first_text = |id: &str| -> Option<String> {
        if !has_log {
            return None;
        }
        let text: Option<Option<String>> = conn
            .query_row(
                "SELECT json_extract(data, '$.text') FROM session_message
                 WHERE session_id = ?1 AND type = 'user' ORDER BY seq LIMIT 1",
                [id],
                |row| row.get(0),
            )
            .optional()
            .ok()?;
        text.flatten().as_deref().and_then(title_line)
    };
    Ok(rows
        .into_iter()
        .map(|row| {
            let count = counts.as_ref().map(|counts| counts.get(&row.id).copied().unwrap_or(0));
            db_entry(row, db, flavor, count, first_text)
        })
        .collect())
}

/// OpenCode 1.2+: `session`, `message`, `part`.
fn query_v1(conn: &Connection, db: &Path, flavor: Flavor) -> rusqlite::Result<Vec<ChatEntry>> {
    let rows = session_rows(conn, "session")?;
    let counts =
        columns(conn, "message").ok().filter(|cols| cols.contains("session_id")).and_then(|_| {
            grouped_counts(conn, "SELECT session_id, count(*) FROM message GROUP BY session_id")
        });
    let first_text = FirstUserText::prepare(conn);
    Ok(rows
        .into_iter()
        .map(|row| {
            let count = counts.as_ref().map(|counts| counts.get(&row.id).copied().unwrap_or(0));
            db_entry(row, db, flavor, count, |id| first_text.as_ref().and_then(|q| q.get(conn, id)))
        })
        .collect())
}

/// `New session - 2026-10-01T10:00:00.000Z`: the name OpenCode gives before
/// it generates a title (`Child session - ` for subagents).
fn is_placeholder(title: &str) -> bool {
    ["New session - ", "Child session - "].iter().any(|prefix| {
        title
            .strip_prefix(prefix)
            .is_some_and(|rest| rest.as_bytes().first().is_some_and(u8::is_ascii_digit))
    })
}

fn grouped_counts(conn: &Connection, sql: &str) -> Option<HashMap<String, u64>> {
    let mut stmt = conn.prepare(sql).ok()?;
    let rows =
        stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))).ok()?;
    rows.map(|row| row.map(|(id, count)| (id, u64::try_from(count).unwrap_or(0))))
        .collect::<Result<_, _>>()
        .ok()
}

/// The first text part of the first user message of a session (S1).
struct FirstUserText;

impl FirstUserText {
    const SQL: &str =
        "SELECT json_extract(p.data, '$.text') FROM part p JOIN message m ON p.message_id = m.id
        WHERE m.session_id = ?1 AND json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
          AND coalesce(json_extract(p.data, '$.synthetic'), 0) = 0
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

/// Where a JSON storage generation keeps sessions, messages and parts.
#[derive(Clone, Copy)]
enum Layout {
    /// J1: `storage/{session/<project>,message/<id>,part/<msg>}`.
    Global,
    /// J0: `storage/session/{info,message/<id>,part/<id>/<msg>}`.
    PerProject,
}

impl Layout {
    fn session_files(self, storage: &Path) -> Vec<PathBuf> {
        match self {
            Self::Global => {
                let Ok(projects) = fs::read_dir(storage.join("session")) else { return Vec::new() };
                projects
                    .flatten()
                    .filter(|project| project.file_type().is_ok_and(|kind| kind.is_dir()))
                    .flat_map(|project| json_files(&project.path()))
                    .collect()
            }
            Self::PerProject => json_files(&storage.join("session/info")),
        }
    }

    fn message_dir(self, storage: &Path, session: &str) -> PathBuf {
        match self {
            Self::Global => storage.join("message").join(session),
            Self::PerProject => storage.join("session/message").join(session),
        }
    }

    fn part_dir(self, storage: &Path, session: &str, message: &str) -> PathBuf {
        match self {
            Self::Global => storage.join("part").join(message),
            Self::PerProject => storage.join("session/part").join(session).join(message),
        }
    }
}

fn json_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(children) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = children
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    files
}

fn json_sessions(
    storage: &Path,
    layout: Layout,
    flavor: Flavor,
    resume: bool,
    max: usize,
) -> Vec<ChatEntry> {
    let mut files: Vec<(PathBuf, FileStamp)> = layout
        .session_files(storage)
        .into_iter()
        .filter_map(|path| {
            let stamp = FileStamp::of(&fs::metadata(&path).ok()?);
            Some((path, stamp))
        })
        .collect();
    files.sort_by(|a, b| b.1.mtime_ms.cmp(&a.1.mtime_ms).then_with(|| a.0.cmp(&b.0)));
    files.truncate(max);
    files
        .into_iter()
        .filter_map(|(path, stamp)| {
            JsonCache::get_or_read(&path, stamp, flavor, resume, || {
                json_session(storage, layout, flavor, &path, stamp.mtime_ms, resume)
            })
        })
        .collect()
}

/// Parsed JSON sessions by file stamp. A DB write rescans the whole root,
/// and the JSON generations it sits beside no longer change; without this
/// every WAL write would re-read up to 2000 sessions and their messages.
/// A session's file is rewritten on each of its messages, so its stamp
/// covers the message count and the first prompt.
struct JsonCache;

type JsonKey = (PathBuf, Flavor, bool);
type JsonSlot = (FileStamp, Option<ChatEntry>);

static JSON_CACHE: LazyLock<Mutex<HashMap<JsonKey, JsonSlot>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

impl JsonCache {
    const MAX: usize = 20_000;

    fn get_or_read(
        path: &Path,
        stamp: FileStamp,
        flavor: Flavor,
        resume: bool,
        read: impl FnOnce() -> Option<ChatEntry>,
    ) -> Option<ChatEntry> {
        let key = (path.to_path_buf(), flavor, resume);
        if let Ok(cache) = JSON_CACHE.lock()
            && let Some((known, entry)) = cache.get(&key)
            && *known == stamp
        {
            return entry.clone();
        }
        let entry = read();
        if let Ok(mut cache) = JSON_CACHE.lock() {
            if cache.len() >= Self::MAX {
                cache.clear();
            }
            cache.insert(key, (stamp, entry.clone()));
        }
        entry
    }
}

fn json_session(
    storage: &Path,
    layout: Layout,
    flavor: Flavor,
    path: &Path,
    mtime: i64,
    resume: bool,
) -> Option<ChatEntry> {
    let info = read_whole_json(path).ok()??;
    let id = info.get("id")?.as_str().filter(|id| !id.is_empty())?.to_owned();
    if info.get("parentID").is_some_and(|parent| !parent.is_null()) {
        return None;
    }
    let time = |key: &str| info.pointer(&format!("/time/{key}")).and_then(Value::as_i64);
    let messages = json_files(&layout.message_dir(storage, &id));
    let probe = MessageProbe::read(storage, layout, &id, &messages);
    let named = info
        .get("title")
        .and_then(Value::as_str)
        .filter(|title| !is_placeholder(title))
        .and_then(title_line);
    let (title, title_source) = match (named, probe.first_prompt) {
        (Some(title), _) => (Some(title), Some(TitleSource::Ai)),
        (None, Some(prompt)) => (Some(prompt), Some(TitleSource::Prompt)),
        (None, None) => (None, None),
    };
    let directory = info.get("directory").and_then(Value::as_str).filter(|dir| !dir.is_empty());
    let created_ms = time("created");
    Some(ChatEntry {
        harness: flavor.kind(),
        title,
        title_source,
        cwd: directory.map(str::to_owned).or(probe.cwd),
        created_ms,
        updated_ms: time("updated").or(created_ms).unwrap_or(mtime),
        message_count: Some(messages.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: time("archived").is_some(),
        resume: if resume { flavor.resume(&id) } else { Resume::ReadOnly },
        session_id: id,
    })
}

/// What the first messages of a JSON session tell: the first typed prompt
/// and (for J0, whose sessions have no folder) the working folder.
#[derive(Default)]
struct MessageProbe {
    first_prompt: Option<String>,
    cwd: Option<String>,
}

impl MessageProbe {
    fn read(storage: &Path, layout: Layout, session: &str, messages: &[PathBuf]) -> Self {
        let mut probe = Self::default();
        for path in messages.iter().take(MESSAGE_PROBE) {
            let Ok(Some(message)) = read_whole_json(path) else { continue };
            if probe.cwd.is_none() {
                probe.cwd = ["/path/cwd", "/path/root", "/metadata/assistant/path/cwd"]
                    .iter()
                    .find_map(|at| message.pointer(at).and_then(Value::as_str))
                    .filter(|cwd| !cwd.is_empty())
                    .map(str::to_owned);
            }
            if probe.first_prompt.is_none()
                && message.get("role").and_then(Value::as_str) == Some("user")
            {
                probe.first_prompt = inline_text(&message).or_else(|| {
                    let id = message.get("id").and_then(Value::as_str)?;
                    part_text(&layout.part_dir(storage, session, id))
                });
            }
            if probe.first_prompt.is_some() && probe.cwd.is_some() {
                break;
            }
        }
        probe
    }
}

/// Text parts inside the message (J0 message formats v1 and v2).
fn inline_text(message: &Value) -> Option<String> {
    message.get("parts")?.as_array()?.iter().find_map(text_of_part)
}

fn part_text(dir: &Path) -> Option<String> {
    json_files(dir)
        .iter()
        .take(MESSAGE_PROBE)
        .find_map(|path| read_whole_json(path).ok().flatten().as_ref().and_then(text_of_part))
}

fn text_of_part(part: &Value) -> Option<String> {
    let flag = |key: &str| part.get(key) == Some(&Value::Bool(true));
    if part.get("type").and_then(Value::as_str) != Some("text")
        || flag("synthetic")
        || flag("ignored")
    {
        return None;
    }
    part.get("text").and_then(prompt_text)
}

/// J0 storage dirs: `project/<slug>/storage`, and the 0.0.53-0.0.55
/// layout nested under the absolute repo path (found by a bounded walk that
/// stays out of OpenCode's own big dirs and out of repo checkouts).
fn legacy_storage_dirs(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Ok(projects) = fs::read_dir(root.join("project")) {
        for project in projects.flatten() {
            let storage = project.path().join("storage");
            if storage.join("session/info").is_dir() {
                out.push(storage);
            }
        }
    }
    const OWN: [&str; 12] = [
        "storage",
        "project",
        "snapshot",
        "bin",
        "log",
        "tool-output",
        "worktree",
        "worktrees",
        "plugin",
        "plugins",
        "cache",
        "state",
    ];
    let mut stack: Vec<(PathBuf, u32)> = fs::read_dir(root)
        .map(|children| {
            children
                .flatten()
                .filter(|child| child.file_type().is_ok_and(|kind| kind.is_dir()))
                .filter(|child| child.file_name().to_str().is_some_and(|name| !OWN.contains(&name)))
                .map(|child| (child.path(), 1))
                .collect()
        })
        .unwrap_or_default();
    let mut visited = 0;
    while let Some((dir, depth)) = stack.pop() {
        visited += 1;
        if visited > LEGACY_WALK_MAX {
            break;
        }
        let storage = dir.join("storage");
        if storage.join("session/info").is_dir() {
            out.push(storage);
        }
        if depth >= 12 || dir.join(".git").exists() {
            continue;
        }
        let Ok(children) = fs::read_dir(&dir) else { continue };
        for child in children.flatten() {
            let name = child.file_name();
            let skip = name.to_str().is_none_or(|name| {
                name.starts_with('.') || name == "node_modules" || name == "storage"
            });
            if !skip && child.file_type().is_ok_and(|kind| kind.is_dir()) {
                stack.push((child.path(), depth + 1));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}
