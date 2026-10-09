//! Keeps saved session data on disk when the workspace registry cannot be
//! opened.
//!
//! Two failures used to put that data at risk:
//!
//! - The database file is missing while its `-wal` or `-journal` sidecar
//!   still holds data. Opening the path creates a fresh, empty database in
//!   place, and SQLite discards the stale sidecar against it.
//! - The database is physically unreadable: SQLite reports it corrupt or not
//!   a database on the first read. The files stayed where a reset or a new
//!   session overwrites them.
//!
//! In both cases the files are moved together into
//! `<session dir>/registry-recovery/<unix ms>/` and the open fails with
//! [`RegistryQuarantined`], naming that directory. The next open starts a new
//! registry beside the preserved files rather than on top of them.
//!
//! Everything else stays in place, because the data may still be good:
//!
//! - a newer-schema registry, which the build that wrote it can open (the
//!   unsupported-schema preflight keeps refusing it), including a schema this
//!   SQLite cannot parse ("malformed database schema");
//! - logical integrity failures after migration (foreign-key violations,
//!   `quick_check`, invariant checks): a daemon bug there must fail every
//!   start with the data intact, not quarantine every upgraded machine;
//! - lock contention and I/O errors.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::{Connection, ErrorCode};

use super::{
    SCHEMA_VERSION, UnsupportedWorkspaceRegistrySchema, meta_value,
    open_registry_database_read_only,
};

pub(crate) const REGISTRY_RECOVERY_DIR: &str = "registry-recovery";

/// The sidecars SQLite keeps next to a database, in the order they are moved
/// after the database itself.
const SIDECAR_SUFFIXES: [&str; 3] = ["-wal", "-journal", "-shm"];

/// The registry could not be opened and its files were moved aside.
#[derive(Debug)]
pub struct RegistryQuarantined {
    pub recovery_dir: PathBuf,
    pub reason: String,
}

impl std::fmt::Display for RegistryQuarantined {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}. The saved session files were moved to {} and are kept there; start again to \
             begin a new session, or restore from that directory",
            self.reason,
            self.recovery_dir.display()
        )
    }
}

impl std::error::Error for RegistryQuarantined {}

pub(crate) fn sidecar_path(db_path: &Path, suffix: &str) -> PathBuf {
    let mut name = db_path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn has_data(path: &Path) -> bool {
    fs::metadata(path).map(|metadata| metadata.is_file() && metadata.len() > 0).unwrap_or(false)
}

/// The sidecars that hold data while the database file itself is missing.
/// An empty `-shm` alone carries nothing worth keeping.
pub(crate) fn orphaned_sidecars(db_path: &Path) -> Vec<PathBuf> {
    if db_path.exists() {
        return Vec::new();
    }
    ["-wal", "-journal"]
        .iter()
        .map(|suffix| sidecar_path(db_path, suffix))
        .filter(|path| has_data(path))
        .collect()
}

/// Moves an orphaned `-wal` or `-journal` aside before opening the path can
/// create an empty database over it. The caller holds the session's locks.
pub(super) fn refuse_orphaned_journal(db_path: &Path) -> anyhow::Result<()> {
    if orphaned_sidecars(db_path).is_empty() {
        return Ok(());
    }
    let reason = "the database file is missing but its journal still holds data";
    Err(quarantine(db_path, reason)?.into())
}

/// Reads the schema once, while the caller still holds the session's locks.
/// A database SQLite reports corrupt or not a database is closed and moved
/// aside; anything else, including a schema this SQLite cannot parse, is
/// left to the normal open path.
pub(super) fn quarantine_if_unreadable(
    db_path: &Path,
    connection: Connection,
) -> anyhow::Result<Connection> {
    let probe =
        connection.query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0));
    // rusqlite reports a failed prepare as `SqliteFailure` or `SqlInputError`;
    // read the SQLite code from either.
    let Err(error) = probe else {
        return Ok(connection);
    };
    let reason = error.to_string();
    let unreadable = matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
    );
    if !unreadable || reason.contains("malformed database schema") {
        return Ok(connection);
    }
    drop(connection);
    Err(quarantine(db_path, &reason)?.into())
}

/// Moves the database and every sidecar present into a fresh recovery
/// directory beside them. The database goes first: an interruption then
/// leaves only sidecars behind, which the next open moves aside as orphans,
/// and never a database stripped of the WAL holding its latest commits. When
/// a rename fails (a reader holding a sidecar open on Windows), the files
/// already moved go back, so a set is never split across directories.
///
/// The caller must hold the session's writer lease, with no connection open.
pub(crate) fn quarantine(db_path: &Path, reason: &str) -> anyhow::Result<RegistryQuarantined> {
    let session_dir = db_path
        .parent()
        .with_context(|| format!("workspace registry has no directory: {}", db_path.display()))?;
    let recovery_root = session_dir.join(REGISTRY_RECOVERY_DIR);
    fs::create_dir_all(&recovery_root).with_context(|| {
        format!("create registry recovery directory {}", recovery_root.display())
    })?;
    let _ = crate::platform::restrict_directory(&recovery_root);
    let recovery_dir = unique_recovery_dir(&recovery_root)?;
    let mut sources = vec![db_path.to_path_buf()];
    sources.extend(SIDECAR_SUFFIXES.iter().map(|suffix| sidecar_path(db_path, suffix)));
    let mut moved: Vec<(PathBuf, PathBuf)> = Vec::new();
    for source in sources.into_iter().filter(|source| source.exists()) {
        let destination = recovery_dir.join(source.file_name().unwrap_or_default());
        if let Err(error) = fs::rename(&source, &destination) {
            for (original, kept) in moved.iter().rev() {
                let _ = fs::rename(kept, original);
            }
            let _ = fs::remove_dir(&recovery_dir);
            return Err(error).with_context(|| {
                format!("move {} aside to {}", source.display(), destination.display())
            });
        }
        moved.push((source, destination));
    }
    let _ = crate::platform::sync_directory(&recovery_dir);
    let _ = crate::platform::sync_directory(session_dir);
    Ok(RegistryQuarantined { recovery_dir, reason: reason.to_string() })
}

fn unique_recovery_dir(recovery_root: &Path) -> anyhow::Result<PathBuf> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    for attempt in 0u32..100 {
        let name = if attempt == 0 { millis.to_string() } else { format!("{millis}-{attempt}") };
        let candidate = recovery_root.join(name);
        match fs::create_dir(&candidate) {
            Ok(()) => {
                let _ = crate::platform::restrict_directory(&candidate);
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("create registry recovery directory {}", candidate.display())
                });
            }
        }
    }
    anyhow::bail!("no free registry recovery directory under {}", recovery_root.display())
}

pub(super) fn preflight_unsupported_schema(
    database_path: &Path,
) -> Option<UnsupportedWorkspaceRegistrySchema> {
    // This probe only improves a writer-conflict error. Initialization remains
    // authoritative, so read-only I/O and SQL failures must not block startup.
    try_preflight_unsupported_schema(database_path).ok().flatten()
}

fn try_preflight_unsupported_schema(
    database_path: &Path,
) -> anyhow::Result<Option<UnsupportedWorkspaceRegistrySchema>> {
    let connection = open_registry_database_read_only(database_path)?;
    connection.busy_timeout(std::time::Duration::from_millis(500))?;
    let has_meta: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |row| row.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let Some(found) = meta_value(&connection, "schema_version")? else {
        return Ok(None);
    };
    let found = found.parse::<i64>().context("workspace registry schema is invalid")?;
    if found <= SCHEMA_VERSION {
        return Ok(None);
    }
    Ok(Some(UnsupportedWorkspaceRegistrySchema {
        found,
        newest_supported: SCHEMA_VERSION,
        database_path: Some(database_path.to_path_buf()),
        registry_id: meta_value(&connection, "registry_id")?,
    }))
}

#[cfg(test)]
#[path = "open_guard_tests.rs"]
mod tests;
