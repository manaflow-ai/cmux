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
//! newer-schema registry, lock contention, a full disk, an I/O error other
//! than a failed read, and every other open error are left to the normal
//! startup error.
//!
//! [`recover_registry_after_failed_open`] then works under the session's
//! guard and writer lease (so no other daemon has the registry open):
//!
//! - Too many interrupted creations: the registry is readable, so it stays.
//!   Every interrupted creation but the newest is marked indeterminate, the
//!   existing outcome for a creation whose effect is unknown, and the start
//!   settles the one left. No terminal, workspace or host is touched. When an
//!   interrupted creation staged a workspace row, nothing changes.
//! - Physical damage, confirmed by a fresh read-only `quick_check`: the
//!   database and its sidecars move into
//!   `<session dir>/registry-recovery/<unix ms>/` beside a `reason.txt`, and
//!   the next open starts a new registry. The new registry knows none of the
//!   old terminals, so their hosts are not adopted: the same outcome as moving
//!   the files aside by hand. At most [`MAX_REGISTRY_QUARANTINES`] directories
//!   are kept, so a disk that damages every new registry does not fill up.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::ErrorCode;

use super::{
    SESSION_WRITER_LOCK_FILE, SessionLease, UnsupportedWorkspaceRegistrySchema,
    WORKSPACE_REGISTRY_FILE, acquire_existing_session_guard, open_registry_database_read_only,
    persistent_session_state_dir,
};
use crate::platform;

/// The directory inside a session directory that keeps quarantined registries.
pub(crate) const REGISTRY_RECOVERY_DIR: &str = "registry-recovery";

/// The most quarantined registries a session keeps; past it a start refuses.
pub(crate) const MAX_REGISTRY_QUARANTINES: usize = 3;

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
    /// SQLite reports the file corrupt, not a database, or a failed read, or
    /// its structural check failed. Confirmed on a fresh read-only connection
    /// before the files move.
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
    if error.chain().any(|cause| cause.is::<UnsupportedWorkspaceRegistrySchema>()) {
        return None;
    }
    for cause in error.chain() {
        if let Some(failure) = cause.downcast_ref::<RegistryIntegrityFailure>() {
            return Some(RegistryStartupDamage::Unreadable(failure.to_string()));
        }
        if let Some(failure) = cause.downcast_ref::<UnrecoverableInterruptedCreations>() {
            return Some(RegistryStartupDamage::InterruptedCreations(failure.to_string()));
        }
        if let Some(sqlite) = cause.downcast_ref::<rusqlite::Error>()
            && sqlite_reports_damage(sqlite)
        {
            return Some(RegistryStartupDamage::Unreadable(sqlite.to_string()));
        }
    }
    None
}

/// Corrupt, not a database, or a failed read of the file. Other I/O errors
/// (a lock, shared memory, a write, a sync, a read-only remount) say nothing
/// about the file's contents.
fn sqlite_reports_damage(error: &rusqlite::Error) -> bool {
    let rusqlite::Error::SqliteFailure(failure, _) = error else { return false };
    let damaged = match failure.code {
        ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase => true,
        ErrorCode::SystemIoFailure => matches!(
            failure.extended_code,
            rusqlite::ffi::SQLITE_IOERR
                | rusqlite::ffi::SQLITE_IOERR_READ
                | rusqlite::ffi::SQLITE_IOERR_SHORT_READ
        ),
        _ => false,
    };
    damaged && !error.to_string().contains("malformed database schema")
}

/// What [`recover_registry_after_failed_open`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryRecovery {
    /// The registry moved to this directory; the next open starts a new one.
    Quarantined(PathBuf),
    /// These interrupted creations (idempotency keys) were marked
    /// indeterminate; the registry stays.
    AbandonedCreations(Vec<String>),
}

impl std::fmt::Display for RegistryRecovery {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Quarantined(directory) => {
                write!(formatter, "moved it to {} and starting a new registry", directory.display())
            }
            Self::AbandonedCreations(keys) => write!(
                formatter,
                "marked {} interrupted creation(s) indeterminate ({}) and kept the registry",
                keys.len(),
                keys.join(", ")
            ),
        }
    }
}

/// Recovers the session's registry after [`registry_startup_damage`]
/// recognized its open failure.
///
/// Refuses (and changes nothing) when another process holds the session,
/// when there is no registry, when physical damage is not confirmed by a
/// fresh read-only `quick_check`, or when the session already keeps
/// [`MAX_REGISTRY_QUARANTINES`] quarantined registries.
pub fn quarantine_session_registry(
    root: &Path,
    session_name: &str,
    damage: &RegistryStartupDamage,
) -> anyhow::Result<RegistryRecovery> {
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    let session_dir = persistent_session_state_dir(&root, session_name);
    let db_path = platform::normalize_filesystem_path(session_dir.join(WORKSPACE_REGISTRY_FILE));
    anyhow::ensure!(db_path.is_file(), "no workspace registry at {}", db_path.display());
    if let RegistryStartupDamage::InterruptedCreations(_) = damage {
        // A normal open takes the same guard and lease.
        let mut registry = super::WorkspaceRegistry::open(&root, session_name)?;
        return abandon_extra_interrupted_creations(&mut registry)
            .map(RegistryRecovery::AbandonedCreations);
    }
    // The same guard and writer lease every open takes: while they are held
    // here no daemon has this registry open, and none can open it.
    let _session_guard = acquire_existing_session_guard(&root, session_name)?;
    let _lease = SessionLease::acquire(&platform::normalize_filesystem_path(
        session_dir.join(SESSION_WRITER_LOCK_FILE),
    ))?;
    confirm_physical_damage(&db_path)?;
    move_registry_aside(&session_dir, &db_path, damage.reason()).map(RegistryRecovery::Quarantined)
}

/// Marks every interrupted creation but the newest indeterminate, so one
/// start can settle the rest. Refuses when an interrupted creation staged a
/// workspace row: abandoning it would leave that row behind.
fn abandon_extra_interrupted_creations(
    registry: &mut super::WorkspaceRegistry,
) -> anyhow::Result<Vec<String>> {
    anyhow::ensure!(
        registry.interrupted_resource_workspaces()?.is_empty(),
        "an interrupted creation staged a workspace; the registry stays as it is"
    );
    let recoveries = registry.interrupted_resource_creation_recoveries()?;
    let Some((_newest, older)) = recoveries.split_last() else { return Ok(Vec::new()) };
    let mut abandoned = Vec::with_capacity(older.len());
    for recovery in older {
        registry.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
        abandoned.push(recovery.idempotency_key.clone());
    }
    Ok(abandoned)
}

/// Fails unless a fresh read-only connection also finds the file damaged.
fn confirm_physical_damage(db_path: &Path) -> anyhow::Result<()> {
    let probe = (|| -> anyhow::Result<String> {
        let connection = open_registry_database_read_only(db_path)?;
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
    let kept = fs::read_dir(&recovery_root)
        .with_context(|| format!("list registry recovery directory {}", recovery_root.display()))?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .count();
    anyhow::ensure!(
        kept < MAX_REGISTRY_QUARANTINES,
        "{} already keeps {kept} quarantined registries; inspect the disk before starting again",
        recovery_root.display()
    );
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
/// is not damage this recovers from (report the original error), otherwise
/// the recovery's result. On `Some(Ok(_))` the caller opens again.
pub fn recover_registry_after_failed_open(
    root: &Path,
    session_name: &str,
    error: &anyhow::Error,
) -> Option<anyhow::Result<(RegistryStartupDamage, RegistryRecovery)>> {
    let damage = registry_startup_damage(error)?;
    Some(quarantine_session_registry(root, session_name, &damage).map(|done| (damage, done)))
}

#[cfg(test)]
#[path = "startup_recovery_tests.rs"]
mod tests;
