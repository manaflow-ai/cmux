//! Phase A: copy the non-output records of the sealed segments into the
//! staging file while the owner serves. Sealed segments never change, so a
//! read-only connection can read them beside the owner. Each segment is one
//! staging transaction together with the cursor that names it, so a quit or
//! a kill resumes at the next segment and never stages a record twice. Then
//! the background build ([`super::build`]) turns the staged records into the
//! new registry's journal, and keeps it current while the owner serves.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use super::super::{
    meta_value, open_registry_database, open_registry_database_read_only,
    open_registry_database_with_flags, required_meta,
};
use super::build::{Build, BuildControl, CaughtUp, build, catch_up, ensure_build_state, set_state};
use super::chunks::{CHUNK_SCHEMA, StagedRecord, insert_chunk};
use super::codec::{inflate_segment, split_records};
use super::journal_compact;
use super::session_puts::{
    SESSION_PUT_KIND, SESSION_PUTS_SCHEMA, SESSION_PUTS_STATE, SessionPuts, record_live_puts,
    release_held_puts,
};
use super::stated_fold::STATED_FOLD_SCHEMA;
use super::{
    CleanupMode, OUTPUT_KIND, STAGED_WORK_CHANGED, copied_bytes, free_space_refusal,
    kept_refusal_in, live_records_within, max_kept_records, pruned_gap, refused_path,
    remove_if_present, remove_staging, staged_bytes_refusal, staging_path,
};
use crate::platform;

/// Format 3 stores kept records compressed (`chunks.rs`); a format 2 file
/// (plain JSON per record) is discarded and staged again. Format 4 drops
/// superseded session puts (`session_puts.rs`): a format 3 file kept them
/// all, so it is staged again.
const STAGING_FORMAT: &str = "4";
/// Session put records (live rows, and every record of a sealed segment
/// that lists the kind) from which a registry without stored output still
/// needs the cleanup: superseded puts may be most of its journal.
const PUT_RECORDS_WORTH_A_CLEANUP: u64 = 100_000;

#[cfg(test)]
thread_local! {
    /// [`PUT_RECORDS_WORTH_A_CLEANUP`] for a test on this thread.
    pub(super) static PUT_RECORDS_LIMIT: std::cell::Cell<u64> =
        const { std::cell::Cell::new(PUT_RECORDS_WORTH_A_CLEANUP) };
}

#[cfg(test)]
fn put_records_worth_a_cleanup() -> u64 {
    PUT_RECORDS_LIMIT.with(std::cell::Cell::get)
}

#[cfg(not(test))]
fn put_records_worth_a_cleanup() -> u64 {
    PUT_RECORDS_WORTH_A_CLEANUP
}

/// Free space is checked again after this many staged segments.
const SEGMENTS_PER_SPACE_CHECK: u64 = 256;
const PROGRESS_LOG_INTERVAL: Duration = Duration::from_secs(10);

pub(super) fn progress_log_interval() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("CMUX_TUI_TEST_OUTPUT_CLEANUP_PROGRESS_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(ms);
    }
    PROGRESS_LOG_INTERVAL
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StageOutcome {
    /// No stored terminal output and too few session puts to matter:
    /// nothing to clean up.
    NotNeeded,
    /// The new registry is built (and was kept current until the owner
    /// stopped); the next owner start swaps.
    Built,
    /// Not enough free space; the staged work so far stays.
    Refused(String),
    /// The owner is stopping; the staged work so far stays.
    Stopped,
    /// The cleanup would keep too much of the journal (module docs of
    /// `output_cleanup`); any staging file is deleted.
    Skipped(String),
}

pub(crate) struct StageControl<'a> {
    /// Called once the registry is known to need a cleanup, before staging.
    pub(crate) on_pending: &'a dyn Fn(),
    /// Called before each segment and build step; `false` stops staging.
    pub(crate) next_segment: &'a dyn Fn() -> bool,
    /// After the build: waits until the next catch-up with the records the
    /// owner appended; `false` once the owner is stopping.
    pub(crate) catch_up: &'a dyn Fn() -> bool,
    /// Whether the owner is stopping. Also read while a read of the registry
    /// runs, so a stop cuts a long scan (the live row counts) short instead
    /// of holding the owner's shutdown until it ends.
    pub(crate) stopped: std::sync::Arc<dyn Fn() -> bool + Send + Sync>,
}

/// SQLite virtual machine steps between two stop checks during a read.
const STOP_CHECK_STEPS: std::ffi::c_int = 10_000;

/// [`stage_registry_in`] for the output cleanup.
#[cfg(test)]
pub(crate) fn stage_registry(
    db_path: &Path,
    control: &StageControl<'_>,
) -> anyhow::Result<StageOutcome> {
    stage_registry_in(db_path, control, CleanupMode::Output)
}

/// Phase A for the registry at `db_path` (owned by the running process) and
/// the cleanup of `mode`; the owner asks for [`CleanupMode::Compact`] only
/// with the opt-in (`journal_compact.rs`). Whatever fails once the owner is
/// stopping (a read the stop cut short) is a stop: the staged work so far
/// stays and the next start resumes it.
pub(crate) fn stage_registry_in(
    db_path: &Path,
    control: &StageControl<'_>,
    mode: CleanupMode,
) -> anyhow::Result<StageOutcome> {
    match stage_registry_until_stopped(db_path, control, mode) {
        Err(_) if (control.stopped)() => Ok(StageOutcome::Stopped),
        outcome => outcome,
    }
}

/// Every read on `source` checks `stopped` as it runs and fails once it is
/// true (SQLite's progress handler interrupts the statement).
fn stop_reads_on(
    source: &Connection,
    stopped: std::sync::Arc<dyn Fn() -> bool + Send + Sync>,
) -> rusqlite::Result<()> {
    source.progress_handler(STOP_CHECK_STEPS, Some(move || stopped()))
}

fn stage_registry_until_stopped(
    db_path: &Path,
    control: &StageControl<'_>,
    mode: CleanupMode,
) -> anyhow::Result<StageOutcome> {
    let source = open_registry_database_read_only(db_path)
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
    source.busy_timeout(Duration::from_secs(5))?;
    stop_reads_on(&source, control.stopped.clone())?;
    // The memo is of one registry: another one at this path (restored,
    // rehomed) is not covered by it.
    let identity = meta_value(&source, "registry_id")?;
    match mode {
        CleanupMode::Output => {
            if let Some(reason) = refusal_memo(db_path, identity.as_deref(), journal_head(&source)?)
            {
                return Ok(StageOutcome::Skipped(reason));
            }
            if !output_present(&source)? && !session_puts_present(&source)? {
                return Ok(StageOutcome::NotNeeded);
            }
        }
        // The opt-in is explicit: a refusal memo of the output cleanup does
        // not cover it, and every journal with a record is rewritten.
        CleanupMode::Compact => {
            if journal_head(&source)? == 0 {
                return Ok(StageOutcome::NotNeeded);
            }
        }
    }
    // A mixed segment counts as output here (the staged count checks it as
    // it goes), but every record counts toward the journal's size.
    let sealed = sealed_records(&source, 0)?;
    // Before the live puts are read, none counts as kept: the staged counts
    // check the real number as staging goes.
    let (live_kept, live_total) = live_records_within(&source, None, max_kept_records(mode))?;
    if let Some(reason) =
        kept_refusal_in(mode, sealed.kept_at_least + live_kept, sealed.total + live_total)
    {
        remove_staging(db_path)?;
        return Ok(StageOutcome::Skipped(reason));
    }
    (control.on_pending)();
    let copied = copied_bytes(&source)?;
    if let Err(reason) = free_space_refusal(db_path, copied)? {
        return Ok(StageOutcome::Refused(reason));
    }
    let source_bytes = journal_compact::source_bytes(&source, db_path)?;
    if mode == CleanupMode::Compact
        && !staging_path(db_path).is_file()
        && let Err(reason) = journal_compact::free_space_refusal(db_path, source_bytes)?
    {
        return Ok(StageOutcome::Refused(reason));
    }
    let registry_id = required_meta(&source, "registry_id")?;
    let staging = open_staging_in(db_path, &registry_id, mode, source_bytes)?;
    if mode == CleanupMode::Output {
        // Before any segment is staged: the latest live put of each session.
        // A compaction reads none, so it drops no put.
        record_live_puts(&source, &staging)?;
    }
    let build_control = BuildControl { next_step: control.next_segment, space: (db_path, copied) };
    // Each pass stages what was sealed since the last one (a restart: the
    // owner sealed while the live rows were staged) or ends; a stop ends it.
    let abandoned = loop {
        if state(&staging, "complete")? != "1" {
            match stage_sealed(db_path, &source, &staging, control.next_segment, copied)? {
                Staged::Finished => {}
                Staged::Stopped => return Ok(StageOutcome::Stopped),
                Staged::Refused(reason) => return Ok(StageOutcome::Refused(reason)),
                Staged::Abandoned(reason) => break Some(reason),
            }
        }
        match build(&source, &staging, &build_control)? {
            Build::Built => break None,
            Build::Restart => {}
            Build::Stopped => return Ok(StageOutcome::Stopped),
            Build::Refused(reason) => return Ok(StageOutcome::Refused(reason)),
            Build::Abandoned(reason) => break Some(reason),
        }
    };
    if let Some(reason) = abandoned {
        drop(staging);
        remove_staging(db_path)?;
        if mode == CleanupMode::Output {
            write_refusal_memo(db_path, &registry_id, journal_head(&source)?, &reason);
        }
        return Ok(StageOutcome::Skipped(reason));
    }
    // Until the owner stops: the records it appends go into the built
    // journal, so the swap at the next start finishes a short tail.
    loop {
        match catch_up(&source, &staging, &build_control)? {
            CaughtUp::Current => {}
            CaughtUp::Stopped => break,
            CaughtUp::Abandoned(reason) => {
                drop(staging);
                remove_staging(db_path)?;
                if mode == CleanupMode::Output {
                    write_refusal_memo(db_path, &registry_id, journal_head(&source)?, &reason);
                }
                return Ok(StageOutcome::Skipped(reason));
            }
        }
        if !(control.catch_up)() {
            break;
        }
    }
    Ok(StageOutcome::Built)
}

/// Phase A: stages the sealed segments after the cursor, checks the bounds,
/// and counts the live rows.
fn stage_sealed(
    db_path: &Path,
    source: &Connection,
    staging: &Connection,
    next_segment: &dyn Fn() -> bool,
    copied: u64,
) -> anyhow::Result<Staged> {
    let started = Instant::now();
    let staged_through = state_u64(staging, "staged_through")?;
    if staged_through > 0 {
        eprintln!(
            "cmux-tui: output cleanup: resuming after sequence {staged_through} ({} segments staged)",
            state_u64(staging, "staged_segments")?
        );
    } else {
        eprintln!("cmux-tui: output cleanup: staging {}", staging_path(db_path).display());
    }
    // The live rows are counted after the last staged segment only: a
    // segment the owner seals between the staging pass and the count is
    // staged first, then the rows are counted again.
    let mut sealed_since: Option<u64> = None;
    loop {
        match stage_segments(source, staging, next_segment, Some((db_path, copied)))? {
            Staged::Finished => {}
            other => return Ok(other),
        }
        if let Some(end) = sealed_since {
            anyhow::ensure!(
                state_u64(staging, "staged_through")? >= end,
                "the journal segments through sequence {end} were not staged"
            );
        }
        // Every sealed segment is staged: the held puts are the latest ones.
        // A later pass (segments sealed since) holds none: their puts were
        // live when the latest puts were read.
        release_held_puts(staging)?;
        let mode = CleanupMode::of(staging)?;
        let (staged_kept, staged_total) = staged_records(staging)?;
        let (live_kept, live_total) = live_records_within(
            source,
            Some(&SessionPuts::load(staging)?),
            max_kept_records(mode),
        )?;
        if let Some(reason) = staged_bytes_refusal(staging)?
            .or_else(|| kept_refusal_in(mode, staged_kept + live_kept, staged_total + live_total))
        {
            return Ok(Staged::Abandoned(reason));
        }
        #[cfg(test)]
        if let Some(seal) = BEFORE_LIVE_COUNT.with(|hook| hook.borrow_mut().take()) {
            seal();
        }
        match count_live_rows(source, staging)? {
            LiveCount::Counted => break,
            LiveCount::Sealed(end) => {
                eprintln!(
                    "cmux-tui: output cleanup: segments through sequence {end} were sealed after \
                     the staging pass; staging them before the live rows are counted"
                );
                sealed_since = Some(end);
            }
        }
    }
    set_state(staging, "complete", "1")?;
    eprintln!(
        "cmux-tui: output cleanup: phase A complete in {:.2} s: {} segments staged, {} records \
         kept; building the new registry next ({})",
        started.elapsed().as_secs_f64(),
        state_u64(staging, "staged_segments")?,
        kept_records(staging)?,
        staging_path(db_path).display()
    );
    Ok(Staged::Finished)
}

/// Live `terminal.output` rows (one index seek) or a sealed segment that
/// holds or may hold output (the segment kind map, a few thousand rows). A
/// legacy kind backfill that started and never finished (its meta marker is
/// not `1`) may have left a mixed segment mapped without its output kind, so
/// the map proves nothing and the segments are staged and decoded.
pub(super) fn output_present(source: &Connection) -> anyhow::Result<bool> {
    Ok(source.query_row(
        "SELECT EXISTS(
                  SELECT 1 FROM meta
                  WHERE key = 'journal_segment_kinds_backfill' AND value != '1')
             OR EXISTS(
                  SELECT 1 FROM session_journal INDEXED BY session_journal_by_kind_sequence
                  WHERE kind = 'terminal.output')
             OR EXISTS(SELECT 1 FROM journal_segment_kinds WHERE kind = 'terminal.output')
             OR EXISTS(
                  SELECT 1 FROM journal_segments AS segment
                  WHERE NOT EXISTS (
                    SELECT 1 FROM journal_segment_kinds AS kinds
                    WHERE kinds.segment_id = segment.segment_id))",
        [],
        |row| row.get(0),
    )?)
}

/// At least [`PUT_RECORDS_WORTH_A_CLEANUP`] session put records, counted
/// from the `(kind, sequence)` index (stopping at the bound) and the
/// segment kind map (every record of a segment that lists the kind).
pub(super) fn session_puts_present(source: &Connection) -> anyhow::Result<bool> {
    let limit = put_records_worth_a_cleanup();
    let (live, sealed): (i64, i64) = source.query_row(
        "SELECT (SELECT COUNT(*) FROM (
                   SELECT 1 FROM session_journal INDEXED BY session_journal_by_kind_sequence
                   WHERE kind = ?1 LIMIT ?2)),
                (SELECT COALESCE(SUM(segment.record_count), 0) FROM journal_segments AS segment
                 WHERE EXISTS (SELECT 1 FROM journal_segment_kinds AS kinds
                               WHERE kinds.segment_id = segment.segment_id AND kinds.kind = ?1))",
        params![SESSION_PUT_KIND, i64::try_from(limit)?],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok(u64::try_from(live)?.saturating_add(u64::try_from(sealed)?) >= limit)
}

/// The journal's last sequence, live or sealed (two index seeks).
fn journal_head(source: &Connection) -> anyhow::Result<u64> {
    let head: i64 = source.query_row(
        "SELECT MAX(COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
                    COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0))",
        [],
        |row| row.get(0),
    )?;
    Ok(u64::try_from(head)?)
}

/// Records that staging of registry `registry_id` finished and was refused
/// at journal head `head`, so later starts do not stage the same journal
/// again (each would copy it all and be refused the same way). Best effort:
/// without the memo the next start stages again.
fn write_refusal_memo(db_path: &Path, registry_id: &str, head: u64, reason: &str) {
    let memo = format!("format {STAGING_FORMAT}\nregistry {registry_id}\nhead {head}\n{reason}\n");
    if let Err(error) = std::fs::write(refused_path(db_path), memo) {
        eprintln!("cmux-tui: output cleanup: could not record the refusal: {error}");
    }
}

/// `Some(reason)` while a refusal memo covers this journal: same staging
/// format, the same registry (`registry_id`; a memo of another registry, or
/// one written before memos named it, covers nothing), and the journal head
/// below twice the head it was refused at. A memo past that (or unreadable)
/// is removed and the cleanup runs again.
fn refusal_memo(db_path: &Path, registry_id: Option<&str>, head: u64) -> Option<String> {
    let path = refused_path(db_path);
    let text = std::fs::read_to_string(&path).ok()?;
    let mut lines = text.lines();
    let format = lines.next().and_then(|line| line.strip_prefix("format "));
    let registry = lines.next().and_then(|line| line.strip_prefix("registry "));
    let refused_at = lines
        .next()
        .and_then(|line| line.strip_prefix("head "))
        .and_then(|n| n.parse::<u64>().ok());
    let reason = lines.next().unwrap_or_default();
    if let Some(refused_at) = refused_at
        && format == Some(STAGING_FORMAT)
        && registry.is_some()
        && registry == registry_id
        && head < refused_at.saturating_mul(2)
    {
        return Some(format!(
            "staging was refused at journal head {refused_at} ({reason}); it runs again once \
             the journal reaches {}",
            refused_at.saturating_mul(2)
        ));
    }
    if let Err(error) = remove_if_present(&path) {
        eprintln!("cmux-tui: output cleanup: could not remove {}: {error:#}", path.display());
    }
    None
}

/// The records of the sealed segments after sequence `after`, from their
/// kind map alone (a row of each segment, never its content).
pub(super) struct SealedRecords {
    /// Records of segments without output or session puts: kept for certain
    /// (superseded puts are dropped, and the map does not say how many).
    pub(super) kept_at_least: u64,
    /// Records of every segment that is not output only (mixed and unmapped
    /// segments too): at most this many are kept.
    pub(super) kept_at_most: u64,
    /// Records of every segment.
    pub(super) total: u64,
}

pub(super) fn sealed_records(source: &Connection, after: u64) -> anyhow::Result<SealedRecords> {
    let (at_least, at_most, total): (i64, i64, i64) = source.query_row(
        "SELECT COALESCE(SUM(CASE WHEN has_other AND NOT has_output AND NOT has_put
                                  THEN record_count END), 0),
                COALESCE(SUM(CASE WHEN has_other OR NOT has_output THEN record_count END), 0),
                COALESCE(SUM(record_count), 0)
         FROM (
           SELECT segment.record_count,
                  EXISTS(SELECT 1 FROM journal_segment_kinds AS kinds
                         WHERE kinds.segment_id = segment.segment_id AND kinds.kind = ?1)
                    AS has_output,
                  EXISTS(SELECT 1 FROM journal_segment_kinds AS kinds
                         WHERE kinds.segment_id = segment.segment_id AND kinds.kind = ?3)
                    AS has_put,
                  EXISTS(SELECT 1 FROM journal_segment_kinds AS kinds
                         WHERE kinds.segment_id = segment.segment_id AND kinds.kind != ?1)
                    AS has_other
           FROM journal_segments AS segment
           WHERE segment.start_sequence > ?2)",
        params![OUTPUT_KIND, i64::try_from(after)?, SESSION_PUT_KIND],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    Ok(SealedRecords {
        kept_at_least: u64::try_from(at_least)?,
        kept_at_most: u64::try_from(at_most)?,
        total: u64::try_from(total)?,
    })
}

/// (kept, all) records of the segments staged so far: one row per segment.
pub(super) fn staged_records(staging: &Connection) -> anyhow::Result<(u64, u64)> {
    let (kept, total): (i64, i64) = staging.query_row(
        "SELECT COALESCE(SUM(kept), 0), COALESCE(SUM(record_count), 0)
         FROM output_cleanup_segments",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok((u64::try_from(kept)?, u64::try_from(total)?))
}

/// The output cleanup's staging file of `db_path` ([`open_staging_in`]).
#[cfg(test)]
pub(super) fn open_staging(db_path: &Path, registry_id: &str) -> anyhow::Result<Connection> {
    open_staging_in(db_path, registry_id, CleanupMode::Output, 0)
}

/// The staging file of `db_path` for registry `registry_id` and the cleanup
/// of `mode`: the existing one when it belongs to that registry, this format
/// and that mode, else a new one. `source_bytes` (the registry's size) sets
/// a new compaction file's size bound.
pub(super) fn open_staging_in(
    db_path: &Path,
    registry_id: &str,
    mode: CleanupMode,
    source_bytes: u64,
) -> anyhow::Result<Connection> {
    let path = staging_path(db_path);
    if path.is_file() {
        match open_existing_staging(&path, registry_id) {
            Ok(Some(connection)) if CleanupMode::of(&connection)? != mode => {
                eprintln!(
                    "cmux-tui: output cleanup: discarding a staging file of another cleanup mode"
                );
            }
            Ok(Some(connection)) => {
                // A swap attempt of an earlier start left it in rollback
                // journal mode; the background build writes beside readers.
                connection.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
                ensure_build_state(&connection)?;
                return Ok(connection);
            }
            Ok(None) => eprintln!("cmux-tui: output cleanup: discarding a stale staging file"),
            Err(error) => {
                eprintln!(
                    "cmux-tui: output cleanup: discarding an unreadable staging file: {error:#}"
                );
            }
        }
        remove_staging(db_path)?;
    }
    let connection = open_registry_database(&path)
        .with_context(|| format!("create output cleanup staging file {}", path.display()))?;
    platform::restrict_file(&path)?;
    connection.execute_batch(
        "PRAGMA auto_vacuum=INCREMENTAL;
         PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         CREATE TABLE output_cleanup_state (
           key TEXT PRIMARY KEY NOT NULL,
           value TEXT NOT NULL
         );
         CREATE TABLE output_cleanup_segments (
           start_sequence INTEGER PRIMARY KEY,
           end_sequence INTEGER NOT NULL,
           record_count INTEGER NOT NULL,
           kept INTEGER NOT NULL,
           removed INTEGER NOT NULL,
           CHECK(kept + removed = record_count),
           CHECK(record_count = end_sequence - start_sequence + 1)
         );",
    )?;
    connection.execute_batch(CHUNK_SCHEMA)?;
    connection.execute_batch(SESSION_PUTS_SCHEMA)?;
    let staged_limit = journal_compact::staged_limit(source_bytes).to_string();
    if mode == CleanupMode::Compact {
        connection.execute_batch(STATED_FOLD_SCHEMA)?;
    }
    let tx = connection.unchecked_transaction()?;
    if mode == CleanupMode::Compact {
        for (key, value) in journal_compact::COMPACT_STATE {
            let value = if key == "compact_staged_limit" { staged_limit.as_str() } else { value };
            tx.execute(
                "INSERT INTO output_cleanup_state(key, value) VALUES(?1, ?2)",
                [key, value],
            )?;
        }
    }
    for (key, value) in SESSION_PUTS_STATE.into_iter().chain([
        ("format", STAGING_FORMAT),
        ("mode", mode.state_value()),
        ("registry_id", registry_id),
        ("staged_through", "0"),
        ("staged_segments", "0"),
        ("last_segment_id", ""),
        ("complete", "0"),
        ("live_archive_end", "0"),
        ("live_head", "0"),
        ("live_output", "0"),
    ]) {
        tx.execute("INSERT INTO output_cleanup_state(key, value) VALUES(?1, ?2)", [key, value])?;
    }
    tx.commit()?;
    ensure_build_state(&connection)?;
    Ok(connection)
}

pub(super) fn open_existing_staging(
    path: &Path,
    registry_id: &str,
) -> anyhow::Result<Option<Connection>> {
    let connection = open_registry_database_with_flags(
        path,
        OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
    )?;
    connection.execute_batch("PRAGMA synchronous=NORMAL;")?;
    let valid = connection
        .query_row(
            "SELECT (SELECT value FROM output_cleanup_state WHERE key = 'format') = ?1
                AND (SELECT value FROM output_cleanup_state WHERE key = 'registry_id') = ?2",
            params![STAGING_FORMAT, registry_id],
            |row| row.get::<_, Option<bool>>(0),
        )
        .optional()?
        .flatten()
        .unwrap_or(false);
    Ok(valid.then_some(connection))
}

pub(super) fn state(staging: &Connection, key: &str) -> anyhow::Result<String> {
    staging
        .query_row("SELECT value FROM output_cleanup_state WHERE key = ?1", [key], |row| row.get(0))
        .with_context(|| format!("output cleanup staging state {key}"))
}

pub(super) fn state_u64(staging: &Connection, key: &str) -> anyhow::Result<u64> {
    state(staging, key)?.parse().with_context(|| format!("output cleanup staging state {key}"))
}

fn kept_records(staging: &Connection) -> anyhow::Result<u64> {
    let count: i64 =
        staging.query_row("SELECT COUNT(*) FROM output_cleanup_records", [], |row| row.get(0))?;
    Ok(u64::try_from(count)?)
}

pub(super) enum Staged {
    Finished,
    Stopped,
    Refused(String),
    /// The staged work passed a bound (`output_cleanup` module docs).
    Abandoned(String),
}

/// Stages every sealed segment of `source` after the staging cursor. With
/// `space_check`, free space beside that registry and the staged work's
/// bounds are checked as it goes.
pub(super) fn stage_segments(
    source: &Connection,
    staging: &Connection,
    next_segment: &dyn Fn() -> bool,
    space_check: Option<(&Path, u64)>,
) -> anyhow::Result<Staged> {
    let total: i64 =
        source.query_row("SELECT COUNT(*) FROM journal_segments", [], |row| row.get(0))?;
    let mut puts = SessionPuts::load(staging)?;
    let mut since_space_check = 0_u64;
    let mut last_log = Instant::now();
    loop {
        if !next_segment() {
            return Ok(Staged::Stopped);
        }
        let staged_through = state_u64(staging, "staged_through")?;
        let Some((segment_id, start, end, record_count)) = source
            .query_row(
                "SELECT segment_id, start_sequence, end_sequence, record_count
                 FROM journal_segments
                 WHERE start_sequence > ?1
                 ORDER BY start_sequence ASC
                 LIMIT 1",
                [i64::try_from(staged_through)?],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .optional()?
        else {
            return Ok(Staged::Finished);
        };
        let (start, end) = (u64::try_from(start)?, u64::try_from(end)?);
        anyhow::ensure!(
            staged_through == 0 || start == staged_through + 1,
            "journal segments contain a gap before sequence {start}"
        );
        let mode = CleanupMode::of(staging)?;
        let kept = kept_segment_records(source, &segment_id, start, end, record_count, mode)?;
        // A sequence an earlier cleanup pruned counts as removed: the
        // segment's records are its whole sequence range.
        let record_count = i64::try_from(end - start + 1)?;
        let split = puts.split_segment(kept, start);
        let kept_count = i64::try_from(split.staged.len())? + i64::try_from(split.held)?;
        let tx = staging.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO output_cleanup_segments(
               start_sequence, end_sequence, record_count, kept, removed)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                i64::try_from(start)?,
                i64::try_from(end)?,
                record_count,
                kept_count,
                record_count - kept_count
            ],
        )?;
        insert_chunk(&tx, &split.staged)?;
        puts.record_split(&tx, &split)?;
        tx.execute(
            "UPDATE output_cleanup_state SET value = ?1 WHERE key = 'staged_through'",
            [end.to_string()],
        )?;
        tx.execute(
            "UPDATE output_cleanup_state SET value = CAST(value AS INTEGER) + 1
             WHERE key = 'staged_segments'",
            [],
        )?;
        tx.execute(
            "UPDATE output_cleanup_state SET value = ?1 WHERE key = 'last_segment_id'",
            [&segment_id],
        )?;
        tx.commit()?;
        since_space_check += 1;
        if let Some((db_path, copied)) = space_check
            && since_space_check >= SEGMENTS_PER_SPACE_CHECK
        {
            since_space_check = 0;
            if let Err(reason) = free_space_refusal(db_path, copied)? {
                return Ok(Staged::Refused(reason));
            }
            let (kept, _) = staged_records(staging)?;
            let max_kept = max_kept_records(CleanupMode::of(staging)?);
            if let Some(reason) = staged_bytes_refusal(staging)?.or_else(|| {
                (kept > max_kept)
                    .then(|| format!("{kept} records staged, over the bound of {max_kept}"))
            }) {
                return Ok(Staged::Abandoned(reason));
            }
        }
        if last_log.elapsed() >= progress_log_interval() {
            last_log = Instant::now();
            eprintln!(
                "cmux-tui: output cleanup: staged {} of {total} segments, {} records kept",
                state_u64(staging, "staged_segments")?,
                kept_records(staging)?
            );
        }
        std::thread::yield_now();
    }
}

#[cfg(test)]
thread_local! {
    /// Runs once between Phase A's staging pass and its live row count: a
    /// test seals a segment there, as the owner can.
    pub(super) static BEFORE_LIVE_COUNT: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

#[derive(Debug)]
enum LiveCount {
    Counted,
    /// The sealed journal ends past the staged segments, at this sequence:
    /// nothing was recorded.
    Sealed(u64),
}

/// Counts the live rows after the sealed segments in one read snapshot, in
/// the background: that they are contiguous (the count equals the range) and
/// how many are output. The swap then checks kept plus removed against these
/// numbers and counts only rows that came later. The snapshot's sealed
/// journal must end where the staged segments do, or the live step would
/// skip the records of a segment no one staged.
fn count_live_rows(source: &Connection, staging: &Connection) -> anyhow::Result<LiveCount> {
    let staged_through = i64::try_from(state_u64(staging, "staged_through")?)?;
    source.execute_batch("BEGIN DEFERRED")?;
    let counted = (|| -> anyhow::Result<Result<(i64, i64, i64), i64>> {
        let archive_end: i64 = source.query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get(0),
        )?;
        if archive_end != staged_through {
            anyhow::ensure!(
                archive_end > staged_through,
                "{STAGED_WORK_CHANGED}: the sealed journal ends at sequence {archive_end}, \
                 before the staged segments"
            );
            return Ok(Err(archive_end));
        }
        let head: i64 = source.query_row(
            "SELECT COALESCE(MAX(sequence), ?1) FROM session_journal",
            [archive_end],
            |row| row.get(0),
        )?;
        // The (kind, sequence) index is a fraction of the table's pages.
        let total: i64 = source.query_row(
            "SELECT COUNT(*) FROM session_journal INDEXED BY session_journal_by_kind_sequence
             WHERE sequence > ?1 AND sequence <= ?2",
            [archive_end, head],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            total == head - archive_end,
            "the live journal rows after sequence {archive_end} are not contiguous"
        );
        let output: i64 = source.query_row(
            "SELECT COUNT(*) FROM session_journal INDEXED BY session_journal_by_kind_sequence
             WHERE kind = ?3 AND sequence > ?1 AND sequence <= ?2",
            params![archive_end, head, OUTPUT_KIND],
            |row| row.get(0),
        )?;
        Ok(Ok((archive_end, head, output)))
    })();
    source.execute_batch("COMMIT")?;
    let (archive_end, head, output) = match counted? {
        Ok(counted) => counted,
        Err(sealed_end) => return Ok(LiveCount::Sealed(u64::try_from(sealed_end)?)),
    };
    let tx = staging.unchecked_transaction()?;
    for (key, value) in
        [("live_archive_end", archive_end), ("live_head", head), ("live_output", output)]
    {
        tx.execute(
            "UPDATE output_cleanup_state SET value = ?1 WHERE key = ?2",
            params![value.to_string(), key],
        )?;
    }
    tx.commit()?;
    Ok(LiveCount::Counted)
}

/// The non-output records of one sealed segment with their stored actors.
/// Every segment is inflated: its kind map is not proof that it holds only
/// output, since a legacy kind backfill killed partway leaves a mixed
/// segment with only some of its kinds, and records dropped here are gone.
fn kept_segment_records(
    source: &Connection,
    segment_id: &str,
    start: u64,
    end: u64,
    record_count: i64,
    mode: CleanupMode,
) -> anyhow::Result<Vec<StagedRecord>> {
    let gaps = match mode {
        CleanupMode::Output => SegmentGaps::Damage,
        CleanupMode::Compact => SegmentGaps::Pruned,
    };
    Ok(inflated_segment_records(source, segment_id, start, end, record_count, gaps)?
        .into_iter()
        .filter(|record| record.1 != OUTPUT_KIND)
        .collect())
}

/// What a missing sequence inside a sealed segment is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SegmentGaps {
    /// Damage: the segment was sealed before any cleanup, so it is whole.
    Damage,
    /// The records an earlier cleanup removed, where one row of the
    /// source's `journal_pruned_ranges` covers the gap; damage otherwise.
    /// The journal compaction reads a registry that already had a cleanup.
    Pruned,
}

/// Every record of one sealed segment, output included, with its actor.
pub(super) fn inflated_segment_records(
    source: &Connection,
    segment_id: &str,
    start: u64,
    end: u64,
    record_count: i64,
    gaps: SegmentGaps,
) -> anyhow::Result<Vec<StagedRecord>> {
    let (codec, content, uncompressed_bytes, sha256, actors_json) = source.query_row(
        "SELECT codec, content, uncompressed_bytes, sha256, actors_json
         FROM journal_segments WHERE segment_id = ?1",
        [segment_id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        },
    )?;
    let json = inflate_segment(segment_id, &codec, &content, uncompressed_bytes, &sha256)?;
    drop(content);
    let records = split_records(&json)?;
    anyhow::ensure!(
        i64::try_from(records.len())? == record_count,
        "journal segment {segment_id} record count is invalid"
    );
    // A segment sealed before any cleanup is whole: a gap here is damage,
    // which must not turn into a pruned range. A segment a cleanup packed
    // has gaps, each one a pruned range of the source.
    let pruned = |after: u64, next: u64| -> anyhow::Result<bool> {
        Ok(gaps == SegmentGaps::Pruned && pruned_gap(source, after, next)?)
    };
    let mut previous = start.saturating_sub(1);
    for record in &records {
        anyhow::ensure!(
            record.sequence > previous
                && record.sequence <= end
                && (record.sequence == previous + 1 || pruned(previous, record.sequence)?),
            "journal segment {segment_id} contains a sequence gap"
        );
        previous = record.sequence;
    }
    anyhow::ensure!(
        previous == end || (previous < end && pruned(previous, end + 1)?),
        "journal segment {segment_id} sequence range is invalid"
    );
    let mut actors: BTreeMap<String, String> = match actors_json {
        Some(json) => serde_json::from_str(&json)
            .with_context(|| format!("journal segment {segment_id} actors are invalid"))?,
        None => BTreeMap::new(),
    };
    records
        .into_iter()
        .map(|record| {
            let actor = actors.remove(&record.sequence.to_string());
            let bytes = json.get(record.bytes).with_context(|| {
                format!("journal segment {segment_id} record {} is out of range", record.sequence)
            })?;
            Ok((record.sequence, record.kind, bytes.to_vec(), actor))
        })
        .collect()
}

#[cfg(test)]
#[path = "stage_tests.rs"]
mod tests;
