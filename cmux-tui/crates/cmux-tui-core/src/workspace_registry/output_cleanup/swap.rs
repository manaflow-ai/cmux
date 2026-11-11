//! Phase B: at owner start, before the registry connection opens, finish a
//! new registry the background build made and rename it into place: stage
//! and pack the short journal tail since the build, copy the other tables,
//! check, rename. Nothing writes the registry file itself; until the rename
//! it is the registry, and after it the old file stays as
//! `.pre-output-cleanup`.

use std::fs::{self, OpenOptions};
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use rusqlite::{Connection, OpenFlags, OptionalExtension as _, Transaction, params};

use super::super::open_guard::sidecar_path;
use super::super::session_journal::{
    query_journal_head, query_session_journal_after, unix_epoch_ms,
};
use super::super::{
    open_registry_database_read_only, open_registry_database_with_flags, required_meta,
    sqlite_filesystem_path,
};
use super::backup::{FULL_STARTS_META_KEY, restore_interrupted_swap};
use super::build::{
    STEP_BUILT, journal_schema_digest, pack_rest, quote, schema_objects, segment_record_limit,
    stage_range, table_columns,
};
use super::stage::{open_existing_staging, state, state_u64};
use super::{
    DONE_META_KEY, OUTPUT_KIND, REBUILT_TABLES, STAGED_WORK_CHANGED, copied_bytes,
    failed_for_this_build, file_len, free_space_refusal, is_temporary, kept_path, mebibytes,
    previous_path, remove_if_present, remove_staging, staged_bytes_refusal, staging_path,
    start_floor, write_failure_marker,
};
use crate::platform;

/// Opens a built registry file the way the owner does and reads its layout.
pub(crate) type VerifyOpen<'a> = &'a dyn Fn(&Path) -> anyhow::Result<()>;

enum Swap {
    NotReady,
    Refused(String),
    /// The staging file passed its size bound (`output_cleanup` module
    /// docs).
    Abandoned(String),
    /// Not at this start, and the staged work stays: the tail since the
    /// background build is too long for a start, or a reader holds the log.
    Deferred(String),
    Done(SwapStats),
}

struct SwapStats {
    before_bytes: u64,
    after_bytes: u64,
    kept: u64,
    /// Journal records after the background build that this start staged.
    tail: u64,
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
    // One kept file at a time (`backup.rs`): a swap now would leave a second
    // one beside it. No worker stages while a file is kept, so this is a
    // staging file from before that rule; it waits.
    if kept_path(db_path).exists() {
        eprintln!(
            "cmux-tui: output cleanup: swap deferred: the registry that the last swap replaced \
             is still kept as {}",
            kept_path(db_path).display()
        );
        return false;
    }
    let started = Instant::now();
    match build_and_swap(db_path, verify_open) {
        Ok(Swap::NotReady) => false,
        Ok(Swap::Refused(reason)) => {
            eprintln!("cmux-tui: output cleanup: swap deferred, not enough free space: {reason}");
            false
        }
        Ok(Swap::Abandoned(reason)) => {
            eprintln!(
                "cmux-tui: output cleanup: abandoned before the copy, the registry is unchanged \
                 and the staging file deleted: {reason}"
            );
            if let Err(error) = remove_staging(db_path) {
                eprintln!("cmux-tui: output cleanup: could not delete the staging file: {error:#}");
            }
            false
        }
        Ok(Swap::Deferred(reason)) => {
            eprintln!("cmux-tui: output cleanup: swap deferred to a later start: {reason}");
            false
        }
        Ok(Swap::Done(stats)) => {
            eprintln!(
                "cmux-tui: output cleanup: swapped the registry in {:.2} s: {} -> {}; \
                 {} records kept in {} segments, a tail of {} records staged at this start, {} \
                 pruned ranges, {} tables copied ({}), {} pending hook deliveries of removed \
                 output abandoned ({}); previous file at {}",
                started.elapsed().as_secs_f64(),
                mebibytes(stats.before_bytes),
                mebibytes(stats.after_bytes),
                stats.kept,
                stats.segments,
                stats.tail,
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

/// Journal records after the background build that a start still stages
/// and packs before the rename. A longer tail defers the swap: the owner's
/// cleanup thread catches up while it serves.
const SWAP_TAIL_LIMIT: u64 = 100_000;

/// New registry meta key written once the swap's transaction committed:
/// what the source registry was and what the start built, so a start killed
/// before the rename finishes it instead of building again.
const SWAP_META_KEY: &str = "output_cleanup_swap";

fn swap_tail_limit() -> u64 {
    #[cfg(debug_assertions)]
    if let Some(records) = std::env::var("CMUX_TUI_TEST_OUTPUT_CLEANUP_TAIL_LIMIT")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return records;
    }
    SWAP_TAIL_LIMIT
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
    let Some(staged) = open_existing_staging(&staging_path(db_path), &registry_id).ok().flatten()
    else {
        // The swap's transaction committed and a kill came before the
        // rename: the file is the new registry, checked again and renamed.
        if let Some(swap) = committed_swap(db_path, &registry_id) {
            eprintln!(
                "cmux-tui: output cleanup: finishing a swap an earlier start committed and did \
                 not rename"
            );
            return finish_committed(
                db_path,
                &registry_id,
                &swap,
                verify_open,
                before_bytes,
                steps,
            );
        }
        // A staging file of another registry or format: Phase A runs again
        // at a later start.
        eprintln!("cmux-tui: output cleanup: discarding a stale staging file");
        remove_staging(db_path)?;
        return Ok(Swap::NotReady);
    };
    // A staging file of an earlier build has no build state yet: the
    // background build adds it, never this start.
    let step = state(&staged, "build_step").unwrap_or_default();
    if state(&staged, "complete")? != "1" || step != STEP_BUILT {
        eprintln!(
            "cmux-tui: output cleanup: the new registry is still being built in the background \
             ({}); the swap waits for it",
            if state(&staged, "complete")? != "1" {
                "phase A".to_string()
            } else {
                format!("step {}", if step.is_empty() { "schema" } else { step.as_str() })
            }
        );
        return Ok(Swap::NotReady);
    }
    if let Some(reason) = staged_bytes_refusal(&staged)? {
        return Ok(Swap::Abandoned(reason));
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
        if busy != 0 {
            // A reader of the registry holds the log (another process, for
            // at least the busy timeout). Nothing is wrong with the staged
            // work: a later start swaps.
            return Ok(Swap::Deferred(
                "a reader of the registry holds its log, so the log could not be folded into \
                 the registry file"
                    .to_string(),
            ));
        }
    }
    steps.mark("checkpoint");
    // Nothing writes the registry file from here until the rename (the
    // reads below change neither its length nor its time): the swap's
    // record names it, so a later start can tell it is unchanged.
    let stamp = source_stamp(db_path)?;
    let source = open_registry_database_read_only(db_path)?;
    source.busy_timeout(Duration::from_secs(5))?;
    check_staged_prefix(&source, &staged)?;
    // The floor of THIS start. It can be lower than at the build: an update
    // whose roster or agent history reducer has another version folds from
    // the first record it finds, and so does a hook that is enabled again. A
    // file that left out records this start reads is not installed; the
    // cleanup worker builds again at the floor it finds.
    // A file with no floor recorded (an earlier format) left out no run.
    let built_floor =
        state(&staged, "floor").ok().and_then(|floor| floor.parse::<u64>().ok()).unwrap_or(0);
    // A floor that cannot be read (a saved reducer state that is not JSON)
    // is floor 0: this start may read every record, so only a file built at
    // floor 0 is installed. It is not a failure of this registry.
    let floor = if built_floor == 0 {
        0
    } else {
        start_floor(&source).unwrap_or_else(|error| {
            eprintln!("cmux-tui: output cleanup: could not read the retention floor: {error:#}");
            0
        })
    };
    if built_floor > floor {
        eprintln!(
            "cmux-tui: output cleanup: the new registry was built without the journal through \
             {built_floor} and this start reads it after {floor}; discarding it"
        );
        drop(source);
        drop(staged);
        remove_staging(db_path)?;
        return Ok(Swap::NotReady);
    }
    // The saved reducer states are the only copy of what the new file left
    // out of the journal: the swap copies each to its base
    // (`journal_retention/base.rs`). A state that cannot be a base (another
    // version, a rebuild owed, a cursor below the floor of the build) is
    // not this start's fold of those records: the file is not installed.
    let retention = super::super::journal_retention::journal_pruned_through(&source)?;
    if built_floor > retention
        && !super::super::journal_retention::reducer_bases_possible(&source, built_floor)?
    {
        eprintln!(
            "cmux-tui: output cleanup: the new registry was built without the journal through \
             {built_floor} and a saved reducer state cannot stand for those records; discarding it"
        );
        drop(source);
        drop(staged);
        remove_staging(db_path)?;
        return Ok(Swap::NotReady);
    }
    let built_head = state_u64(&staged, "built_head")?;
    let head = query_journal_head(&source)?;
    // A catch-up stopped before it packed leaves staged records unpacked;
    // this start would pack them too, so they count toward the limit.
    let tail = head.saturating_sub(built_head);
    let work = tail.saturating_add(unpacked_backlog(&staged)?);
    if work > swap_tail_limit() {
        return Ok(Swap::Deferred(format!(
            "{work} journal records came after the background build or are not packed yet (a \
             start catches up at most {}); the cleanup thread catches up while this owner serves",
            swap_tail_limit()
        )));
    }
    let objects = schema_objects(&source, "main")?;
    anyhow::ensure!(
        journal_schema_digest(&objects) == state(&staged, "schema_digest")?,
        "{STAGED_WORK_CHANGED}: the journal schema changed after the background build"
    );
    steps.mark("tail check");
    let range = TailRange { stamp, built_head, head };
    let (built, swap) = build(&staged, &source, db_path, &objects, &range, &mut steps)?;
    drop(source);
    #[cfg(debug_assertions)]
    if std::env::var_os("CMUX_TUI_TEST_OUTPUT_CLEANUP_EXIT_BEFORE_RENAME").is_some() {
        eprintln!("cmux-tui: test: exiting after the swap committed");
        // The state a kill between the swap's commit and its rename leaves.
        // crash-allow: a test-only exit (debug builds, explicit env).
        std::process::exit(9);
    }
    verify(&staged, &registry_id, &swap, &mut steps)?;
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
        tail,
        segments: built.segments,
        pruned_ranges: built.pruned_ranges,
        abandoned_deliveries: built.abandoned_deliveries,
        tables: built.tables,
        largest_tables: built.largest_tables,
        steps: steps.line(),
    }))
}

/// What a committed swap recorded in the new registry ([`SWAP_META_KEY`]).
#[derive(serde::Serialize, serde::Deserialize)]
struct CommittedSwap {
    /// [`source_stamp`] of the registry after the swap read it.
    source: String,
    /// The journal before this sequence was packed in the background.
    from: u64,
    head: u64,
    /// Records the start packed (after `from`).
    tail_kept: u64,
    /// The floor the file was built at: the journal through it is not in the
    /// file (0: no run was left out). Absent in a record of an earlier build.
    #[serde(default)]
    floor: Option<u64>,
}

/// The registry file's length and modification time, with no WAL beside it
/// holding data: any write after the stamp changes it.
fn source_stamp(db_path: &Path) -> anyhow::Result<String> {
    let metadata = fs::metadata(db_path)?;
    let modified = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |time| time.as_nanos());
    Ok(format!("{}-{modified}-wal{}", metadata.len(), file_len(&sidecar_path(db_path, "-wal"))))
}

/// The staging file is a new registry whose swap committed, for this
/// registry as it is now (nothing wrote it since).
fn committed_swap(db_path: &Path, registry_id: &str) -> Option<CommittedSwap> {
    let staged = open_registry_database_with_flags(
        &staging_path(db_path),
        OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
    )
    .ok()?;
    let meta = |key: &str| -> Option<String> {
        staged
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
            .optional()
            .ok()
            .flatten()
    };
    if meta("registry_id")?.as_str() != registry_id || !meta(DONE_META_KEY)?.contains("\"kept\"") {
        return None;
    }
    let swap: CommittedSwap = serde_json::from_str(&meta(SWAP_META_KEY)?).ok()?;
    (swap.source == source_stamp(db_path).ok()?).then_some(swap)
}

fn finish_committed(
    db_path: &Path,
    registry_id: &str,
    swap: &CommittedSwap,
    verify_open: VerifyOpen<'_>,
    before_bytes: u64,
    mut steps: Steps,
) -> anyhow::Result<Swap> {
    let (segments, pruned_ranges, tables) = {
        let staged = open_registry_database_with_flags(
            &staging_path(db_path),
            OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
        )?;
        // The start that finishes the swap can be of another build than the
        // one that committed it (an update between the kill and this start),
        // with a lower floor: the same rule as before the build.
        let source = open_registry_database_read_only(db_path)?;
        source.busy_timeout(Duration::from_secs(5))?;
        if let Some((built_floor, floor)) = built_above_start_floor(&staged, &source, swap)? {
            // Both files stay and the owner starts on the registry, which has
            // every record. The new file is of no use to a later start (this
            // owner writes the registry, so its stamp no longer names it):
            // the cleanup worker replaces it when it builds again.
            eprintln!(
                "cmux-tui: output cleanup: the swap an earlier start committed was built without \
                 the journal through {built_floor} and this start reads it after {floor}; it is \
                 not installed, the registry is unchanged"
            );
            return Ok(Swap::NotReady);
        }
        drop(source);
        verify(&staged, registry_id, swap, &mut steps)?;
        let count = |sql: &str| -> anyhow::Result<u64> {
            Ok(u64::try_from(staged.query_row(sql, [], |row| row.get::<_, i64>(0))?)?)
        };
        (
            count("SELECT COUNT(*) FROM journal_segments")?,
            count("SELECT COUNT(*) FROM journal_pruned_ranges")?,
            copied_tables(&staged)?.len(),
        )
    };
    verify_open(&staging_path(db_path)).context("open the new registry as the owner does")?;
    steps.mark("open and read layout");
    finish_staged_file(db_path)?;
    install(db_path)?;
    steps.mark("sync and rename");
    Ok(Swap::Done(SwapStats {
        before_bytes,
        after_bytes: file_len(db_path),
        kept: swap.tail_kept,
        tail: 0,
        segments,
        pruned_ranges,
        abandoned_deliveries: 0,
        tables,
        largest_tables: String::new(),
        steps: steps.line(),
    }))
}

/// `Some((built floor, floor of this start))` when the committed new registry
/// `staged` left out records that this start reads from `source`, the
/// registry it was built from. A record of an earlier build names no floor:
/// the floor is then what the new file says is gone, when that is more than
/// the registry itself says.
fn built_above_start_floor(
    staged: &Connection,
    source: &Connection,
    swap: &CommittedSwap,
) -> anyhow::Result<Option<(u64, u64)>> {
    use super::super::journal_retention::journal_pruned_through;
    let built_floor = match swap.floor {
        Some(floor) => floor,
        None => {
            let gone = journal_pruned_through(staged)?;
            if gone > journal_pruned_through(source)? { gone } else { 0 }
        }
    };
    if built_floor == 0 {
        return Ok(None);
    }
    // A floor that cannot be read is floor 0, as before the build.
    let floor = start_floor(source).unwrap_or_else(|error| {
        eprintln!("cmux-tui: output cleanup: could not read the retention floor: {error:#}");
        0
    });
    Ok((built_floor > floor).then_some((built_floor, floor)))
}

/// The staged segments still describe the registry's archive: its last
/// staged segment exists with the same id and end, and the live rows were
/// counted from that end (an earlier build could count past it).
fn check_staged_prefix(source: &Connection, staged: &Connection) -> anyhow::Result<()> {
    let through = state_u64(staged, "staged_through")?;
    let counted_after = state_u64(staged, "live_archive_end")?;
    anyhow::ensure!(
        counted_after == through,
        "{STAGED_WORK_CHANGED}: the live rows were counted after sequence {counted_after}, the \
         staged segments end at {through}"
    );
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

/// Staged records after the packed journal past the one partial segment a
/// finished pack leaves, counted up to just over the tail limit.
fn unpacked_backlog(staged: &Connection) -> anyhow::Result<u64> {
    let partial = u64::try_from(segment_record_limit())?;
    let bound = swap_tail_limit().saturating_add(partial).saturating_add(1);
    let unpacked: i64 = staged.query_row(
        "SELECT COUNT(*) FROM (
           SELECT 1 FROM output_cleanup_records WHERE sequence > ?1 LIMIT ?2)",
        params![
            i64::try_from(state_u64(staged, "packed_through")?)?,
            i64::try_from(bound).unwrap_or(i64::MAX)
        ],
        |row| row.get(0),
    )?;
    Ok(u64::try_from(unpacked)?.saturating_sub(partial))
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
}

/// What the swap at this start finishes: the journal after the background
/// build's head through the registry's head, and the registry's stamp.
struct TailRange {
    stamp: String,
    built_head: u64,
    head: u64,
}

/// Finishes the new registry in the staging file in one transaction: a
/// crash before its commit leaves the background build as it was.
fn build(
    staged: &Connection,
    source: &Connection,
    db_path: &Path,
    objects: &[(String, String, String, String)],
    range: &TailRange,
    steps: &mut Steps,
) -> anyhow::Result<(Built, CommittedSwap)> {
    // A rollback journal: the new pages need no copy, unlike a WAL.
    let mode: String = staged.query_row("PRAGMA journal_mode=DELETE", [], |row| row.get(0))?;
    anyhow::ensure!(mode.eq_ignore_ascii_case("delete"), "staging file kept journal mode {mode}");
    staged.execute_batch("PRAGMA foreign_keys=OFF; PRAGMA synchronous=NORMAL;")?;
    let path = sqlite_filesystem_path(db_path)?;
    let path = path.to_str().context("workspace registry path is not UTF-8")?;
    staged.execute("ATTACH DATABASE ?1 AS src", [path])?;
    let built = (|| -> anyhow::Result<(Built, CommittedSwap)> {
        let tx = staged.unchecked_transaction()?;
        let built = build_in(&tx, source, objects, range, steps)?;
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

/// The one copied table that holds a row per journal record.
const INGRESS_RECEIPTS_TABLE: &str = "journal_ingress_receipts";

fn build_in(
    tx: &Transaction<'_>,
    source: &Connection,
    objects: &[(String, String, String, String)],
    range: &TailRange,
    steps: &mut Steps,
) -> anyhow::Result<(Built, CommittedSwap)> {
    let TailRange { stamp, built_head, head } = range;
    let (built_head, head) = (*built_head, *head);
    let from = state_u64(tx, "packed_through")?;
    let start = state_u64(tx, "pack_next_start")?;
    if head > built_head {
        stage_range(source, tx, built_head, head)?;
    }
    let tail_kept = u64::try_from(tx.query_row(
        "SELECT COUNT(*) FROM main.output_cleanup_records WHERE sequence > ?1",
        [i64::try_from(from)?],
        |row| row.get::<_, i64>(0),
    )?)?;
    steps.mark("stage tail");
    pack_rest(tx, source, from, start, head)?;
    let kept = state_u64(tx, "packed_kept")? + tail_kept;
    anyhow::ensure!(kept > 0, "the journal holds no record other than terminal output");
    steps.mark("pack tail");

    // The copied tables, created again here (the background build made
    // them empty) so they carry the registry's schema of this start.
    let copied = objects
        .iter()
        .filter(|(kind, name, _, _)| kind == "table" && !REBUILT_TABLES.contains(&name.as_str()))
        .collect::<Vec<_>>();
    for (_, table, _, sql) in &copied {
        tx.execute_batch(&format!("DROP TABLE IF EXISTS main.{}", quote(table)))?;
        tx.execute_batch(sql)?;
    }
    // The receipts of the ingress records left out at the floor go with
    // them: only the rows after it are copied (and counted below).
    let cut = state(tx, "floor")?.parse::<u64>().unwrap_or(0);
    let after_cut = |table: &str| -> String {
        if table == INGRESS_RECEIPTS_TABLE && cut > 0 {
            format!(" WHERE journal_sequence > {cut}")
        } else {
            String::new()
        }
    };
    // Rowids are kept: code orders by them (ledger retention, archives,
    // intents, effects, workspace positions).
    for (_, table, _, _) in &copied {
        let columns = column_list(tx, "src", table, None)?;
        let (insert, select, order) = if has_rowid(tx, table)? {
            (format!("rowid, {columns}"), format!("rowid, {columns}"), " ORDER BY rowid")
        } else {
            (columns.clone(), columns.clone(), "")
        };
        tx.execute(
            &format!(
                "INSERT INTO main.{0}({insert}) SELECT {select} FROM src.{0}{1}{order}",
                quote(table),
                after_cut(table)
            ),
            [],
        )?;
    }
    let mut sizes = Vec::with_capacity(copied.len());
    for (_, table, _, _) in &copied {
        let (main_count, src_count): (i64, i64) = tx.query_row(
            &format!(
                "SELECT (SELECT COUNT(*) FROM main.{0}), (SELECT COUNT(*) FROM src.{0}{1})",
                quote(table),
                after_cut(table)
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
    // The packed segments have no kept reducer records (their table is
    // rebuilt empty), and the copied meta holds the backfill cursor of the
    // old segments: the journal maintenance backfill starts over.
    super::super::session_journal::reducer_records::forget_backfill(tx)?;
    // Every kept record has a row in the staged records, packed or not.
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
    let swap = CommittedSwap { source: stamp.clone(), from, head, tail_kept, floor: Some(cut) };
    let swap_json = serde_json::to_string(&swap)?;
    for (key, value) in [
        (DONE_META_KEY, done.as_str()),
        ("journal_segment_kinds_backfill", "1"),
        (FULL_STARTS_META_KEY, "0"),
        (SWAP_META_KEY, swap_json.as_str()),
    ] {
        tx.execute(
            "INSERT INTO main.meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )?;
    }
    // The records through the cut are gone, as the ones retention deletes
    // in place are: the same `meta` floor says so to the readers that ask
    // it (`journal_pruned_through`). It never goes down.
    if cut > 0 {
        tx.execute(
            "INSERT INTO main.meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value
             WHERE CAST(meta.value AS INTEGER) < CAST(excluded.value AS INTEGER)",
            [super::super::journal_retention::PRUNED_THROUGH_META_KEY, cut.to_string().as_str()],
        )?;
        // The saved reducer states (copied with `meta`) are the only copy
        // of what the cut takes from the journal: each gets its base in the
        // new file. `build_and_swap` asked before the build; a state that
        // cannot be a base here is an error, and the registry stays.
        let based = super::super::journal_retention::save_reducer_bases(tx, "main", cut)?;
        anyhow::ensure!(
            based || cut <= super::super::journal_retention::journal_pruned_through(source)?,
            "a saved reducer state cannot stand for the journal through {cut}"
        );
    }
    steps.mark("meta");
    // Indexes of the copied tables after their rows (the rebuilt tables got
    // theirs in the background); triggers last, so none fired on the copy.
    for (_, _, _, sql) in objects
        .iter()
        .filter(|(kind, _, table, _)| kind == "index" && !REBUILT_TABLES.contains(&table.as_str()))
    {
        tx.execute_batch(sql)?;
    }
    for wanted in ["view", "trigger"] {
        for (_, _, _, sql) in objects.iter().filter(|(kind, _, _, _)| kind == wanted) {
            tx.execute_batch(sql)?;
        }
    }
    let count = |sql: &str| -> anyhow::Result<u64> {
        Ok(u64::try_from(tx.query_row(sql, [], |row| row.get::<_, i64>(0))?)?)
    };
    let segments = count("SELECT COUNT(*) FROM main.journal_segments")?;
    let pruned_ranges = count("SELECT COUNT(*) FROM main.journal_pruned_ranges")?;
    // The cleanup's own tables (`schema_objects` refuses a registry that
    // has one of that name), whatever they are.
    let own = {
        let mut statement = tx.prepare(
            "SELECT name FROM main.sqlite_master
             WHERE type = 'table' AND name LIKE 'output\\_cleanup\\_%' ESCAPE '\\'",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    for table in own {
        tx.execute_batch(&format!("DROP TABLE main.{}", quote(&table)))?;
    }
    Ok((
        Built {
            kept,
            segments,
            pruned_ranges,
            abandoned_deliveries,
            tables: copied.len(),
            largest_tables,
        },
        swap,
    ))
}

/// The tables the swap copies as they are (outside the rebuilt journal).
fn copied_tables(staged: &Connection) -> anyhow::Result<Vec<String>> {
    Ok(schema_objects(staged, "main")?
        .into_iter()
        .filter(|(kind, name, _, _)| kind == "table" && !REBUILT_TABLES.contains(&name.as_str()))
        .map(|(_, name, _, _)| name)
        .collect())
}

/// Checks the committed new registry before it replaces the old one: the
/// tables this start wrote (the background build checked the journal it
/// packed), and the journal from the first record this start packed.
fn verify(
    staged: &Connection,
    registry_id: &str,
    swap: &CommittedSwap,
    steps: &mut Steps,
) -> anyhow::Result<()> {
    for table in copied_tables(staged)? {
        let integrity: String =
            staged.query_row(&format!("PRAGMA integrity_check({})", quote(&table)), [], |row| {
                row.get(0)
            })?;
        anyhow::ensure!(
            integrity == "ok",
            "the new registry's {table} failed integrity_check: {integrity}"
        );
    }
    steps.mark("integrity check");
    anyhow::ensure!(
        required_meta(staged, "registry_id")? == registry_id,
        "the new registry has another registry id"
    );
    let live: i64 =
        staged.query_row("SELECT COUNT(*) FROM session_journal", [], |row| row.get(0))?;
    anyhow::ensure!(live == 0, "the new registry kept {live} live journal rows");
    // Read the journal this start packed back through the owner's readers.
    let mut cursor = swap.from;
    let mut read = 0_u64;
    loop {
        let page = query_session_journal_after(staged, cursor, 1024)?;
        anyhow::ensure!(page.head_sequence == swap.head, "the new journal head moved");
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
        read == swap.tail_kept,
        "the new journal reads {read} records back after sequence {}, {} were kept",
        swap.from,
        swap.tail_kept
    );
    anyhow::ensure!(query_journal_head(staged)? == swap.head, "the new journal head moved");
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
pub(super) fn install(db_path: &Path) -> anyhow::Result<()> {
    let wal = sidecar_path(db_path, "-wal");
    anyhow::ensure!(file_len(&wal) == 0, "the registry WAL still holds data: {}", wal.display());
    remove_if_present(&wal)?;
    remove_if_present(&sidecar_path(db_path, "-shm"))?;
    // A rollback-journal sidecar belongs to the old registry's pages. Leaving
    // it beside the cleaned file would let SQLite apply those pages after the
    // rename, corrupting or rolling back the installed registry.
    remove_if_present(&sidecar_path(db_path, "-journal"))?;
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

fn column_list(
    tx: &Connection,
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

fn table_exists(tx: &Connection, schema: &str, table: &str) -> anyhow::Result<bool> {
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
fn has_rowid(tx: &Connection, table: &str) -> anyhow::Result<bool> {
    let without: i64 = tx.query_row(
        "SELECT wr FROM pragma_table_list(?1) WHERE schema = 'src' AND type = 'table'",
        [table],
        |row| row.get(0),
    )?;
    Ok(without == 0)
}
