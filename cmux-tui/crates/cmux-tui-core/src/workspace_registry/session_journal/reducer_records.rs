//! Reducer records of sealed segments: a copy of each sealed record whose
//! kind a registered journal reducer folds, so a reducer's replay of sealed
//! history reads those records, not the segments around them.
//!
//! A kind-scoped read (#39183) skips a sealed segment whose kind map names
//! no kind the reducer folds, but `agent.*` records sit in every segment, so
//! an agent roster replay still inflated every segment and parsed every
//! 6 KB `personal.session.put` in it: 13.9 s of a 14.0 s start after a
//! roster version bump on an 8.4 GB registry (1.59M rows, 769 segments,
//! 64k agent records). Sealing now also writes the records of the folded
//! kinds to `journal_segment_reducer_records`, about 4% of the rows, and the
//! read takes them from there.
//!
//! A segment's rows are written in one transaction (its seal, or one
//! backfill step), so for each kind the table holds every record of that
//! kind in the segment or none. A read uses the rows when every kind it
//! accepts from the segment's kind map has rows there; otherwise (a segment
//! sealed by an older build, or before the backfill reached it) it decodes
//! the segment as before. Segments sealed before the table existed are
//! filled by the journal maintenance worker, a segment per step and never
//! at start ([`WorkspaceRegistry::plan_reducer_record_backfill`]).

use serde_json::json;

use super::*;

/// The kinds every reducer whose replays read sealed history by kind folds,
/// one predicate per reducer: today the agent roster's. A reducer added
/// here, or a predicate that accepts more kinds, needs
/// [`SEALED_REDUCER_KINDS_VERSION`] bumped: the backfill then visits every
/// segment again and adds the missing kinds' records.
pub(crate) const SEALED_REDUCER_KINDS: &[kind_read::JournalKinds] =
    &[crate::journal_reducers::AgentRoster::folds_kind];

/// The version of [`SEALED_REDUCER_KINDS`] the backfill cursor was made for.
const SEALED_REDUCER_KINDS_VERSION: u32 = 1;

/// In the backfill cursor: the cursor was written by a build that does not
/// trust a partly filled kind map to pass a segment over.
const KIND_MAP_RULE: u64 = 1;

/// The backfill's position: the last segment it finished.
const BACKFILL_META_KEY: &str = "journal_segment_reducer_records_backfill";

pub(crate) const REDUCER_RECORDS_SCHEMA: &str =
    "CREATE TABLE IF NOT EXISTS journal_segment_reducer_records (
       sequence INTEGER PRIMARY KEY NOT NULL CHECK(sequence > 0),
       segment_id TEXT NOT NULL,
       kind TEXT NOT NULL,
       record_json TEXT NOT NULL
     );";

/// Whether a sealed record of `kind` is kept for a reducer.
pub(crate) fn kept_for_reducers(kind: &str) -> bool {
    SEALED_REDUCER_KINDS.iter().any(|folds_kind| folds_kind(kind))
}

/// One kept record: its sequence, kind and archived JSON (the segment's own
/// encoding of it, [`journal_record_for_archive`]).
pub(crate) type ReducerRecordRow = (u64, String, String);

/// Write `segment_id`'s kept records. A row of the same sequence (one an
/// older build's output cleanup copied under the segment id it replaced) is
/// replaced.
pub(crate) fn insert_reducer_records(
    transaction: &Transaction<'_>,
    segment_id: &str,
    rows: &[ReducerRecordRow],
) -> anyhow::Result<()> {
    let mut insert = transaction.prepare(
        "INSERT OR REPLACE INTO journal_segment_reducer_records(
           sequence, segment_id, kind, record_json
         ) VALUES(?1, ?2, ?3, ?4)",
    )?;
    for (sequence, kind, record_json) in rows {
        insert.execute(params![i64::try_from(*sequence)?, segment_id, kind, record_json])?;
    }
    Ok(())
}

/// The kept records of `segment_id` (sequences `start..=end`) whose kind
/// `kinds` accepts, oldest first, or `None` when the table does not hold
/// every record of those kinds: one of `accepted` (the accepted kinds of the
/// segment's kind map) has no row. The caller then decodes the segment.
pub(super) fn sealed_reducer_records(
    connection: &Connection,
    segment_id: &str,
    start: u64,
    end: u64,
    accepted: &[&str],
    kinds: kind_read::JournalKinds,
) -> anyhow::Result<Option<Vec<SessionJournalRecord>>> {
    let mut statement = connection.prepare(
        "SELECT sequence, kind, record_json FROM journal_segment_reducer_records
         WHERE sequence >= ?1 AND sequence <= ?2 AND segment_id = ?3
         ORDER BY sequence ASC",
    )?;
    let rows = statement
        .query_map(params![i64::try_from(start)?, i64::try_from(end)?, segment_id], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let present = rows.iter().map(|(_, kind, _)| kind.as_str()).collect::<BTreeSet<_>>();
    if !accepted.iter().all(|kind| present.contains(kind)) {
        return Ok(None);
    }
    let mut records = Vec::new();
    for (sequence, kind, record_json) in rows {
        if !kinds(&kind) {
            continue;
        }
        let mut record = serde_json::from_str::<SessionJournalRecord>(&record_json)
            .with_context(|| format!("decode sealed reducer record {sequence}"))?;
        anyhow::ensure!(
            i64::try_from(record.sequence)? == sequence && record.kind == kind,
            "sealed reducer record {sequence} does not match its row"
        );
        normalize_terminal_output(&mut record, None)
            .with_context(|| format!("validate sealed reducer record {sequence}"))?;
        records.push(record);
    }
    Ok(Some(records))
}

/// A sealed segment the backfill decodes next.
pub(crate) struct ReducerRecordBackfill {
    segment_id: String,
    end_sequence: u64,
}

/// What the backfill does next.
pub(crate) enum ReducerRecordBackfillStep {
    /// Every sealed segment has its kept records.
    Done,
    /// It passed over segments that needed none; more may follow.
    Passed,
    /// Decode this segment.
    Decode(ReducerRecordBackfill),
}

/// One decoded segment's kept records, ready to commit.
pub(crate) struct PreparedReducerRecordBackfill {
    segment: ReducerRecordBackfill,
    rows: Vec<ReducerRecordRow>,
}

impl ReducerRecordBackfill {
    /// Decode the segment on `reader` (no registry lock) and keep its
    /// records of the reducers' kinds.
    pub(crate) fn prepare(
        self,
        reader: &SessionJournalReader,
    ) -> anyhow::Result<PreparedReducerRecordBackfill> {
        let segment = load_journal_segment(&reader.connection, &self.segment_id)?;
        let decoded = decode_journal_segment(&reader.connection, segment)?;
        let rows = decoded
            .records
            .iter()
            .filter(|record| kept_for_reducers(&record.kind))
            .map(|record| {
                let archived = journal_record_for_archive(record);
                Ok((record.sequence, record.kind.clone(), serde_json::to_string(&archived)?))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(PreparedReducerRecordBackfill { segment: self, rows })
    }
}

impl WorkspaceRegistry {
    /// The backfill's next step after its cursor. Segments that need no
    /// kept records (no kind a reducer folds, or rows already there: sealed
    /// by this build) are passed over here, up to `skip` of them, and the
    /// cursor moves past them.
    pub(crate) fn plan_reducer_record_backfill(
        &self,
        skip: usize,
    ) -> anyhow::Result<ReducerRecordBackfillStep> {
        let db = self.connection.get();
        let mut after = backfill_cursor(&db)?;
        let mut next = db.prepare(
            "SELECT segment_id, start_sequence, end_sequence FROM journal_segments
             WHERE end_sequence > ?1 ORDER BY end_sequence ASC LIMIT 1",
        )?;
        for _ in 0..skip {
            let Some((segment_id, start, end)) = next
                .query_row([i64::try_from(after)?], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
                })
                .optional()?
            else {
                return Ok(ReducerRecordBackfillStep::Done);
            };
            let (start, end) = (u64::try_from(start)?, u64::try_from(end)?);
            if segment_needs_reducer_records(&db, &segment_id, start, end)? {
                return Ok(ReducerRecordBackfillStep::Decode(ReducerRecordBackfill {
                    segment_id,
                    end_sequence: end,
                }));
            }
            write_backfill_cursor(&db, end, &segment_id)?;
            after = end;
        }
        Ok(ReducerRecordBackfillStep::Passed)
    }

    /// Commit one backfilled segment's kept records and move the cursor past
    /// it. False when the segment is gone (an output cleanup replaced it):
    /// the next plan starts again from the first segment.
    pub(crate) fn commit_reducer_record_backfill(
        &self,
        prepared: PreparedReducerRecordBackfill,
    ) -> anyhow::Result<bool> {
        let PreparedReducerRecordBackfill { segment, rows } = prepared;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let exists = tx
            .query_row(
                "SELECT 1 FROM journal_segments WHERE segment_id = ?1 AND end_sequence = ?2",
                params![segment.segment_id, i64::try_from(segment.end_sequence)?],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !exists {
            return Ok(false);
        }
        insert_reducer_records(&tx, &segment.segment_id, &rows)?;
        write_backfill_cursor(&tx, segment.end_sequence, &segment.segment_id)?;
        tx.commit()?;
        Ok(true)
    }
}

/// Whether every segment's kind map names all of its kinds. A segment's
/// map is written whole at its seal, but the legacy kind backfill (for
/// segments sealed before kind maps) inserts a kind at a time; while its
/// marker is `0` it stopped partway, and a map may lack some of the
/// segment's kinds until the next read on the registry finishes it.
fn kind_maps_complete(connection: &Connection) -> anyhow::Result<bool> {
    let marker = connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'journal_segment_kinds_backfill'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(marker.as_deref() != Some("0"))
}

/// Whether `segment_id` has a kind a reducer folds with no kept rows. A
/// segment with no kind map yet (sealed before kind maps) is decoded, and
/// so is one with no kept rows while kind maps may be partly filled: its
/// map could lack the folded kinds it holds. Kept rows come from a whole
/// segment (its seal or a backfill decode), so a segment that has any has
/// every folded kind's.
fn segment_needs_reducer_records(
    connection: &Connection,
    segment_id: &str,
    start: u64,
    end: u64,
) -> anyhow::Result<bool> {
    let mut mapped =
        connection.prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1")?;
    let mapped = mapped
        .query_map([segment_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if mapped.is_empty() {
        return Ok(true);
    }
    let mut kept = connection.prepare(
        "SELECT DISTINCT kind FROM journal_segment_reducer_records
         WHERE sequence >= ?1 AND sequence <= ?2 AND segment_id = ?3",
    )?;
    let kept = kept
        .query_map(params![i64::try_from(start)?, i64::try_from(end)?, segment_id], |row| {
            row.get::<_, String>(0)
        })?
        .collect::<Result<BTreeSet<_>, _>>()?;
    if kept.is_empty() && !kind_maps_complete(connection)? {
        return Ok(true);
    }
    Ok(mapped.iter().any(|kind| kept_for_reducers(kind) && !kept.contains(kind)))
}

/// The output cleanup's done marker (`output_cleanup::DONE_META_KEY`), which
/// every build's swap rewrites with its time: the cursor keeps the one it was
/// made under, so a cleanup since then shows.
fn cleanup_marker(connection: &Connection) -> anyhow::Result<Value> {
    let marker = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [output_cleanup::DONE_META_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(marker.map_or(Value::Null, Value::String))
}

/// The end sequence of the last segment the backfill finished. 0 (start
/// over) when there is none, when it was made for another version of the
/// reducer kinds or by a build that trusted a partly filled kind map,
/// when an output cleanup swapped the registry since (its
/// marker changed), or when that segment is gone. A cleanup of this build
/// deletes the cursor itself ([`forget_backfill`]); an older build's copies
/// it across, and repacks the segments under new ids, but a repacked
/// segment can keep the id of the one it replaced, so the cursor's segment
/// can survive while the earlier ones were rewritten without kept records.
fn backfill_cursor(connection: &Connection) -> anyhow::Result<u64> {
    let raw = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [BACKFILL_META_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    let Some(raw) = raw else { return Ok(0) };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else { return Ok(0) };
    if value.get("version").and_then(Value::as_u64) != Some(u64::from(SEALED_REDUCER_KINDS_VERSION))
    {
        return Ok(0);
    }
    if value.get("cleanup").unwrap_or(&Value::Null) != &cleanup_marker(connection)? {
        return Ok(0);
    }
    // A cursor without it was written by a build that passed segments over
    // on a partly filled kind map ([`segment_needs_reducer_records`]).
    if value.get("kind_map").and_then(Value::as_u64) != Some(KIND_MAP_RULE) {
        return Ok(0);
    }
    let (Some(through), Some(segment_id)) = (
        value
            .get("through")
            .and_then(Value::as_str)
            .and_then(|through| through.parse::<u64>().ok()),
        value.get("segment_id").and_then(Value::as_str),
    ) else {
        return Ok(0);
    };
    let exists = connection
        .query_row(
            "SELECT 1 FROM journal_segments WHERE segment_id = ?1 AND end_sequence = ?2",
            params![segment_id, i64::try_from(through)?],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    Ok(if exists { through } else { 0 })
}

/// Called by the output cleanup swap after it packed new segments, on the
/// new registry: the swap empties `journal_segment_reducer_records` (it is
/// one of the rebuilt tables), and a segment it packs can get the id of the
/// segment it replaces (ids hash the range and content), so the cursor it
/// copied across could still name an existing segment and skip the new ones.
/// The backfill starts over from the first segment.
pub(crate) fn forget_backfill(connection: &Connection) -> anyhow::Result<()> {
    connection.execute("DELETE FROM main.meta WHERE key = ?1", [BACKFILL_META_KEY])?;
    Ok(())
}

fn write_backfill_cursor(
    connection: &Connection,
    through: u64,
    segment_id: &str,
) -> anyhow::Result<()> {
    let value = json!({
        "version": SEALED_REDUCER_KINDS_VERSION,
        "through": through.to_string(),
        "segment_id": segment_id,
        "cleanup": cleanup_marker(connection)?,
        "kind_map": KIND_MAP_RULE,
    });
    connection.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![BACKFILL_META_KEY, value.to_string()],
    )?;
    Ok(())
}
