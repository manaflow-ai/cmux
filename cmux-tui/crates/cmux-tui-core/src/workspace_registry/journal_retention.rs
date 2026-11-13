//! Retention of the journal's own tables in a running daemon.
//!
//! Nothing deleted a sealed segment or its bookkeeping: one registry held
//! 9.65 GB with under 0.15 GB of state (2026-11-10: 3.41 GB of kept reducer
//! records, 2.02 GB of segments, 3.30 GB of subject index, 0.33 GB of
//! ingress receipts, 0.31 GB of event index). The maintenance worker now
//! deletes sealed segments at or below a floor, with every row that names
//! their records.
//!
//! One segment goes in more than one transaction, each in its own hold of
//! the registry lock, so a request never waits for a whole segment:
//!
//! 1. [`WorkspaceRegistry::begin_journal_segment_prune`] writes the reducer
//!    bases and moves the floor to the segment's end. It deletes nothing.
//! 2. [`WorkspaceRegistry::delete_pruned_segment_rows`] deletes the rows of
//!    [`RETENTION_RECORDS_PER_HOLD`] records, the lowest first, one hold a
//!    call.
//! 3. [`WorkspaceRegistry::finish_journal_segment_prune`] deletes the
//!    segment's row with its content, when no row of its records is left.
//!
//! A hold of step 2 deletes each row through each index of its table, and
//! each of those is a page of the file that the registry connection reads
//! under the lock: about 10,500 pages a hold on a generated registry of a
//! long-lived session, 85 % or more of the hold (2026-11-13). So before each
//! hold the pass reads those rows on a connection of its own, with no lock
//! ([`RetentionReadAhead`], the file `read_ahead.rs`): the hold then finds
//! its pages in the file cache of the system.
//!
//! Between two of those the segment is at or below the floor with rows for
//! a part of its records. No reader may take those rows for the segment:
//! a subject page starts above the floor, and a kind-scoped read decodes
//! such a segment from its content (which is whole until step 3). A kill
//! between two transactions leaves that same state; the next pass selects
//! the segment again by its end and goes on. No marker is stored.
//!
//! The delete triggers of `journal_segments` and `journal_subject_index`
//! refuse a row above `meta.journal_retention_floor` and let a row at or
//! below it go, so the pass changes no schema.
//!
//! The floor is the end of a sealed segment that no reader still needs:
//! at or below the oldest kept checkpoint (a restore preview reads after
//! it), the saved agent roster cursor and the saved agent history cursor
//! (both reducers hold what they folded in their snapshot), and every
//! enabled hook's cursor and oldest unfinished delivery. A reducer state of
//! another version, or one with a rebuild pending, folds from the first
//! record again: it holds the floor at 0. The newest segment always stays,
//! so the journal head never moves back.
//!
//! The readers' cursors are not the whole rule. A client can ask for a
//! checkpoint after each record, and the newest 16 are then on the newest 16
//! records. So a minimum window always stays, whatever the cursors say: the
//! newest [`MIN_RETAINED_RECORDS`] records, and each segment sealed in the
//! last [`MIN_RETAINED_AGE_MS`] (at most [`MAX_AGE_RETAINED_RECORDS`]
//! records, so a commit storm stays bounded). An ingress receipt is deleted
//! with its record's segment and has no time of its own: the age window is
//! the time in which a retry with the same key is still a replay.
//!
//! Every term is in [`retention_limit`], behind [`journal_retention_floor`]:
//! the maintenance worker, the cleanup worker and the swap at open read the
//! same floor from the registry alone.
//!
//! What is gone is recorded as ONE pruned range `[1..=floor]`, so every
//! reader that crosses it (`output_cleanup::pruned_gap`) reads on from the
//! first retained record, and as `meta.journal_retention_floor`, so
//! `session.journal.subscribe` can refuse an older cursor with `cursor.gap`.
//!
//! A reducer's saved state is then the only copy of what it folded below
//! the floor, under a key that every build writes. So the transaction that
//! moves the floor first copies it to the reducer's base ([`base`]), and a
//! floor that has no base does not move.

mod base;
mod read_ahead;

pub(crate) use base::{reducer_bases_possible, save_reducer_bases, usable_reducer_base};
pub(crate) use read_ahead::RetentionReadAhead;
use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::WorkspaceRegistry;
use crate::journal_reducers::AGENT_ROSTER_REDUCER_ID;

/// `meta` key of the sequence retention has deleted through.
pub(crate) const PRUNED_THROUGH_META_KEY: &str = "journal_retention_floor";

/// The newest records that always stay: one full segment
/// (`JOURNAL_SEGMENT_RECORD_LIMIT`).
const MIN_RETAINED_RECORDS: u64 = 1_024;
/// A segment sealed less than this long ago stays, with the receipts of its
/// records: the time in which an ingress retry with the same key is a replay.
const MIN_RETAINED_AGE_MS: u64 = 60 * 60 * 1_000;
/// The most records the age window holds below the head (64 full segments).
/// It bounds the tables under a commit storm, and it bounds what a wall
/// clock that went back can hold. It also bounds the read of the window: a
/// segment's seal time is stored after its content, so SQLite walks the
/// content's pages to read it.
const MAX_AGE_RETAINED_RECORDS: u64 = 65_536;

/// Records whose rows one hold of the registry lock deletes
/// ([`WorkspaceRegistry::delete_pruned_segment_rows`]): a quarter of a full
/// segment. A full segment in one hold was up to 2.2 s of the registry lock
/// on a busy Mac (the delete's own page writes: about 12 subject rows a
/// record, each in two B-trees).
pub(crate) const RETENTION_RECORDS_PER_HOLD: u64 = 256;

/// The tables with a row for each record, and their sequence column.
const PRUNED_ROW_TABLES: [(&str, &str); 4] = [
    ("journal_segment_reducer_records", "sequence"),
    ("journal_subject_index", "sequence"),
    ("journal_event_index", "sequence"),
    ("journal_ingress_receipts", "journal_sequence"),
];

/// A step of the retention pass that a test looks at
/// ([`RETENTION_STEP_FOR_TEST`]).
#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RetentionStep {
    /// The rows of the hold that deletes through this record were read on a
    /// connection that the registry lock does not guard. The read is over.
    ReadBeforeHold { through: i64 },
    /// One hold deletes the rows of the records through this one
    /// ([`WorkspaceRegistry::delete_pruned_segment_rows`]). Inside the hold.
    RowHold { through: i64 },
    /// The records of the sealed segments at or below a floor are read
    /// (`output_cleanup::stage`): a row seek for each of those segments.
    FloorCut,
}

#[cfg(test)]
thread_local! {
    /// Test seam: runs on this thread at each [`RetentionStep`].
    pub(crate) static RETENTION_STEP_FOR_TEST: std::cell::RefCell<Option<Box<dyn FnMut(RetentionStep)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(crate) fn retention_step_for_test(step: RetentionStep) {
    // Taken while it runs: the seam may wait for the registry lock.
    let hook = RETENTION_STEP_FOR_TEST.with(|slot| slot.borrow_mut().take());
    if let Some(mut hook) = hook {
        hook(step);
        RETENTION_STEP_FOR_TEST.with(|slot| *slot.borrow_mut() = Some(hook));
    }
}

/// A sealed segment whose delete began: the floor is at its `end`.
#[derive(Debug)]
pub(crate) struct PrunedSegment {
    segment_id: String,
    end: u64,
    records: u64,
}

impl PrunedSegment {
    /// The records the segment holds.
    pub(crate) fn records(&self) -> u64 {
        self.records
    }
}

/// The last record of the next row hold of a segment that ends at `end`:
/// the [`RETENTION_RECORDS_PER_HOLD`]th lowest record that still has a row
/// at or below `end`, or `end` when fewer records have one. Each table
/// gives its lowest sequences from its own index, so the read is of one
/// hold's rows and not of the segment's.
///
/// The hold and the read before it ([`RetentionReadAhead::read_hold_rows`])
/// both ask here, so they name the same rows. A second bound of a hold (its
/// subject rows, say) is one more term of this statement.
fn hold_through(connection: &Connection, end: i64) -> anyhow::Result<i64> {
    let last: Option<i64> = connection
        .prepare_cached(
            "SELECT sequence FROM (
               SELECT sequence FROM (
                 SELECT sequence FROM journal_segment_reducer_records
                 WHERE sequence <= ?1 ORDER BY sequence LIMIT ?2)
               UNION
               SELECT sequence FROM (
                 SELECT DISTINCT sequence FROM journal_subject_index
                 WHERE sequence <= ?1 ORDER BY sequence LIMIT ?2)
               UNION
               SELECT sequence FROM (
                 SELECT sequence FROM journal_event_index
                 WHERE sequence <= ?1 ORDER BY sequence LIMIT ?2)
               UNION
               SELECT journal_sequence FROM (
                 SELECT journal_sequence FROM journal_ingress_receipts
                 WHERE journal_sequence <= ?1 ORDER BY journal_sequence LIMIT ?2)
             ) ORDER BY sequence LIMIT 1 OFFSET ?2 - 1",
        )?
        .query_row(params![end, i64::try_from(RETENTION_RECORDS_PER_HOLD)?], |row| row.get(0))
        .optional()?;
    // Fewer records than a hold takes: all of them, through the end.
    Ok(last.unwrap_or(end))
}

/// The oldest sealed segment that ends at or below `floor`, never the
/// newest one: the next one the retention pass deletes.
fn oldest_segment_at_or_below(
    connection: &Connection,
    floor: u64,
) -> anyhow::Result<Option<PrunedSegment>> {
    let segment = connection
        .query_row(
            "SELECT segment_id, end_sequence, record_count FROM journal_segments
             WHERE end_sequence <= ?1
               AND end_sequence < (SELECT MAX(end_sequence) FROM journal_segments)
             ORDER BY end_sequence ASC LIMIT 1",
            [i64::try_from(floor)?],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    let Some((segment_id, end, records)) = segment else { return Ok(None) };
    Ok(Some(PrunedSegment {
        segment_id,
        end: u64::try_from(end)?,
        records: u64::try_from(records)?,
    }))
}

/// The retention floor of the registry behind `connection`: every sealed
/// segment that ends at or below it, and every index, receipt and kept
/// reducer row of a record at or below it, may be deleted. It is the end of
/// a sealed segment, or 0 (keep all). It never goes down: it is at least
/// what retention already deleted through.
pub(crate) fn journal_retention_floor(connection: &Connection) -> anyhow::Result<u64> {
    let pruned_through = journal_pruned_through(connection)?;
    let limit = i64::try_from(retention_limit(connection)?).unwrap_or(i64::MAX);
    let floor: i64 = connection.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments
         WHERE end_sequence <= ?1
           AND end_sequence < (SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments)",
        [limit],
        |row| row.get(0),
    )?;
    Ok(u64::try_from(floor)?.max(pruned_through))
}

/// The sequence retention has deleted through (0: nothing yet).
pub(crate) fn journal_pruned_through(connection: &Connection) -> anyhow::Result<u64> {
    let raw = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [PRUNED_THROUGH_META_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(raw.and_then(|raw| raw.parse().ok()).unwrap_or(0))
}

/// Records that everything at or below `floor` is gone: the `meta` floor and
/// one pruned range from the first sequence, merged with the ranges it
/// covers or touches. Call it in the transaction that deletes those rows.
pub(crate) fn note_journal_pruned_through(tx: &Transaction<'_>, floor: u64) -> anyhow::Result<()> {
    if floor == 0 {
        return Ok(());
    }
    let floor_sequence = i64::try_from(floor)?;
    // A range output cleanup left across the floor ends after it.
    let merged_end: i64 = tx.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_pruned_ranges
         WHERE start_sequence <= ?1 + 1",
        [floor_sequence],
        |row| row.get(0),
    )?;
    tx.execute(
        "DELETE FROM journal_pruned_ranges WHERE start_sequence <= ?1 + 1",
        [floor_sequence],
    )?;
    tx.execute(
        "INSERT INTO journal_pruned_ranges(start_sequence, end_sequence) VALUES(1, ?1)",
        [merged_end.max(floor_sequence)],
    )?;
    // The floor in `meta` never goes down. The swap at open records the
    // floor of its cut (output_cleanup/swap.rs) and a segment at or below
    // that floor can stay: its delete here must not lower the key, or a
    // cursor between the two values reads a hole with no `cursor.gap`.
    tx.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value
         WHERE CAST(meta.value AS INTEGER) < CAST(excluded.value AS INTEGER)",
        params![PRUNED_THROUGH_META_KEY, floor.to_string()],
    )?;
    Ok(())
}

/// The lowest sequence a reader still needs everything after.
fn retention_limit(connection: &Connection) -> anyhow::Result<u64> {
    let minimum = |sql: &str| -> anyhow::Result<Option<u64>> {
        let value: Option<i64> = connection.query_row(sql, [], |row| row.get(0))?;
        Ok(value.map(u64::try_from).transpose()?)
    };
    // No checkpoint: nothing proves a restore can do without the records.
    let Some(mut limit) = minimum("SELECT MIN(source_sequence) FROM journal_checkpoints")? else {
        return Ok(0);
    };
    let roster_rebuilds = connection
        .query_row(
            "SELECT 1 FROM meta WHERE key = ?1",
            [format!("journal_reducer_rebuild.{AGENT_ROSTER_REDUCER_ID}")],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if roster_rebuilds {
        return Ok(0);
    }
    for (reducer, version) in base::FLOOR_REDUCERS {
        limit = limit.min(reducer_cursor(connection, reducer, version)?);
    }
    if let Some(cursor) =
        minimum("SELECT MIN(cursor_sequence) FROM journal_hooks WHERE enabled = 1")?
    {
        limit = limit.min(cursor);
    }
    if let Some(event) = minimum(
        "SELECT MIN(d.event_sequence)
         FROM journal_hook_deliveries d
         JOIN journal_hooks h
           ON h.hook_id = d.hook_id AND h.manifest_version = d.manifest_version
         WHERE h.enabled = 1 AND d.state IN ('scheduled', 'executing')",
    )? {
        limit = limit.min(event.saturating_sub(1));
    }
    minimum_window_limit(connection, limit)
}

/// `limit` lowered to the minimum window (see the module doc).
fn minimum_window_limit(connection: &Connection, limit: u64) -> anyhow::Result<u64> {
    let head: i64 = connection.query_row(
        "SELECT MAX(
           COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
           COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0)
         )",
        [],
        |row| row.get(0),
    )?;
    let head = u64::try_from(head)?;
    let limit = limit.min(head.saturating_sub(MIN_RETAINED_RECORDS));
    // Below this sequence a segment's age holds nothing.
    let age_bound = head.saturating_sub(MAX_AGE_RETAINED_RECORDS);
    if limit <= age_bound {
        return Ok(limit);
    }
    let sealed_before = super::unix_epoch_ms()?.saturating_sub(MIN_RETAINED_AGE_MS);
    // From `limit` down to the first segment that is old enough: one row on
    // a quiet registry, and never a row at or below `age_bound`.
    let aged: Option<i64> = connection
        .query_row(
            "SELECT end_sequence FROM journal_segments
             WHERE end_sequence <= ?1 AND end_sequence > ?2 AND sealed_at_ms <= ?3
             ORDER BY end_sequence DESC LIMIT 1",
            params![
                i64::try_from(limit)?,
                i64::try_from(age_bound)?,
                i64::try_from(sealed_before)?
            ],
            |row| row.get(0),
        )
        .optional()?;
    Ok(match aged {
        Some(end) => u64::try_from(end)?,
        // Every segment in the age window is young: all of them stay.
        None => age_bound,
    })
}

/// The saved cursor of `reducer` when its state is of `version`; 0 for no
/// state or another version (that reducer folds from the first record).
fn reducer_cursor(connection: &Connection, reducer: &str, version: u32) -> anyhow::Result<u64> {
    let saved = connection
        .query_row(
            "SELECT json_extract(value, '$.version'), json_extract(value, '$.cursor')
             FROM meta WHERE key = ?1",
            [format!("journal_reducer.{reducer}")],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()?;
    Ok(match saved {
        Some((Some(saved_version), Some(cursor))) if saved_version == i64::from(version) => {
            cursor.parse().unwrap_or(0)
        }
        _ => 0,
    })
}

/// The `meta` key prefix of a saved reducer state that a start could not
/// load and kept as it was ([`WorkspaceRegistry::keep_unloaded_reducer_state`]).
const KEPT_REDUCER_STATE_PREFIX: &str = "journal_reducer_kept.";

/// How many reducer states are kept that way: a range of the `meta` key.
pub(crate) fn kept_reducer_states(connection: &Connection) -> anyhow::Result<u64> {
    // The prefix with its last character raised by one ends the key range.
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM meta WHERE key >= ?1 AND key < ?2",
        params![KEPT_REDUCER_STATE_PREFIX, "journal_reducer_kept/"],
        |row| row.get(0),
    )?;
    Ok(u64::try_from(count).unwrap_or(0))
}

impl WorkspaceRegistry {
    pub(crate) fn journal_retention_floor(&self) -> anyhow::Result<u64> {
        journal_retention_floor(&self.connection.get())
    }

    pub(crate) fn journal_pruned_through(&self) -> anyhow::Result<u64> {
        journal_pruned_through(&self.connection.get())
    }

    /// Keeps the raw saved state of `reducer_id` under a second `meta` key,
    /// `journal_reducer_kept.<id>`. After retention deleted records, a saved
    /// reducer state is the only copy of what it folded below the floor. A
    /// start that cannot load it folds again from the first RETAINED record
    /// and its next save is smaller: it calls this first. The copy is the
    /// value as it is (it need not be JSON) and is made one time: a later
    /// state that does not load never replaces the copy of the first one.
    /// True when the second key holds a copy after the call (false: there
    /// is no saved state to keep).
    pub(crate) fn keep_unloaded_reducer_state(&self, reducer_id: &str) -> anyhow::Result<bool> {
        let db = self.connection.get();
        let kept_key = format!("{KEPT_REDUCER_STATE_PREFIX}{reducer_id}");
        db.execute(
            "INSERT INTO meta(key, value)
             SELECT ?1, value FROM meta WHERE key = ?2
             ON CONFLICT(key) DO NOTHING",
            params![kept_key, format!("journal_reducer.{reducer_id}")],
        )?;
        let kept = db
            .query_row("SELECT 1 FROM meta WHERE key = ?1", [&kept_key], |_| Ok(()))
            .optional()?;
        Ok(kept.is_some())
    }

    /// The segment that [`Self::begin_journal_segment_prune`] takes at
    /// `floor`, with its record count. It reads only: the pass asks before
    /// it writes, so a tick that may not write (no room in the WAL, or no
    /// room left for a delete in place in this start) begins no delete.
    pub(crate) fn journal_segment_to_prune(
        &self,
        floor: u64,
    ) -> anyhow::Result<Option<PrunedSegment>> {
        oldest_segment_at_or_below(&self.connection.get(), floor)
    }

    /// The first hold of the delete of one segment: the oldest sealed
    /// segment that ends at or below `floor` (never the newest one). It
    /// writes the reducer bases and moves the floor to the segment's end,
    /// and deletes no row. From this commit each reader answers from the
    /// floor (see the module doc), so the rows can go in more than one
    /// transaction. `None` when no such segment is left, or when a reducer
    /// can have no base at that floor.
    pub(crate) fn begin_journal_segment_prune(
        &mut self,
        floor: u64,
    ) -> anyhow::Result<Option<PrunedSegment>> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let Some(segment) = oldest_segment_at_or_below(&tx, floor)? else { return Ok(None) };
        // The saved reducer states are the only copy of what this delete
        // takes from the journal: each gets its base first. A state that
        // cannot be a base (another version, a rebuild owed) leaves the
        // segment: `retention_limit` gives no floor for such a state, so
        // only a caller with a floor of its own comes here.
        if !save_reducer_bases(&tx, "main", segment.end)? {
            return Ok(None);
        }
        note_journal_pruned_through(&tx, segment.end)?;
        tx.commit()?;
        Ok(Some(segment))
    }

    /// One hold of the rows of `segment`: each kept reducer record, subject
    /// row, event index row and ingress receipt of the
    /// [`RETENTION_RECORDS_PER_HOLD`] lowest records that still have a row
    /// at or below the segment's end, in one transaction. True when rows of
    /// more records can be left. The delete triggers let these rows go: the
    /// floor is at or above them since [`Self::begin_journal_segment_prune`].
    pub(crate) fn delete_pruned_segment_rows(
        &mut self,
        segment: &PrunedSegment,
    ) -> anyhow::Result<bool> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let end = i64::try_from(segment.end)?;
        // The last record of this hold, asked again under the lock: the
        // hold is right with no read before it.
        let through = hold_through(&tx, end)?;
        #[cfg(test)]
        retention_step_for_test(RetentionStep::RowHold { through });
        for (table, column) in PRUNED_ROW_TABLES {
            tx.prepare_cached(&format!("DELETE FROM {table} WHERE {column} <= ?1"))?
                .execute([through])?;
        }
        tx.commit()?;
        Ok(through < end)
    }

    /// The last hold of the delete of `segment`: its kind map and its row
    /// with the content, when no row of a record at or below its end is
    /// left. False when a row is left (the backfill of kept reducer records
    /// can write rows of a segment again between two holds): the caller
    /// deletes rows again, and the content stays until then, so a kept row
    /// never outlives the segment it is a copy of.
    pub(crate) fn finish_journal_segment_prune(
        &mut self,
        segment: &PrunedSegment,
    ) -> anyhow::Result<bool> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let end = i64::try_from(segment.end)?;
        for (table, column) in PRUNED_ROW_TABLES {
            let left = tx
                .prepare_cached(&format!("SELECT 1 FROM {table} WHERE {column} <= ?1 LIMIT 1"))?
                .query_row([end], |_| Ok(()))
                .optional()?;
            if left.is_some() {
                return Ok(false);
            }
        }
        tx.execute(
            "DELETE FROM journal_segment_kinds WHERE segment_id = ?1",
            [&segment.segment_id],
        )?;
        tx.execute("DELETE FROM journal_segments WHERE segment_id = ?1", [&segment.segment_id])?;
        tx.commit()?;
        Ok(true)
    }
}

#[cfg(test)]
mod hold_tests;
#[cfg(test)]
mod part_deleted_tests;
#[cfg(test)]
mod read_ahead_tests;
#[cfg(test)]
mod tests;
