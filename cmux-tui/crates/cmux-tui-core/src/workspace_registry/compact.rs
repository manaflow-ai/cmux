//! Offline compaction of a session's workspace registry (cx-ossub).
//!
//! A registry written before journal maintenance (auto_vacuum=NONE) keeps
//! every free page: sealing reuses them, but the file never shrinks, and a
//! legacy registry with more live data than the in-place bound is never
//! converted (a full VACUUM under the registry stalled its owner for minutes,
//! cx-4bd8m). `cmux-tui server compact-registry` rewrites it while NO owner
//! runs: it takes the same session guard and writer lease an owner takes, so
//! it refuses while an owner holds the session, and no write can happen
//! between the copy and the swap.
//!
//! The copy is `VACUUM INTO` a staged file beside the registry, with
//! incremental auto-vacuum set, so the next owner marks the registry migrated
//! and gives free pages back from then on. The staged file is checked
//! (`quick_check`), synced and renamed over the registry. The registry's WAL
//! is checkpointed into it (the source connection closes before the rename)
//! and its sidecars are removed first, so an old WAL is never applied to the
//! new file. On any error the staged file is removed and the registry is left
//! as it was.

use super::open_guard::{refuse_orphaned_journal, sidecar_path};
use super::*;
use cmux_threads::checked::fs as files;

/// What [`compact_registry`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryCompaction {
    /// The registry file that was rewritten.
    pub path: PathBuf,
    /// Registry file plus WAL bytes before the rewrite.
    pub before_bytes: u64,
    /// Registry file bytes after the rewrite.
    pub after_bytes: u64,
    /// Set when the new registry is installed but its directory could not be
    /// synced (the swap may not survive a power loss yet).
    pub warning: Option<String>,
}

/// Why [`compact_registry`] did not rewrite the registry.
#[derive(Debug)]
pub enum RegistryCompactError {
    /// The session has no registry at this path.
    NoRegistry(PathBuf),
    /// Another process (a running owner) holds the session.
    OwnerRunning(anyhow::Error),
    /// The rewrite failed; the registry is unchanged.
    Failed(anyhow::Error),
}

impl std::fmt::Display for RegistryCompactError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoRegistry(path) => write!(f, "no workspace registry at {}", path.display()),
            Self::OwnerRunning(error) => {
                write!(f, "the session is held by a running owner: {error:#}")
            }
            Self::Failed(error) => write!(f, "{error:#}"),
        }
    }
}

impl std::error::Error for RegistryCompactError {}

/// Rewrites the registry of `session_name` under the state root `root` into
/// a compact file with incremental auto-vacuum. Refuses while an owner runs.
pub fn compact_registry(
    root: &Path,
    session_name: &str,
) -> Result<RegistryCompaction, RegistryCompactError> {
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    let session_dir =
        platform::normalize_filesystem_path(root.join(session_storage_component(session_name)));
    let db_path = platform::normalize_filesystem_path(session_dir.join(WORKSPACE_REGISTRY_FILE));
    if !db_path.is_file() {
        return Err(RegistryCompactError::NoRegistry(db_path));
    }
    if let Some(error) = preflight_unsupported_schema(&db_path) {
        return Err(RegistryCompactError::Failed(error.into()));
    }
    // The owner's own locks, held until the swap is durable.
    let _session_guard =
        acquire_existing_session_guard(&root, session_name).map_err(classify_lock_error)?;
    let session_lock =
        platform::normalize_filesystem_path(session_dir.join(SESSION_WRITER_LOCK_FILE));
    let _lease = SessionLease::acquire(&session_lock).map_err(classify_lock_error)?;
    // Checked again under the locks: the file may have gone meanwhile, and a
    // leftover journal of a missing file must not be applied to a new one.
    if !db_path.is_file() {
        return Err(RegistryCompactError::NoRegistry(db_path));
    }
    refuse_orphaned_journal(&db_path).map_err(RegistryCompactError::Failed)?;
    compact_locked(&db_path).map_err(RegistryCompactError::Failed)
}

/// A lock another process holds means a running owner; anything else is a
/// failure to report as is.
fn classify_lock_error(error: anyhow::Error) -> RegistryCompactError {
    let held = error.chain().any(|cause| {
        cause
            .downcast_ref::<fs4::TryLockError>()
            .is_some_and(|error| matches!(error, fs4::TryLockError::WouldBlock))
    });
    if held {
        RegistryCompactError::OwnerRunning(error)
    } else {
        RegistryCompactError::Failed(error)
    }
}

fn compact_locked(db_path: &Path) -> anyhow::Result<RegistryCompaction> {
    let wal = sidecar_path(db_path, "-wal");
    let shm = sidecar_path(db_path, "-shm");
    let before_bytes = file_len(db_path) + file_len(&wal);
    let staged = staged_path(db_path)?;
    remove_staged(&staged)?;
    if let Err(error) = write_staged(db_path, &staged) {
        let _ = remove_staged(&staged);
        return Err(error);
    }
    // The source connection is closed: its WAL was checkpointed into the
    // registry. A WAL that still holds frames would be applied to the new
    // file by the next open, so refuse instead.
    if file_len(&wal) > 0 {
        let _ = remove_staged(&staged);
        anyhow::bail!("the registry WAL still holds data after the copy: {}", wal.display());
    }
    let parent = db_path.parent().context("registry path has no directory")?;
    // The removal of the old sidecars is durable before the rename: an old
    // WAL that came back after a crash would be applied to the new file.
    let installed = (|| -> anyhow::Result<()> {
        remove_if_present(&wal)?;
        remove_if_present(&shm)?;
        platform::sync_directory(parent)
            .with_context(|| format!("sync registry directory {}", parent.display()))?;
        files::rename(&staged, db_path)
            .with_context(|| format!("install compacted registry {}", db_path.display()))
    })();
    if let Err(error) = installed {
        let _ = remove_staged(&staged);
        return Err(error);
    }
    // The registry is replaced from here on: a failed sync is a warning, not
    // an "unchanged" failure.
    let warning = platform::sync_directory(parent)
        .err()
        .map(|error| format!("sync registry directory {}: {error}", parent.display()));
    Ok(RegistryCompaction {
        path: db_path.to_path_buf(),
        before_bytes,
        after_bytes: file_len(db_path),
        warning,
    })
}

/// Copies the registry into `staged` with incremental auto-vacuum and checks
/// the copy. Both connections are closed on return.
fn write_staged(db_path: &Path, staged: &Path) -> anyhow::Result<()> {
    {
        // Never create a database: the registry exists (checked under the locks).
        let source = open_registry_database_with_flags(
            db_path,
            OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
        )
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
        source.busy_timeout(std::time::Duration::from_secs(5))?;
        // On an existing database this only records the mode; SQLite applies
        // it to the VACUUM INTO output.
        source.execute_batch("PRAGMA auto_vacuum=INCREMENTAL;")?;
        let staged_sqlite = sqlite_filesystem_path(staged)?;
        let staged_text = staged_sqlite.to_str().context("compacted registry path is not UTF-8")?;
        source
            .execute("VACUUM INTO ?1", [staged_text])
            .with_context(|| format!("copy workspace registry {}", db_path.display()))?;
    }
    {
        let copy = open_registry_database(staged)
            .with_context(|| format!("open compacted registry {}", staged.display()))?;
        let auto_vacuum = copy.query_row("PRAGMA auto_vacuum", [], |row| row.get::<_, i64>(0))?;
        if auto_vacuum != 2 {
            // This SQLite did not carry the mode into VACUUM INTO: convert
            // the copy (a separate file; nothing waits on it).
            copy.execute_batch("PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")?;
        }
        let check = copy.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))?;
        anyhow::ensure!(check == "ok", "compacted registry failed quick_check: {check}");
        let auto_vacuum = copy.query_row("PRAGMA auto_vacuum", [], |row| row.get::<_, i64>(0))?;
        anyhow::ensure!(auto_vacuum == 2, "compacted registry is not incremental auto-vacuum");
    }
    // The copy's own sidecars, if its connection made any, are empty after
    // the close; a non-empty WAL would be lost by the rename.
    anyhow::ensure!(
        file_len(&sidecar_path(staged, "-wal")) == 0,
        "the compacted registry WAL still holds data"
    );
    remove_if_present(&sidecar_path(staged, "-wal"))?;
    remove_if_present(&sidecar_path(staged, "-shm"))?;
    platform::restrict_file(staged)?;
    // Windows FlushFileBuffers needs write access.
    files::sync_all(&files::open_with(File::options().write(true), staged)?)?;
    Ok(())
}

fn staged_path(db_path: &Path) -> anyhow::Result<PathBuf> {
    let name = db_path.file_name().context("registry path has no file name")?;
    let mut staged = std::ffi::OsString::from(".");
    staged.push(name);
    staged.push(".compact");
    Ok(db_path.with_file_name(staged))
}

fn remove_staged(staged: &Path) -> anyhow::Result<()> {
    remove_if_present(staged)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(staged, suffix))?;
    }
    Ok(())
}

fn remove_if_present(path: &Path) -> anyhow::Result<()> {
    match files::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
    }
}

fn file_len(path: &Path) -> u64 {
    files::metadata(path).map(|metadata| metadata.len()).unwrap_or(0)
}
