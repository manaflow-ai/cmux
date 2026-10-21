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
use super::{OUTPUT_KIND, free_space_refusal, remove_staging, staging_path};
use crate::platform;

const STAGING_FORMAT: &str = "1";
/// Free space is checked again after this many staged segments.
const SEGMENTS_PER_SPACE_CHECK: u64 = 256;
const PROGRESS_LOG_INTERVAL: Duration = Duration::from_secs(10);

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
}

/// Phase A for the registry at `db_path` (owned by the running process).
pub(crate) fn stage_registry(
    db_path: &Path,
    control: &StageControl<'_>,
) -> anyhow::Result<StageOutcome> {
    let source = open_registry_database_read_only(db_path)
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
    source.busy_timeout(Duration::from_secs(5))?;
    if !output_present(&source)? {
        return Ok(StageOutcome::NotNeeded);
    }
    (control.on_pending)();
    if let Err(reason) = free_space_refusal(db_path)? {
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
    match stage_segments(&source, &staging, control.next_segment, Some(db_path))? {
        Staged::Stopped => return Ok(StageOutcome::Stopped),
        Staged::Refused(reason) => return Ok(StageOutcome::Refused(reason)),
        Staged::Finished => {}
    }
    staging.execute("UPDATE output_cleanup_state SET value = '1' WHERE key = 'complete'", [])?;
    Ok(StageOutcome::Complete {
        segments: state_u64(&staging, "staged_segments")?,
        kept: kept_records(&staging)?,
    })
}

/// Live `terminal.output` rows (one index seek) or a sealed segment that
/// holds or may hold output (the segment kind map, a few thousand rows).
pub(super) fn output_present(source: &Connection) -> anyhow::Result<bool> {
    Ok(source.query_row(
        "SELECT EXISTS(
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
    space_check: Option<&Path>,
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
        if let Some(db_path) = space_check
            && since_space_check >= SEGMENTS_PER_SPACE_CHECK
        {
            since_space_check = 0;
            if let Err(reason) = free_space_refusal(db_path)? {
                return Ok(Staged::Refused(reason));
            }
        }
        if last_log.elapsed() >= PROGRESS_LOG_INTERVAL {
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

type KeptRecord = (u64, String, Vec<u8>, Option<String>);

/// The non-output records of one sealed segment with their stored actors.
/// A segment whose kind map lists only output is not inflated.
fn kept_segment_records(
    source: &Connection,
    segment_id: &str,
    start: u64,
    end: u64,
    record_count: i64,
) -> anyhow::Result<Vec<KeptRecord>> {
    let (has_kinds, has_other): (bool, bool) = source.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal_segment_kinds WHERE segment_id = ?1),
                EXISTS(SELECT 1 FROM journal_segment_kinds
                       WHERE segment_id = ?1 AND kind != ?2)",
        params![segment_id, OUTPUT_KIND],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if has_kinds && !has_other {
        return Ok(Vec::new());
    }
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
    let mut previous = start.saturating_sub(1);
    for record in &records {
        anyhow::ensure!(
            record.sequence > previous && record.sequence <= end,
            "journal segment {segment_id} sequence range is invalid"
        );
        previous = record.sequence;
    }
    let mut actors: BTreeMap<String, String> = match actors_json {
        Some(json) => serde_json::from_str(&json)
            .with_context(|| format!("journal segment {segment_id} actors are invalid"))?,
        None => BTreeMap::new(),
    };
    Ok(records
        .into_iter()
        .filter(|record| record.kind != OUTPUT_KIND)
        .map(|record| {
            let actor = actors.remove(&record.sequence.to_string());
            (record.sequence, record.kind, json[record.bytes].to_vec(), actor)
        })
        .collect())
}
