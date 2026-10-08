//! Journal reads that survive an undecodable range (cx-6b12).
//!
//! Startup folds (the agent roster) replay history that can include a
//! sealed segment that no longer decodes. The strict reader fails the whole
//! page for that. This reader narrows a failed page to the first unit that
//! fails on its own (one sealed segment, one active row, or a missing
//! sequence range) and returns that unit as a skip, so the caller keeps
//! every record that decodes, also records that a bad segment's metadata
//! shadows from the strict reader. An error that does not come from the stored
//! bytes (SQLite I/O, a busy database, a corrupt database page) still
//! fails: a skip on it could drop decodable records, and the store needs
//! repair before any read is trustworthy.

use super::*;

/// A journal range that a salvaging read could not decode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SkippedJournalRange {
    pub(crate) start_sequence: u64,
    pub(crate) end_sequence: u64,
    /// The sealed segment that holds the range, when one does.
    pub(crate) segment_id: Option<String>,
    pub(crate) error: String,
}

pub(crate) enum SalvagedJournalPage {
    Page(SessionJournalPage),
    /// No record follows the cursor until after this range. The next read
    /// starts at `end_sequence`.
    Skipped(SkippedJournalRange),
}

impl WorkspaceRegistry {
    /// [`WorkspaceRegistry::session_journal_after`], except that a range
    /// whose stored bytes do not decode is returned as a skip instead of an
    /// error. A page never contains records after a skipped range.
    pub(crate) fn session_journal_after_salvaging(
        &self,
        sequence: u64,
        limit: usize,
    ) -> anyhow::Result<SalvagedJournalPage> {
        salvage_session_journal_after(&self.connection, sequence, limit)
    }
}

impl SessionJournalReader {
    /// The journal head without decoding any record or sealed segment.
    /// Startup reads only the head here, so a bad first segment cannot stop
    /// the daemon before any fold has a chance to skip it.
    pub(crate) fn head(&self) -> anyhow::Result<u64> {
        query_journal_head(&self.connection)
    }
}

fn salvage_session_journal_after(
    connection: &Connection,
    sequence: u64,
    limit: usize,
) -> anyhow::Result<SalvagedJournalPage> {
    // Halve the page until the strict read succeeds. Each success returns
    // every record before the bad unit; a failure at one record belongs to
    // the record after the cursor (or to the store itself).
    let mut strict_limit = limit;
    let strict_error = loop {
        match query_session_journal_after(connection, sequence, strict_limit) {
            Ok(page) => return Ok(SalvagedJournalPage::Page(page)),
            Err(_) if strict_limit > 1 => strict_limit /= 2,
            Err(error) => break error,
        }
    };
    match unit_after(connection, sequence, limit)? {
        Unit::Skip(skip) => Ok(SalvagedJournalPage::Skipped(skip)),
        Unit::Records(records) => Ok(SalvagedJournalPage::Page(SessionJournalPage {
            head_sequence: query_journal_head(connection)?,
            records,
        })),
        Unit::Decodes => Err(strict_error),
    }
}

/// What holds the sequence after a cursor whose one-record strict read
/// failed.
enum Unit {
    /// The unit does not decode, or nothing holds the range.
    Skip(SkippedJournalRange),
    /// Decodable records that the strict reader cannot reach, because a bad
    /// segment's metadata claims their sequences. They start right after
    /// the cursor and are contiguous.
    Records(Vec<SessionJournalRecord>),
    /// The unit decodes, so the strict failure had another cause.
    Decodes,
}

/// The unit that a one-record strict read after `sequence` fails on. It
/// follows the strict reader: the first sealed segment that ends after the
/// cursor, else the first active row after it.
fn unit_after(connection: &Connection, sequence: u64, limit: usize) -> anyhow::Result<Unit> {
    let next = sequence.checked_add(1).context("journal sequence exhausted")?;
    let segment = connection
        .query_row(
            "SELECT segment_id, start_sequence, end_sequence
             FROM journal_segments
             WHERE end_sequence > ?1
             ORDER BY start_sequence ASC
             LIMIT 1",
            params![i64::try_from(sequence)?],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    if let Some((segment_id, start, end)) = segment {
        let start = u64::try_from(start).unwrap_or(0);
        if start > next {
            return missing_range(connection, next, start - 1);
        }
        let error = match load_and_decode_segment(connection, &segment_id)? {
            Ok(_) => return Ok(Unit::Decodes),
            Err(error) => error,
        };
        if let Some(unit) = unit_shadowed_by_bad_segment(connection, sequence, &segment_id, limit)?
        {
            return Ok(unit);
        }
        let end = bounded_skip_end(connection, start, u64::try_from(end).unwrap_or(0))?.max(next);
        return Ok(Unit::Skip(SkippedJournalRange {
            start_sequence: next,
            end_sequence: end,
            segment_id: Some(segment_id),
            error: format!("{error:#}"),
        }));
    }

    let Some(active) = connection
        .query_row(
            "SELECT sequence FROM session_journal WHERE sequence > ?1 ORDER BY sequence ASC LIMIT 1",
            params![i64::try_from(sequence)?],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
    else {
        return Ok(Unit::Decodes);
    };
    let active = u64::try_from(active).context("journal sequence is negative")?;
    if active > next {
        return missing_range(connection, next, active - 1);
    }
    Ok(match active_rows_from(connection, next, 1)? {
        Some(Unit::Skip(skip)) => Unit::Skip(skip),
        _ => Unit::Decodes,
    })
}

/// A bad segment's metadata can claim sequences that another unit holds:
/// a segment that starts right after the cursor, or active rows. Read that
/// unit directly, since the strict reader always picks the bad segment.
fn unit_shadowed_by_bad_segment(
    connection: &Connection,
    sequence: u64,
    bad_segment_id: &str,
    limit: usize,
) -> anyhow::Result<Option<Unit>> {
    let next = sequence.checked_add(1).context("journal sequence exhausted")?;
    let other = connection
        .query_row(
            "SELECT segment_id, start_sequence, end_sequence
             FROM journal_segments
             WHERE start_sequence = ?1 AND segment_id != ?2",
            params![i64::try_from(next)?, bad_segment_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    if let Some((segment_id, start, end)) = other {
        return Ok(Some(match load_and_decode_segment(connection, &segment_id)? {
            Ok(decoded) => Unit::Records(
                decoded
                    .records
                    .into_iter()
                    .filter(|record| record.sequence > sequence)
                    .take(limit)
                    .collect(),
            ),
            Err(error) => Unit::Skip(SkippedJournalRange {
                start_sequence: next,
                end_sequence: bounded_skip_end(
                    connection,
                    u64::try_from(start).unwrap_or(0),
                    u64::try_from(end).unwrap_or(0),
                )?
                .max(next),
                segment_id: Some(segment_id),
                error: format!("{error:#}"),
            }),
        }));
    }
    active_rows_from(connection, next, limit)
}

/// Load and decode one sealed segment. The outer error is the database's
/// (it fails the read); the inner error is the stored segment's (a skip).
fn load_and_decode_segment(
    connection: &Connection,
    segment_id: &str,
) -> anyhow::Result<anyhow::Result<DecodedJournalSegment>> {
    let row = connection.query_row(
        "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                content, uncompressed_bytes, sha256
         FROM journal_segments
         WHERE segment_id = ?1",
        params![segment_id],
        journal_segment_row,
    );
    Ok(match row {
        Ok(row) => decode_journal_segment(row),
        Err(error) if is_stored_value_error(&error) => Err(error.into()),
        Err(error) => return Err(error.into()),
    })
}

/// The contiguous decodable active rows that start at `first`, at most
/// `limit`. `None` when no row has sequence `first`; a skip of `first`
/// alone when that row does not decode.
fn active_rows_from(
    connection: &Connection,
    first: u64,
    limit: usize,
) -> anyhow::Result<Option<Unit>> {
    let mut statement = connection.prepare(
        "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                occurred_at_ms, committed_at_ms, producer_json, authority_json,
                causation_id, correlation_id, causation_depth, subjects_json,
                sensitivity, payload_json, content, resource_revision,
                previous_resource_revision
         FROM session_journal
         WHERE sequence >= ?1
         ORDER BY sequence ASC
         LIMIT ?2",
    )?;
    let mut rows = statement.query(params![i64::try_from(first)?, i64::try_from(limit)?])?;
    let mut records: Vec<SessionJournalRecord> = Vec::new();
    while let Some(row) = rows.next()? {
        let sequence =
            u64::try_from(row.get::<_, i64>(0)?).context("journal sequence is negative")?;
        let expected = first.saturating_add(u64::try_from(records.len())?);
        if sequence != expected {
            break;
        }
        let decoded = match stored_record_row(row) {
            Ok(row) => decode_record(row),
            Err(error) if is_stored_value_error(&error) => Err(error.into()),
            Err(error) => return Err(error.into()),
        };
        match decoded {
            Ok(record) => records.push(record),
            Err(error) if records.is_empty() => {
                return Ok(Some(Unit::Skip(SkippedJournalRange {
                    start_sequence: first,
                    end_sequence: first,
                    segment_id: None,
                    error: format!("{error:#}"),
                })));
            }
            Err(_) => break,
        }
    }
    Ok((!records.is_empty()).then_some(Unit::Records(records)))
}

/// The end of a bad segment's skip. Its `end_sequence` is metadata of the
/// row that failed, so the skip also stops before the next segment and
/// before the first active row: a corrupt end can never hide records that
/// another unit holds.
fn bounded_skip_end(connection: &Connection, start: u64, end: u64) -> anyhow::Result<u64> {
    let start = i64::try_from(start)?;
    let next_unit = connection.query_row(
        "SELECT MIN(first) FROM (
           SELECT MIN(start_sequence) AS first FROM journal_segments WHERE start_sequence > ?1
           UNION ALL
           SELECT MIN(sequence) AS first FROM session_journal WHERE sequence > ?1
         )",
        params![start],
        |row| row.get::<_, Option<i64>>(0),
    )?;
    Ok(match next_unit.and_then(|first| u64::try_from(first).ok()) {
        Some(first) => end.min(first.saturating_sub(1)),
        None => end,
    })
}

/// A sequence range that no sealed segment covers. It is skipped only when
/// no active row falls inside it either; otherwise the strict reader's
/// failure is not about a missing range, and the caller keeps its error.
fn missing_range(connection: &Connection, start: u64, end: u64) -> anyhow::Result<Unit> {
    let active_rows = connection.query_row(
        "SELECT COUNT(*) FROM session_journal WHERE sequence >= ?1 AND sequence <= ?2",
        params![i64::try_from(start)?, i64::try_from(end)?],
        |row| row.get::<_, i64>(0),
    )?;
    if active_rows > 0 {
        return Ok(Unit::Decodes);
    }
    Ok(Unit::Skip(SkippedJournalRange {
        start_sequence: start,
        end_sequence: end,
        segment_id: None,
        error: "no sealed segment or journal row holds these sequences".into(),
    }))
}

/// A row value whose stored type or range does not match the schema: a
/// fault of the stored bytes, not of the database connection.
fn is_stored_value_error(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::FromSqlConversionFailure(..)
            | rusqlite::Error::InvalidColumnType(..)
            | rusqlite::Error::IntegralValueOutOfRange(..)
            | rusqlite::Error::Utf8Error(..)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn append_probe(registry: &mut WorkspaceRegistry, index: usize) -> u64 {
        let producer = JournalProducer { kind: "test".into(), id: "salvage".into() };
        let subjects = [JournalSubject { kind: "session".into(), id: "salvage".into() }];
        let event_id = format!("event_salvage_probe_{index}");
        let tx = registry.connection.transaction().unwrap();
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "test.salvage.probe",
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                occurred_at_ms: 1,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Metadata,
                payload: &serde_json::json!({ "index": index }),
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        sequence
    }

    /// Read everything after `sequence` the way a startup fold does.
    fn salvage_all(
        registry: &WorkspaceRegistry,
        mut sequence: u64,
        limit: usize,
    ) -> (Vec<u64>, Vec<SkippedJournalRange>) {
        let mut records = Vec::new();
        let mut skipped = Vec::new();
        loop {
            match registry.session_journal_after_salvaging(sequence, limit).unwrap() {
                SalvagedJournalPage::Page(page) => {
                    if page.records.is_empty() {
                        return (records, skipped);
                    }
                    for record in page.records {
                        sequence = record.sequence;
                        records.push(record.sequence);
                    }
                }
                SalvagedJournalPage::Skipped(skip) => {
                    sequence = skip.end_sequence;
                    skipped.push(skip);
                }
            }
        }
    }

    #[test]
    fn an_undecodable_active_row_is_skipped_alone_and_every_other_row_is_kept() {
        let root = std::env::temp_dir().join(format!("cmux-journal-salvage-row-{}", new_uuid_v4()));
        let mut registry = WorkspaceRegistry::open(&root, "journal-salvage-row").unwrap();
        let start = registry.session_journal_head().unwrap();
        let sequences = (0..6).map(|index| append_probe(&mut registry, index)).collect::<Vec<_>>();
        let bad = sequences[2];
        registry
            .connection
            .execute_batch(
                "PRAGMA ignore_check_constraints=ON;
                 DROP TRIGGER IF EXISTS session_journal_reject_update;",
            )
            .unwrap();
        registry
            .connection
            .execute(
                "UPDATE session_journal SET class = 'unknown' WHERE sequence = ?1",
                params![i64::try_from(bad).unwrap()],
            )
            .unwrap();

        assert!(registry.session_journal_after(start, 512).is_err());
        for limit in [1, 2, 512] {
            let (records, skipped) = salvage_all(&registry, start, limit);
            let expected =
                sequences.iter().copied().filter(|sequence| *sequence != bad).collect::<Vec<_>>();
            assert_eq!(records, expected, "page limit {limit}");
            assert_eq!(skipped.len(), 1, "page limit {limit}");
            assert_eq!((skipped[0].start_sequence, skipped[0].end_sequence), (bad, bad));
            assert_eq!(skipped[0].segment_id, None);
            assert!(skipped[0].error.contains("unknown journal class"), "{}", skipped[0].error);
        }
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }
}
