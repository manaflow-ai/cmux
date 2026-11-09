//! Kind-scoped journal reads: a reducer that folds a few kinds of record
//! reads those records, not the history around them.
//!
//! The agent roster's replay after a reducer version change read every
//! record other than terminal output (`query_session_journal_without_output_after`).
//! On Leo's registry (2026-11-08) that was about 12M rows, 96.6% of them
//! `personal.session.put`, which the roster discards, and the daemon took
//! 26 min to start. This read seeks the `(kind, sequence)` index once per
//! kind the reducer folds, and inflates a sealed segment only when its kind
//! map names one of them.

use super::*;

/// Which journal kinds a kind-scoped read returns. It is asked once per
/// distinct kind (of the active journal, or of a sealed segment's kind map),
/// never per record.
pub(crate) type JournalKinds = fn(&str) -> bool;

impl WorkspaceRegistry {
    /// Records in `(sequence, through]` whose kind `kinds` accepts, oldest
    /// first, and the sequence the read covered through. A page holds at
    /// most `limit` active records; a sealed segment is consumed whole, so a
    /// page that decodes one can exceed `limit` by that segment's matches.
    pub(crate) fn session_journal_kinds_after(
        &self,
        sequence: u64,
        through: u64,
        kinds: JournalKinds,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
        query_session_journal_kinds_after(&self.connection.get(), sequence, through, kinds, limit)
    }
}

impl SessionJournalReader {
    /// [`WorkspaceRegistry::session_journal_kinds_after`] on this reader's
    /// own read-only connection (no registry lock), in one read transaction
    /// like [`SessionJournalReader::without_output_after`].
    pub(crate) fn kinds_after(
        &self,
        sequence: u64,
        through: u64,
        kinds: JournalKinds,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
        let snapshot = self.connection.unchecked_transaction()?;
        query_session_journal_kinds_after(&snapshot, sequence, through, kinds, limit)
    }
}

pub(crate) fn query_session_journal_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
    anyhow::ensure!(limit > 0, "journal page limit must be positive");
    anyhow::ensure!(
        limit <= MAX_JOURNAL_PAGE_SIZE,
        "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    if sequence >= through {
        return Ok((Vec::new(), through));
    }
    let archive_end = query_archived_journal_head(connection)?;
    let archive_through = through.min(archive_end);
    let mut records = Vec::new();
    let mut reached = sequence;
    if sequence < archive_through {
        match archived_kinds_after(connection, sequence, archive_through, kinds, limit)? {
            Some((archived, archived_reached)) => {
                records = archived;
                reached = archived_reached;
            }
            None => {
                // Older sealed segments predate journal_segment_kinds: decode
                // them with the validating legacy path, as the non-output
                // read does.
                let covered = archived_records_after(connection, sequence, limit)?
                    .into_iter()
                    .take_while(|record| record.sequence <= archive_through)
                    .collect::<Vec<_>>();
                reached = covered.last().map_or(archive_through, |record| record.sequence);
                records.extend(covered.into_iter().filter(|record| kinds(&record.kind)));
            }
        }
        // A page that stopped inside the archive ends there: the active rows
        // all come after it.
        if records.len() >= limit || reached >= through || reached < archive_through {
            return Ok((records, reached));
        }
    }
    let (active, reached) =
        active_kinds_after(connection, reached, through, kinds, limit - records.len())?;
    records.extend(active);
    Ok((records, reached))
}

/// The active rows in `(sequence, through]` of the accepted kinds, at most
/// `limit`. The distinct kinds come from the kind index by a skip scan (a
/// seek per kind); each accepted kind is one range seek on
/// `(kind, sequence)` that reads at most `limit` sequences from the index
/// alone. The sequences are merged in order and only the first `limit`
/// records are read and decoded. A rejected kind costs one seek, however
/// many rows it has.
fn active_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
    let mut distinct = connection.prepare(
        "WITH RECURSIVE kinds(kind) AS (
           SELECT (SELECT MIN(kind) FROM session_journal
                   INDEXED BY session_journal_by_kind_sequence)
           UNION ALL
           SELECT (SELECT MIN(kind) FROM session_journal
                   INDEXED BY session_journal_by_kind_sequence
                   WHERE kind > kinds.kind)
           FROM kinds WHERE kinds.kind IS NOT NULL
         )
         SELECT kind FROM kinds WHERE kind IS NOT NULL",
    )?;
    let mut accepted =
        distinct.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
    accepted.retain(|kind| kinds(kind));
    let mut range = connection.prepare(
        "SELECT sequence FROM session_journal
         INDEXED BY session_journal_by_kind_sequence
         WHERE kind = ?1 AND sequence > ?2 AND sequence <= ?3
         ORDER BY sequence ASC
         LIMIT ?4",
    )?;
    let after = i64::try_from(sequence).context("journal sequence exceeds SQLite range")?;
    let until = i64::try_from(through).context("journal sequence exceeds SQLite range")?;
    let page = i64::try_from(limit).context("journal page limit exceeds SQLite range")?;
    let mut sequences = Vec::new();
    // Once `limit` matches are in hand, a later kind reads only below the
    // last of them: a page reads about `limit` index entries, not `limit`
    // per kind.
    let mut until = until;
    for kind in &accepted {
        let rows =
            range.query_map(params![kind, after, until, page], |row| row.get::<_, i64>(0))?;
        for row in rows {
            sequences.push(row?);
        }
        if sequences.len() >= limit {
            sequences.sort_unstable();
            sequences.truncate(limit);
            until = sequences[limit - 1];
        }
    }
    sequences.sort_unstable();
    // Each kind read its first `limit` matches up to its bound, which is at
    // or after the last match kept, so the first `limit` of the merge are
    // the first `limit` of all: no kind has an unread match at or before the
    // last one kept. Fewer than `limit` in all means every match through
    // `through` was read.
    sequences.truncate(limit);
    let reached = match sequences.last() {
        Some(&last) if sequences.len() == limit => {
            u64::try_from(last).context("journal sequence is negative")?
        }
        _ => through,
    };
    let mut row = connection.prepare(
        "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                occurred_at_ms, committed_at_ms, producer_json, authority_json,
                causation_id, correlation_id, causation_depth, subjects_json,
                sensitivity, payload_json, content, resource_revision,
                previous_resource_revision
         FROM session_journal
         WHERE sequence = ?1",
    )?;
    let records = sequences
        .into_iter()
        .map(|sequence| decode_record(row.query_row([sequence], stored_record_row)?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok((records, reached))
}

/// The sealed records in `(sequence, through]` of the accepted kinds, or
/// `None` when a segment in the range has no kind map (an older segment:
/// the caller takes the validating legacy path). A segment whose kind map
/// names no accepted kind is skipped without loading its content; one that
/// does is decoded whole and consumed whole, so the next page never decodes
/// it again. The page ends after the segment that brings it to `limit`.
fn archived_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<Option<(Vec<SessionJournalRecord>, u64)>> {
    backfill_legacy_journal_segment_kinds(connection)?;
    let mut statement = connection.prepare(
        "SELECT segment_id, start_sequence, end_sequence
         FROM journal_segments
         WHERE end_sequence > ?1 AND start_sequence <= ?2
         ORDER BY end_sequence ASC",
    )?;
    let segments = statement
        .query_map(params![i64::try_from(sequence)?, i64::try_from(through)?], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if segments.is_empty() {
        return Ok(None);
    }
    anyhow::ensure!(
        segments[0].1 <= i64::try_from(sequence.saturating_add(1))?,
        "journal segments contain a gap before sequence {}",
        segments[0].1
    );
    for pair in segments.windows(2) {
        anyhow::ensure!(
            pair[1].1 == pair[0].2 + 1,
            "journal segments contain a gap before sequence {}",
            pair[1].1
        );
    }
    let mut segment_kinds =
        connection.prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1")?;
    let mut reached = sequence;
    let mut records = Vec::new();
    for (segment_id, _, end) in segments {
        let mapped = segment_kinds
            .query_map([&segment_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if mapped.is_empty() {
            return Ok(None);
        }
        let end = u64::try_from(end)?.min(through);
        if mapped.iter().any(|kind| kinds(kind)) {
            let segment = load_journal_segment(connection, &segment_id)?;
            let decoded = decode_journal_segment(connection, segment)?;
            records.extend(decoded.records.into_iter().filter(|record| {
                record.sequence > sequence && record.sequence <= through && kinds(&record.kind)
            }));
        }
        reached = reached.max(end);
        if records.len() >= limit {
            break;
        }
    }
    Ok(Some((records, reached)))
}

/// One record a test appends as its writer would.
#[cfg(test)]
#[derive(Clone)]
pub(crate) struct TestJournalRecord {
    pub(crate) kind: String,
    pub(crate) producer: JournalProducer,
    pub(crate) subjects: Vec<JournalSubject>,
    pub(crate) payload: Value,
}

#[cfg(test)]
impl WorkspaceRegistry {
    /// Test seam: append `records` to the active journal in one transaction,
    /// as their writers would. Returns their sequences.
    pub(crate) fn append_journal_records_for_test(
        &self,
        records: &[TestJournalRecord],
    ) -> Vec<u64> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        let sequences = records
            .iter()
            .map(|record| {
                let event_id = format!("event_test_{}", new_uuid_v4().replace('-', ""));
                append_journal_record(
                    &tx,
                    &JournalAppend {
                        event_id: &event_id,
                        schema_version: 1,
                        kind: &record.kind,
                        class: JournalClass::Observation,
                        replay: JournalReplayPolicy::Advisory,
                        occurred_at_ms: 1,
                        producer: &record.producer,
                        authority: None,
                        causation_id: None,
                        correlation_id: None,
                        causation_depth: 0,
                        subjects: &record.subjects,
                        sensitivity: JournalSensitivity::Metadata,
                        payload: &record.payload,
                        content: None,
                        resource_revision: None,
                        previous_resource_revision: None,
                        actor: None,
                    },
                )
                .unwrap()
            })
            .collect();
        tx.commit().unwrap();
        sequences
    }

    /// SQLite VM steps `run` takes on the registry connection, counted in
    /// batches of 16 (deterministic, unlike wall time; see open_cost_tests.rs).
    /// `run` takes the connection itself, through the registry.
    pub(crate) fn vm_steps_for_test(&self, run: impl FnOnce()) -> u64 {
        let steps = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter = Arc::clone(&steps);
        self.connection
            .get()
            .progress_handler(
                16,
                Some(move || {
                    counter.fetch_add(16, std::sync::atomic::Ordering::Relaxed);
                    false
                }),
            )
            .unwrap();
        run();
        self.connection.get().progress_handler(0, None::<fn() -> bool>).unwrap();
        steps.load(std::sync::atomic::Ordering::Relaxed)
    }
}
