//! The background build: once Phase A staged every sealed segment, the owner's
//! cleanup thread builds the new registry's journal in the staging file while
//! the owner serves. Every step is a short staging transaction that records
//! where it got to, so a quit or a kill resumes at that point:
//!
//! - `""`: the bounds of the `output_cleanup` module docs, checked again
//!   (a staging file of an earlier build, segments sealed after Phase A),
//!   then the schema: every table of the registry (empty) and the indexes of
//!   the journal tables the swap rebuilds.
//! - `live`: the non-output live rows up to the head Phase A counted, read
//!   through the `(kind, sequence)` index, a few chunks per transaction.
//! - `pack`: the kept records packed into new sealed segments, one segment per
//!   transaction with its pruned ranges and index rows. A packed segment's
//!   chunks leave the staging file once no later record is in them, so the
//!   file does not hold the records twice; their rows stay (the counts and
//!   the swap's hook deliveries read them).
//! - `check`: the counts, an integrity check and a read back of the packed
//!   journal through the owner's readers.
//! - `built`: the swap may run. While the owner keeps serving, the thread
//!   catches up with the records appended since ([`catch_up`]), so the next
//!   start finishes the swap with a short tail ([`stage_range`],
//!   [`pack_rest`]) instead of building the whole registry.
//!
//! Design from the app-wedge-recover lane (cmuxterm-hq#8246): the build used
//! to run inside `WorkspaceRegistry::open` and held a start for minutes.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Instant;

use anyhow::Context as _;
use rusqlite::{Connection, OptionalExtension as _, params, params_from_iter, types::Value};
use sha2::{Digest, Sha256};

use super::super::journal_extensions::JOURNAL_SEGMENT_RECORD_LIMIT;
use super::super::segment_codec::SEAL_CODEC;
use super::super::session_journal::{
    MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES, decode_record, journal_record_for_archive,
    query_journal_head, query_session_journal_after, stored_record_row, unix_epoch_ms,
};
use super::chunks::{CHUNK_RECORD_LIMIT, ChunkReader, StagedRecord, insert_chunk};
use super::codec::{SegmentWriter, encode_hex};
use super::journal_compact::{Folded, fold_record};
use super::session_puts::{Put, SessionPuts};
use super::stage::{
    SegmentGaps, inflated_segment_records, progress_log_interval, sealed_records, staged_records,
    state, state_u64,
};
use super::stated_fold::{FoldDelta, StatedFold};
use super::{
    CleanupMode, OUTPUT_KIND, PRUNED_RANGES_SCHEMA, REBUILT_TABLES, free_space_refusal,
    kept_refusal_in, live_records_within, max_kept_records, staged_bytes_refusal,
};

pub(super) const STEP_LIVE: &str = "live";
const STEP_PACK: &str = "pack";
const STEP_CHECK: &str = "check";
pub(super) const STEP_BUILT: &str = "built";
/// Live rows staged per transaction.
const LIVE_ROWS_PER_STEP: i64 = 2_048;
/// Payload bytes a live step holds before it stages them: 2,048 rows of
/// 64 KiB would hold 128 MiB.
const LIVE_BYTES_PER_STEP: usize = MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES;
/// Journal records a catch-up reads per transaction.
const CATCH_UP_RECORDS_PER_STEP: u64 = 8_192;
/// Free pages one incremental vacuum step returns to the file system.
const VACUUM_PAGES_PER_STEP: i64 = 4_096;
/// Free space and the staged size are checked again after this many packed
/// segments.
const PACKS_PER_SPACE_CHECK: u64 = 256;

/// Build state kept beside Phase A's in `output_cleanup_state`; a staging
/// file of an earlier build gets them at its first open.
const BUILD_STATE: [(&str, &str); 10] = [
    ("build_step", ""),
    ("schema_digest", ""),
    ("live_kind", ""),
    ("live_sequence", "0"),
    // Live rows in the counted range that the live step dropped although
    // they are not output: the count check adds them to the removed ones.
    ("live_dropped", "0"),
    ("pack_next_start", "0"),
    ("packed_through", "0"),
    ("packed_segments", "0"),
    ("packed_kept", "0"),
    ("built_head", "0"),
];

/// Kept records per new segment: the sealing limit, smaller in tests so a
/// small fixture packs several segments.
pub(super) fn segment_record_limit() -> usize {
    #[cfg(debug_assertions)]
    if let Some(records) = std::env::var("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_RECORDS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|records| *records > 0)
    {
        return records.min(JOURNAL_SEGMENT_RECORD_LIMIT);
    }
    JOURNAL_SEGMENT_RECORD_LIMIT
}

pub(super) fn ensure_build_state(staging: &Connection) -> anyhow::Result<()> {
    let tx = staging.unchecked_transaction()?;
    for (key, value) in BUILD_STATE {
        tx.execute(
            "INSERT OR IGNORE INTO output_cleanup_state(key, value) VALUES(?1, ?2)",
            [key, value],
        )?;
    }
    // A packed segment's chunks go once no later record is in them.
    tx.execute_batch(
        "CREATE INDEX IF NOT EXISTS output_cleanup_records_by_chunk
           ON output_cleanup_records(chunk, sequence)",
    )?;
    tx.commit()?;
    Ok(())
}

pub(super) fn set_state(staging: &Connection, key: &str, value: &str) -> anyhow::Result<()> {
    let changed = staging
        .execute("UPDATE output_cleanup_state SET value = ?1 WHERE key = ?2", [value, key])?;
    anyhow::ensure!(changed == 1, "output cleanup staging state {key} is missing");
    Ok(())
}

pub(super) enum Build {
    Built,
    /// Segments were sealed while the live rows were staged: the live rows
    /// are staged again after Phase A stages the new segments.
    Restart,
    Stopped,
    /// Not enough free space; the built work so far stays.
    Refused(String),
    /// The staged work passed a bound (`output_cleanup` module docs).
    Abandoned(String),
}

pub(super) struct BuildControl<'a> {
    /// Called before each step; `false` stops the build.
    pub(super) next_step: &'a dyn Fn() -> bool,
    /// The registry and the bytes the swap copies, for the free space check.
    pub(super) space: (&'a Path, u64),
}

/// Runs the build from where its state says, until the new registry's
/// journal is built (or the owner stops).
pub(super) fn build(
    source: &Connection,
    staging: &Connection,
    control: &BuildControl<'_>,
) -> anyhow::Result<Build> {
    let started = Instant::now();
    let step = state(staging, "build_step")?;
    if step == STEP_BUILT {
        return Ok(Build::Built);
    }
    if step.is_empty() {
        if let Some(reason) = build_refusal(source, staging)? {
            return Ok(Build::Abandoned(reason));
        }
        eprintln!("cmux-tui: output cleanup: building the new registry in the background");
        create_schema(source, staging)?;
    } else {
        eprintln!(
            "cmux-tui: output cleanup: resuming the background build at step {step} \
             ({} segments packed through sequence {})",
            state_u64(staging, "packed_segments")?,
            state_u64(staging, "packed_through")?
        );
    }
    if state(staging, "build_step")? == STEP_LIVE {
        match stage_live(source, staging, control.next_step)? {
            Live::Done => {}
            Live::Restart => return Ok(Build::Restart),
            Live::Stopped => return Ok(Build::Stopped),
        }
    }
    if state(staging, "build_step")? == STEP_PACK {
        match pack_closed(source, staging, control)? {
            Packed::Done => set_state(staging, "build_step", STEP_CHECK)?,
            Packed::Stopped => return Ok(Build::Stopped),
            Packed::Refused(reason) => return Ok(Build::Refused(reason)),
            Packed::Abandoned(reason) => return Ok(Build::Abandoned(reason)),
        }
    }
    if state(staging, "build_step")? == STEP_CHECK {
        check_packed(staging)?;
        if !vacuum(staging, control.next_step)? {
            return Ok(Build::Stopped);
        }
        set_state(staging, "build_step", STEP_BUILT)?;
        eprintln!(
            "cmux-tui: output cleanup: built the new registry in the background in {:.2} s: \
             {} segments, {} records kept through sequence {}; the registry is swapped at the \
             next start",
            started.elapsed().as_secs_f64(),
            state_u64(staging, "packed_segments")?,
            state_u64(staging, "packed_kept")?,
            state_u64(staging, "built_head")?
        );
    }
    Ok(Build::Built)
}

/// Before the build starts: the bounds Phase A checked, for what is staged
/// now (a staging file an earlier build left) and the segments sealed after
/// it, at their kind map's most.
fn build_refusal(source: &Connection, staging: &Connection) -> anyhow::Result<Option<String>> {
    if let Some(reason) = staged_bytes_refusal(staging)? {
        return Ok(Some(reason));
    }
    let mode = CleanupMode::of(staging)?;
    let (staged_kept, staged_total) = staged_records(staging)?;
    let tail = sealed_records(source, state_u64(staging, "staged_through")?)?;
    let (live_kept, live_total) =
        live_records_within(source, Some(&SessionPuts::load(staging)?), max_kept_records(mode))?;
    Ok(kept_refusal_in(
        mode,
        staged_kept + tail.kept_at_most + live_kept,
        staged_total + tail.total + live_total,
    ))
}

/// The tables, indexes, views and triggers of `source` (none of SQLite's
/// own), in creation order: `(type, name, tbl_name, sql)`.
pub(super) fn schema_objects(
    connection: &Connection,
    schema: &str,
) -> anyhow::Result<Vec<(String, String, String, String)>> {
    let mut statement = connection.prepare(&format!(
        "SELECT type, name, tbl_name, sql FROM {schema}.sqlite_master
         WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
         ORDER BY rowid"
    ))?;
    let objects = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))?
        .collect::<Result<Vec<(String, String, String, String)>, _>>()?;
    for (kind, name, _, sql) in &objects {
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
    Ok(objects)
}

/// The schema of the rebuilt journal tables and their indexes: the built
/// journal fits a registry whose digest is this one.
pub(super) fn journal_schema_digest(objects: &[(String, String, String, String)]) -> String {
    let mut rebuilt = objects
        .iter()
        .filter(|(kind, _, table, _)| {
            matches!(kind.as_str(), "table" | "index") && REBUILT_TABLES.contains(&table.as_str())
        })
        .map(|(kind, name, _, sql)| format!("{kind}\0{name}\0{sql}\0"))
        .collect::<Vec<_>>();
    rebuilt.sort();
    encode_hex(&Sha256::digest(rebuilt.concat().as_bytes()))
}

/// Every table of the registry, empty (the swap fills the copied ones), and
/// the indexes of the rebuilt journal tables.
fn create_schema(source: &Connection, staging: &Connection) -> anyhow::Result<()> {
    let objects = schema_objects(source, "main")?;
    let tx = staging.unchecked_transaction()?;
    for (_, name, _, sql) in objects.iter().filter(|(kind, _, _, _)| kind == "table") {
        tx.execute_batch(&format!("DROP TABLE IF EXISTS main.{}", quote(name)))?;
        tx.execute_batch(sql)?;
    }
    tx.execute_batch(PRUNED_RANGES_SCHEMA)?;
    for (_, _, _, sql) in objects
        .iter()
        .filter(|(kind, _, table, _)| kind == "index" && REBUILT_TABLES.contains(&table.as_str()))
    {
        tx.execute_batch(sql)?;
    }
    set_state(&tx, "schema_digest", &journal_schema_digest(&objects))?;
    set_state(&tx, "live_kind", "")?;
    set_state(&tx, "live_sequence", "0")?;
    set_state(&tx, "live_dropped", "0")?;
    set_state(&tx, "build_step", STEP_LIVE)?;
    tx.commit()?;
    Ok(())
}

enum Live {
    Done,
    Restart,
    Stopped,
}

/// The `session_journal` columns a stored record row reads, then the actor.
fn record_columns(source: &Connection) -> anyhow::Result<String> {
    let actor = if table_columns(source, "main", "session_journal")?.iter().any(|c| c == "actor") {
        "actor"
    } else {
        "NULL"
    };
    Ok(format!(
        "sequence, event_id, schema_version, kind, class, replay_policy,
         occurred_at_ms, committed_at_ms, producer_json, authority_json,
         causation_id, correlation_id, causation_depth, subjects_json,
         sensitivity, payload_json, content, resource_revision,
         previous_resource_revision, {actor}"
    ))
}

/// A stored row (columns of [`record_columns`]) decoded, with its actor.
fn decoded_row(
    row: &rusqlite::Row<'_>,
) -> anyhow::Result<(super::super::SessionJournalRecord, Option<String>)> {
    let stored = stored_record_row(row)?;
    let actor = row.get::<_, Option<String>>(19)?;
    Ok((decode_record(stored)?, actor))
}

/// A decoded record in its archived form.
fn archived(
    record: &super::super::SessionJournalRecord,
    actor: Option<String>,
) -> anyhow::Result<StagedRecord> {
    let json = serde_json::to_vec(&journal_record_for_archive(record))?;
    Ok((record.sequence, record.kind.clone(), json, actor))
}

/// A stored row (columns of [`record_columns`]) in its archived form.
fn archived_row(row: &rusqlite::Row<'_>) -> anyhow::Result<StagedRecord> {
    let (record, actor) = decoded_row(row)?;
    archived(&record, actor)
}

/// Stages the non-output live rows after the sealed journal through the
/// head Phase A counted, in `(kind, sequence)` order on both sides of
/// `terminal.output`, so no step reads an output row. A session put that a
/// later live put superseded (`session_puts.rs`) is dropped and counted in
/// `live_dropped`.
fn stage_live(
    source: &Connection,
    staging: &Connection,
    next_step: &dyn Fn() -> bool,
) -> anyhow::Result<Live> {
    let puts = SessionPuts::load(staging)?;
    let archive_end = i64::try_from(state_u64(staging, "live_archive_end")?)?;
    let head = i64::try_from(state_u64(staging, "live_head")?)?;
    // A staging file whose live rows were counted past its staged segments
    // (an earlier build counted after a segment sealed): the rows of that
    // segment are in neither range, so Phase A stages it and counts again.
    if archive_end != i64::try_from(state_u64(staging, "staged_through")?)? {
        eprintln!(
            "cmux-tui: output cleanup: the live rows were counted past the staged segments; \
             staging the segments and counting the live rows again"
        );
        restart_live(staging)?;
        return Ok(Live::Restart);
    }
    let columns = record_columns(source)?;
    loop {
        if !next_step() {
            return Ok(Live::Stopped);
        }
        let kind = state(staging, "live_kind")?;
        let after = i64::try_from(state_u64(staging, "live_sequence")?)?;
        let below = kind.as_str() < OUTPUT_KIND;
        // One read snapshot: the sealed journal still ends where Phase A
        // counted, so the live rows in range are the ones it counted.
        source.execute_batch("BEGIN DEFERRED")?;
        // The kept rows, the dropped puts, and the last row read.
        type Page = (Vec<StagedRecord>, u64, Option<(String, u64)>);
        let read = (|| -> anyhow::Result<Option<Page>> {
            let now_end: i64 = source.query_row(
                "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
                [],
                |row| row.get(0),
            )?;
            if now_end != archive_end {
                return Ok(None);
            }
            let mut statement = source.prepare(&format!(
                "SELECT {columns}
                 FROM session_journal INDEXED BY session_journal_by_kind_sequence
                 WHERE (kind, sequence) > (?1, ?2) AND kind {} ?3
                   AND sequence > ?4 AND sequence <= ?5
                 ORDER BY kind, sequence
                 LIMIT ?6",
                if below { "<" } else { ">" }
            ))?;
            let mut rows = statement.query(params![
                kind,
                after,
                OUTPUT_KIND,
                archive_end,
                head,
                LIVE_ROWS_PER_STEP
            ])?;
            let mut kept = Vec::new();
            let mut dropped = 0_u64;
            let mut last = None;
            let mut bytes = 0_usize;
            while let Some(row) = rows.next()? {
                let (record, actor) = decoded_row(row)?;
                last = Some((record.kind.clone(), record.sequence));
                if Put::from_value(&record.kind, &record.payload)
                    .is_some_and(|put| puts.drops(record.sequence, &put))
                {
                    dropped = dropped.saturating_add(1);
                } else {
                    let record = archived(&record, actor)?;
                    bytes += record.2.len();
                    kept.push(record);
                    // The cursor moves to the last row read, so the next
                    // step reads on from there.
                    if bytes >= LIVE_BYTES_PER_STEP {
                        break;
                    }
                }
            }
            Ok(Some((kept, dropped, last)))
        })();
        let _ = source.execute_batch("COMMIT");
        let Some((kept, dropped, last)) = read? else {
            eprintln!(
                "cmux-tui: output cleanup: segments were sealed while the live rows were staged; \
                 staging the new segments, then the live rows again"
            );
            restart_live(staging)?;
            return Ok(Live::Restart);
        };
        let Some((last_kind, last_sequence)) = last else {
            if below {
                // Past every kind below output: the kinds above it next.
                let tx = staging.unchecked_transaction()?;
                set_state(&tx, "live_kind", OUTPUT_KIND)?;
                set_state(&tx, "live_sequence", &i64::MAX.to_string())?;
                tx.commit()?;
                continue;
            }
            finish_live(source, staging)?;
            return Ok(Live::Done);
        };
        let tx = staging.unchecked_transaction()?;
        insert_chunks(&tx, kept, true)?;
        if dropped > 0 {
            let total = state_u64(&tx, "live_dropped")?.saturating_add(dropped);
            set_state(&tx, "live_dropped", &total.to_string())?;
        }
        set_state(&tx, "live_kind", &last_kind)?;
        set_state(&tx, "live_sequence", &last_sequence.to_string())?;
        tx.commit()?;
        std::thread::yield_now();
    }
}

/// The live rows staged so far go; Phase A runs again from its cursor. A
/// live chunk is named by its first record, which is after the cursor.
fn restart_live(staging: &Connection) -> anyhow::Result<()> {
    let tx = staging.unchecked_transaction()?;
    let through = i64::try_from(state_u64(&tx, "staged_through")?)?;
    tx.execute("DELETE FROM output_cleanup_records WHERE sequence > ?1", [through])?;
    tx.execute("DELETE FROM output_cleanup_chunks WHERE chunk > ?1", [through])?;
    set_state(&tx, "complete", "0")?;
    set_state(&tx, "build_step", "")?;
    tx.commit()?;
    Ok(())
}

/// Stages `records` as chunks under a segment's limits, as Phase A's are.
/// With `by_kind` (records in `(kind, sequence)` order) a chunk holds one
/// kind, so a read in sequence order moves between one open chunk per kind
/// (`ChunkReader`); records in sequence order share chunks across kinds.
pub(super) fn insert_chunks(
    staging: &Connection,
    records: Vec<StagedRecord>,
    by_kind: bool,
) -> anyhow::Result<()> {
    let mut writer = ChunkWriter::new(by_kind);
    for record in records {
        writer.push(staging, record)?;
    }
    writer.finish(staging)
}

/// Writes records as [`insert_chunks`] does, one at a time, holding only
/// the open chunk.
struct ChunkWriter {
    chunk: Vec<StagedRecord>,
    bytes: usize,
    by_kind: bool,
}

impl ChunkWriter {
    fn new(by_kind: bool) -> Self {
        Self { chunk: Vec::with_capacity(CHUNK_RECORD_LIMIT), bytes: 0, by_kind }
    }

    fn push(&mut self, staging: &Connection, record: StagedRecord) -> anyhow::Result<()> {
        if self.chunk.len() == CHUNK_RECORD_LIMIT
            || (self.by_kind && self.chunk.last().is_some_and(|last| last.1 != record.1))
            || self.bytes.saturating_add(record.2.len()).saturating_add(self.chunk.len() + 2)
                >= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES
        {
            insert_chunk(staging, &self.chunk)?;
            self.chunk.clear();
            self.bytes = 0;
        }
        self.bytes += record.2.len();
        self.chunk.push(record);
        Ok(())
    }

    fn finish(self, staging: &Connection) -> anyhow::Result<()> {
        insert_chunk(staging, &self.chunk)
    }
}

/// Every record through the counted head is staged: checks that kept and
/// removed add up, then starts packing at the first journal sequence.
fn finish_live(source: &Connection, staging: &Connection) -> anyhow::Result<()> {
    check_staged_counts(staging)?;
    let lo: Option<i64> = source.query_row(
        // One aggregate per subquery: SQLite answers a lone MIN from the
        // index, two in one SELECT scan the table.
        "SELECT MIN(COALESCE((SELECT MIN(start_sequence) FROM journal_segments),
                             (SELECT MIN(sequence) FROM session_journal)),
                    COALESCE((SELECT MIN(sequence) FROM session_journal),
                             (SELECT MIN(start_sequence) FROM journal_segments)))",
        [],
        |row| row.get(0),
    )?;
    let lo = u64::try_from(lo.context("the journal is empty")?)?.max(1);
    let head = state_u64(staging, "live_head")?.max(state_u64(staging, "live_archive_end")?);
    let tx = staging.unchecked_transaction()?;
    set_state(&tx, "pack_next_start", &lo.to_string())?;
    set_state(&tx, "packed_through", &(lo - 1).to_string())?;
    set_state(&tx, "built_head", &head.to_string())?;
    set_state(&tx, "build_step", STEP_PACK)?;
    tx.commit()?;
    Ok(())
}

/// Every record Phase A and the live step saw is either staged or removed:
/// per staged segment, and for the live rows, whose contiguity and output
/// count Phase A took in one snapshot.
pub(super) fn check_staged_counts(staging: &Connection) -> anyhow::Result<()> {
    let kept_in = |after: i64, through: i64| -> anyhow::Result<i64> {
        Ok(staging.query_row(
            "SELECT COUNT(*) FROM output_cleanup_records WHERE sequence > ?1 AND sequence <= ?2",
            [after, through],
            |row| row.get(0),
        )?)
    };
    let archive_end = i64::try_from(state_u64(staging, "live_archive_end")?)?;
    let live_head = i64::try_from(state_u64(staging, "live_head")?)?;
    let live_output = i64::try_from(state_u64(staging, "live_output")?)?;
    let live_dropped = i64::try_from(state_u64(staging, "live_dropped")?)?;
    // The live rows start where the staged segments end, or the records
    // between the two would be packed as pruned.
    let staged_through = i64::try_from(state_u64(staging, "staged_through")?)?;
    anyhow::ensure!(
        archive_end == staged_through,
        "the live rows were counted after sequence {archive_end}, the staged segments end at \
         {staged_through}"
    );
    let (segments, first, last, records, kept): (i64, Option<i64>, Option<i64>, i64, i64) = staging
        .query_row(
            "SELECT COUNT(*), MIN(start_sequence), MAX(end_sequence),
                    COALESCE(SUM(record_count), 0), COALESCE(SUM(kept), 0)
             FROM output_cleanup_segments",
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
        let mismatched: i64 = staging.query_row(
            "SELECT COUNT(*) FROM output_cleanup_segments AS segment
             WHERE segment.kept + segment.removed != segment.record_count
                OR segment.kept != (
                  SELECT COUNT(*) FROM output_cleanup_records AS kept
                  WHERE kept.sequence BETWEEN segment.start_sequence AND segment.end_sequence)",
            [],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            mismatched == 0,
            "{mismatched} staged segments do not add up (kept plus removed)"
        );
        let gaps: i64 = staging.query_row(
            "SELECT COUNT(*) FROM output_cleanup_segments AS segment
             WHERE segment.start_sequence > ?1 AND NOT EXISTS (
               SELECT 1 FROM output_cleanup_segments AS previous
               WHERE previous.end_sequence = segment.start_sequence - 1)",
            [first],
            |row| row.get(0),
        )?;
        anyhow::ensure!(gaps == 0, "the staged segments are not contiguous");
    } else {
        anyhow::ensure!(
            archive_end == 0,
            "no segment is staged, but the sealed journal ends at sequence {archive_end}"
        );
    }
    if live_head > archive_end {
        anyhow::ensure!(
            kept_in(archive_end, live_head)? + live_output + live_dropped
                == live_head - archive_end,
            "kept and removed live rows do not add up to the live journal"
        );
    }
    anyhow::ensure!(
        kept_in(live_head.max(archive_end), i64::MAX)? == 0,
        "records after the counted head were staged"
    );
    Ok(())
}

enum Packed {
    Done,
    Stopped,
    Refused(String),
    Abandoned(String),
}

/// Packs every full segment of staged records; the records after the last
/// full one stay staged for the next catch-up or the swap (so at least one
/// is always left for the journal's last segment).
fn pack_closed(
    source: &Connection,
    staging: &Connection,
    control: &BuildControl<'_>,
) -> anyhow::Result<Packed> {
    let mut since_space_check = 0_u64;
    let mut last_log = Instant::now();
    let mut fold = stated_fold(staging)?;
    loop {
        if !(control.next_step)() {
            return Ok(Packed::Stopped);
        }
        let start = state_u64(staging, "pack_next_start")?;
        let after = state_u64(staging, "packed_through")?;
        let (segment, full) = collect_segment(staging, after, start, fold.as_ref())?;
        if !full {
            return Ok(Packed::Done);
        }
        let end = segment.last;
        let tx = staging.unchecked_transaction()?;
        let kept = segment.sequences.len();
        let (_, compacted) = write_segment(&tx, source, segment, end)?;
        commit_compacted(&tx, fold.as_mut(), compacted)?;
        forget_packed(&tx, start, end)?;
        set_state(&tx, "pack_next_start", &(end + 1).to_string())?;
        set_state(&tx, "packed_through", &end.to_string())?;
        tx.execute(
            "UPDATE output_cleanup_state SET value = CAST(value AS INTEGER) + 1
             WHERE key = 'packed_segments'",
            [],
        )?;
        tx.execute(
            "UPDATE output_cleanup_state SET value = CAST(value AS INTEGER) + ?1
             WHERE key = 'packed_kept'",
            [i64::try_from(kept)?],
        )?;
        tx.commit()?;
        since_space_check += 1;
        if since_space_check >= PACKS_PER_SPACE_CHECK {
            since_space_check = 0;
            if let Err(reason) = free_space_refusal(control.space.0, control.space.1)? {
                return Ok(Packed::Refused(reason));
            }
            if let Some(reason) = staged_bytes_refusal(staging)? {
                return Ok(Packed::Abandoned(reason));
            }
        }
        if last_log.elapsed() >= progress_log_interval() {
            last_log = Instant::now();
            eprintln!(
                "cmux-tui: output cleanup: packed {} segments through sequence {end}",
                state_u64(staging, "packed_segments")?
            );
        }
        std::thread::yield_now();
    }
}

/// The chunks of a packed range that hold no later record leave the staging
/// file. The records' rows stay.
fn forget_packed(staging: &Connection, start: u64, end: u64) -> anyhow::Result<()> {
    staging.execute(
        "DELETE FROM output_cleanup_chunks
         WHERE chunk IN (SELECT DISTINCT chunk FROM output_cleanup_records
                         WHERE sequence BETWEEN ?1 AND ?2)
           AND NOT EXISTS (SELECT 1 FROM output_cleanup_records AS later
                           WHERE later.chunk = output_cleanup_chunks.chunk
                             AND later.sequence > ?2)",
        params![i64::try_from(start)?, i64::try_from(end)?],
    )?;
    Ok(())
}

/// One new segment's records, gathered from the staged records after
/// `after`. `full` when the next record did not fit (it starts the next
/// segment); otherwise the segment holds every staged record left.
fn collect_segment(
    staging: &Connection,
    after: u64,
    start: u64,
    fold: Option<&StatedFold>,
) -> anyhow::Result<(OpenSegment, bool)> {
    let limit = segment_record_limit();
    let mut statement = staging.prepare(
        "SELECT sequence, kind, chunk, actor FROM main.output_cleanup_records
         WHERE sequence > ?1 ORDER BY sequence ASC",
    )?;
    let mut rows = statement.query([i64::try_from(after)?])?;
    let mut chunks = ChunkReader::new();
    let mut segment = OpenSegment::new(start);
    while let Some(row) = rows.next()? {
        let sequence = u64::try_from(row.get::<_, i64>(0)?)?;
        let json = chunks.record(staging, row.get::<_, i64>(2)?, sequence)?;
        // A compaction packs the record without the upserts it restates
        // (`journal_compact.rs`); the fold moves only once the record is in.
        let folded = match fold {
            Some(fold) => fold_record(json, fold, &segment.compacted.delta)
                .with_context(|| format!("compact journal record {sequence}"))?,
            None => Folded::default(),
        };
        let json = folded.rewritten.as_ref().map_or(json, |rewritten| rewritten.json.as_slice());
        if segment.writer.records() == limit
            || (segment.writer.records() > 0 && !segment.writer.fits(json))
        {
            return Ok((segment, true));
        }
        anyhow::ensure!(sequence >= start, "kept journal record {sequence} is before {start}");
        segment.writer.push(json);
        segment.compacted.delta.extend(folded.delta);
        if let Some(rewritten) = folded.rewritten {
            segment.compacted.removed += rewritten.removed;
            segment.compacted.subjects.push((sequence, rewritten.subjects));
        }
        segment.sequences.push(sequence);
        segment.last = sequence;
        segment.kinds.insert(row.get::<_, String>(1)?);
        if let Some(actor) = row.get::<_, Option<String>>(3)? {
            segment.actors.insert(sequence.to_string(), actor);
        }
    }
    Ok((segment, false))
}

/// Writes `segment` over `start..=end` with its pruned ranges and the index
/// rows of its records. Returns its pruned ranges and what a compaction did
/// to its records, for the caller to commit in the same transaction.
fn write_segment(
    staging: &Connection,
    source: &Connection,
    mut segment: OpenSegment,
    end: u64,
) -> anyhow::Result<(u64, Compacted)> {
    let mut previous = segment.start - 1;
    let mut pruned = 0;
    for &sequence in &segment.sequences {
        anyhow::ensure!(
            sequence > previous && sequence <= end,
            "kept journal record {sequence} is outside the segment range"
        );
        if sequence > previous + 1 {
            insert_pruned(staging, previous + 1, sequence - 1)?;
            pruned += 1;
        }
        previous = sequence;
    }
    if previous < end {
        insert_pruned(staging, previous + 1, end)?;
        pruned += 1;
    }
    // Before the index rows are derived: a rewritten record's subjects.
    if !segment.compacted.subjects.is_empty() {
        let mut update = staging.prepare_cached(
            "UPDATE main.output_cleanup_records
             SET index_json = json_set(index_json, '$.subjects', json(?2))
             WHERE sequence = ?1",
        )?;
        for (sequence, subjects) in &segment.compacted.subjects {
            let changed = update.execute(params![i64::try_from(*sequence)?, subjects])?;
            anyhow::ensure!(changed == 1, "staged journal record {sequence} is missing");
        }
    }
    copy_index_rows(staging, source, segment.start, end, &segment.sequences)?;
    let with_actors = table_columns(staging, "main", "journal_segments")?
        .iter()
        .any(|name| name == "actors_json");
    let compacted = std::mem::take(&mut segment.compacted);
    segment.insert(staging, end, i64::try_from(unix_epoch_ms()?)?, with_actors)?;
    Ok((pruned, compacted))
}

/// At the swap: packs every staged record after `after` into segments from
/// `start`, the last one through `head`. Returns (segments, pruned ranges).
pub(super) fn pack_rest(
    staging: &Connection,
    source: &Connection,
    mut after: u64,
    mut start: u64,
    head: u64,
) -> anyhow::Result<(u64, u64)> {
    let mut segments = 0;
    let mut pruned = 0;
    let mut fold = stated_fold(staging)?;
    // Each pass packs at least one staged record (or fails), so it ends.
    loop {
        let (segment, full) = collect_segment(staging, after, start, fold.as_ref())?;
        anyhow::ensure!(
            !segment.sequences.is_empty(),
            "no kept record is left for the last journal segment"
        );
        let end = if full { segment.last } else { head };
        let (ranges, compacted) = write_segment(staging, source, segment, end)?;
        pruned += ranges;
        commit_compacted(staging, fold.as_mut(), compacted)?;
        forget_packed(staging, start, end)?;
        segments += 1;
        if !full {
            return Ok((segments, pruned));
        }
        after = end;
        start = end + 1;
    }
}

fn insert_pruned(staging: &Connection, start: u64, end: u64) -> anyhow::Result<()> {
    staging.execute(
        "INSERT INTO main.journal_pruned_ranges(start_sequence, end_sequence) VALUES(?1, ?2)",
        params![i64::try_from(start)?, i64::try_from(end)?],
    )?;
    Ok(())
}

/// The event index columns [`copy_index_rows`] derives from a record.
const DERIVED_EVENT_COLUMNS: [&str; 7] = [
    "event_id",
    "sequence",
    "causation_depth",
    "causation_id",
    "causal_hook_id",
    "resource_revision",
    "previous_resource_revision",
];

/// The subject and event index rows of the kept records in `start..=end`.
/// They are derived from each record's staged index fields, as the append
/// that wrote them did: copying them from the registry's 125M-row subject
/// index took one random read per record (127 s for 86k records on a cold
/// network disk). Only the values an append looked up (`causal_hook_id` of
/// a record with a cause or from the hook dispatcher, the revisions of a
/// record that names only its own) are read from the registry, by sequence.
fn copy_index_rows(
    staging: &Connection,
    source: &Connection,
    start: u64,
    end: u64,
    sequences: &[u64],
) -> anyhow::Result<()> {
    let range = [i64::try_from(start)?, i64::try_from(end)?];
    staging.execute(
        "INSERT OR IGNORE INTO main.journal_subject_index(sequence, kind, id)
         SELECT kept.sequence,
                json_extract(subject.value, '$.kind'),
                json_extract(subject.value, '$.id')
         FROM main.output_cleanup_records AS kept,
              json_each(kept.index_json, '$.subjects') AS subject
         WHERE kept.sequence BETWEEN ?1 AND ?2
           AND json_type(subject.value, '$.kind') = 'text'
           AND json_type(subject.value, '$.id') = 'text'",
        range,
    )?;
    let columns = table_columns(staging, "main", "journal_event_index")?;
    if columns.len() != DERIVED_EVENT_COLUMNS.len()
        || !DERIVED_EVENT_COLUMNS.iter().all(|name| columns.iter().any(|c| c == name))
    {
        // A table shape this derivation does not know: copy by sequence.
        return copy_event_rows(staging, source, &columns, sequences);
    }
    // Resource revisions as `ensure_journal_event_index_schema` backfilled
    // them: from the record, else from a legacy `event_resource_N` id.
    staging.execute(
        "INSERT INTO main.journal_event_index(
           event_id, sequence, causation_depth, causation_id, causal_hook_id,
           resource_revision, previous_resource_revision)
         SELECT record.event_id, record.sequence, record.causation_depth, record.causation_id,
                NULL,
                COALESCE(record.resource_revision, record.legacy_revision),
                COALESCE(record.previous_resource_revision, record.legacy_revision - 1)
         FROM (
           SELECT kept.sequence AS sequence,
                  json_extract(json, '$.event_id') AS event_id,
                  json_extract(json, '$.causation_depth') AS causation_depth,
                  json_extract(json, '$.causation_id') AS causation_id,
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
           FROM (SELECT sequence, index_json AS json
                 FROM main.output_cleanup_records
                 WHERE sequence BETWEEN ?1 AND ?2) AS kept
         ) AS record",
        range,
    )?;
    // The looked-up values: (sequence, needs the hook id, needs the
    // revisions).
    let lookups = {
        let mut statement = staging.prepare(
            "SELECT sequence, needs_hook, needs_revisions FROM (
               SELECT sequence,
                      json_extract(index_json, '$.causation_id') IS NOT NULL
                        OR json_extract(index_json, '$.producer.kind') = 'hook_dispatcher'
                        AS needs_hook,
                      json_extract(index_json, '$.resource_revision') IS NOT NULL
                        AND json_extract(index_json, '$.previous_resource_revision') IS NULL
                        AS needs_revisions
               FROM main.output_cleanup_records WHERE sequence BETWEEN ?1 AND ?2)
             WHERE needs_hook OR needs_revisions",
        )?;
        statement
            .query_map(range, |row| Ok((row.get::<_, i64>(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<Result<Vec<(i64, bool, bool)>, _>>()?
    };
    if lookups.is_empty() {
        return Ok(());
    }
    let mut select = source.prepare(
        "SELECT causal_hook_id, resource_revision, previous_resource_revision
         FROM journal_event_index WHERE sequence = ?1",
    )?;
    let mut update = staging.prepare(
        "UPDATE main.journal_event_index
         SET causal_hook_id = CASE WHEN ?2 THEN ?3 ELSE causal_hook_id END,
             resource_revision = CASE WHEN ?4 THEN ?5 ELSE resource_revision END,
             previous_resource_revision =
               CASE WHEN ?4 THEN ?6 ELSE previous_resource_revision END
         WHERE sequence = ?1",
    )?;
    for (sequence, needs_hook, needs_revisions) in lookups {
        let (hook, revision, previous) = select
            .query_row([sequence], |row| {
                Ok((row.get::<_, Value>(0)?, row.get::<_, Value>(1)?, row.get::<_, Value>(2)?))
            })
            .optional()?
            .unwrap_or((Value::Null, Value::Null, Value::Null));
        update.execute(params![sequence, needs_hook, hook, needs_revisions, revision, previous])?;
    }
    Ok(())
}

/// The registry's event index rows of `sequences`, as they are.
fn copy_event_rows(
    staging: &Connection,
    source: &Connection,
    columns: &[String],
    sequences: &[u64],
) -> anyhow::Result<()> {
    let list = columns.iter().map(|column| quote(column)).collect::<Vec<_>>().join(", ");
    let mut select =
        source.prepare(&format!("SELECT {list} FROM journal_event_index WHERE sequence = ?1"))?;
    let mut insert = staging.prepare(&format!(
        "INSERT INTO main.journal_event_index({list}) VALUES({})",
        vec!["?"; columns.len()].join(", ")
    ))?;
    for &sequence in sequences {
        let values = select
            .query_row([i64::try_from(sequence)?], |row| {
                (0..columns.len())
                    .map(|index| row.get::<_, Value>(index))
                    .collect::<rusqlite::Result<Vec<Value>>>()
            })
            .optional()?;
        if let Some(values) = values {
            insert.execute(params_from_iter(values))?;
        }
    }
    Ok(())
}

struct OpenSegment {
    start: u64,
    last: u64,
    sequences: Vec<u64>,
    writer: SegmentWriter,
    kinds: BTreeSet<String>,
    actors: BTreeMap<String, String>,
    compacted: Compacted,
}

/// What a compaction did to the records of one open segment
/// (`journal_compact.rs`); empty for an output cleanup.
#[derive(Default)]
struct Compacted {
    /// The records' changes to the stated fold.
    delta: FoldDelta,
    /// The narrowed subjects of each rewritten record, by sequence.
    subjects: Vec<(u64, String)>,
    /// Changes removed from the rewritten records.
    removed: u64,
}

/// The stated fold of a compaction's staging file; `None` for an output
/// cleanup, whose pack copies every record as it is.
fn stated_fold(staging: &Connection) -> anyhow::Result<Option<StatedFold>> {
    match CleanupMode::of(staging)? {
        CleanupMode::Output => Ok(None),
        CleanupMode::Compact => StatedFold::load(staging).map(Some),
    }
}

/// Commits what a packed segment's records did to the fold, with the
/// compaction's counts, in that segment's staging transaction.
fn commit_compacted(
    transaction: &Connection,
    fold: Option<&mut StatedFold>,
    compacted: Compacted,
) -> anyhow::Result<()> {
    let Some(fold) = fold else { return Ok(()) };
    for (key, count) in [
        ("compact_rewritten", compacted.subjects.len() as u64),
        ("compact_removed_changes", compacted.removed),
    ] {
        transaction.execute(
            "UPDATE main.output_cleanup_state SET value = CAST(value AS INTEGER) + ?1
             WHERE key = ?2",
            params![i64::try_from(count)?, key],
        )?;
    }
    fold.commit(transaction, compacted.delta)
}

impl OpenSegment {
    fn new(start: u64) -> Self {
        Self {
            start,
            last: 0,
            sequences: Vec::new(),
            writer: SegmentWriter::new(),
            kinds: BTreeSet::new(),
            actors: BTreeMap::new(),
            compacted: Compacted::default(),
        }
    }

    fn insert(
        self,
        staging: &Connection,
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
        staging.execute(
            &format!(
                "INSERT INTO main.journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms{columns}
                 ) VALUES(?1, ?2, ?3, ?4, '{SEAL_CODEC}', ?5, ?6, ?7, ?8{values})"
            ),
            params_from_iter(
                [
                    Value::Text(segment_id.clone()),
                    Value::Integer(i64::try_from(self.start)?),
                    Value::Integer(i64::try_from(end)?),
                    Value::Integer(i64::try_from(records)?),
                    Value::Blob(encoded.compressed),
                    Value::Integer(i64::try_from(encoded.uncompressed_bytes)?),
                    Value::Blob(encoded.digest.to_vec()),
                    Value::Integer(sealed_at_ms),
                    actors.map_or(Value::Null, Value::Text),
                ]
                .into_iter()
                .take(if with_actors { 9 } else { 8 }),
            ),
        )?;
        for kind in &self.kinds {
            staging.execute(
                "INSERT INTO main.journal_segment_kinds(segment_id, kind) VALUES(?1, ?2)",
                params![segment_id, kind],
            )?;
        }
        Ok(())
    }
}

/// The packed journal before the swap may use it: an integrity check of the
/// staging file and a read back through the owner's readers.
fn check_packed(staging: &Connection) -> anyhow::Result<()> {
    let integrity: String = staging.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    anyhow::ensure!(integrity == "ok", "the new registry failed integrity_check: {integrity}");
    let packed_through = state_u64(staging, "packed_through")?;
    let packed_kept = state_u64(staging, "packed_kept")?;
    if state_u64(staging, "packed_segments")? == 0 {
        return Ok(());
    }
    let mut cursor = 0_u64;
    let mut read = 0_u64;
    // Each page moves the cursor past its last record; an empty page ends.
    loop {
        let page = query_session_journal_after(staging, cursor, 1024)?;
        anyhow::ensure!(page.head_sequence == packed_through, "the packed journal head moved");
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        anyhow::ensure!(
            page.records.iter().all(|record| record.kind != OUTPUT_KIND),
            "the packed journal holds terminal output"
        );
        read += u64::try_from(page.records.len())?;
    }
    anyhow::ensure!(
        read == packed_kept,
        "the packed journal reads {read} records back, {packed_kept} were packed"
    );
    anyhow::ensure!(
        query_journal_head(staging)? == packed_through,
        "the packed journal head moved"
    );
    Ok(())
}

/// Returns the staging file's free pages to the file system, a step at a
/// time. False when stopped first.
fn vacuum(staging: &Connection, next_step: &dyn Fn() -> bool) -> anyhow::Result<bool> {
    // Each step frees pages or ends the loop: the free count only falls.
    loop {
        let free: i64 = staging.query_row("PRAGMA freelist_count", [], |row| row.get(0))?;
        if free == 0 {
            return Ok(true);
        }
        if !next_step() {
            return Ok(false);
        }
        staging.execute_batch(&format!("PRAGMA incremental_vacuum({VACUUM_PAGES_PER_STEP})"))?;
        let left: i64 = staging.query_row("PRAGMA freelist_count", [], |row| row.get(0))?;
        if left >= free {
            // Not an incremental auto-vacuum file: the pages stay free.
            return Ok(true);
        }
    }
}

/// Stages every journal record in `after+1..=through`, wherever it is now
/// (live rows, or segments sealed after the build), read in one snapshot:
/// the non-output ones go to `staging` as chunks in sequence order, with
/// one chunk in memory at a time (a 100,000-record tail of 64 KiB payloads
/// is over 6 GiB). Fails unless every sequence in the range is there
/// exactly once, in order; the caller's transaction then drops the chunks.
pub(super) fn stage_range(
    source: &Connection,
    staging: &Connection,
    after: u64,
    through: u64,
) -> anyhow::Result<()> {
    source.execute_batch("BEGIN DEFERRED")?;
    let read = (|| -> anyhow::Result<()> {
        let (lo, hi) = (i64::try_from(after)?, i64::try_from(through)?);
        let mut writer = ChunkWriter::new(false);
        let mut next = after + 1;
        let mut take = |sequence: u64| -> anyhow::Result<()> {
            anyhow::ensure!(
                sequence == next,
                "the journal records after sequence {after} through {through} are not contiguous"
            );
            next += 1;
            Ok(())
        };
        let mut segments = source.prepare(
            "SELECT segment_id, start_sequence, end_sequence, record_count FROM journal_segments
             WHERE end_sequence > ?1 AND start_sequence <= ?2 ORDER BY start_sequence",
        )?;
        let overlapping = segments
            .query_map([lo, hi], |row| {
                Ok((row.get::<_, String>(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?
            .collect::<Result<Vec<(String, i64, i64, i64)>, _>>()?;
        for (id, start, end, count) in overlapping {
            let records = inflated_segment_records(
                source,
                &id,
                u64::try_from(start)?,
                u64::try_from(end)?,
                count,
                // Sealed after the build began, from live rows: whole.
                SegmentGaps::Damage,
            )?;
            for record in records {
                if record.0 > after && record.0 <= through {
                    take(record.0)?;
                    if record.1 != OUTPUT_KIND {
                        writer.push(staging, record)?;
                    }
                }
            }
        }
        let columns = record_columns(source)?;
        let mut live = source.prepare(
            "SELECT sequence, kind = ?3 FROM session_journal
             WHERE sequence > ?1 AND sequence <= ?2 ORDER BY sequence",
        )?;
        let mut full = source
            .prepare(&format!("SELECT {columns} FROM session_journal WHERE sequence = ?1"))?;
        let mut rows = live.query(params![lo, hi, OUTPUT_KIND])?;
        while let Some(row) = rows.next()? {
            let sequence = row.get::<_, i64>(0)?;
            take(u64::try_from(sequence)?)?;
            if !row.get::<_, bool>(1)? {
                let mut rows = full.query([sequence])?;
                let row = rows.next()?.context("a live journal row went away")?;
                writer.push(staging, archived_row(row)?)?;
            }
        }
        anyhow::ensure!(
            next == through + 1,
            "the journal records after sequence {after} through {through} are not contiguous"
        );
        writer.finish(staging)
    })();
    let _ = source.execute_batch("COMMIT");
    read
}

pub(super) enum CaughtUp {
    /// The built journal reaches the registry's head (or a free space
    /// refusal waits for the next round).
    Current,
    Stopped,
    /// The staging file passed its size bound.
    Abandoned(String),
}

/// While the owner serves after the build: stages and packs the records
/// appended since, so the next start's tail stays short.
pub(super) fn catch_up(
    source: &Connection,
    staging: &Connection,
    control: &BuildControl<'_>,
) -> anyhow::Result<CaughtUp> {
    let mut caught = 0_u64;
    // Each pass moves `built_head` toward the head read in that pass; the
    // loop ends at the head or at a stop.
    loop {
        if !(control.next_step)() {
            return Ok(CaughtUp::Stopped);
        }
        let built = state_u64(staging, "built_head")?;
        let head = query_journal_head(source)?;
        if head <= built {
            break;
        }
        let through = head.min(built + CATCH_UP_RECORDS_PER_STEP);
        let tx = staging.unchecked_transaction()?;
        stage_range(source, &tx, built, through)?;
        set_state(&tx, "built_head", &through.to_string())?;
        tx.commit()?;
        caught += through - built;
    }
    match pack_closed(source, staging, control)? {
        Packed::Done | Packed::Refused(_) => {}
        Packed::Stopped => return Ok(CaughtUp::Stopped),
        Packed::Abandoned(reason) => return Ok(CaughtUp::Abandoned(reason)),
    }
    if caught == 0 {
        return Ok(CaughtUp::Current);
    }
    if !vacuum(staging, control.next_step)? {
        return Ok(CaughtUp::Stopped);
    }
    if let Some(reason) = staged_bytes_refusal(staging)? {
        return Ok(CaughtUp::Abandoned(reason));
    }
    eprintln!(
        "cmux-tui: output cleanup: caught up through sequence {} ({caught} records)",
        state_u64(staging, "built_head")?
    );
    Ok(CaughtUp::Current)
}

pub(super) fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

pub(super) fn table_columns(
    connection: &Connection,
    schema: &str,
    table: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement =
        connection.prepare("SELECT name FROM pragma_table_info(?1, ?2) ORDER BY cid")?;
    let columns = statement
        .query_map([table, schema], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    anyhow::ensure!(!columns.is_empty(), "table {schema}.{table} has no columns");
    Ok(columns)
}
