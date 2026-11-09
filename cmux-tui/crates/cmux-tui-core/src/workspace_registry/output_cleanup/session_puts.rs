//! Superseded `personal.session.put` records: the cleanup drops them with
//! the output. One registry (59 GB, 2026-11-09) held about 11.5M of them,
//! most for one session id that a loop re-put every 1-50 ms, so its kept
//! records passed [`super::MAX_KEPT_RECORDS`] and the cleanup refused.
//!
//! A put is the fact of one `put-session` write (`personal_mutations.rs`
//! `put_session_in`); the state itself is the `sessions` row, which the swap
//! copies as is. What reads the put records:
//!
//! - The history feed skips every `personal.*` kind (`history_ops/
//!   journal_feed.rs` `read_kind`); the agent roster reads only its own
//!   kinds (`session_journal/kind_read.rs`).
//! - No reducer folds them: the checkpoint reducer folds journal, hook,
//!   terminal and resource-change records (`journal_checkpoint.rs`
//!   `apply_required_record`), and a put carries no `changes`.
//! - Nothing rebuilds personal state from the journal: `personal-changed`
//!   names the `personal_revision` counter, and frontends refetch
//!   `list-personal` from the tables (`mux/personal.rs`).
//! - A put has no resource revision and no causation id
//!   (`presentation_store.rs` `append_presentation_record`), so no revision
//!   chain runs through it and no record names it as a cause, except a
//!   hook's delivery of it: the swap abandons a pending one, as it does for
//!   removed output.
//! - Journal readers past a removed sequence (streams, cursors, hooks,
//!   checkpoints) accept the gap through `journal_pruned_ranges`, which the
//!   swap's pack writes for every run with no kept record.
//!
//! The rule. Within the journal up to `puts_bound` (the head when staging
//! began; nothing after it is dropped), a put of session `S` is dropped when
//! a later put of `S` exists there and the put did not create the session
//! (`created: true` stays). So each session keeps its latest put and its
//! creating puts. The later put is known two ways, both without inflating a
//! segment twice:
//!
//! - Live rows (after the archive when staging began): one pass over their
//!   puts records each session's latest put
//!   (`output_cleanup_session_puts`), before any segment is staged.
//! - Sealed segments, staged in order: a session with no live put holds its
//!   latest put so far (`output_cleanup_held_puts`, counted kept in its
//!   segment); a later put of that session drops it and takes the place.
//!   When every segment is staged, the held puts are staged as kept.
//!
//! Memory is one entry per session id (thousands), never per record.

use std::collections::HashMap;

use rusqlite::{Connection, Transaction, params};
use serde::Deserialize;
use serde_json::Value;

use super::super::session_journal::MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES;
use super::chunks::{CHUNK_RECORD_LIMIT, StagedRecord, insert_chunk};
use super::stage::state;

pub(super) const SESSION_PUT_KIND: &str = "personal.session.put";

pub(super) const SESSION_PUTS_SCHEMA: &str = "CREATE TABLE output_cleanup_session_puts (
       session_id TEXT PRIMARY KEY NOT NULL,
       sequence INTEGER NOT NULL
     ) WITHOUT ROWID;
     CREATE TABLE output_cleanup_held_puts (
       session_id TEXT PRIMARY KEY NOT NULL,
       sequence INTEGER UNIQUE NOT NULL,
       json BLOB NOT NULL,
       actor TEXT
     );";

/// The staging state keys of this module and their initial values.
pub(super) const SESSION_PUTS_STATE: [(&str, &str); 4] = [
    // Empty until the live puts were read.
    ("puts_bound", ""),
    ("puts_archive_end", "0"),
    ("puts_live_kept", "0"),
    ("puts_released", "0"),
];

#[derive(Deserialize)]
struct PutSession {
    #[serde(default)]
    session_id: Option<String>,
}

#[derive(Deserialize)]
struct PutPayload {
    #[serde(default)]
    session: Option<PutSession>,
    #[serde(default)]
    created: Option<bool>,
}

#[derive(Deserialize)]
struct PutRecord {
    #[serde(default)]
    payload: Option<PutPayload>,
}

/// A put's session id and whether it may be dropped (it did not create the
/// session). A payload without a session id or a `created` flag names no
/// session here: it is kept and supersedes nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Put {
    pub(super) session: String,
    pub(super) droppable: bool,
}

impl Put {
    fn from_payload(payload: PutPayload) -> Option<Self> {
        let session = payload.session?.session_id?;
        Some(Self { session, droppable: !payload.created? })
    }

    /// From a record's archived JSON.
    pub(super) fn from_record(kind: &str, json: &[u8]) -> Option<Self> {
        if kind != SESSION_PUT_KIND {
            return None;
        }
        Self::from_payload(serde_json::from_slice::<PutRecord>(json).ok()?.payload?)
    }

    /// From a decoded record's payload.
    pub(super) fn from_value(kind: &str, payload: &Value) -> Option<Self> {
        if kind != SESSION_PUT_KIND {
            return None;
        }
        Self::from_payload(PutPayload::deserialize(payload).ok()?)
    }
}

/// Session id to (its latest put, whether that put may be dropped).
type LatestPuts = HashMap<String, (u64, bool)>;

/// Reads the live puts once, before any segment is staged, in one read
/// snapshot of `source`: each session's latest put and how many live puts
/// stay. Done once per staging file.
pub(super) fn record_live_puts(source: &Connection, staging: &Connection) -> anyhow::Result<()> {
    if !state(staging, "puts_bound")?.is_empty() {
        return Ok(());
    }
    source.execute_batch("BEGIN DEFERRED")?;
    let read = (|| -> anyhow::Result<(i64, i64, LatestPuts, u64)> {
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
        let mut latest = LatestPuts::new();
        let mut puts = 0_u64;
        let mut dropped = 0_u64;
        let mut statement = source.prepare(
            "SELECT sequence, payload_json
             FROM session_journal INDEXED BY session_journal_by_kind_sequence
             WHERE kind = ?1 AND sequence > ?2 AND sequence <= ?3
             ORDER BY sequence ASC",
        )?;
        let mut rows = statement.query(params![SESSION_PUT_KIND, archive_end, head])?;
        while let Some(row) = rows.next()? {
            puts = puts.saturating_add(1);
            let sequence = u64::try_from(row.get::<_, i64>(0)?)?;
            let payload = row.get_ref(1)?.as_str()?;
            let Some(put) =
                serde_json::from_str::<PutPayload>(payload).ok().and_then(Put::from_payload)
            else {
                continue;
            };
            if let Some((_, true)) = latest.insert(put.session, (sequence, put.droppable)) {
                dropped = dropped.saturating_add(1);
            }
        }
        Ok((archive_end, head, latest, puts.saturating_sub(dropped)))
    })();
    source.execute_batch("COMMIT")?;
    let (archive_end, head, latest, live_kept) = read?;
    let tx = staging.unchecked_transaction()?;
    {
        let mut insert = tx.prepare(
            "INSERT INTO output_cleanup_session_puts(session_id, sequence) VALUES(?1, ?2)",
        )?;
        for (session, (sequence, _)) in &latest {
            insert.execute(params![session, i64::try_from(*sequence)?])?;
        }
    }
    for (key, value) in [
        ("puts_bound", head.to_string()),
        ("puts_archive_end", archive_end.to_string()),
        ("puts_live_kept", live_kept.to_string()),
    ] {
        tx.execute(
            "UPDATE output_cleanup_state SET value = ?1 WHERE key = ?2",
            params![value, key],
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// A put held while the sealed segments are staged: the latest so far of a
/// session with no live put.
struct Held {
    sequence: u64,
    json: Vec<u8>,
    actor: Option<String>,
}

/// What [`SessionPuts::split_segment`] keeps of one segment.
pub(super) struct SegmentPuts {
    /// Records staged now.
    pub(super) staged: Vec<StagedRecord>,
    /// Puts of this segment still held after it: counted kept in it.
    pub(super) held: u64,
    /// Held puts of earlier segments that a put of this one superseded.
    pub(super) superseded: Vec<u64>,
    /// Sessions whose held put changed.
    changed: Vec<String>,
}

/// The staging file's record of the superseded puts.
pub(super) struct SessionPuts {
    /// Nothing after this sequence is dropped; 0 when the live puts were
    /// never read (nothing is dropped).
    bound: u64,
    /// The archive end when the live puts were read: only sealed puts at or
    /// before it can be held.
    archive_end: u64,
    /// Live puts at or before `bound` that stay.
    live_kept: u64,
    released: bool,
    latest: HashMap<String, u64>,
    held: HashMap<String, Held>,
}

impl SessionPuts {
    /// The record in `staging` (main schema, or the staging file the swap
    /// builds in).
    pub(super) fn load(staging: &Connection) -> anyhow::Result<Self> {
        let number = |key: &str| -> anyhow::Result<u64> {
            let value = state(staging, key)?;
            Ok(if value.is_empty() { 0 } else { value.parse()? })
        };
        let latest = {
            let mut statement =
                staging.prepare("SELECT session_id, sequence FROM output_cleanup_session_puts")?;
            let rows = statement
                .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?;
            let mut latest = HashMap::new();
            for row in rows {
                let (session, sequence) = row?;
                latest.insert(session, u64::try_from(sequence)?);
            }
            latest
        };
        let held = {
            let mut statement = staging.prepare(
                "SELECT session_id, sequence, json, actor FROM output_cleanup_held_puts",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })?;
            let mut held = HashMap::new();
            for row in rows {
                let (session, sequence, json, actor) = row?;
                held.insert(session, Held { sequence: u64::try_from(sequence)?, json, actor });
            }
            held
        };
        Ok(Self {
            bound: number("puts_bound")?,
            archive_end: number("puts_archive_end")?,
            live_kept: number("puts_live_kept")?,
            released: state(staging, "puts_released")? == "1",
            latest,
            held,
        })
    }

    pub(super) fn bound(&self) -> u64 {
        self.bound
    }

    pub(super) fn live_kept(&self) -> u64 {
        self.live_kept
    }

    /// True when the put at `sequence` is dropped because a later live put of
    /// its session exists (at or before the bound).
    pub(super) fn drops(&self, sequence: u64, put: &Put) -> bool {
        put.droppable
            && sequence <= self.bound
            && self.latest.get(&put.session).is_some_and(|latest| sequence < *latest)
    }

    /// Splits the non-output records of one sealed segment, in sequence
    /// order: staged now, held, or dropped. `start` is the segment's first
    /// sequence.
    pub(super) fn split_segment(&mut self, records: Vec<StagedRecord>, start: u64) -> SegmentPuts {
        let mut split = SegmentPuts {
            staged: Vec::with_capacity(records.len()),
            held: 0,
            superseded: Vec::new(),
            changed: Vec::new(),
        };
        for record in records {
            let sequence = record.0;
            let Some(put) = Put::from_record(&record.1, &record.2) else {
                split.staged.push(record);
                continue;
            };
            if sequence > self.bound || self.latest.contains_key(&put.session) {
                if !self.drops(sequence, &put) {
                    split.staged.push(record);
                }
                continue;
            }
            if self.released || sequence > self.archive_end {
                split.staged.push(record);
                continue;
            }
            // A later put of a session with no live put: the held one goes.
            if let Some(previous) = self.held.remove(&put.session) {
                if previous.sequence < start {
                    split.superseded.push(previous.sequence);
                } else {
                    split.held = split.held.saturating_sub(1);
                }
                split.changed.push(put.session.clone());
            }
            if put.droppable {
                let (sequence, _, json, actor) = record;
                self.held.insert(put.session.clone(), Held { sequence, json, actor });
                split.held = split.held.saturating_add(1);
                split.changed.push(put.session);
            } else {
                split.staged.push(record);
            }
        }
        split
    }

    /// Writes the held puts `split` changed, and moves each superseded one
    /// from kept to removed in its segment's counts, inside the segment's
    /// staging transaction.
    pub(super) fn record_split(
        &self,
        tx: &Transaction<'_>,
        split: &SegmentPuts,
    ) -> anyhow::Result<()> {
        for session in &split.changed {
            tx.execute("DELETE FROM output_cleanup_held_puts WHERE session_id = ?1", [session])?;
            if let Some(held) = self.held.get(session) {
                tx.execute(
                    "INSERT INTO output_cleanup_held_puts(session_id, sequence, json, actor)
                     VALUES(?1, ?2, ?3, ?4)",
                    params![session, i64::try_from(held.sequence)?, held.json, held.actor],
                )?;
            }
        }
        for sequence in &split.superseded {
            let changed = tx.execute(
                "UPDATE output_cleanup_segments SET kept = kept - 1, removed = removed + 1
                 WHERE start_sequence = (
                   SELECT MAX(start_sequence) FROM output_cleanup_segments
                   WHERE start_sequence <= ?1)
                   AND end_sequence >= ?1 AND kept > 0",
                [i64::try_from(*sequence)?],
            )?;
            anyhow::ensure!(changed == 1, "no staged segment holds the put at {sequence}");
        }
        Ok(())
    }
}

/// Stages the held puts as kept, once every sealed segment is staged: each
/// is its session's latest put up to the bound. Their segments already
/// count them kept.
pub(super) fn release_held_puts(staging: &Connection) -> anyhow::Result<()> {
    if state(staging, "puts_released")? == "1" {
        return Ok(());
    }
    let tx = staging.unchecked_transaction()?;
    let held = {
        let mut statement = tx.prepare(
            "SELECT sequence, json, actor FROM output_cleanup_held_puts ORDER BY sequence ASC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?, row.get::<_, Option<String>>(2)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let mut chunk: Vec<StagedRecord> = Vec::new();
    let mut chunk_bytes = 0_usize;
    for (sequence, json, actor) in held {
        if chunk.len() == CHUNK_RECORD_LIMIT
            || chunk_bytes.saturating_add(json.len()).saturating_add(chunk.len().saturating_add(2))
                >= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES
        {
            insert_chunk(&tx, &chunk)?;
            chunk.clear();
            chunk_bytes = 0;
        }
        chunk_bytes = chunk_bytes.saturating_add(json.len());
        chunk.push((u64::try_from(sequence)?, SESSION_PUT_KIND.to_owned(), json, actor));
    }
    insert_chunk(&tx, &chunk)?;
    tx.execute_batch(
        "DELETE FROM output_cleanup_held_puts;
         UPDATE output_cleanup_state SET value = '1' WHERE key = 'puts_released';",
    )?;
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
#[path = "session_puts_tests.rs"]
mod tests;
