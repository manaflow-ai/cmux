//! Retention of the journal's own tables in a running daemon.
//!
//! Nothing deleted a sealed segment or its bookkeeping: one registry held
//! 9.65 GB with under 0.15 GB of state (2026-11-10: 3.41 GB of kept reducer
//! records, 2.02 GB of segments, 3.30 GB of subject index, 0.33 GB of
//! ingress receipts, 0.31 GB of event index). The maintenance worker now
//! deletes sealed segments at or below a floor, with every row that names
//! their records, a segment per transaction.
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

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::WorkspaceRegistry;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};

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
    for (reducer, version) in [
        (AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION),
        (AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION),
    ] {
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
        let kept_key = format!("journal_reducer_kept.{reducer_id}");
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

    /// Deletes the oldest sealed segment that ends at or below `floor`
    /// (never the newest one) with the rows of its records: kept reducer
    /// records, segment kinds, subject index, event index and ingress
    /// receipts, in one transaction of at most one segment (1,024 records).
    /// False when no such segment is left.
    pub(crate) fn prune_oldest_journal_segment(&mut self, floor: u64) -> anyhow::Result<bool> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let segment = tx
            .query_row(
                "SELECT segment_id, end_sequence FROM journal_segments
                 WHERE end_sequence <= ?1
                   AND end_sequence < (SELECT MAX(end_sequence) FROM journal_segments)
                 ORDER BY end_sequence ASC LIMIT 1",
                [i64::try_from(floor)?],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?;
        let Some((segment_id, end)) = segment else { return Ok(false) };
        // The tables refuse deletes by trigger; as the seal does for the
        // live rows it archives, this transaction alone may delete.
        tx.execute_batch(
            "DROP TRIGGER IF EXISTS journal_segments_reject_delete;
             DROP TRIGGER IF EXISTS journal_subject_index_reject_delete;",
        )?;
        for table in
            ["journal_segment_reducer_records", "journal_subject_index", "journal_event_index"]
        {
            tx.execute(&format!("DELETE FROM {table} WHERE sequence <= ?1"), [end])?;
        }
        tx.execute("DELETE FROM journal_ingress_receipts WHERE journal_sequence <= ?1", [end])?;
        tx.execute("DELETE FROM journal_segment_kinds WHERE segment_id = ?1", [&segment_id])?;
        tx.execute("DELETE FROM journal_segments WHERE segment_id = ?1", [&segment_id])?;
        note_journal_pruned_through(&tx, u64::try_from(end)?)?;
        tx.execute_batch(
            "CREATE TRIGGER IF NOT EXISTS journal_segments_reject_delete
               BEFORE DELETE ON journal_segments
             BEGIN
               SELECT RAISE(ABORT, 'journal segments are immutable');
             END;
             CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_delete
               BEFORE DELETE ON journal_subject_index
             BEGIN
               SELECT RAISE(ABORT, 'journal subject index is append-only');
             END;",
        )?;
        tx.commit()?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests;
