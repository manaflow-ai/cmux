//! The daemon stores a rollback must check (plans/cmux-next/updates-and-announcements.md,
//! Rollback): the newest schema of each store this build reads, and the
//! newest schema each store holds on disk. An older build refuses to open a
//! store whose schema is newer than its own, so the app compares the two
//! before it swaps in a kept build.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::Context;
use rusqlite::{Connection, OpenFlags, OptionalExtension};

/// Every store a rollback checks: its name, its file in a session directory,
/// and the newest schema this build reads.
const STORES: &[(&str, &str, i64)] = &[
    (
        "workspace_registry",
        crate::workspace_registry::WORKSPACE_REGISTRY_FILE,
        crate::workspace_registry::SCHEMA_VERSION,
    ),
    (
        "conversation_store",
        crate::conversation_store::CONVERSATIONS_FILE,
        crate::conversation_store::SCHEMA_VERSION,
    ),
];

/// The newest schema of every store this build reads.
pub fn readable() -> BTreeMap<String, i64> {
    STORES.iter().map(|(name, _, version)| ((*name).to_string(), *version)).collect()
}

/// What a check of the stored schemas found.
#[derive(Debug, PartialEq, Eq)]
pub enum Stored {
    /// Each session was read: the newest schema each store holds.
    Schemas(BTreeMap<String, i64>),
    /// The check's time ended first. `sessions` session folders of the state
    /// root hold a store, and this call read `sessions_read` of them.
    NotReady { sessions: usize, sessions_read: usize },
}

/// The newest schema each store holds in any session under `state_root`.
/// A store that no session has written yet is absent. A store that cannot be
/// read is an error: the caller must not guess.
///
/// `end` is the check's end time. The caller of the check ends its process
/// after a fixed time, and a check that is ended gives no answer. So before
/// each session after the first, the check reads the clock; at or after
/// `end` it stops and says how far it is ([`Stored::NotReady`]). The first
/// session of a call is always read, so each call reads 1 session or more.
/// The check keeps nothing between 2 calls: a call after it starts at the
/// first session again, in the same order (the session folders sorted by
/// path), and is faster only because the files are in the file cache. With
/// no `end` it reads each session.
pub fn stored_until(state_root: &Path, end: Option<Instant>) -> anyhow::Result<Stored> {
    let mut found = BTreeMap::new();
    let entries = match std::fs::read_dir(state_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Stored::Schemas(found));
        }
        Err(error) => {
            return Err(error).with_context(|| format!("read {}", state_root.display()));
        }
    };
    // The session folders that hold a store, before the first read: an
    // answer before the end names how many there are.
    let mut sessions: Vec<PathBuf> = Vec::new();
    for entry in entries {
        let session = entry.with_context(|| format!("read {}", state_root.display()))?.path();
        if session.is_dir() && STORES.iter().any(|(_, file, _)| session.join(file).is_file()) {
            sessions.push(session);
        }
    }
    // The same order in each call.
    sessions.sort();
    for (sessions_read, session) in sessions.iter().enumerate() {
        if sessions_read > 0 && end.is_some_and(|end| Instant::now() >= end) {
            return Ok(Stored::NotReady { sessions: sessions.len(), sessions_read });
        }
        for (name, file, _) in STORES {
            let path = session.join(file);
            // A store can go away after the listing (a session that is
            // reset is renamed, then deleted): then it is no store.
            if !path.is_file() {
                continue;
            }
            if let Some(version) = schema_version(&path)? {
                let newest = found.entry((*name).to_string()).or_insert(version);
                *newest = (*newest).max(version);
            }
        }
    }
    Ok(Stored::Schemas(found))
}

/// `meta.schema_version` of the SQLite store at `path`, read-only; nil when
/// the store has no schema yet.
fn schema_version(path: &Path) -> anyhow::Result<Option<i64>> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("open {}", path.display()))?;
    connection.busy_timeout(Duration::from_millis(500))?;
    let has_meta: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |row| row.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let value: Option<String> = connection
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
        .optional()?;
    value
        .map(|value| {
            value.parse::<i64>().with_context(|| format!("{} schema is invalid", path.display()))
        })
        .transpose()
}

const USAGE: &str = "usage: cmux-tui __store-schemas [--stored [--within-ms N]]";

/// The time of `--within-ms N`: `text` as a count of milliseconds, nil when
/// it is not one.
pub fn within_of(text: &str) -> Option<Duration> {
    text.parse::<u64>().ok().map(Duration::from_millis)
}

/// `cmux-tui __store-schemas [--stored [--within-ms N]]`: one JSON object
/// of store name to schema, what this build reads or (`--stored`) what the
/// state directory holds. Internal plumbing for the app's build stamp and
/// rollback check.
///
/// `--within-ms N` is the check's own end time, N milliseconds after its
/// start, below the time at which its caller ends the process. A check that
/// is not at its end then stops before the next session, prints
/// `{"not_ready":{"sessions":M,"sessions_read":R}}` and still exits 0
/// ([`stored_until`]). A caller that knows only the object of numbers reads
/// that as no answer, as it reads a process that was ended.
pub fn run(args: &[String]) -> Result<String, String> {
    let began = Instant::now();
    let within = match args {
        [] => return serde_json::to_string(&readable()).map_err(|error| error.to_string()),
        [flag] if flag == "--stored" => None,
        [flag, within, millis] if flag == "--stored" && within == "--within-ms" => {
            Some(within_of(millis).ok_or_else(|| USAGE.to_string())?)
        }
        _ => return Err(USAGE.to_string()),
    };
    let root = crate::platform::workspace_state_dir()
        .ok_or_else(|| "no workspace state directory".to_string())?;
    // A time that the clock cannot hold is no end time.
    let end = within.and_then(|within| began.checked_add(within));
    let answer = match stored_until(&root, end).map_err(|error| format!("{error:#}"))? {
        Stored::Schemas(schemas) => serde_json::to_string(&schemas),
        Stored::NotReady { sessions, sessions_read } => serde_json::to_string(&serde_json::json!({
            "not_ready": { "sessions": sessions, "sessions_read": sessions_read },
        })),
    };
    answer.map_err(|error| error.to_string())
}
