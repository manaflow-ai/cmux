//! One-time removal of the terminal output that older builds stored in the
//! session journal (`terminal.output` rows and the output records inside
//! sealed segments). A registry of that era is almost all output: 14.9M of
//! 15M live rows, their index rows and most of the sealed segments.
//!
//! The registry file is never changed in place. Two phases build a new file
//! beside it:
//!
//! - Phase A ([`stage_registry`]) runs on a low-priority thread of the owner
//!   with a read-only connection. It copies the non-output records of every
//!   sealed segment (segments are immutable) into the staging file
//!   `workspace-registry.sqlite3.output-cleanup`, one segment per staging
//!   transaction, so a quit resumes at the next segment.
//! - Phase B ([`swap_at_open`]) runs at the next owner start, inside
//!   `WorkspaceRegistry::open` while the session locks are held and before
//!   any connection writes the registry. It copies every other table, the
//!   non-output live rows (through the `(kind, sequence)` index, never a full
//!   scan) and their index rows, packs all kept records into new sealed
//!   segments over the same sequence range, records each removed run in
//!   `journal_pruned_ranges`, checks the result, and renames it over the
//!   registry. The old file stays as `workspace-registry.sqlite3.pre-output-
//!   cleanup` until the next start that opens the new registry.
//!
//! Sequences never change: cursors, checkpoints and hook deliveries keep
//! pointing at the same records. The journal readers accept a missing run of
//! sequences exactly when one pruned range covers it ([`pruned_gap`]).

mod codec;
mod pruned;
mod stage;
mod swap;

use std::path::{Path, PathBuf};

use rusqlite::Connection;

use super::open_guard::sidecar_path;
use super::{WorkspaceRegistry, meta_value};

pub(crate) use pruned::{PRUNED_RANGES_SCHEMA, pruned_gap};
pub(crate) use stage::{StageControl, StageOutcome, stage_registry};
pub(super) use swap::{
    note_full_start, refuse_open_beside_backup, remove_previous_registry_when_started,
    restore_interrupted_swap, roll_back_swap, rollback_possible, swap_at_open,
};

/// Registry meta key set once the cleanup is done (or was not needed). The
/// cleanup is one-time: a registry with this key is never staged again.
pub(crate) const DONE_META_KEY: &str = "output_cleanup_v1";
const STAGING_SUFFIX: &str = ".output-cleanup";
const PREVIOUS_SUFFIX: &str = ".pre-output-cleanup";
/// Written when a swap failed for a reason other than free space; no later
/// start stages this registry again until the file is removed.
const FAILED_SUFFIX: &str = ".output-cleanup-failed";
/// Free space beyond the staged file that both phases require.
const DISK_MARGIN_BYTES: u64 = 1 << 30;
const OUTPUT_KIND: &str = "terminal.output";

pub(crate) fn staging_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, STAGING_SUFFIX)
}

pub(crate) fn previous_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, PREVIOUS_SUFFIX)
}

pub(crate) fn failed_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, FAILED_SUFFIX)
}

fn disk_margin() -> u64 {
    #[cfg(debug_assertions)]
    if let Some(bytes) = std::env::var("CMUX_TUI_TEST_OUTPUT_CLEANUP_MARGIN_BYTES")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return bytes;
    }
    DISK_MARGIN_BYTES
}

/// Journal tables the swap rebuilds; every other table is copied as is.
const REBUILT_TABLES: [&str; 6] = [
    "session_journal",
    "journal_segments",
    "journal_segment_kinds",
    "journal_subject_index",
    "journal_event_index",
    "journal_pruned_ranges",
];

/// Bytes the swap copies unchanged from `source` (every table and index
/// outside the rebuilt journal tables): their pages, counted per b-tree with
/// `dbstat`, which reads only those b-trees. Without `dbstat`, the whole
/// file's used pages, an upper bound.
fn copied_bytes(source: &Connection) -> anyhow::Result<u64> {
    let names = {
        let rebuilt = REBUILT_TABLES.iter().map(|name| format!("'{name}'")).collect::<Vec<_>>();
        let mut statement = source.prepare(&format!(
            "SELECT name FROM sqlite_master
             WHERE type IN ('table', 'index') AND tbl_name NOT IN ({})",
            rebuilt.join(", ")
        ))?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    let mut total = 0_u64;
    for name in &names {
        let bytes = source.query_row(
            "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name = ?1 AND aggregate = TRUE",
            [name],
            |row| row.get::<_, i64>(0),
        );
        match bytes {
            Ok(bytes) => total = total.saturating_add(u64::try_from(bytes).unwrap_or(0)),
            Err(_) => {
                let (pages, free, size): (i64, i64, i64) = source.query_row(
                    "SELECT (SELECT page_count FROM pragma_page_count()),
                            (SELECT freelist_count FROM pragma_freelist_count()),
                            (SELECT page_size FROM pragma_page_size())",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )?;
                return Ok(u64::try_from((pages - free).max(0) * size).unwrap_or(u64::MAX));
            }
        }
    }
    Ok(total)
}

/// `Err(reason)` when the directory of `db_path` has less free space than
/// what the new registry still needs (the copied tables, `copied`, plus what
/// is not staged yet is bounded by the staged file so far) plus the margin.
fn free_space_refusal(db_path: &Path, copied: u64) -> anyhow::Result<Result<(), String>> {
    let dir = db_path.parent().unwrap_or(Path::new("."));
    let available = fs4::available_space(dir)?;
    let staged = file_len(&staging_path(db_path));
    let needed = staged.saturating_add(copied).saturating_add(disk_margin());
    Ok(if available < needed {
        Err(format!(
            "{} MiB free in {}, {} MiB needed (staged {} MiB, copied tables {} MiB, a {} MiB \
             margin)",
            available >> 20,
            dir.display(),
            needed >> 20,
            staged >> 20,
            copied >> 20,
            disk_margin() >> 20
        ))
    } else {
        Ok(())
    })
}

/// This binary, for the failure marker: a newer build retries a cleanup an
/// older one gave up on.
fn build_stamp() -> String {
    let exe = std::env::current_exe()
        .ok()
        .and_then(|path| std::fs::metadata(path).ok())
        .map(|metadata| {
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |time| time.as_nanos());
            format!("{}-{modified}", metadata.len())
        })
        .unwrap_or_default();
    format!("build {} exe {exe}", crate::release::DISTRIBUTION_VERSION)
}

/// True when an earlier attempt of this same build failed for a reason that
/// would fail again. A marker of another build is removed.
pub(crate) fn failed_for_this_build(db_path: &Path) -> bool {
    let marker = failed_path(db_path);
    let Ok(text) = std::fs::read_to_string(&marker) else { return false };
    if text.lines().next() == Some(build_stamp().as_str()) {
        return true;
    }
    eprintln!(
        "cmux-tui: output cleanup: a different build retries the cleanup an older build stopped"
    );
    let _ = std::fs::remove_file(&marker);
    false
}

fn write_failure_marker(db_path: &Path, reason: &str) {
    let _ = std::fs::write(failed_path(db_path), format!("{}\n{reason}\n", build_stamp()));
}

/// Errors that a later start can get past: a busy or locked database, a full
/// disk, an I/O error, or a registry that changed under the staged work.
fn is_temporary(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if let Some(code) =
            cause.downcast_ref::<rusqlite::Error>().and_then(rusqlite::Error::sqlite_error_code)
        {
            return matches!(
                code,
                rusqlite::ErrorCode::DatabaseBusy
                    | rusqlite::ErrorCode::DatabaseLocked
                    | rusqlite::ErrorCode::DiskFull
            );
        }
        if let Some(error) = cause.downcast_ref::<std::io::Error>() {
            return matches!(
                error.kind(),
                std::io::ErrorKind::StorageFull
                    | std::io::ErrorKind::ResourceBusy
                    | std::io::ErrorKind::WouldBlock
                    | std::io::ErrorKind::Interrupted
            );
        }
        cause.to_string().contains(STAGED_WORK_CHANGED)
    })
}

/// The message of an error that makes the staged work unusable.
const STAGED_WORK_CHANGED: &str = "the registry's sealed segments changed after staging";

fn file_len(path: &Path) -> u64 {
    std::fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0)
}

fn remove_if_present(path: &Path) -> anyhow::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow::Error::from(error).context(format!("remove {}", path.display()))),
    }
}

/// Removes a staging file and its SQLite sidecars.
fn remove_staging(db_path: &Path) -> anyhow::Result<()> {
    let staging = staging_path(db_path);
    remove_if_present(&staging)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(&staging, suffix))?;
    }
    Ok(())
}

fn mebibytes(bytes: u64) -> String {
    format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
}

impl WorkspaceRegistry {
    /// The cleanup ran (or found no output) for this registry.
    pub(crate) fn output_cleanup_done(&self) -> anyhow::Result<bool> {
        Ok(meta_value(&self.connection.get(), DONE_META_KEY)?.is_some())
    }

    /// Records that this registry holds no stored terminal output.
    pub(crate) fn mark_output_cleanup_done(&self, value: &str) -> anyhow::Result<()> {
        self.connection.get().execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [DONE_META_KEY, value],
        )?;
        Ok(())
    }
}
