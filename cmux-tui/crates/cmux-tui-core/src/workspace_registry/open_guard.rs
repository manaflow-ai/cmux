//! Keeps saved session data on disk when the workspace registry cannot be
//! opened.
//!
//! Two failures used to put that data at risk:
//!
//! - The database file is missing while its `-wal` or `-journal` sidecar
//!   still holds data. Opening the path creates a fresh, empty database in
//!   place, and SQLite discards the stale sidecar against it.
//! - The database is corrupt (SQLite reports it, `quick_check` fails, or a
//!   foreign-key violation remains). The files stay where a later open, or a
//!   reset, can overwrite them.
//!
//! In both cases the files are moved together into
//! `<session dir>/registry-recovery/<unix ms>/` and the open fails with
//! [`RegistryQuarantined`], naming that directory. The next open starts a new
//! registry beside the preserved files rather than on top of them.
//!
//! A newer-schema registry is not moved: the newer build that wrote it can
//! still open it, so the unsupported-schema preflight keeps refusing it in
//! place. Lock contention and I/O errors are not moved either; they are not
//! evidence that the data is bad.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::ErrorCode;

use super::{
    SCHEMA_VERSION, UnsupportedWorkspaceRegistrySchema, meta_value,
    open_registry_database_read_only,
};

pub(crate) const REGISTRY_RECOVERY_DIR: &str = "registry-recovery";

/// The sidecars SQLite keeps next to a database, in the order they are moved
/// after the database itself.
const SIDECAR_SUFFIXES: [&str; 3] = ["-wal", "-journal", "-shm"];

/// Integrity failures detected by the registry itself (as opposed to SQLite
/// error codes). Opening reports these instead of plain messages so the open
/// guard can tell corruption from other failures without matching text.
#[derive(Debug)]
pub(crate) struct RegistryIntegrityError(String);

impl std::fmt::Display for RegistryIntegrityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RegistryIntegrityError {}

pub(crate) fn integrity_error(message: impl Into<String>) -> anyhow::Error {
    RegistryIntegrityError(message.into()).into()
}

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

/// Whether `error` shows the registry's contents are damaged, as opposed to
/// a lock, permission or I/O failure that says nothing about the data.
pub(crate) fn is_corruption(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if cause.downcast_ref::<RegistryIntegrityError>().is_some() {
            return true;
        }
        matches!(
            cause.downcast_ref::<rusqlite::Error>(),
            Some(rusqlite::Error::SqliteFailure(failure, _))
                if matches!(failure.code, ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
        )
    })
}

/// Moves the database and every sidecar present into a fresh recovery
/// directory beside them. The database goes first: an interruption then
/// leaves only sidecars behind, which the next open moves aside as orphans,
/// and never a database stripped of the WAL holding its latest commits.
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
    for source in sources {
        if !source.exists() {
            continue;
        }
        let file_name = source.file_name().with_context(|| {
            format!("workspace registry file has no name: {}", source.display())
        })?;
        let destination = recovery_dir.join(file_name);
        fs::rename(&source, &destination).with_context(|| {
            format!("move {} aside to {}", source.display(), destination.display())
        })?;
    }
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

/// Opens the registry through `open`, keeping its files when that fails.
///
/// The caller holds the session's locks. An orphaned journal is moved aside
/// before `open` can create an empty database over it. When `open` fails on
/// corruption it has already released the locks with its connection, so
/// `relock` takes them again before anything moves; when that fails, the
/// files stay in place and the original error is returned.
pub(super) fn open_or_quarantine<T, Locks>(
    db_path: &Path,
    relock: impl FnOnce() -> anyhow::Result<Locks>,
    open: impl FnOnce() -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    if !orphaned_sidecars(db_path).is_empty() {
        let reason = "the database file is missing but its journal still holds data";
        return Err(quarantine(db_path, reason)?.into());
    }
    let error = match open() {
        Ok(opened) => return Ok(opened),
        Err(error) if is_corruption(&error) => error,
        Err(error) => return Err(error),
    };
    let Ok(_locks) = relock() else { return Err(error) };
    match quarantine(db_path, &format!("{error:#}")) {
        Ok(quarantined) => Err(quarantined.into()),
        Err(move_error) => Err(error.context(format!("{move_error:#}"))),
    }
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
