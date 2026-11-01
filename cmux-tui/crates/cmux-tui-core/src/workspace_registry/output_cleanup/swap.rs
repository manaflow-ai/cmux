//! Phase B: at owner start, before the registry connection opens, turn a
//! complete staging file into the new registry and rename it into place.
//! Nothing writes the registry file itself; until the rename it is the
//! registry, and after it the old file stays as `.pre-output-cleanup`.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use rusqlite::{Connection, OpenFlags, OptionalExtension as _, Transaction, params};

use super::super::journal_extensions::JOURNAL_SEGMENT_RECORD_LIMIT;
use super::super::open_guard::sidecar_path;
use super::super::session_journal::{
    decode_record, journal_record_for_archive, query_journal_head, query_session_journal_after,
    stored_record_row, unix_epoch_ms,
};
use super::super::{
    open_registry_database_read_only, open_registry_database_with_flags, required_meta,
    sqlite_filesystem_path,
};
use super::codec::{SegmentWriter, encode_hex};
use super::stage::{Staged, open_existing_staging, stage_segments, state, state_u64};
use super::{
    DONE_META_KEY, OUTPUT_KIND, PRUNED_RANGES_SCHEMA, REBUILT_TABLES, STAGED_WORK_CHANGED,
    copied_bytes, failed_for_this_build, file_len, free_space_refusal, is_temporary, mebibytes,
    previous_path, remove_if_present, remove_staging, rollback_pending_path, staging_path,
    write_failure_marker,
};
use crate::platform;

/// Meta key: full owner starts since the swap. The previous file is removed
/// at an open once one start after the swap got through restore.
const FULL_STARTS_META_KEY: &str = "output_cleanup_full_starts";

/// Opens a built registry file the way the owner does and reads its layout.
pub(crate) type VerifyOpen<'a> = &'a dyn Fn(&Path) -> anyhow::Result<()>;

enum Swap {
    NotReady,
    Refused(String),
    Done(SwapStats),
}

struct SwapStats {
    before_bytes: u64,
    after_bytes: u64,
    kept: u64,
    segments: u64,
    pruned_ranges: u64,
    abandoned_deliveries: usize,
    tables: usize,
    largest_tables: String,
    steps: String,
}

/// Runs Phase B when Phase A finished for this registry. True when the
/// registry file was replaced. On any failure the registry is unchanged and
/// the reason is logged: a temporary failure keeps the staged work for the
/// next start, any other one removes it and stops the cleanup for this build.
pub(crate) fn swap_at_open(db_path: &Path, verify_open: VerifyOpen<'_>) -> bool {
    restore_interrupted_swap(db_path);
    if !staging_path(db_path).is_file() || !db_path.is_file() {
        return false;
    }
    if failed_for_this_build(db_path) {
        let _ = remove_staging(db_path);
        return false;
    }
    let started = Instant::now();
    match build_and_swap(db_path, verify_open) {
        Ok(Swap::NotReady) => false,
        Ok(Swap::Refused(reason)) => {
            eprintln!("cmux-tui: output cleanup: swap deferred, not enough free space: {reason}");
            false
        }
        Ok(Swap::Done(stats)) => {
            eprintln!(
                "cmux-tui: output cleanup: swapped the registry in {:.2} s: {} -> {}; \
                 {} records kept in {} segments, {} pruned ranges, {} tables copied ({}), \
                 {} pending hook deliveries of removed output abandoned ({}); previous file at {}",
                started.elapsed().as_secs_f64(),
                mebibytes(stats.before_bytes),
                mebibytes(stats.after_bytes),
                stats.kept,
                stats.segments,
                stats.pruned_ranges,
                stats.tables,
                stats.largest_tables,
                stats.abandoned_deliveries,
                stats.steps,
                previous_path(db_path).display()
            );
            #[cfg(debug_assertions)]
            if let Some(copy) = std::env::var_os("CMUX_TUI_TEST_OUTPUT_CLEANUP_SNAPSHOT") {
                let _ = fs::copy(db_path, copy);
            }
            true
        }
        Err(error) if is_temporary(&error) => {
            eprintln!(
                "cmux-tui: output cleanup: swap failed after {:.2} s, retried at the next start; \
                 the registry is unchanged: {error:#}",
                started.elapsed().as_secs_f64()
            );
            if error.chain().any(|cause| cause.to_string().contains(STAGED_WORK_CHANGED)) {
                let _ = remove_staging(db_path);
            }
            false
        }
        Err(error) => {
            eprintln!(
                "cmux-tui: output cleanup failed after {:.2} s; the registry is unchanged: {error:#}",
                started.elapsed().as_secs_f64()
            );
            let _ = remove_staging(db_path);
            write_failure_marker(db_path, &format!("{error:#}"));
            false
        }
    }
}

/// The swapped-in registry did not open: put the previous file back and
/// never stage this registry again (the failure marker). When the previous
/// file cannot be put back (the swapped file still held open: a syncer
/// thread of the failed open, a sharing violation on Windows), the start is
/// refused, and the next start finishes the rollback before anything opens
/// the registry ([`finish_pending_rollback`]).
pub(crate) fn roll_back_swap(db_path: &Path, error: &anyhow::Error) -> anyhow::Result<()> {
    eprintln!(
        "cmux-tui: output cleanup: the new registry did not open ({error:#}); \
         restoring the previous registry"
    );
    write_failure_marker(db_path, &format!("the new registry did not serve: {error:#}"));
    // On disk before the rename, so a crash or a failed rename leaves the
    // next start a record to finish. A marker that cannot be written (a
    // full disk) does not stop the rename: the failure marker and an
    // unconfirmed swap are the fallback record.
    let pending = rollback_pending_path(db_path);
    if let Err(marker_error) = write_synced(&pending, &format!("{error:#}\n")) {
        eprintln!(
            "cmux-tui: output cleanup: could not record the rollback in {}: {marker_error:#}",
            pending.display()
        );
    }
    // A sidecar left behind belongs to the cleaned file's pages: the next
    // open would apply its WAL frames to the previous registry. One that
    // cannot go (held open without delete sharing on Windows) refuses the
    // start like a failed rename, and the next start tries again.
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(db_path, suffix)).context(
            "clear the cleaned registry's sidecar before putting the previous registry back; \
             the next start tries again",
        )?;
    }
    let restored = fs::rename(previous_path(db_path), db_path);
    if let Some(parent) = db_path.parent() {
        let _ = platform::sync_directory(parent);
    }
    restored.with_context(|| {
        format!(
            "put the previous workspace registry {} back after a failed output cleanup; the \
             next start tries again",
            previous_path(db_path).display()
        )
    })?;
    remove_if_present(&pending)?;
    Ok(())
}

/// Writes `contents` to `path` and syncs the file and its directory.
fn write_synced(path: &Path, contents: &str) -> anyhow::Result<()> {
    use std::io::Write as _;
    let mut file = fs::File::create(path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
    if let Some(parent) = path.parent() {
        platform::sync_directory(parent)?;
    }
    Ok(())
}

/// Finishes a rollback an earlier start could not complete: called before
/// anything opens the registry. The record is the rollback marker, or, when
/// that could not be written, the failure marker beside a swap no full start
/// confirmed (only a rollback writes the failure marker after a swap).
pub(crate) fn finish_pending_rollback(db_path: &Path) -> anyhow::Result<()> {
    let pending = rollback_pending_path(db_path);
    let unrecorded_rollback =
        || super::failed_path(db_path).is_file() && rollback_possible(db_path);
    if !(pending.is_file() || unrecorded_rollback()) {
        return Ok(());
    }
    if !previous_path(db_path).is_file() {
        // Already put back (the marker's removal did not happen).
        return remove_if_present(&pending);
    }
    roll_back_swap(db_path, &anyhow::anyhow!("an earlier rollback could not finish"))
}

/// Refuses an open while the registry exists only as the backup of a swap
/// (the restore of an interrupted swap failed). The error names the backup.
pub(crate) fn refuse_open_beside_backup(db_path: &Path) -> anyhow::Result<()> {
    let previous = previous_path(db_path);
    anyhow::ensure!(
        !rollback_pending_path(db_path).is_file(),
        "an output cleanup rollback of the workspace registry is unfinished; the previous \
         registry {} could not be put back in place (see the log above). Move it to {} by hand \
         to start this session",
        previous.display(),
        db_path.display()
    );
    anyhow::ensure!(
        db_path.exists() || !previous.is_file(),
        "the workspace registry exists only as the output cleanup backup {}; it could not be \
         put back in place (see the log above). Move it to {} by hand to start this session",
        previous.display(),
        db_path.display()
    );
    Ok(())
}

/// The registry at `db_path` is the one a swap made from the backup: same
/// registry id, and the swap's completion record. A registry created in its
/// place (another id, or no record) never lets the backup be removed or
/// counts a start for it.
fn is_swapped_registry(db_path: &Path) -> bool {
    swapped_registry(db_path).unwrap_or_else(|error| {
        eprintln!(
            "cmux-tui: output cleanup: could not tell whether the registry was swapped: {error:#}"
        );
        false
    })
}

/// [`is_swapped_registry`] that reports a file it could not read instead of
/// answering "not swapped": a locked or unreadable backup is not evidence that
/// the registry is another one. A missing key reads as absent.
fn swapped_registry(db_path: &Path) -> anyhow::Result<bool> {
    let read = |path: &Path, key: &str| -> anyhow::Result<Option<String>> {
        let connection = open_registry_database_read_only(path)
            .with_context(|| format!("open {} to read {key}", path.display()))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get::<_, String>(0)
            })
            .optional()
            .with_context(|| format!("read {key} from {}", path.display()))
    };
    let Some(current) = read(db_path, "registry_id")? else { return Ok(false) };
    if read(&previous_path(db_path), "registry_id")?.as_deref() != Some(current.as_str()) {
        return Ok(false);
    }
    Ok(read(db_path, DONE_META_KEY)?.is_some_and(|value| value.contains("\"kept\"")))
}

/// A previous registry exists and no owner got through a full start on the
/// registry that replaced it: a failed owner build may still roll back.
pub(crate) fn rollback_possible(db_path: &Path) -> bool {
    if !previous_path(db_path).is_file() || !db_path.is_file() || !is_swapped_registry(db_path) {
        return false;
    }
    open_registry_database_read_only(db_path)
        .ok()
        .map(|connection| {
            connection
                .query_row("SELECT value FROM meta WHERE key = ?1", [FULL_STARTS_META_KEY], |row| {
                    row.get::<_, String>(0)
                })
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0)
                == 0
        })
        .unwrap_or(false)
}

/// Records a full owner start (restore done) on a registry that still has
/// the file a swap replaced.
pub(crate) fn note_full_start(db_path: &Path) -> anyhow::Result<()> {
    if !previous_path(db_path).exists() {
        return Ok(());
    }
    // A backup that cannot be read (held by another process, unreadable) is
    // not proof the registry is another one: answering "not swapped" would
    // let this start serve without its confirmation, and a later failed start
    // could roll back over what it served. Once more after a failure, then
    // the start is refused.
    let swapped =
        swapped_registry(db_path).or_else(|_| swapped_registry(db_path)).with_context(|| {
            format!(
                "check whether the registry was made from the output cleanup backup {} (the \
                 start is refused; the next start tries again)",
                previous_path(db_path).display()
            )
        })?;
    if !swapped {
        eprintln!(
            "cmux-tui: output cleanup: the registry is not the one made from {}; it stays",
            previous_path(db_path).display()
        );
        return Ok(());
    }
    let note = || -> anyhow::Result<()> {
        let connection = open_registry_database_with_flags(
            db_path,
            OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
        )?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')
             ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1",
            [FULL_STARTS_META_KEY],
        )?;
        Ok(())
    };
    // Once more after a failure (a busy registry). A start that cannot
    // record itself is not a full start: the caller refuses it before it
    // serves, so a later failed start can never roll back a served session.
    note().or_else(|_| note()).context(
        "record the first full start on the output-cleaned registry (the start is refused; \
         the next start tries again)",
    )
}

/// At an open after a swap: the previous file goes, off the start path, once
/// an owner got through a full start on the new registry. Until then it stays
/// so the original can be put back.
pub(crate) fn remove_previous_registry_when_started(db_path: &Path) {
    let previous = previous_path(db_path);
    if !previous.exists() {
        return;
    }
    if !is_swapped_registry(db_path) {
        eprintln!(
            "cmux-tui: output cleanup: kept {}: the registry is not the one made from it",
            previous.display()
        );
        return;
    }
    let started = open_registry_database_read_only(db_path)
        .ok()
        .and_then(|connection| {
            connection
                .query_row("SELECT value FROM meta WHERE key = ?1", [FULL_STARTS_META_KEY], |row| {
                    row.get::<_, String>(0)
                })
                .ok()
        })
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0);
    if started == 0 {
        return;
    }
    let _ =
        std::thread::Builder::new().name("cmux-output-cleanup-remove".into()).spawn(move || {
            match fs::remove_file(&previous) {
                Ok(()) => eprintln!(
                    "cmux-tui: output cleanup: removed the previous registry {}",
                    previous.display()
                ),
                Err(error) => eprintln!(
                    "cmux-tui: output cleanup: could not remove {}: {error}",
                    previous.display()
                ),
            }
        });
}

/// Without hard links the swap renames the registry aside first; a crash
/// between the two renames leaves only the previous file.
pub(crate) fn restore_interrupted_swap(db_path: &Path) {
    let previous = previous_path(db_path);
    if db_path.exists() || !previous.is_file() {
        return;
    }
    // Sidecars without their main file belong to a file that is gone; an old
    // WAL must never be applied to the backup. They are moved aside, not
    // deleted.
    let orphaned = super::super::open_guard::orphaned_sidecars(db_path);
    let shm = sidecar_path(db_path, "-shm");
    if !orphaned.is_empty() || shm.exists() {
        match super::super::open_guard::quarantine(
            db_path,
            "sidecars of a missing registry before an interrupted swap was undone",
        ) {
            Ok(kept) => eprintln!(
                "cmux-tui: output cleanup: moved stale sidecars to {}",
                kept.recovery_dir.display()
            ),
            Err(error) => {
                eprintln!(
                    "cmux-tui: output cleanup: could not move stale sidecars aside, \
                     the backup stays at {}: {error:#}",
                    previous.display()
                );
                return;
            }
        }
    }
    match fs::rename(&previous, db_path) {
        Ok(()) => {
            eprintln!("cmux-tui: output cleanup: restored the registry after an interrupted swap");
        }
        Err(error) => {
            eprintln!(
                "cmux-tui: output cleanup: could not restore {}: {error}",
                previous.display()
            );
        }
    }
}

fn build_and_swap(db_path: &Path, verify_open: VerifyOpen<'_>) -> anyhow::Result<Swap> {
    let mut steps = Steps { last: Some(Instant::now()), done: Vec::new() };
    let before_bytes = file_len(db_path) + file_len(&sidecar_path(db_path, "-wal"));
    // Read-only until the staged work is known to be complete.
    let (registry_id, copied) = {
        let source = open_registry_database_read_only(db_path)?;
        source.busy_timeout(Duration::from_secs(5))?;
        (required_meta(&source, "registry_id")?, copied_bytes(&source)?)
    };
    // A staging file of another registry, or one a kill left between the
    // build commit and the rename (its state table is gone): Phase A runs
    // again at a later start.
    let Some(staged) = open_existing_staging(&staging_path(db_path), &registry_id).ok().flatten()
    else {
        eprintln!("cmux-tui: output cleanup: discarding a stale staging file");
        remove_staging(db_path)?;
        return Ok(Swap::NotReady);
    };
    if state(&staged, "complete")? != "1" {
        return Ok(Swap::NotReady);
    }
    if let Err(reason) = free_space_refusal(db_path, copied)? {
        return Ok(Swap::Refused(reason));
    }
    // Fold a WAL left by a killed owner into the registry, so the copy
    // below reads everything and the rename leaves no WAL behind. This is
    // the cleanup's only write to the registry file; it changes no content.
    {
        let source = open_registry_database_with_flags(
            db_path,
            OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
        )?;
        source.busy_timeout(Duration::from_secs(5))?;
        let busy: i64 =
            source.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))?;
        anyhow::ensure!(busy == 0, "the registry WAL could not be checkpointed");
    }
    steps.mark("checkpoint");
    {
        // Segments sealed after Phase A (by an explicit seal request).
        let source = open_registry_database_read_only(db_path)?;
        check_staged_prefix(&source, &staged)?;
        match stage_segments(&source, &staged, &|| true, None)? {
            Staged::Finished => {}
            Staged::Stopped | Staged::Refused(_) => {
                anyhow::bail!("staging the last segments stopped")
            }
        }
    }
    steps.mark("stage tail");
    let built = build(&staged, db_path, &mut steps)?;
    verify(&staged, &registry_id, &built, &mut steps)?;
    drop(staged);
    verify_open(&staging_path(db_path)).context("open the new registry as the owner does")?;
    steps.mark("open and read layout");
    finish_staged_file(db_path)?;
    install(db_path)?;
    steps.mark("sync and rename");
    Ok(Swap::Done(SwapStats {
        before_bytes,
        after_bytes: file_len(db_path),
        kept: built.kept,
        segments: built.segments,
        pruned_ranges: built.pruned_ranges,
        abandoned_deliveries: built.abandoned_deliveries,
        tables: built.tables,
        largest_tables: built.largest_tables,
        steps: steps.line(),
    }))
}

/// The staged segments still describe the registry's archive: its last
/// staged segment exists with the same id and end.
fn check_staged_prefix(source: &Connection, staged: &Connection) -> anyhow::Result<()> {
    let through = state_u64(staged, "staged_through")?;
    if through == 0 {
        return Ok(());
    }
    let last_id = state(staged, "last_segment_id")?;
    let present: bool = source.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal_segments WHERE segment_id = ?1 AND end_sequence = ?2)",
        params![last_id, i64::try_from(through)?],
        |row| row.get(0),
    )?;
    anyhow::ensure!(present, "{STAGED_WORK_CHANGED}");
    Ok(())
}

/// Wall time of each Phase B step, for the swap log line.
#[derive(Default)]
struct Steps {
    last: Option<Instant>,
    done: Vec<(&'static str, Duration)>,
}

impl Steps {
    fn mark(&mut self, name: &'static str) {
        let now = Instant::now();
        let since = self.last.replace(now).map_or(Duration::ZERO, |last| now - last);
        self.done.push((name, since));
    }

    fn line(&self) -> String {
        self.done
            .iter()
            .map(|(name, time)| format!("{name} {:.2} s", time.as_secs_f64()))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

struct Built {
    kept: u64,
    segments: u64,
    pruned_ranges: u64,
    abandoned_deliveries: usize,
    tables: usize,
    largest_tables: String,
    head: u64,
}

/// Writes the new registry into the staging file in one transaction: a
/// crash before its commit leaves the Phase A state.
fn build(staged: &Connection, db_path: &Path, steps: &mut Steps) -> anyhow::Result<Built> {
    // A rollback journal: the new pages need no copy, unlike a WAL.
    let mode: String = staged.query_row("PRAGMA journal_mode=DELETE", [], |row| row.get(0))?;
    anyhow::ensure!(mode.eq_ignore_ascii_case("delete"), "staging file kept journal mode {mode}");
    staged.execute_batch("PRAGMA foreign_keys=OFF; PRAGMA synchronous=NORMAL;")?;
    let source = sqlite_filesystem_path(db_path)?;
    let source = source.to_str().context("workspace registry path is not UTF-8")?;
    staged.execute("ATTACH DATABASE ?1 AS src", [source])?;
    let built = (|| -> anyhow::Result<Built> {
        let tx = staged.unchecked_transaction()?;
        let built = build_in(&tx, steps)?;
        tx.commit()?;
        steps.mark("commit");
        Ok(built)
    })();
    staged.execute_batch("DETACH DATABASE src")?;
    let built = built?;
    staged.execute_batch("PRAGMA incremental_vacuum;")?;
    steps.mark("vacuum");
    Ok(built)
}

fn build_in(tx: &Transaction<'_>, steps: &mut Steps) -> anyhow::Result<Built> {
    let objects = {
        let mut statement = tx.prepare(
            "SELECT type, name, sql FROM src.sqlite_master
             WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
             ORDER BY rowid",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (kind, name, sql) in &objects {
        anyhow::ensure!(
            !name.starts_with("output_cleanup_"),
            "the registry has a table named like the cleanup's own: {name}"
        );
        anyhow::ensure!(
            !(kind == "table"
                && sql.trim_start().to_ascii_uppercase().starts_with("CREATE VIRTUAL")),
            "the registry has a virtual table {name}"
        );
    }
    for (_, _, sql) in objects.iter().filter(|(kind, _, _)| kind == "table") {
        tx.execute_batch(sql)?;
    }
    tx.execute_batch(PRUNED_RANGES_SCHEMA)?;

    let copied = objects
        .iter()
        .filter(|(kind, name, _)| kind == "table" && !REBUILT_TABLES.contains(&name.as_str()))
        .map(|(_, name, _)| name.clone())
        .collect::<Vec<_>>();
    // Rowids are kept: code orders by them (ledger retention, archives,
    // intents, effects, workspace positions).
    for table in &copied {
        let columns = column_list(tx, "src", table, None)?;
        let (insert, select, order) = if has_rowid(tx, table)? {
            (format!("rowid, {columns}"), format!("rowid, {columns}"), " ORDER BY rowid")
        } else {
            (columns.clone(), columns.clone(), "")
        };
        tx.execute(
            &format!(
                "INSERT INTO main.{0}({insert}) SELECT {select} FROM src.{0}{order}",
                quote(table)
            ),
            [],
        )?;
    }

    let mut sizes = Vec::with_capacity(copied.len());
    for table in &copied {
        let (main_count, src_count): (i64, i64) = tx.query_row(
            &format!(
                "SELECT (SELECT COUNT(*) FROM main.{0}), (SELECT COUNT(*) FROM src.{0})",
                quote(table)
            ),
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        anyhow::ensure!(
            main_count == src_count,
            "table {table} has {main_count} rows in the new registry, {src_count} before"
        );
        sizes.push((main_count, table.as_str()));
    }
    sizes.sort_by_key(|(count, _)| std::cmp::Reverse(*count));
    let largest_tables = sizes
        .iter()
        .take(10)
        .map(|(count, table)| format!("{table} {count}"))
        .collect::<Vec<_>>()
        .join(", ");
    steps.mark("copy tables");
    stage_live_rows(tx)?;
    check_counts(tx)?;
    steps.mark("live rows");
    let (lo, head) = journal_range(tx)?;
    let kept: i64 =
        tx.query_row("SELECT COUNT(*) FROM main.output_cleanup_records", [], |row| row.get(0))?;
    anyhow::ensure!(kept > 0, "the journal holds no record other than terminal output");
    let (segments, pruned_ranges) = pack_segments(tx, lo, head)?;
    steps.mark("pack segments");

    copy_index_rows(tx)?;
    steps.mark("index rows");
    let abandoned_deliveries = if table_exists(tx, "main", "journal_hook_deliveries")? {
        tx.execute(
            "UPDATE main.journal_hook_deliveries
             SET state = 'abandoned', error = 'output cleanup removed the event',
                 completed_at_ms = ?1
             WHERE state IN ('scheduled', 'executing')
               AND NOT EXISTS (
                 SELECT 1 FROM main.output_cleanup_records AS kept
                 WHERE kept.sequence = journal_hook_deliveries.event_sequence)",
            [i64::try_from(unix_epoch_ms()?)?],
        )?
    } else {
        0
    };
    if table_exists(tx, "src", "sqlite_sequence")? && table_exists(tx, "main", "sqlite_sequence")? {
        tx.execute_batch(
            "DELETE FROM main.sqlite_sequence;
             INSERT INTO main.sqlite_sequence(name, seq) SELECT name, seq FROM src.sqlite_sequence;",
        )?;
    }
    let done = format!("{{\"at_ms\":\"{}\",\"kept\":\"{kept}\"}}", unix_epoch_ms()?);
    for (key, value) in [
        (DONE_META_KEY, done.as_str()),
        ("journal_segment_kinds_backfill", "1"),
        (FULL_STARTS_META_KEY, "0"),
    ] {
        tx.execute(
            "INSERT INTO main.meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )?;
    }
    steps.mark("meta");
    // Indexes after the rows; triggers last, so none fired on the copy.
    for wanted in ["index", "view", "trigger"] {
        for (_, _, sql) in objects.iter().filter(|(kind, _, _)| kind == wanted) {
            tx.execute_batch(sql)?;
        }
    }

    tx.execute_batch(
        "DROP TABLE main.output_cleanup_records; DROP TABLE main.output_cleanup_state;
         DROP TABLE main.output_cleanup_segments;",
    )?;
    Ok(Built {
        kept: u64::try_from(kept)?,
        segments,
        pruned_ranges,
        abandoned_deliveries,
        tables: copied.len(),
        largest_tables,
        head,
    })
}

/// The subject and event index rows of every kept record. They are derived
/// from the kept record itself, as the append that wrote them did: copying
/// them from the registry's 125M-row subject index took one random read per
/// record (127 s for 86k records on a cold network disk). Only the value an
/// append looked up (`causal_hook_id`, records with a cause or from the hook
/// dispatcher) is read from the registry, by sequence.
fn copy_index_rows(tx: &Transaction<'_>) -> anyhow::Result<()> {
    tx.execute(
        "INSERT OR IGNORE INTO main.journal_subject_index(sequence, kind, id)
         SELECT kept.sequence,
                json_extract(subject.value, '$.kind'),
                json_extract(subject.value, '$.id')
         FROM main.output_cleanup_records AS kept,
              json_each(CAST(kept.record_json AS TEXT), '$.subjects') AS subject
         WHERE json_type(subject.value, '$.kind') = 'text'
           AND json_type(subject.value, '$.id') = 'text'",
        [],
    )?;
    let derived = [
        "event_id",
        "sequence",
        "causation_depth",
        "causation_id",
        "causal_hook_id",
        "resource_revision",
        "previous_resource_revision",
    ];
    let columns = table_columns(tx, "main", "journal_event_index")?;
    if columns.len() != derived.len()
        || !derived.iter().all(|name| columns.iter().any(|c| c == name))
    {
        // A table shape this derivation does not know: copy by sequence.
        let list = column_list(tx, "src", "journal_event_index", None)?;
        tx.execute(
            &format!(
                "INSERT INTO main.journal_event_index({list})
                 SELECT {}
                 FROM main.output_cleanup_records AS kept
                 CROSS JOIN src.journal_event_index AS event
                 WHERE event.sequence = kept.sequence",
                column_list(tx, "src", "journal_event_index", Some("event"))?
            ),
            [],
        )?;
        return Ok(());
    }
    // Resource revisions as `ensure_journal_event_index_schema` backfilled
    // them: from the record, else from a legacy `event_resource_N` id.
    tx.execute(
        "INSERT INTO main.journal_event_index(
           event_id, sequence, causation_depth, causation_id, causal_hook_id,
           resource_revision, previous_resource_revision)
         SELECT record.event_id, record.sequence, record.causation_depth, record.causation_id,
                CASE WHEN record.causation_id IS NOT NULL OR record.hook_producer
                     THEN (SELECT event.causal_hook_id FROM src.journal_event_index AS event
                           WHERE event.sequence = record.sequence)
                END,
                CASE WHEN record.resource_revision IS NOT NULL
                          AND record.previous_resource_revision IS NULL
                     THEN (SELECT event.resource_revision FROM src.journal_event_index AS event
                           WHERE event.sequence = record.sequence)
                     ELSE COALESCE(record.resource_revision, record.legacy_revision)
                END,
                CASE WHEN record.resource_revision IS NOT NULL
                          AND record.previous_resource_revision IS NULL
                     THEN (SELECT event.previous_resource_revision
                           FROM src.journal_event_index AS event
                           WHERE event.sequence = record.sequence)
                     ELSE COALESCE(record.previous_resource_revision, record.legacy_revision - 1)
                END
         FROM (
           SELECT kept.sequence AS sequence,
                  json_extract(json, '$.event_id') AS event_id,
                  json_extract(json, '$.causation_depth') AS causation_depth,
                  json_extract(json, '$.causation_id') AS causation_id,
                  json_extract(json, '$.producer.kind') = 'hook_dispatcher' AS hook_producer,
                  json_extract(json, '$.resource_revision') AS resource_revision,
                  json_extract(json, '$.previous_resource_revision')
                    AS previous_resource_revision,
                  CASE
                    WHEN length(json_extract(json, '$.event_id')) = length('event_resource_') + 20
                     AND substr(json_extract(json, '$.event_id'), 1, length('event_resource_'))
                         = 'event_resource_'
                     AND substr(json_extract(json, '$.event_id'), length('event_resource_') + 1)
                         NOT GLOB '*[^0-9]*'
                     AND json_extract(json, '$.event_id')
                         BETWEEN 'event_resource_00000000000000000001'
                             AND 'event_resource_09223372036854775807'
                    THEN CAST(substr(json_extract(json, '$.event_id'),
                                     length('event_resource_') + 1) AS INTEGER)
                  END AS legacy_revision
           FROM (SELECT sequence, CAST(record_json AS TEXT) AS json
                 FROM main.output_cleanup_records) AS kept
         ) AS record",
        [],
    )?;
    Ok(())
}

/// The non-output live rows, read through the `(kind, sequence)` index on
/// both sides of `terminal.output`, in their archived form.
fn stage_live_rows(tx: &Transaction<'_>) -> anyhow::Result<()> {
    let actor = if table_columns(tx, "src", "session_journal")?.iter().any(|name| name == "actor") {
        "actor"
    } else {
        "NULL"
    };
    let select = |side: &str| {
        format!(
            "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                    occurred_at_ms, committed_at_ms, producer_json, authority_json,
                    causation_id, correlation_id, causation_depth, subjects_json,
                    sensitivity, payload_json, content, resource_revision,
                    previous_resource_revision, {actor}
             FROM src.session_journal INDEXED BY session_journal_by_kind_sequence
             WHERE kind {side} '{OUTPUT_KIND}'"
        )
    };
    let mut statement = tx.prepare(&format!("{} UNION ALL {}", select("<"), select(">")))?;
    let mut rows = statement.query([])?;
    let mut insert = tx.prepare(
        "INSERT INTO main.output_cleanup_records(sequence, kind, record_json, actor)
         VALUES(?1, ?2, ?3, ?4)",
    )?;
    while let Some(row) = rows.next()? {
        let stored = stored_record_row(row)?;
        let actor = row.get::<_, Option<String>>(19)?;
        let record = decode_record(stored)?;
        let json = serde_json::to_vec(&journal_record_for_archive(&record))?;
        insert.execute(params![i64::try_from(record.sequence)?, record.kind, json, actor])?;
    }
    Ok(())
}

/// The first and last sequence the registry's journal covers.
fn journal_range(tx: &Transaction<'_>) -> anyhow::Result<(u64, u64)> {
    let (lo, hi): (Option<i64>, Option<i64>) = tx.query_row(
        // One aggregate per subquery: SQLite answers a lone MIN or MAX from
        // the index, but two in one SELECT scan the whole table.
        "SELECT MIN(COALESCE((SELECT MIN(start_sequence) FROM src.journal_segments),
                             (SELECT MIN(sequence) FROM src.session_journal)),
                    COALESCE((SELECT MIN(sequence) FROM src.session_journal),
                             (SELECT MIN(start_sequence) FROM src.journal_segments))),
                MAX(COALESCE((SELECT MAX(end_sequence) FROM src.journal_segments), 0),
                    COALESCE((SELECT MAX(sequence) FROM src.session_journal), 0))",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let (Some(lo), Some(hi)) = (lo, hi) else { anyhow::bail!("the journal is empty") };
    Ok((u64::try_from(lo)?.max(1), u64::try_from(hi)?))
}

/// Seals every kept record into new segments that cover `lo..=head` with no
/// gap between them, and records each removed run as a pruned range.
fn pack_segments(tx: &Transaction<'_>, lo: u64, head: u64) -> anyhow::Result<(u64, u64)> {
    let with_actors =
        table_columns(tx, "main", "journal_segments")?.iter().any(|name| name == "actors_json");
    let sealed_at_ms = i64::try_from(unix_epoch_ms()?)?;
    let mut statement = tx.prepare(
        "SELECT sequence, kind, record_json, actor FROM main.output_cleanup_records
         ORDER BY sequence ASC",
    )?;
    let mut rows = statement.query([])?;
    let mut segment = OpenSegment::new(lo);
    let mut previous = lo - 1;
    let mut segments = 0_u64;
    let mut pruned = 0_u64;
    while let Some(row) = rows.next()? {
        let sequence = u64::try_from(row.get::<_, i64>(0)?)?;
        let kind = row.get::<_, String>(1)?;
        let json = row.get::<_, Vec<u8>>(2)?;
        let actor = row.get::<_, Option<String>>(3)?;
        anyhow::ensure!(
            sequence > previous && sequence <= head,
            "kept journal record {sequence} is outside the journal range"
        );
        if sequence > previous + 1 {
            insert_pruned(tx, previous + 1, sequence - 1)?;
            pruned += 1;
        }
        previous = sequence;
        if segment.writer.records() == JOURNAL_SEGMENT_RECORD_LIMIT
            || (segment.writer.records() > 0 && !segment.writer.fits(&json))
        {
            let next_start = segment.last + 1;
            let full = std::mem::replace(&mut segment, OpenSegment::new(next_start));
            let end = full.last;
            full.insert(tx, end, sealed_at_ms, with_actors)?;
            segments += 1;
        }
        segment.writer.push(&json);
        segment.last = sequence;
        segment.kinds.insert(kind);
        if let Some(actor) = actor {
            segment.actors.insert(sequence.to_string(), actor);
        }
    }
    if previous < head {
        insert_pruned(tx, previous + 1, head)?;
        pruned += 1;
    }
    segment.insert(tx, head, sealed_at_ms, with_actors)?;
    segments += 1;
    Ok((segments, pruned))
}

fn insert_pruned(tx: &Transaction<'_>, start: u64, end: u64) -> anyhow::Result<()> {
    tx.execute(
        "INSERT INTO main.journal_pruned_ranges(start_sequence, end_sequence) VALUES(?1, ?2)",
        params![i64::try_from(start)?, i64::try_from(end)?],
    )?;
    Ok(())
}

struct OpenSegment {
    start: u64,
    last: u64,
    writer: SegmentWriter,
    kinds: BTreeSet<String>,
    actors: BTreeMap<String, String>,
}

impl OpenSegment {
    fn new(start: u64) -> Self {
        Self {
            start,
            last: 0,
            writer: SegmentWriter::new(),
            kinds: BTreeSet::new(),
            actors: BTreeMap::new(),
        }
    }

    fn insert(
        self,
        tx: &Transaction<'_>,
        end: u64,
        sealed_at_ms: i64,
        with_actors: bool,
    ) -> anyhow::Result<()> {
        let records = self.writer.records();
        let encoded = self.writer.finish()?;
        let segment_id = format!("segment_{}_{end}_{}", self.start, encode_hex(&encoded.digest));
        let actors =
            if self.actors.is_empty() { None } else { Some(serde_json::to_string(&self.actors)?) };
        let columns = if with_actors { ", actors_json" } else { "" };
        let values = if with_actors { ", ?9" } else { "" };
        tx.execute(
            &format!(
                "INSERT INTO main.journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms{columns}
                 ) VALUES(?1, ?2, ?3, ?4, 'gzip-json-v1', ?5, ?6, ?7, ?8{values})"
            ),
            rusqlite::params_from_iter(
                [
                    rusqlite::types::Value::Text(segment_id.clone()),
                    rusqlite::types::Value::Integer(i64::try_from(self.start)?),
                    rusqlite::types::Value::Integer(i64::try_from(end)?),
                    rusqlite::types::Value::Integer(i64::try_from(records)?),
                    rusqlite::types::Value::Blob(encoded.compressed),
                    rusqlite::types::Value::Integer(i64::try_from(encoded.uncompressed_bytes)?),
                    rusqlite::types::Value::Blob(encoded.digest.to_vec()),
                    rusqlite::types::Value::Integer(sealed_at_ms),
                    actors.map_or(rusqlite::types::Value::Null, rusqlite::types::Value::Text),
                ]
                .into_iter()
                .take(if with_actors { 9 } else { 8 }),
            ),
        )?;
        for kind in &self.kinds {
            tx.execute(
                "INSERT INTO main.journal_segment_kinds(segment_id, kind) VALUES(?1, ?2)",
                params![segment_id, kind],
            )?;
        }
        Ok(())
    }
}

/// Checks the committed new registry before it replaces the old one.
fn verify(
    staged: &Connection,
    registry_id: &str,
    built: &Built,
    steps: &mut Steps,
) -> anyhow::Result<()> {
    let integrity: String = staged.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    steps.mark("integrity check");
    anyhow::ensure!(integrity == "ok", "the new registry failed integrity_check: {integrity}");
    anyhow::ensure!(
        required_meta(staged, "registry_id")? == registry_id,
        "the new registry has another registry id"
    );
    let live: i64 =
        staged.query_row("SELECT COUNT(*) FROM session_journal", [], |row| row.get(0))?;
    anyhow::ensure!(live == 0, "the new registry kept {live} live journal rows");
    // Read the whole journal back through the readers the owner uses.
    let mut cursor = 0_u64;
    let mut read = 0_u64;
    loop {
        let page = query_session_journal_after(staged, cursor, 1024)?;
        anyhow::ensure!(page.head_sequence == built.head, "the new journal head moved");
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        for record in &page.records {
            anyhow::ensure!(
                record.kind != OUTPUT_KIND,
                "the new registry still holds terminal output at {}",
                record.sequence
            );
        }
        read += u64::try_from(page.records.len())?;
    }
    anyhow::ensure!(
        read == built.kept,
        "the new journal reads {read} records back, {} were kept",
        built.kept
    );
    anyhow::ensure!(query_journal_head(staged)? == built.head, "the new journal head moved");
    steps.mark("read back");
    Ok(())
}

/// The staged file is closed: no sidecar may hold data, and its bytes are
/// durable before the rename.
fn finish_staged_file(db_path: &Path) -> anyhow::Result<()> {
    let staged = staging_path(db_path);
    for suffix in ["-wal", "-journal"] {
        anyhow::ensure!(
            file_len(&sidecar_path(&staged, suffix)) == 0,
            "the new registry {suffix} still holds data"
        );
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(&staged, suffix))?;
    }
    platform::restrict_file(&staged)?;
    // Windows FlushFileBuffers needs write access.
    OpenOptions::new().write(true).open(&staged)?.sync_all()?;
    Ok(())
}

/// Keeps the registry as `.pre-output-cleanup` (a hard link, so a crash at
/// any point leaves a registry in place) and renames the new file over it.
fn install(db_path: &Path) -> anyhow::Result<()> {
    let wal = sidecar_path(db_path, "-wal");
    anyhow::ensure!(file_len(&wal) == 0, "the registry WAL still holds data: {}", wal.display());
    remove_if_present(&wal)?;
    remove_if_present(&sidecar_path(db_path, "-shm"))?;
    let previous = previous_path(db_path);
    remove_if_present(&previous)?;
    let parent = db_path.parent().context("registry path has no directory")?;
    let linked = fs::hard_link(db_path, &previous).is_ok();
    if !linked {
        fs::rename(db_path, &previous)
            .with_context(|| format!("keep the registry as {}", previous.display()))?;
    }
    // From here the registry may exist only as `previous`: no error path
    // may leave db_path empty. A failed directory sync is only logged (the
    // rename below orders after the link or rename above on every file
    // system the daemon supports; a crash leaves `previous`, which the next
    // open restores).
    if let Err(error) = platform::sync_directory(parent) {
        eprintln!("cmux-tui: output cleanup: sync {}: {error}", parent.display());
    }
    if let Err(error) = fs::rename(staging_path(db_path), db_path) {
        if !linked {
            if let Err(restore) = fs::rename(&previous, db_path) {
                eprintln!(
                    "cmux-tui: output cleanup: could not put back {}: {restore}",
                    previous.display()
                );
            }
        } else {
            let _ = fs::remove_file(&previous);
        }
        return Err(anyhow::Error::from(error).context("install the new registry"));
    }
    if let Err(error) = platform::sync_directory(parent) {
        eprintln!("cmux-tui: output cleanup: sync {}: {error}", parent.display());
    }
    Ok(())
}

fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn table_columns(tx: &Transaction<'_>, schema: &str, table: &str) -> anyhow::Result<Vec<String>> {
    let mut statement = tx.prepare("SELECT name FROM pragma_table_info(?1, ?2) ORDER BY cid")?;
    let columns = statement
        .query_map([table, schema], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    anyhow::ensure!(!columns.is_empty(), "table {schema}.{table} has no columns");
    Ok(columns)
}

fn column_list(
    tx: &Transaction<'_>,
    schema: &str,
    table: &str,
    alias: Option<&str>,
) -> anyhow::Result<String> {
    Ok(table_columns(tx, schema, table)?
        .iter()
        .map(|column| match alias {
            Some(alias) => format!("{alias}.{}", quote(column)),
            None => quote(column),
        })
        .collect::<Vec<_>>()
        .join(", "))
}

fn table_exists(tx: &Transaction<'_>, schema: &str, table: &str) -> anyhow::Result<bool> {
    Ok(tx.query_row(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM {schema}.sqlite_master WHERE type = 'table' AND name = ?1)"
        ),
        [table],
        |row| row.get(0),
    )?)
}

/// The table stores a rowid (it is not WITHOUT ROWID). An INTEGER PRIMARY
/// KEY column aliases it; naming `rowid` too copies the same value.
fn has_rowid(tx: &Transaction<'_>, table: &str) -> anyhow::Result<bool> {
    let without: i64 = tx.query_row(
        "SELECT wr FROM pragma_table_list(?1) WHERE schema = 'src' AND type = 'table'",
        [table],
        |row| row.get(0),
    )?;
    Ok(without == 0)
}

/// Every source record is either kept or removed output: per staged segment
/// (Phase A counted them), and for the live rows, whose contiguity and output
/// count Phase A took in one snapshot. Rows that came after that snapshot are
/// counted here; they are few.
fn check_counts(tx: &Transaction<'_>) -> anyhow::Result<()> {
    let value = |key: &str| -> anyhow::Result<i64> {
        Ok(tx
            .query_row(
                "SELECT value FROM main.output_cleanup_state WHERE key = ?1",
                [key],
                |row| row.get::<_, String>(0),
            )?
            .parse()?)
    };
    let kept_in = |after: i64, through: i64| -> anyhow::Result<i64> {
        Ok(tx.query_row(
            "SELECT COUNT(*) FROM main.output_cleanup_records WHERE sequence > ?1 AND sequence <= ?2",
            [after, through],
            |row| row.get(0),
        )?)
    };
    let archive_end: i64 = tx.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0) FROM src.journal_segments",
        [],
        |row| row.get(0),
    )?;
    let (segments, first, last, records, kept): (i64, Option<i64>, Option<i64>, i64, i64) = tx
        .query_row(
            "SELECT COUNT(*), MIN(start_sequence), MAX(end_sequence),
                    COALESCE(SUM(record_count), 0), COALESCE(SUM(kept), 0)
             FROM main.output_cleanup_segments",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )?;
    if segments > 0 {
        let (first, last) = (first.unwrap_or(0), last.unwrap_or(0));
        anyhow::ensure!(
            last == archive_end && records == last - first + 1,
            "the staged segments do not cover the sealed journal"
        );
        anyhow::ensure!(
            kept_in(first - 1, last)? == kept,
            "the kept sealed records do not match the staged segment counts"
        );
        let mismatched: i64 = tx.query_row(
            "SELECT COUNT(*) FROM main.output_cleanup_segments AS segment
             WHERE segment.kept + segment.removed != segment.record_count
                OR segment.kept != (
                  SELECT COUNT(*) FROM main.output_cleanup_records AS kept
                  WHERE kept.sequence BETWEEN segment.start_sequence AND segment.end_sequence)",
            [],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            mismatched == 0,
            "{mismatched} staged segments do not add up (kept plus removed)"
        );
        let gaps: i64 = tx.query_row(
            "SELECT COUNT(*) FROM main.output_cleanup_segments AS segment
             WHERE segment.start_sequence > ?1 AND NOT EXISTS (
               SELECT 1 FROM main.output_cleanup_segments AS previous
               WHERE previous.end_sequence = segment.start_sequence - 1)",
            [first],
            |row| row.get(0),
        )?;
        anyhow::ensure!(gaps == 0, "the staged segments are not contiguous");
    }
    let live_archive_end = value("live_archive_end")?;
    let live_head = value("live_head")?;
    anyhow::ensure!(
        archive_end >= live_archive_end,
        "the sealed journal is shorter than when it was staged"
    );
    let range_end = live_head.max(archive_end);
    if live_head > archive_end {
        let output = if archive_end == live_archive_end {
            value("live_output")?
        } else {
            tx.query_row(
                "SELECT COUNT(*) FROM src.session_journal
                   INDEXED BY session_journal_by_kind_sequence
                 WHERE kind = ?3 AND sequence > ?1 AND sequence <= ?2",
                params![archive_end, live_head, OUTPUT_KIND],
                |row| row.get::<_, i64>(0),
            )?
        };
        anyhow::ensure!(
            kept_in(archive_end, live_head)? + output == live_head - archive_end,
            "kept and removed live rows do not add up to the live journal"
        );
    }
    let (total, output): (i64, i64) = tx.query_row(
        "SELECT (SELECT COUNT(*) FROM src.session_journal WHERE sequence > ?1),
                (SELECT COUNT(*) FROM src.session_journal
                   INDEXED BY session_journal_by_kind_sequence
                 WHERE kind = ?2 AND sequence > ?1)",
        params![range_end, OUTPUT_KIND],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let head: i64 = tx.query_row(
        "SELECT COALESCE(MAX(sequence), ?1) FROM src.session_journal",
        [range_end],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        total == head - range_end && kept_in(range_end, head)? + output == total,
        "kept and removed rows after the staged snapshot do not add up"
    );
    Ok(())
}

#[cfg(test)]
#[path = "swap_rollback_tests.rs"]
mod rollback_tests;
