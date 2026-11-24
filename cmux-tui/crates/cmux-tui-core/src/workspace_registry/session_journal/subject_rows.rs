//! The subject rows of the session journal, and the one module that names
//! their table.
//!
//! A journal row names its subjects in its own `subjects_json`. The table
//! `journal_subject_index` holds one row for each subject of each journal
//! row, and its index `(kind, id, sequence)` answers a read by subject. The
//! rows are derived data, and a later commit writes them:
//!
//! - **The mark.** The `meta` row `journal_subject_rows_through` names the
//!   last journal row whose subject rows the table holds. An open gives a
//!   store its first mark ([`create_schema`]). After that the mark moves
//!   only in the commit that writes the subject rows to it
//!   ([`write_through`]): the commit of the journal row that ends a period
//!   ([`PERIOD`]), a seal, and the write of the tail ([`write_tail`]) at a
//!   stop, at the release of the session, at an open and in a rollback's
//!   check of a store that no daemon owns
//!   ([`stored_number_for_a_rollback`]). The commit of each other journal
//!   row writes no subject row, so a page of the index that many journal
//!   rows of a period share is written one time for the period.
//! - **Reads.** Each journal row after the mark is in the active table: a
//!   seal writes the subject rows to its end before it moves rows out. A
//!   read by subject takes the rows of the table and, when the table does
//!   not fill the page, for each journal row after the mark the subjects
//!   that the row itself names. One statement reads both, so both come from
//!   one snapshot ([`read`]). The write and the read take a row's subjects
//!   from one function ([`subjects_of`]), so a read gives the same before
//!   and after the write.
//! - **The schema number.** A build that does not know the mark reads the
//!   table alone, and would miss each journal row after the mark with no
//!   sign. So while a journal row is after the mark, the stored schema
//!   number is [`ROWS_DUE_SCHEMA_VERSION`], which such a build refuses. The
//!   number is set in the same transaction as the insert of the first
//!   journal row that gets no subject rows ([`after_append`]): not in a
//!   commit before it and not in one after it. The write of the tail puts
//!   the subject rows to the journal's head, the mark, and the number of
//!   [`SCHEMA_VERSION`] again, in one commit. The number can stay at
//!   [`ROWS_DUE_SCHEMA_VERSION`] with no journal row after the mark (after
//!   the commit that ends a period, until the stop): no write closes that.
//!   A store whose owner ended with no stop step stays at
//!   [`ROWS_DUE_SCHEMA_VERSION`] until this build opens the session or a
//!   rollback's check writes its tail.
//!
//! A store with no mark is a store that no build with this rule opened:
//! each of its journal rows got its subject rows in its own commit. An open
//! gives each store a mark before the first append ([`create_schema`]).
//!
//! No other product module names the table. The statements here are
//! private, and a test row fails for the table's name in another product
//! file (`tests/late_subject_rows.rs`).

use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

/// The journal rows of one period: the commit of a journal row whose
/// sequence is a multiple of this writes the subject rows of each journal
/// row after the mark.
pub(crate) const PERIOD: i64 = 100;

/// The stored schema number of a store at [`SCHEMA_VERSION`] with a journal
/// row after the mark. It is not a schema of its own: the tables are those
/// of [`SCHEMA_VERSION`].
pub(crate) const ROWS_DUE_SCHEMA_VERSION: i64 = SCHEMA_VERSION + 1;

// This fails at the next change of `SCHEMA_VERSION`, for the person who
// makes it (spec/session-journal.md, "Subject rows").
const _: () = assert!(
    SCHEMA_VERSION == 15,
    "the stored number 16 is schema 15 with subject rows due, so 16 is no plain schema number: \
     the next plain number is 17 and its due number is 18. The open of that build can meet a \
     store left at 16 with rows due (a crash before the update): it writes those subject rows \
     before it migrates the store"
);

/// The schema that a stored schema number names.
pub(crate) fn schema_of_stored_number(stored: i64) -> i64 {
    if stored == ROWS_DUE_SCHEMA_VERSION { SCHEMA_VERSION } else { stored }
}

/// SQL: the mark, or `$absent` for a store with no mark.
macro_rules! mark_or {
    ($absent:literal) => {
        concat!(
            "COALESCE((SELECT CAST(value AS INTEGER) FROM meta
                       WHERE key = 'journal_subject_rows_through'), ",
            $absent,
            ")"
        )
    };
}

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS journal_subject_index (
       sequence INTEGER NOT NULL CHECK(sequence > 0),
       kind TEXT NOT NULL,
       id TEXT NOT NULL,
       PRIMARY KEY(sequence, kind, id)
     ) WITHOUT ROWID;
     CREATE INDEX IF NOT EXISTS journal_subject_index_by_subject_sequence
       ON journal_subject_index(kind, id, sequence);
     CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_update
       BEFORE UPDATE ON journal_subject_index
     BEGIN
       SELECT RAISE(ABORT, 'journal subject index is append-only');
     END;
     CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_delete
       BEFORE DELETE ON journal_subject_index
     BEGIN
       SELECT RAISE(ABORT, 'journal subject index is append-only');
     END;";

/// The first mark of a store that has the table and no mark: each journal
/// row has its subject rows, so the mark is the newest active row (an open
/// moves it to the head).
const FIRST_MARK: &str = "INSERT OR IGNORE INTO meta(key, value)
     SELECT 'journal_subject_rows_through', CAST(COALESCE(MAX(sequence), 0) AS TEXT)
     FROM session_journal";

/// The active journal rows after `?1` to `?2`, with the subjects that each
/// names ([`subjects_of`] reads them).
const ROWS_DUE: &str = "SELECT sequence, subjects_json FROM session_journal
     WHERE sequence > ?1 AND sequence <= ?2 ORDER BY sequence";

const WRITE_ROW: &str =
    "INSERT OR IGNORE INTO journal_subject_index(sequence, kind, id) VALUES(?1, ?2, ?3)";

const MOVE_MARK: &str = "INSERT INTO meta(key, value)
     VALUES('journal_subject_rows_through', CAST(?1 AS TEXT))
     ON CONFLICT(key) DO UPDATE SET value = excluded.value";

/// Sets the stored schema number to `?1` when it is `?2`.
const SET_NUMBER: &str = "UPDATE meta SET value = CAST(?1 AS TEXT)
     WHERE key = 'schema_version' AND value = CAST(?2 AS TEXT)";

/// One page of sequences by subject. `?1`: the subjects, `?2`: the cursor,
/// `?3`: the page's limit. The table's part has the limit of the page; the
/// journal rows after the mark are fewer than a period in a store that an
/// owner has.
///
/// The journal rows after the mark are read only when the table's part has
/// fewer rows than the limit. The journal rows whose subject rows the table
/// holds are the first rows of the journal: each write of subject rows goes
/// from the mark on with no gap ([`write_through`]), and a staging registry
/// gets the rows of each kept record. So a journal row with no subject row
/// in the table is after each row of the table, and a page that the table
/// fills has none. Then the lower bound of the second part is the largest
/// sequence: one seek, and no journal row is taken. The table's part is
/// made one time (`MATERIALIZED`), so its rows and their count are the same.
const SEQUENCES_AFTER: &str = concat!(
    "WITH from_table(sequence) AS MATERIALIZED (
       SELECT DISTINCT indexed.sequence
       FROM json_each(?1) AS requested
       JOIN journal_subject_index AS indexed
         INDEXED BY journal_subject_index_by_subject_sequence
         ON indexed.kind = json_extract(requested.value, '$.kind')
        AND indexed.id = json_extract(requested.value, '$.id')
       WHERE indexed.sequence > ?2
       ORDER BY indexed.sequence ASC
       LIMIT ?3)
     SELECT sequence, NULL, NULL FROM from_table
     UNION ALL
     SELECT sequence, NULL, subjects_json FROM session_journal
     WHERE sequence > CASE WHEN (SELECT COUNT(*) FROM from_table) < ?3
                           THEN MAX(?2, ",
    mark_or!("9223372036854775807"),
    ")
                           ELSE 9223372036854775807 END"
);

/// The ids of one kind in a range. `?1`: the kind, `?2` and `?3`: the first
/// and the last sequence.
const IDS_IN_RANGE: &str = concat!(
    "SELECT NULL, id, NULL FROM (
       SELECT DISTINCT id FROM journal_subject_index
       WHERE kind = ?1 AND sequence >= ?2 AND sequence <= ?3)
     UNION ALL
     SELECT sequence, NULL, subjects_json FROM session_journal
     WHERE sequence >= ?2 AND sequence <= ?3 AND sequence > ",
    mark_or!("9223372036854775807")
);

/// Makes the table, and gives a store with no mark its first one. A store
/// that had no table gets the subject rows of each active journal row here,
/// in the transaction that makes the table: no commit holds the table
/// without them. A mark of such a store names rows that the table does not
/// hold, so it starts again at 0.
pub(super) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let existed: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master
                       WHERE type = 'table' AND name = 'journal_subject_index')",
        [],
        |row| row.get(0),
    )?;
    transaction.execute_batch(SCHEMA)?;
    if existed {
        transaction.execute(FIRST_MARK, [])?;
    } else {
        transaction.execute(MOVE_MARK, [0])?;
        let newest: i64 = transaction.query_row(
            "SELECT COALESCE(MAX(sequence), 0) FROM session_journal",
            [],
            |row| row.get(0),
        )?;
        write_through(transaction, u64::try_from(newest).context("journal sequence is negative")?)?;
    }
    Ok(())
}

/// Writes the subject rows of each active journal row after the mark to
/// `through`, and moves the mark to `through`: the rows and the mark are in
/// the caller's one commit. After a store's first mark ([`create_schema`]
/// gives it), no other statement moves the mark. Returns the subject rows
/// written.
///
/// The mark is read from the store each time, so a store with no mark gets
/// the rows of each active journal row: more work one time, never a row
/// too few.
pub(crate) fn write_through(transaction: &Transaction<'_>, through: u64) -> anyhow::Result<usize> {
    let through = i64::try_from(through).context("journal sequence exceeds SQLite range")?;
    let mark = transaction
        .prepare_cached(concat!("SELECT ", mark_or!("0")))?
        .query_row([], |row| row.get::<_, i64>(0))?;
    if mark >= through {
        return Ok(0);
    }
    let mut skips = Skips::default();
    let mut written = 0_usize;
    {
        let mut due = transaction.prepare_cached(ROWS_DUE)?;
        let mut write = transaction.prepare_cached(WRITE_ROW)?;
        let mut rows = due.query([mark, through])?;
        while let Some(row) = rows.next()? {
            let sequence = row.get::<_, i64>(0)?;
            let named = row.get::<_, String>(1)?;
            #[cfg(test)]
            ROWS_TAKEN_BY_WRITES.with(|rows| rows.set(rows.get() + 1));
            for (kind, id) in subjects_of(sequence, &named, &mut skips) {
                written = written.saturating_add(write.execute(params![sequence, kind, id])?);
            }
        }
    }
    transaction.prepare_cached(MOVE_MARK)?.execute([through])?;
    skips.report("the write of subject rows");
    Ok(written)
}

/// The count of subjects that this process skipped: see [`subjects_of`].
static SKIPPED: AtomicU64 = AtomicU64::new(0);

/// The subjects that this process skipped in each write and each read.
#[cfg(test)]
pub(crate) fn skipped_subjects() -> u64 {
    SKIPPED.load(Ordering::Relaxed)
}

/// The subjects that one write or one read skipped.
#[derive(Default)]
struct Skips {
    count: u64,
    /// The first journal rows with a skip, by sequence.
    rows: Vec<i64>,
}

impl Skips {
    fn note(&mut self, sequence: i64) {
        self.count = self.count.saturating_add(1);
        if self.rows.len() < 8 && self.rows.last() != Some(&sequence) {
            self.rows.push(sequence);
        }
    }

    /// One log line for the skips of `during`, with the journal rows by
    /// sequence and nothing that a row stores.
    fn report(self, during: &str) {
        if self.count == 0 {
            return;
        }
        SKIPPED.fetch_add(self.count, Ordering::Relaxed);
        eprintln!(
            "cmux-tui: {during} skipped {} journal subject(s) that do not read; the first \
             journal rows with one, by sequence: {:?}",
            self.count, self.rows
        );
    }
}

/// The subjects `(kind, id)` that the stored `subjects_json` of the journal
/// row `sequence` names: the one reading of a stored row's subjects. The
/// write of the subject rows and each read of a journal row after the mark
/// call it, so a read gives for a row what the table gives after the write.
///
/// A subject is an object with a text `kind` and a text `id`. An element
/// that is not one is skipped, and so is a value that is no JSON list; each
/// skip is counted. An append stores the subjects from typed values, so a
/// skip is a sign of file damage.
fn subjects_of(sequence: i64, subjects_json: &str, skips: &mut Skips) -> Vec<(String, String)> {
    let Ok(Value::Array(named)) = serde_json::from_str::<Value>(subjects_json) else {
        skips.note(sequence);
        return Vec::new();
    };
    let mut subjects = Vec::with_capacity(named.len());
    for subject in &named {
        let kind = subject.get("kind").and_then(Value::as_str);
        let id = subject.get("id").and_then(Value::as_str);
        match (kind, id) {
            (Some(kind), Some(id)) => subjects.push((kind.to_owned(), id.to_owned())),
            _ => skips.note(sequence),
        }
    }
    subjects
}

/// After the insert of the journal row `sequence`, in the insert's own
/// transaction.
///
/// A row that ends a period writes the subject rows of each row after the
/// mark, itself too. Each other row gets no subject row now, so the stored
/// schema number must say that rows are due: when it is the number of
/// [`SCHEMA_VERSION`], this sets [`ROWS_DUE_SCHEMA_VERSION`] in this same
/// transaction, so no commit holds the journal row with the old number. The
/// number is read from the store each time (one seek in `meta`): another
/// connection can change it.
pub(super) fn after_append(transaction: &Transaction<'_>, sequence: i64) -> anyhow::Result<()> {
    let through = u64::try_from(sequence).context("journal sequence is negative")?;
    if sequence % PERIOD == 0 {
        write_through(transaction, through)?;
        return Ok(());
    }
    let number = transaction
        .prepare_cached("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'schema_version'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .optional()?;
    match number {
        Some(ROWS_DUE_SCHEMA_VERSION) => {}
        Some(SCHEMA_VERSION) => {
            transaction
                .prepare_cached(SET_NUMBER)?
                .execute([ROWS_DUE_SCHEMA_VERSION, SCHEMA_VERSION])?;
        }
        // A store on its way to this schema (an open's migration appends
        // before it writes the number), or one with no number yet: the
        // number cannot say that rows are due, so this row gets its subject
        // rows now.
        _ => {
            write_through(transaction, through)?;
        }
    }
    Ok(())
}

/// Writes the subject rows of each journal row after the mark, moves the
/// mark to the journal's head, and puts the number of [`SCHEMA_VERSION`]
/// back, all in the caller's one commit: the write of a stop, of the release
/// of the session after it, of an open, and of a rollback's check of a
/// session that no daemon owns. Returns the subject rows written.
pub(crate) fn write_tail(transaction: &Transaction<'_>) -> anyhow::Result<usize> {
    let rows = write_through(transaction, query_journal_head(transaction)?)?;
    transaction.execute(SET_NUMBER, [SCHEMA_VERSION, ROWS_DUE_SCHEMA_VERSION])?;
    Ok(rows)
}

impl WorkspaceRegistry {
    /// The stop's write ([`write_tail`]), in a commit of its own. A journal
    /// row after it puts the store at [`ROWS_DUE_SCHEMA_VERSION`] again, so
    /// the release of the session runs it one time more, before the session
    /// is free for another owner. Neither runs while the journal's writer
    /// can still append (a writer that did not end in the stop's time): this
    /// takes the registry's connection with no end time. The registry stays
    /// open after the release, so a row can still come after it.
    pub(crate) fn write_journal_subject_tail(&self) -> anyhow::Result<usize> {
        let db = self.connection.get();
        let transaction = db.unchecked_transaction()?;
        let rows = write_tail(&transaction)?;
        transaction.commit()?;
        Ok(rows)
    }
}

/// One row of a read by subject.
enum Found {
    /// A sequence of the table.
    Sequence(i64),
    /// An id of the table.
    Id(String),
    /// A journal row after the mark, and the subjects that it names.
    AfterTheMark(i64, Vec<(String, String)>),
}

#[cfg(test)]
thread_local! {
    /// The journal rows after the mark that the reads of this thread took.
    static ROWS_READ_AFTER_THE_MARK: Cell<u64> = const { Cell::new(0) };
    /// The journal rows that the writes of subject rows of this thread took.
    static ROWS_TAKEN_BY_WRITES: Cell<u64> = const { Cell::new(0) };
    /// The stores that the rollback's checks of this thread opened for a
    /// write.
    static STORES_OPENED_FOR_A_WRITE: Cell<u64> = const { Cell::new(0) };
}

/// The stores that the rollback's checks of this thread opened for a write
/// of subject rows ([`stored_number_for_a_rollback`]).
#[cfg(test)]
pub(crate) fn stores_opened_for_a_write() -> u64 {
    STORES_OPENED_FOR_A_WRITE.with(Cell::get)
}

/// The journal rows after the mark that the reads by subject of this thread
/// took from the store and parsed.
#[cfg(test)]
pub(crate) fn rows_read_after_the_mark() -> u64 {
    ROWS_READ_AFTER_THE_MARK.with(Cell::get)
}

/// The journal rows whose subjects the writes of subject rows of this thread
/// took from the store ([`write_through`]).
#[cfg(test)]
pub(crate) fn rows_taken_by_writes() -> u64 {
    ROWS_TAKEN_BY_WRITES.with(Cell::get)
}

/// The one read of the table: the rows of the table that `statement` asks
/// for, and each journal row after the mark in its range with the subjects
/// that the row names. `statement` is one SQL statement, so the table, the
/// mark and the journal rows are of one snapshot, also on a connection with
/// no open transaction.
///
/// The subjects of a journal row after the mark are those that the write of
/// its subject rows gives ([`subjects_of`]), so a read gives the same before
/// and after that write. It fails for an SQL or I/O error only.
fn read(
    connection: &Connection,
    statement: &str,
    params: impl rusqlite::Params,
    mut found: impl FnMut(Found),
) -> anyhow::Result<()> {
    let mut skips = Skips::default();
    {
        let mut statement = connection.prepare_cached(statement)?;
        let mut rows = statement.query(params)?;
        while let Some(row) = rows.next()? {
            let sequence = row.get::<_, Option<i64>>(0)?;
            let named = row.get::<_, Option<String>>(2)?;
            found(match (sequence, named) {
                (Some(sequence), Some(named)) => {
                    #[cfg(test)]
                    ROWS_READ_AFTER_THE_MARK.with(|rows| rows.set(rows.get() + 1));
                    Found::AfterTheMark(sequence, subjects_of(sequence, &named, &mut skips))
                }
                (Some(sequence), None) => Found::Sequence(sequence),
                (None, _) => Found::Id(row.get(1)?),
            });
        }
    }
    skips.report("a read by subject");
    Ok(())
}

/// The sequences of one page by subject: the first `limit` journal rows
/// after `sequence` that name one of `subjects`, in order.
pub(super) fn sequences_after(
    connection: &Connection,
    sequence: u64,
    limit: usize,
    subjects: &[JournalSubject],
) -> anyhow::Result<Vec<u64>> {
    let requested = canonical_json(&serde_json::to_value(subjects)?)?;
    let cursor = i64::try_from(sequence).context("journal sequence exceeds SQLite range")?;
    let page = i64::try_from(limit).context("journal page limit exceeds SQLite range")?;
    let mut sequences = BTreeSet::new();
    read(connection, SEQUENCES_AFTER, params![requested, cursor, page], |found| match found {
        Found::Sequence(row) => {
            sequences.insert(row);
        }
        Found::AfterTheMark(row, named) => {
            let wanted = |(kind, id): &(String, String)| {
                subjects.iter().any(|subject| subject.kind == *kind && subject.id == *id)
            };
            if named.iter().any(wanted) {
                sequences.insert(row);
            }
        }
        Found::Id(_) => {}
    })?;
    sequences
        .into_iter()
        .take(limit)
        .map(|sequence| u64::try_from(sequence).context("journal sequence is negative"))
        .collect()
}

/// The ids of the kind `kind` that the journal rows `start..=end` name, in
/// order.
pub(super) fn ids_in_range(
    connection: &Connection,
    kind: &str,
    start: u64,
    end: u64,
) -> anyhow::Result<Vec<String>> {
    let mut ids = BTreeSet::new();
    read(
        connection,
        IDS_IN_RANGE,
        params![kind, i64::try_from(start)?, i64::try_from(end)?],
        |found| match found {
            Found::Id(id) => {
                ids.insert(id);
            }
            Found::AfterTheMark(_, named) => {
                ids.extend(named.into_iter().filter(|(named, _)| named == kind).map(|(_, id)| id));
            }
            Found::Sequence(_) => {}
        },
    )?;
    Ok(ids.into_iter().collect())
}

/// Reads the leaf of the index that the next row of each subject
/// `(kind, id)` lands on, so that the page is in memory when a later commit
/// writes the row. A warm-up only: it gives no result, and it does not look
/// at the journal rows after the mark.
pub(crate) fn warm_leaves<'a>(
    connection: &Connection,
    subjects: impl Iterator<Item = (&'a str, &'a str)>,
) -> rusqlite::Result<()> {
    let mut newest = connection.prepare(
        "SELECT sequence FROM journal_subject_index WHERE kind = ?1 AND id = ?2
         ORDER BY sequence DESC LIMIT 1",
    )?;
    for (kind, id) in subjects {
        let mut rows = newest.query([kind, id])?;
        let _ = rows.next()?;
    }
    Ok(())
}

/// Output cleanup: the subject rows of the kept records `range` of a staging
/// registry, from the subjects that each staged record names. The staging
/// registry gets the rows of each kept record, so its mark can be before
/// rows that it holds; an open moves it.
pub(crate) fn write_rows_of_staged_records(
    staging: &Connection,
    range: [i64; 2],
) -> rusqlite::Result<usize> {
    staging.execute(
        "INSERT OR IGNORE INTO main.journal_subject_index(sequence, kind, id)
         SELECT kept.sequence,
                json_extract(subject.value, '$.kind'),
                json_extract(subject.value, '$.id')
         FROM main.output_cleanup_records AS kept,
              json_each(kept.index_json, '$.subjects') AS subject
         WHERE kept.sequence BETWEEN ?1 AND ?2
           AND json_type(subject.value, '$.kind') = 'text'
           AND json_type(subject.value, '$.id') = 'text'",
        range,
    )
}

/// The schema number that a rollback's check takes for the registry
/// `database` of the session directory `session` of the state root `root`,
/// whose stored number is `stored`. Each number that is not
/// [`ROWS_DUE_SCHEMA_VERSION`] is as stored, and nothing is written.
///
/// [`ROWS_DUE_SCHEMA_VERSION`] with a daemon that owns the session now reads
/// as [`SCHEMA_VERSION`]: that owner's stop writes the subject rows and puts
/// the number back before another build opens the store.
///
/// With no owner, no stop will write them (the owner ended with no stop
/// step), and one such session would refuse a rollback for each session. So
/// the check writes them here, as an open does ([`write_tail`]), with the
/// session's guard held: no daemon starts on the store in that time, and a
/// daemon that has the session gets no write from here. Then the number is
/// the one that the store has after the commit.
///
/// The guard has the name of `session`, and the open for the write follows
/// a link. So the caller gives a store at [`ROWS_DUE_SCHEMA_VERSION`] only
/// when `session` is a directory by itself and `database` is a plain file by
/// itself (`store_schemas::read_session`): with a link, the write would go
/// into a file of another folder under a guard that is not its guard.
///
/// A write that fails after the store gave [`ROWS_DUE_SCHEMA_VERSION`] with
/// the guard held reads as that number: a build that does not know the mark
/// must not open that store. The failed write is one transaction, so the
/// store is as it was.
///
/// Each doubt is an error, and the check then gives no number: the guard
/// cannot tell whether a daemon owns the session (a lock file is not there,
/// the lock of the session-locks directory stayed busy), or the store did
/// not open or did not give its number with the guard held. The number that
/// was read with no guard does not answer the question then: an owner's stop
/// puts [`SCHEMA_VERSION`] back.
pub(crate) fn stored_number_for_a_rollback(
    root: &Path,
    session: &Path,
    database: &Path,
    stored: i64,
) -> anyhow::Result<i64> {
    use crate::workspace_registry::session_guard::{WhileUnowned, while_no_daemon_owns};

    if stored != ROWS_DUE_SCHEMA_VERSION {
        return Ok(stored);
    }
    let doubt = || {
        format!(
            "the rollback check cannot tell whether an older build can open {}: journal subject \
             rows are due in it, and it is not known whether a daemon owns its session",
            database.display()
        )
    };
    let component = session
        .file_name()
        .and_then(|component| component.to_str())
        .with_context(|| format!("{} has no name of a session guard", session.display()))
        .with_context(doubt)?;
    let part = crate::store_schemas::Part::start();
    let found = while_no_daemon_owns(root, component, || write_tail_of_an_unowned_store(database));
    part.end("16: the 2 locks, with the write in them");
    match found.with_context(doubt)? {
        WhileUnowned::Owned => Ok(SCHEMA_VERSION),
        WhileUnowned::Ran(written) => match written.with_context(doubt)? {
            UnownedWrite::Number(number) => Ok(number),
            UnownedWrite::Failed(error) => {
                eprintln!(
                    "cmux-tui: the rollback check did not write the journal subject rows of {}: \
                     {error:#}",
                    database.display()
                );
                Ok(stored)
            }
        },
    }
}

/// What [`write_tail_of_an_unowned_store`] found in a store that it opened.
enum UnownedWrite {
    /// The stored schema number, after the write when the store had rows
    /// due.
    Number(i64),
    /// The store has rows due, and the write did not commit: the store is
    /// as it was.
    Failed(anyhow::Error),
}

/// The write of a stop and of an open ([`write_tail`]) on the store
/// `database`, for a caller that holds the session's guard.
///
/// The store is opened, never made. One transaction takes the write lock
/// first and reads the number again: only a store at
/// [`ROWS_DUE_SCHEMA_VERSION`] gets the write, because each other number
/// names a schema that this function does not know or a store with nothing
/// due. The commit is on the disk before this returns (`synchronous=FULL`,
/// and the full fsync of an owner's connection): the caller's answer lets
/// another build open the store. An error is a store that did not open or
/// did not give its number.
fn write_tail_of_an_unowned_store(database: &Path) -> anyhow::Result<UnownedWrite> {
    use crate::store_schemas::Part;

    #[cfg(test)]
    STORES_OPENED_FOR_A_WRITE.with(|stores| stores.set(stores.get() + 1));
    let part = Part::start();
    let mut connection = open_registry_database_with_flags(
        database,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.busy_timeout(std::time::Duration::from_millis(500))?;
    connection.execute_batch(REGISTRY_FULLFSYNC_PRAGMA)?;
    connection.execute_batch("PRAGMA synchronous=FULL;")?;
    part.end("write: the open");
    let part = Part::start();
    let transaction =
        connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let number = transaction.query_row(
        "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'schema_version'",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    part.end("write: the write lock and the number");
    if number != ROWS_DUE_SCHEMA_VERSION {
        return Ok(UnownedWrite::Number(number));
    }
    let part = Part::start();
    let rows = write_tail(&transaction);
    part.end("write: the rows");
    let part = Part::start();
    let written = rows.and_then(|_| transaction.commit().map_err(anyhow::Error::from));
    part.end("write: the commit");
    // The last connection of the store: its close puts the log in the main
    // file.
    let part = Part::start();
    drop(connection);
    part.end("write: the close");
    Ok(match written {
        Ok(()) => UnownedWrite::Number(SCHEMA_VERSION),
        Err(error) => UnownedWrite::Failed(error),
    })
}
