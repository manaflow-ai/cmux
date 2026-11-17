//! Startup self-recovery for a workspace registry no start can open.
//!
//! A Cloud machine that was hard-stopped can leave a registry SQLite reports
//! malformed (`database disk image is malformed`, a failed `quick_check`
//! such as `Tree N page N cell N: invalid page number N`, or a persistent
//! `disk I/O error`), or a registry holding more interrupted resource
//! creations than a start can settle. Every start then fails the same way and
//! the machine's supervisor restarts the daemon forever.
//!
//! [`registry_startup_damage`] recognizes those failures and nothing else: a
//! newer-schema registry, lock contention and every other open error are left
//! to the normal startup error. [`quarantine_session_registry`] then takes
//! the session's guard and writer lease (so no other daemon has the registry
//! open), confirms physical damage on a fresh connection, and moves
//! the database and its sidecars into
//! `<session dir>/registry-recovery/<unix ms>/`, beside a `reason.txt`. The
//! next open starts a new registry; the old files are kept for inspection.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::ErrorCode;

use super::{
    SESSION_WRITER_LOCK_FILE, SessionLease, UnsupportedWorkspaceRegistrySchema,
    WORKSPACE_REGISTRY_FILE, acquire_existing_session_guard, open_registry_database,
    persistent_session_state_dir,
};
use crate::platform;

/// The directory inside a session directory that keeps quarantined registries.
pub const REGISTRY_RECOVERY_DIR: &str = "registry-recovery";

/// The sidecars SQLite keeps next to a database, moved after the database.
const SIDECAR_SUFFIXES: [&str; 3] = ["-wal", "-journal", "-shm"];

/// The registry's structural check (`quick_check`) reported damage on open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryIntegrityFailure {
    pub report: String,
}

impl std::fmt::Display for RegistryIntegrityFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "workspace registry integrity check failed: {}", self.report)
    }
}

impl std::error::Error for RegistryIntegrityFailure {}

/// The registry holds more interrupted creations than one start can settle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnrecoverableInterruptedCreations {
    pub message: &'static str,
}

impl std::fmt::Display for UnrecoverableInterruptedCreations {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message)
    }
}

impl std::error::Error for UnrecoverableInterruptedCreations {}

/// Why a registry open failed in a way only a fresh registry gets past.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryStartupDamage {
    /// SQLite reports the file corrupt, not a database, or failing I/O, or
    /// its structural check failed. Confirmed on a fresh connection before
    /// the files move.
    Unreadable(String),
    /// More interrupted resource or workspace creations than a start settles.
    InterruptedCreations(String),
}

impl RegistryStartupDamage {
    pub fn reason(&self) -> &str {
        match self {
            Self::Unreadable(reason) | Self::InterruptedCreations(reason) => reason,
        }
    }
}

/// Classifies a failed registry open. `None` for every failure a later start
/// may get past or that must keep its data in place (a newer schema, a busy
/// lock, a missing directory, a malformed schema a newer SQLite may parse).
pub fn registry_startup_damage(error: &anyhow::Error) -> Option<RegistryStartupDamage> {
    // RED: recognizes nothing yet.
    let _ = error;
    None
}

fn sqlite_reports_damage(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase | ErrorCode::SystemIoFailure)
    ) && !error.to_string().contains("malformed database schema")
}

/// Moves the session's registry aside after [`registry_startup_damage`]
/// recognized its open failure, and returns the recovery directory.
///
/// Refuses (and moves nothing) when another process holds the session, when
/// there is no registry, or when the damage was physical and a fresh
/// `quick_check` of the file now passes: a transient I/O failure
/// must not cost the session its state.
pub fn quarantine_session_registry(
    root: &Path,
    session_name: &str,
    damage: &RegistryStartupDamage,
) -> anyhow::Result<PathBuf> {
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    let session_dir = persistent_session_state_dir(&root, session_name);
    let db_path = platform::normalize_filesystem_path(session_dir.join(WORKSPACE_REGISTRY_FILE));
    anyhow::ensure!(
        db_path.is_file(),
        "no workspace registry to move aside at {}",
        db_path.display()
    );
    // The same guard and writer lease every open takes: while they are held
    // here no daemon has this registry open, and none can open it.
    let _session_guard = acquire_existing_session_guard(&root, session_name)?;
    let _lease = SessionLease::acquire(&platform::normalize_filesystem_path(
        session_dir.join(SESSION_WRITER_LOCK_FILE),
    ))?;
    if let RegistryStartupDamage::Unreadable(_) = damage {
        confirm_physical_damage(&db_path)?;
    }
    move_registry_aside(&session_dir, &db_path, damage.reason())
}

/// Fails unless a fresh connection also finds the file damaged. The caller
/// holds the writer lease, and the check only reads.
fn confirm_physical_damage(db_path: &Path) -> anyhow::Result<()> {
    let probe = (|| -> anyhow::Result<String> {
        let connection = open_registry_database(db_path)?;
        Ok(connection.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))?)
    })();
    match probe {
        Ok(report) if report == "ok" => anyhow::bail!(
            "workspace registry {} passed a fresh quick_check; it stays in place",
            db_path.display()
        ),
        Ok(_) => Ok(()),
        Err(error)
            if error
                .chain()
                .filter_map(|cause| cause.downcast_ref::<rusqlite::Error>())
                .any(sqlite_reports_damage) =>
        {
            Ok(())
        }
        Err(error) => Err(error.context(format!(
            "could not confirm damage of workspace registry {}; it stays in place",
            db_path.display()
        ))),
    }
}

/// The database goes first: an interruption then leaves only sidecars, never
/// a database stripped of the WAL holding its latest commits. A failed rename
/// puts back what already moved, so a set is never split.
fn move_registry_aside(
    session_dir: &Path,
    db_path: &Path,
    reason: &str,
) -> anyhow::Result<PathBuf> {
    let recovery_root = session_dir.join(REGISTRY_RECOVERY_DIR);
    fs::create_dir_all(&recovery_root).with_context(|| {
        format!("create registry recovery directory {}", recovery_root.display())
    })?;
    let _ = platform::restrict_directory(&recovery_root);
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
    let _ = fs::write(recovery_dir.join("reason.txt"), format!("{reason}\n"));
    let _ = platform::sync_directory(&recovery_dir);
    let _ = platform::sync_directory(session_dir);
    Ok(recovery_dir)
}

fn sidecar_path(db_path: &Path, suffix: &str) -> PathBuf {
    let mut name = db_path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn unique_recovery_dir(recovery_root: &Path) -> anyhow::Result<PathBuf> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    for attempt in 0..100u32 {
        let name = match attempt {
            0 => millis.to_string(),
            _ => format!("{millis}-{attempt}"),
        };
        let candidate = recovery_root.join(name);
        match fs::create_dir(&candidate) {
            Ok(()) => {
                let _ = platform::restrict_directory(&candidate);
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

/// What a start does after its registry open failed: `None` when the failure
/// is not damage a fresh registry recovers from (report the original error),
/// otherwise the result of moving the registry aside. On `Some(Ok(dir))` the
/// caller opens again and gets a new, empty registry.
pub fn recover_registry_after_failed_open(
    root: &Path,
    session_name: &str,
    error: &anyhow::Error,
) -> Option<anyhow::Result<(RegistryStartupDamage, PathBuf)>> {
    let damage = registry_startup_damage(error)?;
    Some(quarantine_session_registry(root, session_name, &damage).map(|dir| (damage, dir)))
}

#[cfg(test)]
#[path = "startup_recovery_tests.rs"]
mod tests;
