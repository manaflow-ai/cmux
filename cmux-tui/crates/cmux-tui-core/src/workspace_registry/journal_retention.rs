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
//! What is gone is recorded as ONE pruned range `[1..=floor]`, so every
//! reader that crosses it (`output_cleanup::pruned_gap`) reads on from the
//! first retained record, and as `meta.journal_retention_floor`, so
//! `session.journal.subscribe` can refuse an older cursor with `cursor.gap`.

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::WorkspaceRegistry;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};

/// `meta` key of the sequence retention has deleted through.
const PRUNED_THROUGH_META_KEY: &str = "journal_retention_floor";

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
    tx.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
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
    Ok(limit)
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
