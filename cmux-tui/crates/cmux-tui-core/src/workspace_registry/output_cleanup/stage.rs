//! Phase A: copy the non-output records of the sealed segments into the
//! staging file while the owner serves. Sealed segments never change, so a
//! read-only connection can read them beside the owner. Each segment is one
//! staging transaction together with the cursor that names it, so a quit or
//! a kill resumes at the next segment and never stages a record twice.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use super::super::{
    open_registry_database, open_registry_database_read_only, open_registry_database_with_flags,
    required_meta,
};
use super::codec::{inflate_segment, split_records};
use super::{OUTPUT_KIND, copied_bytes, free_space_refusal, remove_staging, staging_path};
use crate::platform;

const STAGING_FORMAT: &str = "2";
/// Free space is checked again after this many staged segments.
const SEGMENTS_PER_SPACE_CHECK: u64 = 256;
const PROGRESS_LOG_INTERVAL: Duration = Duration::from_secs(10);

fn progress_log_interval() -> Duration {
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
    /// No stored terminal output: nothing to clean up.
    NotNeeded,
    /// Every sealed segment is staged; the next owner start swaps.
    Complete { segments: u64, kept: u64 },
    /// Not enough free space; the staged work so far stays.
    Refused(String),
    /// The owner is stopping; the staged work so far stays.
    Stopped,
}

pub(crate) struct StageControl<'a> {
    /// Called once the registry is known to need a cleanup, before staging.
    pub(crate) on_pending: &'a dyn Fn(),
    /// Called before each segment; `false` stops staging.
    pub(crate) next_segment: &'a dyn Fn() -> bool,
    /// Whether the owner is stopping. Also read while a read of the registry
    /// runs, so a stop cuts a long scan (the live row counts) short instead
    /// of holding the owner's shutdown until it ends.
    pub(crate) stopped: std::sync::Arc<dyn Fn() -> bool + Send + Sync>,
}

/// SQLite virtual machine steps between two stop checks during a read.
const STOP_CHECK_STEPS: std::ffi::c_int = 10_000;

/// Phase A for the registry at `db_path` (owned by the running process).
/// Whatever fails once the owner is stopping (a read the stop cut short) is
/// a stop: the staged work so far stays and the next start resumes it.
pub(crate) fn stage_registry(
    db_path: &Path,
    control: &StageControl<'_>,
) -> anyhow::Result<StageOutcome> {
    match stage_registry_until_stopped(db_path, control) {
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
) -> anyhow::Result<StageOutcome> {
    let source = open_registry_database_read_only(db_path)
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
    source.busy_timeout(Duration::from_secs(5))?;
    stop_reads_on(&source, control.stopped.clone())?;
    if !output_present(&source)? {
        return Ok(StageOutcome::NotNeeded);
    }
    (control.on_pending)();
    let copied = copied_bytes(&source)?;
    if let Err(reason) = free_space_refusal(db_path, copied)? {
        return Ok(StageOutcome::Refused(reason));
    }
    let registry_id = required_meta(&source, "registry_id")?;
    let staging = open_staging(db_path, &registry_id)?;
    if state(&staging, "complete")? == "1" {
        return Ok(StageOutcome::Complete {
            segments: state_u64(&staging, "staged_segments")?,
            kept: kept_records(&staging)?,
        });
    }
    let staged_through = state_u64(&staging, "staged_through")?;
    if staged_through > 0 {
        eprintln!(
            "cmux-tui: output cleanup: resuming after sequence {staged_through} ({} segments staged)",
            state_u64(&staging, "staged_segments")?
        );
    } else {
        eprintln!("cmux-tui: output cleanup: staging {}", staging_path(db_path).display());
    }
    match stage_segments(&source, &staging, control.next_segment, Some((db_path, copied)))? {
        Staged::Stopped => return Ok(StageOutcome::Stopped),
        Staged::Refused(reason) => return Ok(StageOutcome::Refused(reason)),
        Staged::Finished => {}
    }
    count_live_rows(&source, &staging)?;
    staging.execute("UPDATE output_cleanup_state SET value = '1' WHERE key = 'complete'", [])?;
    Ok(StageOutcome::Complete {
        segments: state_u64(&staging, "staged_segments")?,
        kept: kept_records(&staging)?,
    })
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

/// The staging file of `db_path` for registry `registry_id`: the existing
/// one when it belongs to that registry and this format, else a new one.
pub(super) fn open_staging(db_path: &Path, registry_id: &str) -> anyhow::Result<Connection> {
    let path = staging_path(db_path);
    if path.is_file() {
        match open_existing_staging(&path, registry_id) {
            Ok(Some(connection)) => return Ok(connection),
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
         CREATE TABLE output_cleanup_records (
           sequence INTEGER PRIMARY KEY CHECK(sequence > 0),
           kind TEXT NOT NULL,
           record_json BLOB NOT NULL,
           actor TEXT
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
    let tx = connection.unchecked_transaction()?;
    for (key, value) in [
        ("format", STAGING_FORMAT),
        ("registry_id", registry_id),
        ("staged_through", "0"),
        ("staged_segments", "0"),
        ("last_segment_id", ""),
        ("complete", "0"),
        ("live_archive_end", "0"),
        ("live_head", "0"),
        ("live_output", "0"),
    ] {
        tx.execute("INSERT INTO output_cleanup_state(key, value) VALUES(?1, ?2)", [key, value])?;
    }
    tx.commit()?;
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
}

/// Stages every sealed segment of `source` after the staging cursor. With
/// `space_check`, free space beside that registry is checked as it goes.
pub(super) fn stage_segments(
    source: &Connection,
    staging: &Connection,
    next_segment: &dyn Fn() -> bool,
    space_check: Option<(&Path, u64)>,
) -> anyhow::Result<Staged> {
    let total: i64 =
        source.query_row("SELECT COUNT(*) FROM journal_segments", [], |row| row.get(0))?;
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
        let kept = kept_segment_records(source, &segment_id, start, end, record_count)?;
        let tx = staging.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO output_cleanup_segments(
               start_sequence, end_sequence, record_count, kept, removed)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                i64::try_from(start)?,
                i64::try_from(end)?,
                record_count,
                i64::try_from(kept.len())?,
                record_count - i64::try_from(kept.len())?
            ],
        )?;
        for record in &kept {
            tx.execute(
                "INSERT INTO output_cleanup_records(sequence, kind, record_json, actor)
                 VALUES(?1, ?2, ?3, ?4)",
                params![i64::try_from(record.0)?, record.1, record.2, record.3],
            )?;
        }
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

/// Counts the live rows after the sealed segments in one read snapshot, in
/// the background: that they are contiguous (the count equals the range) and
/// how many are output. The swap then checks kept plus removed against these
/// numbers and counts only rows that came later.
fn count_live_rows(source: &Connection, staging: &Connection) -> anyhow::Result<()> {
    source.execute_batch("BEGIN DEFERRED")?;
    let counted = (|| -> anyhow::Result<(i64, i64, i64)> {
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
        Ok((archive_end, head, output))
    })();
    source.execute_batch("COMMIT")?;
    let (archive_end, head, output) = counted?;
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
    Ok(())
}

type KeptRecord = (u64, String, Vec<u8>, Option<String>);

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
) -> anyhow::Result<Vec<KeptRecord>> {
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
    // which must not turn into a pruned range.
    for (offset, record) in records.iter().enumerate() {
        anyhow::ensure!(
            record.sequence == start + offset as u64 && record.sequence <= end,
            "journal segment {segment_id} contains a sequence gap"
        );
    }
    anyhow::ensure!(
        records.last().is_some_and(|record| record.sequence == end),
        "journal segment {segment_id} sequence range is invalid"
    );
    let mut actors: BTreeMap<String, String> = match actors_json {
        Some(json) => serde_json::from_str(&json)
            .with_context(|| format!("journal segment {segment_id} actors are invalid"))?,
        None => BTreeMap::new(),
    };
    records
        .into_iter()
        .filter(|record| record.kind != OUTPUT_KIND)
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
