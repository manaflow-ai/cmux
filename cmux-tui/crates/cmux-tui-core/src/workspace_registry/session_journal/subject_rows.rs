//! The journal's subject rows (`journal_subject_index`): the page read by
//! subject, and the drop of the index by subject that older builds made.
//!
//! The table's own key is `(sequence, kind, id)`. It has no index by
//! subject: each append paid for a leaf of that index at a random place. So
//! a read by subject reads the subject rows after its cursor in the order of
//! their sequence and matches each against the list.

use super::*;

/// The index of the subject rows by subject that the schema made before.
const SUBJECT_INDEX_BY_SUBJECT: &str = "journal_subject_index_by_subject_sequence";

/// The most sequences whose subject rows one subject page reads. A list
/// with no match after the cursor would else read each subject row to the
/// head in one read transaction. A page that ends at this bound gives its
/// caller a cursor to go on from.
pub(super) const SUBJECT_PAGE_SCAN: u64 = 65_536;

/// `?1` the subjects as JSON, `?2` the cursor, `?3` the page's limit, `?4`
/// the last sequence that the page reads.
pub(super) const SUBJECT_PAGE_QUERY: &str = "SELECT DISTINCT indexed.sequence
     FROM journal_subject_index AS indexed
     WHERE indexed.sequence > ?2 AND indexed.sequence <= ?4
       AND (indexed.kind, indexed.id) IN (
         SELECT json_extract(requested.value, '$.kind'),
                json_extract(requested.value, '$.id')
         FROM json_each(?1) AS requested
       )
     ORDER BY indexed.sequence ASC
     LIMIT ?3";

/// Drops [`SUBJECT_INDEX_BY_SUBJECT`] from a store that has it.
///
/// `secure_delete` is off for this one statement. With it on, the drop
/// writes each page of the index to the WAL as zeros, in the daemon's
/// start: as many bytes as the index has. The index holds only copies of
/// the `(kind, id, sequence)` of rows that the table keeps, and no payload.
/// With the pragma off those copies stay in free pages until a later write
/// uses the pages. The pragma has its value of before when this returns,
/// also when the drop fails.
pub(super) fn drop_journal_subject_index_by_subject(connection: &Connection) -> anyhow::Result<()> {
    let present = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?1)",
        [SUBJECT_INDEX_BY_SUBJECT],
        |row| row.get::<_, bool>(0),
    )?;
    if !present {
        return Ok(());
    }
    let secure_delete: i64 = connection.query_row("PRAGMA secure_delete", [], |row| row.get(0))?;
    connection.execute_batch("PRAGMA secure_delete=OFF;")?;
    let dropped =
        connection.execute_batch(&format!("DROP INDEX IF EXISTS {SUBJECT_INDEX_BY_SUBJECT};"));
    let restored = connection.execute_batch(&format!("PRAGMA secure_delete={secure_delete};"));
    dropped.context("drop the journal's index by subject")?;
    restored.context("restore secure_delete after the drop of the journal's index by subject")?;
    Ok(())
}

/// One page of the records after `sequence` that name one of `subjects`:
/// [`query_subject_page`] with the bound [`SUBJECT_PAGE_SCAN`].
pub(super) fn query_session_journal_after_subjects(
    connection: &Connection,
    sequence: u64,
    limit: usize,
    subjects: &[JournalSubject],
) -> anyhow::Result<SessionJournalSubjectPage> {
    query_subject_page(connection, sequence, limit, subjects, SUBJECT_PAGE_SCAN)
}

/// One page of the records after `sequence` that name one of `subjects`.
///
/// It reads the subject rows of at most `scan` sequences after the cursor.
/// `scanned_through` is the sequence that the page read to: its last
/// record's when the page is full, else the end of that range (the head at
/// the latest). So a page can have no record and a cursor below the head:
/// the caller goes on from it.
pub(super) fn query_subject_page(
    connection: &Connection,
    sequence: u64,
    limit: usize,
    subjects: &[JournalSubject],
    scan: u64,
) -> anyhow::Result<SessionJournalSubjectPage> {
    anyhow::ensure!(limit > 0, "journal page limit must be positive");
    anyhow::ensure!(
        limit <= MAX_JOURNAL_PAGE_SIZE,
        "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    anyhow::ensure!(!subjects.is_empty(), "journal subject filter must not be empty");
    let head_sequence = query_journal_head(connection)?;
    anyhow::ensure!(
        sequence <= head_sequence,
        "cursor.invalid: journal sequence {sequence} is ahead of {head_sequence}"
    );
    let scan_end = sequence.saturating_add(scan).min(head_sequence);
    let requested_json = canonical_json(&serde_json::to_value(subjects)?)?;
    let mut statement = connection.prepare_cached(SUBJECT_PAGE_QUERY)?;
    let sequences = statement
        .query_map(
            params![
                requested_json,
                i64::try_from(sequence).context("journal sequence exceeds SQLite range")?,
                i64::try_from(limit).context("journal page limit exceeds SQLite range")?,
                i64::try_from(scan_end).context("journal sequence exceeds SQLite range")?,
            ],
            |row| row.get::<_, i64>(0),
        )?
        .map(|row| {
            u64::try_from(row?).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Integer,
                    Box::new(error),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    let records = query_session_journal_sequences(connection, &sequences)?;
    let scanned_through = if sequences.len() == limit {
        sequences.last().copied().unwrap_or(sequence)
    } else {
        scan_end
    };
    Ok(SessionJournalSubjectPage { head_sequence, scanned_through, records })
}
