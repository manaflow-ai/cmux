//! The sparse part of the shape ([`super::ShapeOptions::sparse_head`]).
//!
//! The real file of 2026-11-11 holds 2.44 M records and its journal head is
//! 24.1 M: its first segment starts at sequence 1, and 149,568 pruned ranges
//! say which sequences are gone. The first output cleanup made it so: it
//! removed the stored terminal output and the superseded session puts, and
//! packed what it kept into segments that tile the same sequence range.
//!
//! The generator makes that part with the same cleanup. In bursts up to
//! `sparse_head` it writes:
//!
//! - [`BURST_RECORDS`] records by the shape's own writers (the cleanup keeps
//!   them, except each `personal.session.put` that a later put superseded);
//! - [`BURST_OUTPUT_ROWS`] `terminal.output` rows as an older build journaled
//!   output (4 KiB of content each, through `append_journal_record`);
//! - then `terminal.output` rows with EMPTY fields, one SQL statement, to the
//!   end of the burst. These are NOT rows of any build: they have the kind
//!   and a sequence, and no producer, subject or content. The cleanup reads
//!   no live output row (it counts them through the `(kind, sequence)`
//!   index), and no owner opens the registry before the cleanup removed them.
//!
//! Then `stage_registry` at floor 0 and an open of the registry, which
//! swaps: the product's own stage, pack, check and swap. The file that the
//! swap replaced is removed here, as on a Mac where that cleanup ran days ago.
//!
//! [`super::ShapeOptions::sparse_stretch`] is for a small test only: after the swap
//! it moves the end of the last packed segment, the end of the pruned range
//! there and the journal's sequence counter up to that sequence, by SQL. The
//! result is what the cleanup writes when a long run of removed rows follows
//! the last kept record, but the cleanup did not write it.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use rusqlite::params;
use serde_json::{Value, json};

use super::Shape;
use crate::JournalSubject;
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::open_guard::sidecar_path;
use crate::workspace_registry::output_cleanup::{
    StageControl, StageOutcome, previous_path, stage_registry,
};
use crate::workspace_registry::presentation_store::append_presentation_record;
use crate::workspace_registry::session_journal::{query_journal_head, unix_epoch_ms};

/// Records by the shape's writers at the start of each burst.
const BURST_RECORDS: u64 = 2;
/// Output rows of an older build's encoding in each burst.
const BURST_OUTPUT_ROWS: u64 = 2;
/// The fewest sequences of a burst: its records, its output rows and a hole.
const MIN_BURST_SPAN: u64 = BURST_RECORDS + BURST_OUTPUT_ROWS + 3;
/// `?1` output rows with empty fields; `?2` makes their event ids unique.
const EMPTY_OUTPUT_ROWS: &str = "WITH RECURSIVE filler(i) AS (
       SELECT 1 UNION ALL SELECT i + 1 FROM filler WHERE i < ?1)
     INSERT INTO session_journal(
       event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
       committed_at_ms, producer_json, causation_depth, subjects_json, sensitivity,
       payload_json)
     SELECT 'synth_removed_' || ?2 || '_' || i, 1, 'terminal.output', 'observation',
            'required', ?3, ?3, '{}', 0, '[]', 'sensitive', '{}'
     FROM filler";

/// A segment row refuses an update: the generator drops the trigger and
/// makes it again in the same transaction.
const DROP_SEGMENT_TRIGGER: &str = "DROP TRIGGER IF EXISTS journal_segments_reject_update;";
const SEGMENT_TRIGGER: &str = "CREATE TRIGGER IF NOT EXISTS journal_segments_reject_update
       BEFORE UPDATE ON journal_segments
     BEGIN
       SELECT RAISE(ABORT, 'journal segments are immutable');
     END;";
/// The labels of the checkpoints that [`advance_checkpoints`] makes start here.
const ADVANCE_LABEL_BASE: u64 = 1_000;

/// The generator copies its log into the file when the log reaches this
/// size. Its commits by hand wake no checkpointer and a row writes many pages
/// again: with no checkpoint the log of a 9.6 GB registry passed 98 GB, and
/// with one each 20,000 records the log of a 160 MiB test registry reached
/// 2.5 GiB (a burst of the sparse part is 2 records and a commit of removed
/// rows, and three tests build such a registry at one time).
const LOG_BYTES: u64 = 32 << 20;

/// Rows of one transaction of [`append_progress`].
const APPEND_BATCH: u64 = 1_000;

/// Moves the restore points of a generated registry to its journal head, as
/// days of use do on a Mac. The migration proof calls this before a SECOND
/// rebuild of a registry (an owner rebuilds only when 100,000 records are at
/// or below a new floor). In this order:
///
/// - `append` more `terminal.progress` records of the shape's size (no
///   reducer of an agent reads that kind, so no agent and no session changes);
/// - `checkpoints` new checkpoints, each by an owner at a head of its own (the
///   maintenance pass of the next owner prunes the ones they replace);
/// - every record into segments, and each segment's `sealed_at_ms` moved back
///   by [`super::ShapeOptions::seal_age_minutes`].
///
/// The retention floor of the next start is then near the head. Returns what
/// it did.
pub fn advance_checkpoints(
    state_root: &Path,
    options: &super::ShapeOptions,
    checkpoints: u64,
    append: u64,
) -> anyhow::Result<Value> {
    let base = options.base();
    let appended_through = append_progress(state_root, &options.session, append, 0)?;
    // The journal head is in each idempotency key: an owner answers a key
    // that it knows with the old receipt, so the keys of the generator and
    // of an earlier advance must not come again.
    let label = ADVANCE_LABEL_BASE + appended_through;
    let mut made = Vec::new();
    for index in 0..checkpoints {
        // `source_sequence` is unique: one more record for each checkpoint.
        append_progress(state_root, &options.session, 1, append + index)?;
        made.push(super::checkpoint(state_root, &base, label + index)?);
    }
    // And one for the checkpoint that the seal step takes.
    append_progress(state_root, &options.session, 1, append + checkpoints)?;
    let (sealed_through, segments_sealed) =
        super::super::seal_as(state_root, &base, &format!("-advance-{label}"))?;
    anyhow::ensure!(
        made.last().is_none_or(|last| sealed_through > *last),
        "the seal ended at {sealed_through}, at or below the last new checkpoint {made:?}"
    );
    let age_ms = options.seal_age_minutes.saturating_mul(60_000);
    let registry = open_registry(state_root, &options.session)?;
    registry.connection.get().execute_batch(&format!(
        "BEGIN IMMEDIATE;
         {DROP_SEGMENT_TRIGGER}
         UPDATE journal_segments SET sealed_at_ms = MAX(sealed_at_ms - {age_ms}, 0);
         {SEGMENT_TRIGGER}
         COMMIT;"
    ))?;
    Ok(json!({
        "appended": append,
        "appended_through": appended_through,
        "checkpoints": made.len(),
        "first_checkpoint": made.first(),
        "last_checkpoint": made.last(),
        "sealed_through": sealed_through,
        "segments_sealed": segments_sealed,
        "seal_age_minutes": options.seal_age_minutes,
    }))
}

/// The registry of `session`. An owner's last worker may still hold the
/// session for a moment after its shutdown.
pub(super) fn open_registry(state_root: &Path, session: &str) -> anyhow::Result<WorkspaceRegistry> {
    let mut tries = 0;
    loop {
        match WorkspaceRegistry::open(state_root, session) {
            Ok(registry) => return Ok(registry),
            Err(error) if tries >= super::OPEN_TRIES => return Err(error),
            Err(_) => {
                tries += 1;
                std::thread::sleep(super::OPEN_RETRY_PAUSE);
            }
        }
    }
}

/// Appends `rows` `terminal.progress` records of the first agent terminal,
/// each with a filler of the shape's size. Returns the journal head.
fn append_progress(state_root: &Path, session: &str, rows: u64, first: u64) -> anyhow::Result<u64> {
    let registry = open_registry(state_root, session)?;
    let connection = registry.connection.get();
    let terminal = format!("{}{:012x}", super::AGENT_TERMINAL_PREFIX, 0);
    let mut written = 0;
    while written < rows {
        let batch = (rows - written).min(APPEND_BATCH);
        let tx = connection.unchecked_transaction()?;
        for row in first + written..first + written + batch {
            let subjects = vec![JournalSubject { kind: "terminal".into(), id: terminal.clone() }];
            let payload = json!({
                "terminal_id": terminal,
                "progress": {"state": "set", "value": row % 100},
                "synth_fill": progress_fill(row),
            });
            append_presentation_record(&tx, "terminal.progress", subjects, &payload)?;
        }
        tx.commit()?;
        written += batch;
    }
    query_journal_head(&connection)
}

/// A filler of the size of a `terminal.progress` record's, from `seed`.
fn progress_fill(seed: u64) -> String {
    let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..super::PROGRESS_FILL_BYTES)
        .map(|_| {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            // The top 6 bits: one of the 64 characters (`get`, so no index can panic).
            char::from(super::FILL_ALPHABET.get((state >> 58) as usize).copied().unwrap_or(b'A'))
        })
        .collect()
}

/// What the sparse part is after the cleanup.
#[derive(Debug, Clone, Default)]
pub struct SparseReport {
    /// The journal head when the cleanup ran.
    pub head: u64,
    /// Records of the shape's writers in the bursts.
    pub records: u64,
    /// Output rows of an older build's encoding, and with empty fields.
    pub output_rows: u64,
    pub empty_output_rows: u64,
    /// After the swap: the records the journal holds, its segments and its
    /// pruned ranges.
    pub kept: u64,
    pub segments: u64,
    pub pruned_ranges: u64,
    /// The registry file before the cleanup and after the swap.
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Stage, pack and swap.
    pub cleanup_seconds: f64,
    /// The journal head after [`super::ShapeOptions::sparse_stretch`] (0: not
    /// stretched).
    pub stretched_to: u64,
}

impl SparseReport {
    pub fn to_json(&self) -> Value {
        json!({
            "head": self.head,
            "records": self.records,
            "output_rows": self.output_rows,
            "empty_output_rows": self.empty_output_rows,
            "kept": self.kept,
            "segments": self.segments,
            "pruned_ranges": self.pruned_ranges,
            "bytes_before": self.bytes_before,
            "bytes_after": self.bytes_after,
            "cleanup_s": (self.cleanup_seconds * 10.0).round() / 10.0,
            "stretched_to": self.stretched_to,
        })
    }
}

impl Shape {
    /// Reads the size of the registry's log, keeps the largest, and copies
    /// the log into the file when it reached [`LOG_BYTES`].
    pub(super) fn bound_log(&mut self) -> anyhow::Result<()> {
        let registry = super::super::registry_path(&self.state_root, &self.options.session);
        let bytes = std::fs::metadata(sidecar_path(&registry, "-wal")).map_or(0, |log| log.len());
        self.counters.log_peak_bytes = self.counters.log_peak_bytes.max(bytes);
        if bytes >= LOG_BYTES {
            self.checkpoint()?;
        }
        Ok(())
    }

    /// Writes the sparse part and runs the first output cleanup on it (the
    /// module doc). `None` without [`super::ShapeOptions::sparse_head`]. The
    /// registry is open again at the end.
    pub(super) fn sparse_part(&mut self) -> anyhow::Result<Option<SparseReport>> {
        let target = self.options.sparse_head;
        if target == 0 {
            return Ok(None);
        }
        let bursts = self.options.sparse_records / BURST_RECORDS;
        let first = self.head()?;
        anyhow::ensure!(bursts > 0, "the sparse part needs --sparse-records");
        let span = target.saturating_sub(first) / bursts;
        anyhow::ensure!(
            span >= MIN_BURST_SPAN,
            "{bursts} bursts from sequence {first} to {target} leave {span} sequences a burst: \
             no room for a hole"
        );
        let mut report = SparseReport::default();
        let rows_before = self.counters.rows;
        for burst in 0..bursts {
            self.append(BURST_RECORDS)?;
            let stop = if burst + 1 == bursts { target } else { first + span * (burst + 1) };
            self.removed_rows(burst, stop, &mut report)?;
            self.bound_log()?;
            if self.options.progress && (burst + 1).is_multiple_of(10_000) {
                eprintln!("synth: sparse part, burst {} of {bursts}", burst + 1);
            }
        }
        {
            let registry = self.registry.as_ref().context("the generator's registry is closed")?;
            let connection = registry.connection.get();
            let tx = connection.unchecked_transaction()?;
            self.writer.save_output_offsets(&tx)?;
            tx.commit()?;
        }
        report.records = self.counters.rows - rows_before;
        report.head = self.head()?;
        anyhow::ensure!(report.head == target, "the sparse part ends at {}", report.head);
        self.close_registry()?;

        let registry_path = super::super::registry_path(&self.state_root, &self.options.session);
        report.bytes_before = std::fs::metadata(&registry_path)?.len();
        let started = Instant::now();
        let outcome = stage_registry(
            &registry_path,
            0,
            &StageControl {
                on_pending: &|| {},
                next_segment: &|| true,
                catch_up: &|| false,
                stopped: Arc::new(|| false),
            },
        )?;
        anyhow::ensure!(
            outcome == StageOutcome::Built,
            "the first output cleanup did not build the new registry: {outcome:?}"
        );
        // The open swaps, as an owner's start does.
        self.open_registry()?;
        report.cleanup_seconds = started.elapsed().as_secs_f64();
        let previous = previous_path(&registry_path);
        anyhow::ensure!(
            previous.is_file() && self.registry()?.output_cleanup_done()?,
            "the open after the first output cleanup did not swap the registry"
        );
        for suffix in ["", "-wal", "-shm"] {
            let mut path = previous.clone().into_os_string();
            path.push(suffix);
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(anyhow::Error::from(error)
                        .context("remove the file that the swap replaced"));
                }
            }
        }
        report.bytes_after = std::fs::metadata(&registry_path)?.len();
        if self.options.sparse_stretch > report.head {
            self.stretch(report.head, self.options.sparse_stretch)?;
            report.stretched_to = self.options.sparse_stretch;
            self.save_roster()?;
        }
        {
            let connection = self.registry()?.connection.get();
            let number = |sql: &str| -> anyhow::Result<u64> {
                Ok(u64::try_from(connection.query_row(sql, [], |row| row.get::<_, i64>(0))?)?)
            };
            report.kept = number(
                "SELECT (SELECT COUNT(*) FROM session_journal)
                      + (SELECT COALESCE(SUM(record_count), 0) FROM journal_segments)",
            )?;
            report.segments = number("SELECT COUNT(*) FROM journal_segments")?;
            report.pruned_ranges = number("SELECT COUNT(*) FROM journal_pruned_ranges")?;
        }
        if self.options.progress {
            eprintln!("synth: sparse part done: {}", report.to_json());
        }
        Ok(Some(report))
    }

    /// The rows of burst `burst` that the cleanup removes, through sequence
    /// `stop`.
    fn removed_rows(
        &mut self,
        burst: u64,
        stop: u64,
        report: &mut SparseReport,
    ) -> anyhow::Result<()> {
        let registry = self.registry.as_ref().context("the generator's registry is closed")?;
        let connection = registry.connection.get();
        let room = stop.saturating_sub(query_journal_head(&connection)?);
        anyhow::ensure!(room > BURST_OUTPUT_ROWS, "burst {burst} has no room for a hole");
        let tx = connection.unchecked_transaction()?;
        for _ in 0..BURST_OUTPUT_ROWS {
            self.writer.output(&tx)?;
        }
        let empty = room - BURST_OUTPUT_ROWS;
        let written = tx.execute(
            EMPTY_OUTPUT_ROWS,
            params![i64::try_from(empty)?, i64::try_from(burst)?, i64::try_from(unix_epoch_ms()?)?],
        )?;
        anyhow::ensure!(written as u64 == empty, "burst {burst}: {written} of {empty} rows");
        tx.commit()?;
        report.output_rows += BURST_OUTPUT_ROWS;
        report.empty_output_rows += empty;
        Ok(())
    }

    /// Moves the end of the journal from `from` to `to` (the module doc): the
    /// last packed segment, the pruned range that ends there, and the counter.
    fn stretch(&self, from: u64, to: u64) -> anyhow::Result<()> {
        let connection = self.registry()?.connection.get();
        connection.execute_batch(&format!(
            "BEGIN IMMEDIATE;
             {DROP_SEGMENT_TRIGGER}
             UPDATE journal_segments SET end_sequence = {to} WHERE end_sequence = {from};
             {SEGMENT_TRIGGER}
             UPDATE journal_pruned_ranges SET end_sequence = {to} WHERE end_sequence = {from};
             UPDATE sqlite_sequence SET seq = {to} WHERE name = 'session_journal';
             INSERT INTO sqlite_sequence(name, seq)
               SELECT 'session_journal', {to}
               WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'session_journal');
             COMMIT;"
        ))?;
        let moved: (i64, i64, i64) = connection.query_row(
            "SELECT (SELECT COUNT(*) FROM journal_segments WHERE end_sequence = ?1),
                    (SELECT COUNT(*) FROM journal_pruned_ranges WHERE end_sequence = ?1),
                    (SELECT COUNT(*) FROM sqlite_sequence
                      WHERE name = 'session_journal' AND seq = ?1)",
            [i64::try_from(to)?],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        anyhow::ensure!(
            moved == (1, 1, 1) && query_journal_head(&connection)? == to,
            "the stretch from {from} to {to} moved (segment, pruned range, counter) = {moved:?}"
        );
        Ok(())
    }
}
