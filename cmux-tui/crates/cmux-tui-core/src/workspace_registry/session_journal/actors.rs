//! The actor of a journal record (plans/cmux-next/identity.md section 3, P8
//! landing 2c). A live record keeps it in `session_journal.actor`. Sealing
//! moves it to `journal_segments.actors_json` (sequence -> actor), never into
//! the record JSON, so a daemon from before this landing still decodes every
//! segment. The wire form of a record does not carry it yet.

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

/// The actor the mutation ledger stored for `idempotency_key`, if any. The
/// mutation row comes first; a close writes both rows with the receipt's actor.
pub(crate) fn ledger_actor(
    transaction: &Transaction<'_>,
    idempotency_key: &str,
) -> anyhow::Result<Option<String>> {
    let actor = transaction
        .query_row(
            "SELECT actor FROM (
               SELECT 0 AS rank, actor FROM resource_mutations WHERE idempotency_key = ?1
               UNION ALL
               SELECT 1, actor FROM resource_effect_receipts WHERE idempotency_key = ?1
             ) ORDER BY rank LIMIT 1",
            [idempotency_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(actor)
}

/// The actor of a resource journal record for `idempotency_key`. A migrated
/// legacy revision (`fresh` false) has none, and its ledgers may predate the
/// column. A fresh record is its resource ledger row's; a terminal or
/// workspace registry commit writes no such row, so it is the actor of its
/// `terminal_mutations` or `mutations` row (`origin`, `idempotency_key`; NULL
/// there reads `legacy`, P8 landing 3b); with no row at all, the daemon's own.
pub(crate) fn resource_record_actor(
    transaction: &Transaction<'_>,
    origin: &str,
    idempotency_key: &str,
    fresh: bool,
) -> anyhow::Result<Option<String>> {
    if !fresh {
        return Ok(None);
    }
    if let Some(actor) = ledger_actor(transaction, idempotency_key)? {
        return Ok(Some(actor));
    }
    for table in ["terminal_mutations", "mutations"] {
        let sql = format!(
            "SELECT COALESCE(actor, '{}') FROM {table} WHERE origin = ?1 AND mutation_id = ?2",
            crate::Actor::Legacy.wire()
        );
        let actor = transaction
            .query_row(&sql, params![origin, idempotency_key], |row| row.get::<_, String>(0))
            .optional()?;
        if actor.is_some() {
            return Ok(actor);
        }
    }
    Ok(Some(crate::Actor::Daemon.wire()))
}

/// The actor of record `sequence`, from its live row or from the segment
/// that sealed it. `None`: no actor was stored (legacy) or no such record.
/// Read by tests until the wire carries the actor (`journal-actor-v1`).
#[cfg_attr(not(test), expect(dead_code, reason = "journal-actor-v1 reads it later"))]
pub(crate) fn journal_actor(
    connection: &Connection,
    sequence: u64,
) -> anyhow::Result<Option<String>> {
    let sequence = i64::try_from(sequence)?;
    let live = connection
        .query_row("SELECT actor FROM session_journal WHERE sequence = ?1", [sequence], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()?;
    if let Some(actor) = live {
        return Ok(actor);
    }
    let sealed = connection
        .query_row(
            "SELECT actors_json FROM journal_segments
             WHERE ?1 BETWEEN start_sequence AND end_sequence",
            [sequence],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    let Some(sealed) = sealed else { return Ok(None) };
    let mut actors: BTreeMap<String, String> = serde_json::from_str(&sealed)?;
    Ok(actors.remove(&sequence.to_string()))
}

/// The `actors_json` of a segment that seals live records
/// `start..=end`: their stored actors by sequence, or `None` when none has one.
pub(crate) fn segment_actors_json(
    transaction: &Transaction<'_>,
    start: u64,
    end: u64,
) -> anyhow::Result<Option<String>> {
    let mut statement = transaction.prepare(
        "SELECT sequence, actor FROM session_journal
         WHERE sequence BETWEEN ?1 AND ?2 AND actor IS NOT NULL",
    )?;
    let actors = statement
        .query_map(params![i64::try_from(start)?, i64::try_from(end)?], |row| {
            Ok((row.get::<_, i64>(0)?.to_string(), row.get::<_, String>(1)?))
        })?
        .collect::<Result<BTreeMap<_, _>, _>>()?;
    Ok(if actors.is_empty() { None } else { Some(serde_json::to_string(&actors)?) })
}
