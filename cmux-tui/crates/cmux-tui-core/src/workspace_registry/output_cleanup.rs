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
//!   transaction, so a quit resumes at the next segment. The same thread
//!   then builds the new registry's journal in that file (`build`): the
//!   non-output live rows (through the `(kind, sequence)` index, never a
//!   full scan), all kept records packed into new sealed segments over the
//!   same sequence range with their index rows, each removed run recorded in
//!   `journal_pruned_ranges`, and a check. Every step records its progress,
//!   so a quit or a kill resumes it. While the owner serves on, the thread
//!   packs the records appended since.
//! - Phase B ([`swap_at_open`]) runs at the next owner start, inside
//!   `WorkspaceRegistry::open` while the session locks are held and before
//!   any connection writes the registry. It only finishes the built file:
//!   the journal tail since the last catch-up (a start with a tail, plus
//!   any records a stopped catch-up left unpacked, over `SWAP_TAIL_LIMIT`
//!   records defers the swap), every other table copied,
//!   a check, and the rename over the registry. The old file stays as
//!   `workspace-registry.sqlite3.pre-output-cleanup` until the next start
//!   that opens the new registry. A start that swaps used to build the whole
//!   journal here and took minutes on a large registry.
//!
//! The same pass drops the `personal.session.put` records a later put of
//! the same session superseded ([`session_puts`] says which and why no
//! reader needs them): a loop that re-put one session every few
//! milliseconds left 11.5M of them in one registry. The pack records their
//! runs in `journal_pruned_ranges` like removed output.
//!
//! Sequences never change: cursors, checkpoints and hook deliveries keep
//! pointing at the same records. The journal readers accept a missing run of
//! sequences exactly when one pruned range covers it ([`pruned_gap`]).
//!
//! The cleanup copies every kept record (in the background; Phase B did it
//! inside the open before). That is cheap only while output and superseded
//! session puts are most of the journal; a registry whose journal is mostly
//! other records (one held 12M rows, 96.6% of them session records) staged
//! 38 GB and would have spent hours of a start copying it. So
//! the cleanup runs only while the kept records stay under
//! [`MAX_KEPT_RECORDS`] and at most half of the journal, and the staging file
//! under [`MAX_STAGED_BYTES`]: Phase A checks an estimate before it stages and
//! the staged count as it goes, the build the staged count and the segments
//! sealed since before it starts, and the staged size as it packs and
//! catches up; Phase B the staged size before it copies anything, and it
//! copies at most a bounded tail of the journal. Past a bound the staging
//! file is deleted and the registry stays as it is; the next start
//! estimates again. A refusal after staging is recorded
//! (`.output-cleanup-refused`, with the journal head), and no start stages
//! again until the journal has doubled.
//!
//! The cleanup runs once per registry ([`DONE_META_KEY`], version 2). A
//! registry the version 1 cleanup finished or found without output runs it
//! once more when its journal holds enough session puts to compact.
//!
//! The same pipeline runs a second, opt-in transformation
//! ([`CleanupMode::Compact`], `journal_compact.rs`): it drops nothing and
//! rewrites the resource records that restate the whole session. It has its
//! own bounds and its own done marker.

mod build;
mod chunks;
mod codec;
pub(crate) mod journal_compact;
mod mode;
mod pruned;
mod session_puts;
mod stage;
mod stated_fold;
mod swap;

use std::path::{Path, PathBuf};

use rusqlite::{Connection, params};

use super::open_guard::sidecar_path;
use super::{WorkspaceRegistry, meta_value};

pub(crate) use mode::CleanupMode;
pub(crate) use pruned::{PRUNED_RANGES_SCHEMA, pruned_gap};
#[cfg(test)]
pub(crate) use stage::stage_registry;
pub(crate) use stage::{StageControl, StageOutcome, stage_registry_in};
pub(super) use swap::{
    finish_pending_rollback, note_full_start, refuse_open_beside_backup,
    remove_previous_registry_when_started, restore_interrupted_swap, roll_back_swap,
    rollback_possible, swap_at_open,
};

/// Registry meta key set once the cleanup is done (or was not needed). The
/// cleanup is one-time: a registry with this key is never staged again.
/// Version 2 also drops superseded session puts (`session_puts.rs`), so a
/// registry the version 1 cleanup finished or found clean runs it once more.
pub(crate) const DONE_META_KEY: &str = "output_cleanup_v2";
/// The version 1 key: a swap of that version wrote it (its backup is still
/// recognized), but it no longer marks the cleanup done.
pub(crate) const V1_DONE_META_KEY: &str = "output_cleanup_v1";
const STAGING_SUFFIX: &str = ".output-cleanup";
const PREVIOUS_SUFFIX: &str = ".pre-output-cleanup";
/// Written when a swap failed for a reason other than free space; no later
/// start stages this registry again until the file is removed.
const FAILED_SUFFIX: &str = ".output-cleanup-failed";
/// Written when a rollback could not put the previous registry back (a file
/// still held open, e.g. on Windows): no open uses the swapped registry
/// until a later start finishes the rollback.
const ROLLBACK_PENDING_SUFFIX: &str = ".output-cleanup-rollback";
/// Written when staging finished and the result passed a bound
/// (`stage.rs` `refusal_memo`): no start stages again until the journal
/// has doubled or the staging format changed.
const REFUSED_SUFFIX: &str = ".output-cleanup-refused";
/// Free space beyond the staged file that both phases require.
const DISK_MARGIN_BYTES: u64 = 1 << 30;
const OUTPUT_KIND: &str = "terminal.output";
/// Kept records past which the cleanup does not run: the build copies each
/// of them.
const MAX_KEPT_RECORDS: u64 = 1_000_000;
/// Staging file size past which the cleanup is abandoned.
const MAX_STAGED_BYTES: u64 = 2 << 30;

#[cfg(test)]
thread_local! {
    /// [`MAX_STAGED_BYTES`] for a test on this thread: a test reaches the
    /// bound without writing 2 GiB.
    static STAGED_BYTES_LIMIT: std::cell::Cell<u64> = const { std::cell::Cell::new(MAX_STAGED_BYTES) };
}

#[cfg(test)]
fn max_staged_bytes() -> u64 {
    STAGED_BYTES_LIMIT.with(std::cell::Cell::get)
}

#[cfg(not(test))]
fn max_staged_bytes() -> u64 {
    MAX_STAGED_BYTES
}

pub(crate) fn staging_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, STAGING_SUFFIX)
}

pub(crate) fn previous_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, PREVIOUS_SUFFIX)
}

pub(crate) fn failed_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, FAILED_SUFFIX)
}

pub(crate) fn rollback_pending_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, ROLLBACK_PENDING_SUFFIX)
}

pub(crate) fn refused_path(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, REFUSED_SUFFIX)
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
const REBUILT_TABLES: [&str; 7] = [
    "session_journal",
    "journal_segments",
    "journal_segment_kinds",
    // Keyed by the old segment ids: the rebuilt segments get theirs from
    // the reducer record backfill, which starts over when its cursor's
    // segment is gone.
    "journal_segment_reducer_records",
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

/// `Some(reason)` when a cleanup that keeps `kept` of `total` journal
/// records would copy too much: over [`MAX_KEPT_RECORDS`], or over half of
/// the journal (output and superseded puts are not what fills it).
fn kept_refusal(kept: u64, total: u64) -> Option<String> {
    if kept > MAX_KEPT_RECORDS {
        Some(format!(
            "{kept} of {total} journal records would be kept, over the bound of {MAX_KEPT_RECORDS}"
        ))
    } else if kept.saturating_mul(2) > total {
        Some(format!(
            "{kept} of {total} journal records are neither terminal output nor superseded \
             session puts"
        ))
    } else {
        None
    }
}

/// [`kept_refusal`] for a staging file of `mode`: a compaction copies every
/// record by design, so only its own record bound applies.
fn kept_refusal_in(mode: CleanupMode, kept: u64, total: u64) -> Option<String> {
    match mode {
        CleanupMode::Output => kept_refusal(kept, total),
        CleanupMode::Compact => journal_compact::kept_refusal(kept, total),
    }
}

/// The kept records past which a staging file of `mode` is abandoned.
fn max_kept_records(mode: CleanupMode) -> u64 {
    match mode {
        CleanupMode::Output => MAX_KEPT_RECORDS,
        CleanupMode::Compact => journal_compact::MAX_KEPT_RECORDS,
    }
}

/// `Some(reason)` when the staging database is over its size bound:
/// [`MAX_STAGED_BYTES`], or the bound a compaction recorded when it created
/// the file (the registry's size plus the margin).
fn staged_bytes_refusal(staging: &Connection) -> anyhow::Result<Option<String>> {
    let limit = match CleanupMode::of(staging)? {
        CleanupMode::Output => max_staged_bytes(),
        CleanupMode::Compact => stage::state_u64(staging, "compact_staged_limit")?,
    };
    staged_bytes_over(staging, limit)
}

/// The staging database's logical size (its pages, read through
/// `staging`) against `limit`. Not the file's length: pages a transaction
/// wrote are in the WAL until a checkpoint, and the close copies them into
/// the file.
fn staged_bytes_over(staging: &Connection, limit: u64) -> anyhow::Result<Option<String>> {
    let (pages, size): (i64, i64) = staging.query_row(
        "SELECT (SELECT page_count FROM pragma_page_count()),
                (SELECT page_size FROM pragma_page_size())",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let staged = u64::try_from(pages.max(0).saturating_mul(size)).unwrap_or(u64::MAX);
    Ok((staged > limit).then(|| {
        format!("the staging file is {}, over the bound of {}", mebibytes(staged), mebibytes(limit))
    }))
}

/// (kept, all) live journal rows after the sealed segments. The kept count
/// (index ranges on either side of the output and session put kinds) stops
/// one past [`MAX_KEPT_RECORDS`], so it reads at most that many index
/// entries; the total is the sequence range (two index seeks). Session puts
/// count with `puts`: the ones its read kept that are still live, and every
/// live put after its bound. Without it (before the read) no put counts.
#[cfg(test)]
fn live_records(
    source: &Connection,
    puts: Option<&session_puts::SessionPuts>,
) -> anyhow::Result<(u64, u64)> {
    live_records_within(source, puts, MAX_KEPT_RECORDS)
}

/// [`live_records`] whose kept count stops one past `max_kept`.
fn live_records_within(
    source: &Connection,
    puts: Option<&session_puts::SessionPuts>,
    max_kept: u64,
) -> anyhow::Result<(u64, u64)> {
    let archive_end: i64 = source.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
        [],
        |row| row.get(0),
    )?;
    let head: i64 = source.query_row(
        "SELECT COALESCE(MAX(sequence), ?1) FROM session_journal",
        [archive_end],
        |row| row.get(0),
    )?;
    // `personal.session.put` sorts before `terminal.output`. Every range
    // names ?4 and ?1 binds by index, so an unused one is fine.
    let mut kept = 0_u64;
    let ranges = ["kind < ?4", "kind > ?4 AND kind < ?1", "kind > ?1 AND kind > ?4"];
    let put_range = format!("kind = ?4 AND sequence > {}", puts.map_or(0, |puts| puts.bound()));
    let ranges = ranges.iter().copied().chain(puts.map(|_| put_range.as_str()));
    for range in ranges {
        let limit = i64::try_from((max_kept + 1).saturating_sub(kept))?;
        let rows: i64 = source.query_row(
            &format!(
                "SELECT COUNT(*) FROM (
                   SELECT 1 FROM session_journal INDEXED BY session_journal_by_kind_sequence
                   WHERE {range} AND sequence > ?2 LIMIT ?3)"
            ),
            params![OUTPUT_KIND, archive_end, limit, session_puts::SESSION_PUT_KIND],
            |row| row.get(0),
        )?;
        kept = kept.saturating_add(u64::try_from(rows)?);
    }
    if let Some(puts) = puts {
        // Only the read puts still live: the ones sealed since are counted
        // with their segments.
        kept = kept.saturating_add(puts.live_kept_after(source, u64::try_from(archive_end)?)?);
    }
    Ok((kept, u64::try_from((head - archive_end).max(0))?))
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
    format!("build {} exe {exe}", crate::release::distribution_version())
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

/// The registry meta key that marks the cleanup of `mode` done.
fn done_meta_key(mode: CleanupMode) -> &'static str {
    match mode {
        CleanupMode::Output => DONE_META_KEY,
        CleanupMode::Compact => journal_compact::DONE_META_KEY,
    }
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

#[cfg(test)]
#[path = "output_cleanup/guard_tests.rs"]
mod guard_tests;

#[cfg(test)]
#[path = "output_cleanup/journal_compact_tests.rs"]
mod journal_compact_tests;

impl WorkspaceRegistry {
    /// The cleanup ran (or found no output) for this registry.
    pub(crate) fn output_cleanup_done(&self) -> anyhow::Result<bool> {
        Ok(meta_value(&self.connection.get(), DONE_META_KEY)?.is_some())
    }

    /// The cleanup of `mode` ran (or was not needed) for this registry.
    pub(crate) fn cleanup_done(&self, mode: CleanupMode) -> anyhow::Result<bool> {
        Ok(meta_value(&self.connection.get(), done_meta_key(mode))?.is_some())
    }

    /// Records that the cleanup of `mode` has nothing to do in this registry
    /// (for the output cleanup: it holds no stored terminal output).
    pub(crate) fn mark_cleanup_done(&self, mode: CleanupMode, value: &str) -> anyhow::Result<()> {
        self.connection.get().execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [done_meta_key(mode), value],
        )?;
        Ok(())
    }
}
