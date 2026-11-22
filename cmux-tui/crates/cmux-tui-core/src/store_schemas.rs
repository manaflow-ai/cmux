//! The daemon stores a rollback must check (plans/cmux-next/updates-and-announcements.md,
//! Rollback): the newest schema of each store this build reads, and the
//! newest schema each store holds on disk. An older build refuses to open a
//! store whose schema is newer than its own, so the app compares the two
//! before it swaps in a kept build.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

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

/// The newest schema each store holds in any session under `state_root`.
/// A store that no session has written yet is absent. A store that cannot be
/// read is an error: the caller must not guess.
pub fn stored(state_root: &Path) -> anyhow::Result<BTreeMap<String, i64>> {
    let mut found = BTreeMap::new();
    let sessions = match std::fs::read_dir(state_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(found),
        Err(error) => {
            return Err(error).with_context(|| format!("read {}", state_root.display()));
        }
    };
    for entry in sessions {
        let session = entry.with_context(|| format!("read {}", state_root.display()))?.path();
        if !session.is_dir() {
            continue;
        }
        for (name, file, _) in STORES {
            let path = session.join(file);
            if !path.is_file() {
                continue;
            }
            if let Some(version) = schema_version(&path)? {
                let newest = found.entry((*name).to_string()).or_insert(version);
                *newest = (*newest).max(version);
            }
        }
    }
    Ok(found)
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

/// `cmux-tui __store-schemas [--stored]`: one JSON object of store name to
/// schema, what this build reads or (`--stored`) what the state directory
/// holds. Internal plumbing for the app's build stamp and rollback check.
pub fn run(args: &[String]) -> Result<String, String> {
    let stored_only = match args {
        [] => false,
        [flag] if flag == "--stored" => true,
        _ => return Err("usage: cmux-tui __store-schemas [--stored]".to_string()),
    };
    let schemas = if stored_only {
        let root = crate::platform::workspace_state_dir()
            .ok_or_else(|| "no workspace state directory".to_string())?;
        stored(&root).map_err(|error| format!("{error:#}"))?
    } else {
        readable()
    };
    serde_json::to_string(&schemas).map_err(|error| error.to_string())
}

#[cfg(test)]
#[path = "store_schemas_tests.rs"]
mod tests;
