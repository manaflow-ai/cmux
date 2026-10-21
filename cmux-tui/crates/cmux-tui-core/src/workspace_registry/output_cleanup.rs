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

use super::open_guard::sidecar_path;
use super::{WorkspaceRegistry, meta_value};

pub(crate) use pruned::{PRUNED_RANGES_SCHEMA, pruned_gap};
pub(crate) use stage::{StageControl, StageOutcome, stage_registry};
pub(super) use swap::{remove_previous_registry_later, roll_back_swap, swap_at_open};

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

/// `Err(reason)` when the directory of `db_path` has less free space than
/// the staged file so far plus the margin.
fn free_space_refusal(db_path: &Path) -> anyhow::Result<Result<(), String>> {
    let dir = db_path.parent().unwrap_or(Path::new("."));
    let available = fs4::available_space(dir)?;
    let staged = file_len(&staging_path(db_path));
    let needed = staged.saturating_add(disk_margin());
    Ok(if available < needed {
        Err(format!(
            "{} MiB free in {}, {} MiB needed (staged {} MiB plus a {} MiB margin)",
            available >> 20,
            dir.display(),
            needed >> 20,
            staged >> 20,
            disk_margin() >> 20
        ))
    } else {
        Ok(())
    })
}

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
