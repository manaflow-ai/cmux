//! Subject rows that a later commit writes.
//!
//! A journal row names its subjects in its own `subjects_json`. The table
//! `journal_subject_index` holds one row for each subject of each journal
//! row, and a read by subject goes through it. These rows hold the rule for
//! a store whose subject rows end before its journal does:
//!
//! - The `meta` row `journal_subject_rows_through` (the mark) names the last
//!   journal row whose subject rows the table holds. The mark moves only in
//!   the commit that writes the subject rows to it.
//! - Each journal row after the mark is in the active table, and a read
//!   takes its subjects from its `subjects_json`.
//! - While a journal row is after the mark, the store's schema number is 16,
//!   so a build that does not know the rule does not open the store. A stop
//!   and an open write the subject rows to the head and put the 15 back.
//!
//! The oracle is a table that test code fills at record time, from each
//! record's own subjects, with the statement of a build that writes the
//! subject rows in the record transaction ([`RecordTimeTable`]). Each read by
//! subject of the registry must give what that build's statements give on it.
//!
//! A crash is modelled on the store's file ([`lose_rows`]): a second
//! connection moves the mark back and deletes the subject rows after it. That
//! is the file of an earlier point of the same run, where the subject rows of
//! the newest journal rows were not yet written. A close with no stop step
//! and an open is a crash at that point of the run.
//!
//! Each row prints `late_subject_rows` lines. A time in a line is a
//! measurement for a reader: no row asserts on a time.

use std::time::{Duration, Instant};

use serde_json::json;

use super::super::kind_read_tests::TestJournalRecord;
use super::*;

/// The `meta` row that names the last journal row whose subject rows the
/// table holds.
const MARK_KEY: &str = "journal_subject_rows_through";
/// The schema number of a store with no journal row after the mark, and of a
/// store with one.
const PLAIN_NUMBER: &str = "15";
pub(crate) const DUE_NUMBER: &str = "16";
/// The journal rows of one period: the commit of a journal row whose
/// sequence is a multiple of this writes the subject rows to it. It is the
/// product's one constant, not a second number.
pub(crate) const PERIOD: u64 = subject_rows::PERIOD.unsigned_abs();
const SESSION: &str = "late-subject-rows";

/// The rollback's check of the state root `root` with no end time: it reads
/// each session, so its answer is the numbers. An answer of a check that
/// stopped before its end fails the row.
fn stored_numbers(root: &Path) -> anyhow::Result<BTreeMap<String, i64>> {
    match crate::store_schemas::stored_until(root, None)? {
        crate::store_schemas::Stored::Schemas(found) => Ok(found),
        stopped => panic!("a check with no end time stopped before its end: {stopped:?}"),
    }
}

const SUBJECT_TABLE: &str = "CREATE TABLE journal_subject_index (
       sequence INTEGER NOT NULL CHECK(sequence > 0),
       kind TEXT NOT NULL,
       id TEXT NOT NULL,
       PRIMARY KEY(sequence, kind, id)
     ) WITHOUT ROWID;
     CREATE INDEX journal_subject_index_by_subject_sequence
       ON journal_subject_index(kind, id, sequence);";
const REJECT_DELETE: &str = "CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_delete
       BEFORE DELETE ON journal_subject_index
     BEGIN
       SELECT RAISE(ABORT, 'journal subject index is append-only');
     END;";
const ROWS_THROUGH: &str = "SELECT sequence, kind, id FROM journal_subject_index
     WHERE sequence <= ?1 ORDER BY sequence, kind, id";
/// The 2 b-trees of the subject rows, by their names in `dbstat`.
const SUBJECT_TREES: [&str; 2] =
    ["journal_subject_index", "journal_subject_index_by_subject_sequence"];
const WAL_HEADER: usize = 32;
const WAL_FRAME_HEADER: usize = 24;
/// The journal rows of the frames row's fixture before its period.
const FRAMES_FIXTURE_ROWS: u64 = 10_000;
/// The frames row's bound: the frames that one period writes in the 2
/// b-trees of the subject rows, as a percentage of the frames that the same
/// run writes there with a write after each journal row. Both counts are of
/// this run, so a change of the fixture or of a page's fill moves both. How
/// it was found: a run of this fixture gave 397 frames against 1,289, which
/// is 31 percent, and the counts are not the same at each run. The bound is
/// half: the row holds that a period writes fewer frames than a write row
/// by row, and (its other assert) more than none. A count at or above the
/// bound means that a period's write no longer shares its pages: the
/// subject rows are written row by row again, or a period got shorter.
const MAX_SUBJECT_FRAMES_PERCENT: usize = 50;
/// The seeds of the model row, and its steps for each seed.
const SEEDS: [u64; 4] =
    [0x9e37_79b9_7f4a_7c15, 0x2545_f491_4f6c_dd1d, 0x0123_4567_89ab_cdef, 0x0fed_cba9_8765_4321];
const STEPS: usize = 80;

fn int(value: u64) -> i64 {
    i64::try_from(value).unwrap()
}

pub(crate) fn ms(time: Duration) -> f64 {
    time.as_secs_f64() * 1000.0
}

/// The fastest of `runs` runs of `act`.
fn fastest(runs: usize, mut act: impl FnMut()) -> Duration {
    (0..runs)
        .map(|_| {
            let started = Instant::now();
            act();
            started.elapsed()
        })
        .min()
        .unwrap()
}

/// The subject rows of the journal rows to `sequence`, in the table's order.
fn rows_through(connection: &Connection, sequence: u64) -> Vec<(i64, String, String)> {
    connection
        .prepare(ROWS_THROUGH)
        .unwrap()
        .query_map([int(sequence)], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// What is not the same in the subject rows of the journal rows to
/// `through`: the store's file against the record-time table.
fn table_problem(database: &Path, table: &RecordTimeTable, through: u64) -> Option<String> {
    let got = rows_through(&open_registry_database_read_only(database).unwrap(), through);
    let wanted = rows_through(&table.connection, through);
    let first = got.iter().zip(&wanted).position(|(got, wanted)| got != wanted);
    (got != wanted).then(|| {
        format!(
            "the subject table has {} rows for the journal rows to {through} and the \
             record-time table has {}; the first row that is not the same: {first:?}",
            got.len(),
            wanted.len()
        )
    })
}

/// The subject table as a build that writes it in the record transaction
/// keeps it, with that build's 2 reads by subject.
struct RecordTimeTable {
    connection: Connection,
}

impl RecordTimeTable {
    fn new() -> Self {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(SUBJECT_TABLE).unwrap();
        Self { connection }
    }

    fn record(&self, sequence: u64, subjects: &[JournalSubject]) {
        self.connection
            .prepare_cached(
                "INSERT OR IGNORE INTO journal_subject_index(sequence, kind, id)
                 SELECT ?1, json_extract(value, '$.kind'), json_extract(value, '$.id')
                 FROM json_each(?2)",
            )
            .unwrap()
            .execute(params![int(sequence), serde_json::to_string(subjects).unwrap()])
            .unwrap();
    }

    /// The sequences of one page by subject.
    fn sequences_after(
        &self,
        sequence: u64,
        limit: usize,
        subjects: &[JournalSubject],
    ) -> Vec<u64> {
        self.connection
            .prepare_cached(
                "SELECT DISTINCT indexed.sequence
                 FROM json_each(?1) AS requested
                 JOIN journal_subject_index AS indexed
                   INDEXED BY journal_subject_index_by_subject_sequence
                   ON indexed.kind = json_extract(requested.value, '$.kind')
                  AND indexed.id = json_extract(requested.value, '$.id')
                 WHERE indexed.sequence > ?2
                 ORDER BY indexed.sequence ASC
                 LIMIT ?3",
            )
            .unwrap()
            .query_map(
                params![
                    serde_json::to_string(subjects).unwrap(),
                    int(sequence),
                    i64::try_from(limit).unwrap()
                ],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
            .map(|sequence| u64::try_from(sequence.unwrap()).unwrap())
            .collect()
    }

    /// The ids of one kind that the journal rows `start` to `end` name.
    fn ids_in_range(&self, kind: &str, start: u64, end: u64) -> BTreeSet<String> {
        self.connection
            .prepare_cached(
                "SELECT DISTINCT id FROM journal_subject_index
                 WHERE kind = ?1 AND sequence >= ?2 AND sequence <= ?3",
            )
            .unwrap()
            .query_map(params![kind, int(start), int(end)], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }
}

/// The mark, the count of active journal rows after it, and the schema
/// number, each as the file has it. A store with no mark is the store of a
/// build that writes the subject rows at record time: its mark is the head.
pub(crate) fn file_state(database: &Path, head: u64) -> (u64, u64, String) {
    let connection = open_registry_database_read_only(database).unwrap();
    let stored = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [MARK_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()
        .unwrap();
    let mark = stored.map_or(head, |value| value.parse::<u64>().unwrap());
    let after = connection
        .query_row("SELECT COUNT(*) FROM session_journal WHERE sequence > ?1", [int(mark)], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    let number = connection
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| {
            row.get::<_, String>(0)
        })
        .unwrap();
    (mark, u64::try_from(after).unwrap(), number)
}

/// What is wrong with the file for a build that knows the schema number
/// only: a journal row is after the mark and the number is not 16. Also
/// wrong: a mark after the head, and a journal row after the mark that is
/// not in the active table.
fn file_problem(database: &Path, head: u64) -> Option<String> {
    let (mark, after, number) = file_state(database, head);
    if mark > head {
        return Some(format!("the mark {mark} is after the journal's head {head}"));
    }
    if after != head - mark {
        return Some(format!(
            "{} journal rows are after the mark {mark} and {after} of them are active",
            head - mark
        ));
    }
    (after > 0 && number != DUE_NUMBER).then(|| {
        format!("{after} journal rows are after the mark {mark} and the schema number is {number}")
    })
}

/// The file that a crash leaves when the subject rows of the last `rows`
/// journal rows were not yet written: the mark is `rows` before the head (not
/// before `sealed`, the last sealed row, and not after the mark of now), no
/// subject row is after it, and the schema number is `number` when a journal
/// row is after it. Returns the mark.
pub(crate) fn lose_rows(database: &Path, head: u64, sealed: u64, rows: u64, number: &str) -> u64 {
    let mark = head.saturating_sub(rows).max(sealed).min(file_state(database, head).0);
    let connection = open_registry_database_with_flags(database, OpenFlags::default()).unwrap();
    connection.busy_timeout(Duration::from_secs(10)).unwrap();
    connection
        .execute_batch(
            "BEGIN IMMEDIATE;
             DROP TRIGGER IF EXISTS journal_subject_index_reject_delete;",
        )
        .unwrap();
    connection
        .execute("DELETE FROM journal_subject_index WHERE sequence > ?1", [int(mark)])
        .unwrap();
    connection
        .execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![MARK_KEY, mark.to_string()],
        )
        .unwrap();
    if mark < head {
        connection
            .execute("UPDATE meta SET value = ?1 WHERE key = 'schema_version'", [number])
            .unwrap();
    }
    connection.execute_batch(&format!("{REJECT_DELETE} COMMIT;")).unwrap();
    mark
}

/// What is wrong with the file of a store after a stop: a journal row is
/// after the mark, or the schema number is not 15, or the subject rows are
/// not the rows that a write at record time gives.
pub(crate) fn stopped_file_problem(database: &Path) -> Option<String> {
    let reader = SessionJournalReader::open(database).unwrap();
    let table = RecordTimeTable::new();
    let mut head = 0;
    loop {
        let page = reader.after(head, 1024).unwrap();
        let Some(last) = page.records.last() else { break };
        for record in &page.records {
            table.record(record.sequence, &record.subjects);
        }
        head = last.sequence;
    }
    let (mark, after, number) = file_state(database, head);
    if mark != head || after != 0 || number != PLAIN_NUMBER {
        return Some(format!(
            "after the stop the journal's head is {head}, the mark is {mark}, {after} active \
             journal rows are after it and the schema number is {number}"
        ));
    }
    table_problem(database, &table, head)
}

/// One page by subject: its sequences, how far it scanned, and the head.
type Page = (Vec<u64>, u64, u64);

pub(crate) fn records(rows: &[Vec<JournalSubject>]) -> Vec<TestJournalRecord> {
    rows.iter()
        .enumerate()
        .map(|(index, subjects)| TestJournalRecord {
            kind: "agent.turn.started".into(),
            producer: JournalProducer {
                kind: "agent_adapter".into(),
                id: crate::AGENT_HOOK_PRODUCER_ID.into(),
            },
            subjects: subjects.clone(),
            payload: json!({"turn": index}),
        })
        .collect()
}

/// A registry on a file of its own, and the record-time table of its journal.
struct Store {
    root: PathBuf,
    registry: Option<WorkspaceRegistry>,
    table: RecordTimeTable,
    /// The last journal row that the record-time table has.
    recorded: u64,
    seals: usize,
}

impl Store {
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-late-subject-rows-{label}-{}", new_uuid_v4().replace('-', "")));
        let registry = WorkspaceRegistry::open(&root, SESSION).unwrap();
        let mut store = Self {
            root,
            registry: Some(registry),
            table: RecordTimeTable::new(),
            recorded: 0,
            seals: 0,
        };
        store.record();
        store
    }

    fn registry(&self) -> &WorkspaceRegistry {
        self.registry.as_ref().expect("the store is open")
    }

    fn database(&self) -> PathBuf {
        self.registry().session_journal_database_path().unwrap()
    }

    fn head(&self) -> u64 {
        self.registry().session_journal_head().unwrap()
    }

    /// Puts each journal row after the last recorded one in the record-time
    /// table, from the record's own subjects.
    fn record(&mut self) {
        let head = self.head();
        while self.recorded < head {
            let page = self.registry().session_journal_after(self.recorded, 1024).unwrap();
            assert!(!page.records.is_empty(), "the journal has rows after {}", self.recorded);
            for record in &page.records {
                self.table.record(record.sequence, &record.subjects);
                self.recorded = record.sequence;
            }
        }
    }

    /// Appends one journal row for each entry of `rows`, in one transaction.
    fn append(&mut self, rows: &[Vec<JournalSubject>]) {
        self.registry().append_journal_records_for_test(&records(rows));
        self.record();
    }

    /// Seals the journal to its head.
    fn seal(&mut self) {
        self.seals += 1;
        let key = format!("late_subject_rows_{}", self.seals);
        self.registry.as_mut().expect("the store is open").seal_journal_for_test(&key);
        self.record();
    }

    /// Closes the store with no stop step and opens it again. Returns the
    /// time of the open.
    fn reopen(&mut self, what: &str) -> Duration {
        drop(self.registry.take());
        let started = Instant::now();
        let registry = WorkspaceRegistry::open(&self.root, SESSION)
            .unwrap_or_else(|error| panic!("{what}: the store does not open: {error:#}"));
        let took = started.elapsed();
        self.registry = Some(registry);
        self.record();
        took
    }

    /// A stop's write of the subject rows, a close and an open. After the
    /// write no journal row is after the mark and the schema number is 15.
    fn stop_and_reopen(&mut self, what: &str) {
        self.registry().write_journal_subject_tail().unwrap();
        let head = self.head();
        let (mark, after, number) = self.file_state();
        assert_eq!(
            (mark, after, number.as_str()),
            (head, 0, PLAIN_NUMBER),
            "{what}: after the stop's write (the mark, the journal rows after it, the number)"
        );
        self.check_table(what, head);
        self.reopen(what);
    }

    fn file_state(&self) -> (u64, u64, String) {
        file_state(&self.database(), self.head())
    }

    /// See [`lose_rows`]: the schema number is 16 when a journal row is
    /// after the mark.
    fn lose_rows(&self, rows: u64) -> u64 {
        self.lose_rows_with_number(rows, DUE_NUMBER)
    }

    fn lose_rows_with_number(&self, rows: u64, number: &str) -> u64 {
        let sealed = self.registry().journal_segments_end().unwrap();
        lose_rows(&self.database(), self.head(), sealed, rows, number)
    }

    fn file_problem(&self) -> Option<String> {
        file_problem(&self.database(), self.head())
    }

    /// The file's check, as a build that knows the schema number only reads
    /// it ([`file_problem`]), and the subject rows of each journal row to
    /// the mark against the record-time table's.
    fn check_file(&self, what: &str) {
        let problem = self.file_problem();
        assert!(problem.is_none(), "{what}: {}", problem.unwrap_or_default());
        self.check_table(what, self.file_state().0);
    }

    /// The reader that a journal stream by subject uses.
    fn reader(&self) -> SessionJournalReader {
        SessionJournalReader::open(&self.database()).unwrap()
    }

    fn page(
        reader: &SessionJournalReader,
        sequence: u64,
        limit: usize,
        subjects: &[JournalSubject],
    ) -> Page {
        let page = reader.after_subjects(sequence, limit, subjects).unwrap();
        let sequences = page.records.iter().map(|record| record.sequence).collect();
        (sequences, page.scanned_through, page.head_sequence)
    }

    /// The page that a build with the record-time table gives.
    fn wanted_page(&self, sequence: u64, limit: usize, subjects: &[JournalSubject]) -> Page {
        let sequences = self.table.sequences_after(sequence, limit, subjects);
        let scanned = if sequences.len() == limit {
            sequences.last().copied().unwrap_or(sequence)
        } else {
            self.recorded
        };
        (sequences, scanned, self.recorded)
    }

    /// One page by subject against the record-time table. Returns how far it
    /// scanned.
    fn check_page(
        &self,
        what: &str,
        reader: &SessionJournalReader,
        sequence: u64,
        limit: usize,
        subjects: &[JournalSubject],
    ) -> u64 {
        let got = Self::page(reader, sequence, limit, subjects);
        assert_eq!(
            got,
            self.wanted_page(sequence, limit, subjects),
            "{what}: a page by subject after {sequence} with the limit {limit} of {subjects:?} \
             (its sequences, how far it scanned, the head) is not the record-time table's"
        );
        got.1
    }

    /// Each page by `subjects` from the journal's start to its head.
    fn check_pages(
        &self,
        what: &str,
        reader: &SessionJournalReader,
        limit: usize,
        subjects: &[JournalSubject],
    ) {
        let mut cursor = 0;
        while cursor < self.recorded {
            let scanned = self.check_page(what, reader, cursor, limit, subjects);
            assert!(scanned > cursor, "{what}: a page after {cursor} scanned to {scanned}");
            cursor = scanned;
        }
    }

    /// The ids of one kind in a range against the record-time table.
    fn check_ids(&self, what: &str, kind: &str, start: u64, end: u64) {
        let got = self
            .registry()
            .journal_subject_ids_in_range(kind, start, end)
            .unwrap()
            .into_iter()
            .collect::<BTreeSet<_>>();
        assert_eq!(
            got,
            self.table.ids_in_range(kind, start, end),
            "{what}: the ids of the kind {kind} that the journal rows {start} to {end} name are \
             not the record-time table's"
        );
    }

    /// Each read by subject against the record-time table: the pages of each
    /// subject of `subjects` alone and of all together, from the journal's
    /// start to its head, and the ids of each kind over the whole journal.
    fn check_reads(&self, what: &str, subjects: &[JournalSubject], limit: usize) {
        let reader = self.reader();
        for subject in subjects {
            self.check_pages(what, &reader, limit, std::slice::from_ref(subject));
        }
        self.check_pages(what, &reader, limit, subjects);
        let kinds = subjects.iter().map(|subject| subject.kind.as_str()).collect::<BTreeSet<_>>();
        for kind in kinds {
            self.check_ids(what, kind, 1, self.recorded.max(1));
        }
    }

    /// The subject rows of the journal rows to `through` against the
    /// record-time table's.
    fn check_table(&self, what: &str, through: u64) {
        let problem = table_problem(&self.database(), &self.table, through);
        assert!(problem.is_none(), "{what}: {}", problem.unwrap_or_default());
    }

    /// The schema number that a rollback's check reads for the store.
    fn rollback_number(&self) -> i64 {
        stored_numbers(&self.root).unwrap()["workspace_registry"]
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        drop(self.registry.take());
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The 7 subjects of the journal row `row` of the fixture: the one session,
/// and a workspace, a screen, a pane, a tab, a terminal and an agent. The
/// fixture has 100 workspaces with 1 screen and 4 terminals each; a terminal
/// has 1 pane, 1 tab and 1 agent. 9 of 10 journal rows are of 40 terminals in
/// turn; each tenth row is of the other 360 in turn. The first 8 hex digits
/// of an id come from a product with a constant, so that ids near in count
/// are not near in the index.
pub(crate) fn fixture_subjects(row: u64) -> Vec<JournalSubject> {
    let terminal = if row % 10 == 9 { 40 + (row / 10) % 360 } else { (row - (row + 1) / 10) % 40 };
    let workspace = terminal / 4;
    let subject = |kind: &str, index: u64| JournalSubject {
        kind: kind.into(),
        id: format!("{kind}_{:08x}{index:024x}", index.wrapping_mul(2_654_435_761) & 0xffff_ffff),
    };
    vec![
        subject("session", 0),
        subject("workspace", workspace),
        subject("screen", workspace),
        subject("pane", terminal),
        subject("tab", terminal),
        subject("terminal", terminal),
        subject("agent", terminal),
    ]
}

/// A store with `rows` journal rows of the fixture, 1,000 in a transaction.
fn fixture(label: &str, rows: u64) -> Store {
    let mut store = Store::new(label);
    let mut next = 0;
    while store.head() < rows {
        let count = (rows - store.head()).min(1_000);
        let batch = (next..next + count).map(fixture_subjects).collect::<Vec<_>>();
        store.append(&batch);
        next += count;
    }
    store
}

#[test]
fn a_page_by_subject_over_rows_after_the_mark_is_the_page_of_the_record_time_table() {
    let store = fixture("page", 2_000);
    let head = store.head();
    let session = fixture_subjects(0)[..1].to_vec();
    let limit = usize::try_from(PERIOD).unwrap();
    let reader = store.reader();
    let page = || Store::page(&reader, head - PERIOD, limit, &session);
    let wanted = store.wanted_page(head - PERIOD, limit, &session);
    assert_eq!(wanted.0.len(), limit, "each journal row of the fixture names the session");
    assert_eq!(page(), wanted, "a page by subject with each subject row in the table");
    let in_the_table = fastest(20, || drop(page()));
    assert_eq!(store.lose_rows(PERIOD), head - PERIOD);
    let got = page();
    let after_the_mark = fastest(20, || drop(page()));
    println!(
        "late_subject_rows: a page by subject over the last {PERIOD} journal rows of {head} \
         (the fastest of 20 reads): {:.3} ms with their subject rows in the table, {:.3} ms with \
         the {PERIOD} journal rows after the mark",
        ms(in_the_table),
        ms(after_the_mark)
    );
    assert_eq!(
        got, wanted,
        "a page by subject over {PERIOD} journal rows after the mark (its sequences, how far it \
         scanned, the head) is not the record-time table's"
    );
    let what = "the last period's journal rows are after the mark";
    store.check_reads(what, &fixture_subjects(head - 1), 64);
    store.check_file(what);
}

#[test]
fn the_ids_of_a_range_after_the_mark_come_from_the_rows_and_a_read_skips_what_the_write_skips() {
    let store = fixture("ids", 300);
    let head = store.head();
    assert_eq!(store.lose_rows(60), head - 60);
    let what = "the last 60 journal rows are after the mark";
    for kind in ["terminal", "workspace", "session"] {
        store.check_ids(what, kind, head - 59, head);
        store.check_ids(what, kind, head - 150, head - 30);
        store.check_ids(what, kind, 1, head);
    }
    // File damage in 2 journal rows after the mark (an append stores the
    // subjects from typed values, so no build writes these): the subjects of
    // one are not a list; the other names one subject that reads, then a
    // number and an object with no id.
    const DAMAGED: &str = "terminal_damaged";
    let connection =
        open_registry_database_with_flags(&store.database(), OpenFlags::default()).unwrap();
    connection.execute_batch("DROP TRIGGER IF EXISTS session_journal_reject_update;").unwrap();
    let damage = "UPDATE session_journal SET subjects_json = ?2 WHERE sequence = ?1";
    connection.execute(damage, params![int(head - 10), r#"{"kind":"terminal"}"#]).unwrap();
    let some = format!(r#"[{{"kind":"terminal","id":"{DAMAGED}"}},7,{{"kind":"terminal"}}]"#);
    connection.execute(damage, params![int(head - 20), some]).unwrap();
    drop(connection);
    // Each read by subject gives the same from the journal rows after the
    // mark as from the table after the write of their subject rows: a
    // subject that does not read is skipped by both, and each skip is
    // counted.
    let named = JournalSubject { kind: "terminal".into(), id: DAMAGED.into() };
    let reads = || {
        let registry = store.registry();
        let ids = registry.journal_subject_ids_in_range("terminal", head - 59, head).unwrap();
        let sequences = subject_rows::sequences_after(
            &registry.connection.get(),
            0,
            8,
            std::slice::from_ref(&named),
        )
        .unwrap();
        (ids, sequences)
    };
    let skipped = subject_rows::skipped_subjects();
    let from_the_rows = reads();
    let skipped_by_the_reads = subject_rows::skipped_subjects() - skipped;
    assert_eq!(skipped_by_the_reads, 6, "2 reads, each over the 3 subjects that do not read");
    assert_eq!(from_the_rows.1, vec![head - 20], "the journal row that names the id that reads");
    assert!(from_the_rows.0.contains(&DAMAGED.to_string()), "{:?}", from_the_rows.0);
    store.registry().write_journal_subject_tail().unwrap();
    let skipped_by_the_write = subject_rows::skipped_subjects() - skipped - skipped_by_the_reads;
    assert_eq!(skipped_by_the_write, 3, "the write skips the 3 subjects that do not read");
    assert_eq!(store.file_state().0, head, "the write moved the mark to the head");
    assert_eq!(
        reads(),
        from_the_rows,
        "the ids of the range and the page by subject, from the table after the write, are \
         those from the journal rows after the mark before it"
    );
    store.check_ids("a range before the rows whose subjects do not read", "terminal", 1, head - 21);
}

#[test]
fn an_open_writes_the_subject_rows_that_a_crash_left_out() {
    for rows in [PERIOD, 10 * PERIOD] {
        let mut store = fixture("open", 2_000);
        let head = store.head();
        let plain = store.reopen("an open of a store with each subject row in the table");
        println!(
            "late_subject_rows: an open of a store of {head} journal rows with no subject row \
             to write: {:.3} ms",
            ms(plain)
        );
        assert_eq!(store.lose_rows(rows), head - rows);
        let what = format!("a crash with the subject rows of {rows} journal rows not written");
        store.check_file(&what);
        let repair = store.reopen(&what);
        let after = store.reopen(&what);
        println!(
            "late_subject_rows: an open of that store with the subject rows of {rows} journal \
             rows to write: {:.3} ms; the open after it: {:.3} ms",
            ms(repair),
            ms(after)
        );
        let what = format!("{what}, and an open");
        store.check_table(&what, head);
        store.check_file(&what);
        store.check_reads(&what, &fixture_subjects(head - 1), 64);
        let (mark, _, number) = store.file_state();
        assert!(mark >= head, "{what}: the mark {mark} is before the journal row {head}");
        if store.head() == head {
            assert_eq!(number, PLAIN_NUMBER, "{what}, with no new journal row");
        }
    }
}

#[test]
fn a_seal_over_rows_after_the_mark_writes_their_subject_rows_first() {
    let mut store = fixture("seal", 300);
    let head = store.head();
    assert_eq!(store.lose_rows(150), head - 150);
    store.seal();
    let sealed = store.registry().journal_segments_end().unwrap();
    assert!(sealed >= head, "the seal went to the journal row {sealed} of {head}");
    let what = "a seal over 150 journal rows after the mark";
    store.check_table(what, sealed);
    store.check_file(what);
    store.check_reads(what, &fixture_subjects(head - 1), 64);
    store.reopen(what);
    let what = "a seal over 150 journal rows after the mark, and an open";
    store.check_table(what, sealed);
    store.check_file(what);
    store.check_reads(what, &fixture_subjects(head - 1), 64);
}

/// The frames that the store's WAL file got after the last read of it.
struct WalFrames {
    path: PathBuf,
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: Vec<u8>,
    seen: usize,
}

impl WalFrames {
    fn new(database: &Path) -> Self {
        let mut path = database.as_os_str().to_owned();
        path.push("-wal");
        let mut frames = Self { path: path.into(), salts: Vec::new(), seen: 0 };
        frames.new_pages();
        frames
    }

    /// The page of each new frame. A frame after the header is 24 bytes and
    /// one page: its first 4 bytes are the page's number, and bytes 8 to 16
    /// are the salts of the header.
    fn new_pages(&mut self) -> Vec<u32> {
        let bytes = fs::read(&self.path).unwrap_or_default();
        let Some(header) = bytes.get(..WAL_HEADER) else { return Vec::new() };
        let page = usize::try_from(u32::from_be_bytes(header[8..12].try_into().unwrap())).unwrap();
        if page == 0 {
            return Vec::new();
        }
        let salts = header[16..24].to_vec();
        let pages = bytes[WAL_HEADER..]
            .chunks_exact(WAL_FRAME_HEADER + page)
            .take_while(|frame| frame[8..16] == salts[..])
            .map(|frame| u32::from_be_bytes(frame[..4].try_into().unwrap()))
            .collect::<Vec<_>>();
        if salts != self.salts {
            self.salts = salts;
            self.seen = 0;
        }
        let new = pages[self.seen.min(pages.len())..].to_vec();
        self.seen = pages.len();
        new
    }
}

/// The b-tree of each page of the store, by `dbstat`.
fn page_trees(database: &Path) -> BTreeMap<u32, String> {
    open_registry_database_read_only(database)
        .unwrap()
        .prepare("SELECT pageno, name FROM dbstat")
        .unwrap()
        .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))
        .unwrap()
        .map(|row| {
            let (page, name) = row.unwrap();
            (u32::try_from(page).unwrap(), name)
        })
        .collect()
}

#[test]
fn a_period_of_journal_rows_writes_its_subject_rows_one_time() {
    let mut store = fixture("frames", FRAMES_FIXTURE_ROWS);
    assert_eq!(store.head(), FRAMES_FIXTURE_ROWS, "the fixture ends at the end of a period");
    let database = store.database();
    let mut wal = WalFrames::new(&database);
    let (mut pages, mut times) = (Vec::new(), Vec::new());
    for row in 0..PERIOD {
        let record = records(&[fixture_subjects(FRAMES_FIXTURE_ROWS + row)]);
        let started = Instant::now();
        store.registry().append_journal_records_for_test(&record);
        times.push(started.elapsed());
        pages.extend(wal.new_pages());
    }
    store.record();
    let in_subject_trees = |pages: &[u32]| {
        let trees = page_trees(&database);
        let of_subjects = |page: &&u32| {
            trees.get(*page).is_some_and(|tree| SUBJECT_TREES.contains(&tree.as_str()))
        };
        pages.iter().filter(of_subjects).count()
    };
    let subject_frames = in_subject_trees(&pages);
    // The last row of the loop ends the period: its commit wrote the subject
    // rows of the period, so the count is not 0 and the mark is at the head.
    let (mark, head) = (store.file_state().0, store.head());
    assert!(
        subject_frames > 0 && mark == head,
        "{PERIOD} journal rows to the end of a period wrote {subject_frames} frames in the \
         subject table and its index, and the mark is {mark} with the journal's head at {head}"
    );
    // The same count with a write after each journal row, as the write at
    // record time was: the next period's rows, each with the stop's write.
    let mut row_by_row = Vec::new();
    for row in PERIOD..2 * PERIOD {
        let record = records(&[fixture_subjects(FRAMES_FIXTURE_ROWS + row)]);
        store.registry().append_journal_records_for_test(&record);
        store.registry().write_journal_subject_tail().unwrap();
        row_by_row.extend(wal.new_pages());
    }
    store.record();
    let row_by_row_frames = in_subject_trees(&row_by_row);
    let last = times.pop().unwrap();
    times.sort();
    println!(
        "late_subject_rows: {PERIOD} journal rows with 7 subjects each, each row in a commit of \
         its own, after {FRAMES_FIXTURE_ROWS} journal rows of the fixture: {} WAL frames, \
         {subject_frames} of them in the subject table and its index ({row_by_row_frames} for \
         the next {PERIOD} journal rows with a write after each row); the commit of the row \
         that ends the period: {:.3} ms; the {} commits before it: median {:.3} ms, slowest \
         {:.3} ms",
        pages.len(),
        ms(last),
        times.len(),
        ms(times[times.len() / 2]),
        ms(times[times.len() - 1])
    );
    assert!(
        subject_frames * 100 < row_by_row_frames * MAX_SUBJECT_FRAMES_PERCENT,
        "{PERIOD} journal rows wrote {subject_frames} frames in the subject table and its \
         index, and the next {PERIOD} wrote {row_by_row_frames} with a write after each row; \
         the bound is below {MAX_SUBJECT_FRAMES_PERCENT} percent of that"
    );
    let what = "after a period of journal rows and a period with a write after each row";
    store.check_file(what);
    store.check_reads(what, &fixture_subjects(FRAMES_FIXTURE_ROWS + 2 * PERIOD - 1), 64);
}

/// A generator with a seed: the same steps at each run.
struct Dice(u64);

impl Dice {
    fn below(&mut self, bound: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % bound
    }

    fn index(&mut self, bound: usize) -> usize {
        usize::try_from(self.below(u64::try_from(bound).unwrap())).unwrap()
    }

    /// `least` to `most` subjects of `pool`.
    fn subjects(
        &mut self,
        pool: &[JournalSubject],
        least: usize,
        most: usize,
    ) -> Vec<JournalSubject> {
        let count = least + self.index(most - least + 1);
        (0..count).map(|_| pool[self.index(pool.len())].clone()).collect()
    }

    /// `count` journal rows with 1 to 3 subjects of `pool` each; a row in 8
    /// has none.
    fn batch(&mut self, pool: &[JournalSubject], count: u64) -> Vec<Vec<JournalSubject>> {
        (0..count)
            .map(|_| if self.below(8) == 0 { Vec::new() } else { self.subjects(pool, 1, 3) })
            .collect()
    }
}

/// The subjects of the model row: 6 terminals, 3 workspaces and 2 agents.
fn pool() -> Vec<JournalSubject> {
    [("terminal", 6), ("workspace", 3), ("agent", 2)]
        .into_iter()
        .flat_map(|(kind, count)| {
            (0..count).map(move |index| JournalSubject {
                kind: kind.into(),
                id: format!("{kind}_{index:032x}"),
            })
        })
        .collect()
}

/// The model row: steps by a seed (appends of 1 to 30 journal rows and at
/// times to 150, single reads, seals, a close with no stop step and an open,
/// a crash file and an open, a stop and an open, a crash file with no open).
/// After each step:
/// the file's check and, where the step names it, each read against the
/// record-time table.
#[test]
fn each_read_by_subject_is_the_record_time_tables_through_appends_seals_opens_and_crashes() {
    let pool = pool();
    for seed in SEEDS {
        let mut dice = Dice(seed);
        let mut store = Store::new("model");
        for step in 0..STEPS {
            let what = format!("seed {seed:#x}, step {step}");
            let limit = 8 + dice.index(57);
            match dice.below(13) {
                0..=4 => {
                    let most = if dice.below(8) == 0 { 150 } else { 30 };
                    let count = 1 + dice.below(most);
                    let batch = dice.batch(&pool, count);
                    store.append(&batch);
                }
                5 | 6 => {
                    let subjects = dice.subjects(&pool, 1, 3);
                    let cursor = dice.below(store.head() + 1);
                    store.check_page(&what, &store.reader(), cursor, limit, &subjects);
                }
                7 => {
                    let head = store.head().max(1);
                    let start = 1 + dice.below(head);
                    let end = start + dice.below(head - start + 1);
                    let kind = pool[dice.index(pool.len())].kind.as_str();
                    store.check_ids(&what, kind, start, end);
                }
                8 => {
                    if store.head() > store.registry().journal_segments_end().unwrap() {
                        store.seal();
                        store.check_reads(&format!("{what}: after a seal"), &pool, limit);
                    }
                }
                9 => {
                    let what = format!("{what}: a close with no stop step and an open");
                    store.reopen(&what);
                    store.check_reads(&what, &pool, limit);
                }
                10 => {
                    let head = store.head();
                    store.lose_rows(dice.below(2 * PERIOD + 1));
                    store.check_file(&format!("{what}: the file of a crash"));
                    let what = format!("{what}: journal rows after the mark, a crash and an open");
                    store.reopen(&what);
                    store.check_table(&what, head);
                    store.check_reads(&what, &pool, limit);
                }
                11 => {
                    let what = format!("{what}: a stop and an open");
                    store.stop_and_reopen(&what);
                    store.check_reads(&what, &pool, limit);
                }
                _ => {
                    store.lose_rows(dice.below(PERIOD + 1));
                    let what = format!("{what}: journal rows after the mark");
                    store.check_reads(&what, &pool, limit);
                }
            }
            store.check_file(&what);
        }
        store.check_reads(&format!("seed {seed:#x}, the end"), &pool, 64);
    }
}

/// Each point of a period: 1 to 100 journal rows after the end of a period,
/// each row in a commit of its own with the file's check after it, then the
/// file of a crash at that point, and an open.
#[test]
fn a_crash_at_each_point_of_a_period_and_an_open_lose_no_subject_row() {
    let pool = pool();
    let mut dice = Dice(SEEDS[0]);
    let mut store = Store::new("each-point");
    for rows in 1..=PERIOD {
        let to_the_end = (PERIOD - store.head() % PERIOD) % PERIOD;
        if to_the_end > 0 {
            let batch = dice.batch(&pool, to_the_end);
            store.append(&batch);
        }
        for _ in 0..rows {
            let batch = dice.batch(&pool, 1);
            store.append(&batch);
            let problem = store.file_problem();
            assert!(
                problem.is_none(),
                "after a journal row in a commit of its own: {}",
                problem.unwrap_or_default()
            );
            // The row that ends a period writes the subject rows, so the
            // journal rows after the mark stay fewer than a period.
            let (mark, after, _) = store.file_state();
            assert!(
                after < PERIOD,
                "after a journal row in a commit of its own, {after} journal rows are after the \
                 mark {mark}; a period has {PERIOD}"
            );
        }
        let what = format!("a crash {rows} journal rows after the end of a period");
        let head = store.head();
        store.lose_rows(rows);
        store.check_file(&what);
        store.reopen(&what);
        let what = format!("{what}, and an open");
        store.check_table(&what, head);
        store.check_file(&what);
    }
    store.check_reads("after a crash at each point of a period", &pool, 64);
}

/// A control of the file's check: it fails for the number 15 with a journal
/// row after the mark, and passes for the number 16 with one.
#[test]
fn the_check_of_the_file_fails_for_the_number_15_with_a_journal_row_after_the_mark() {
    let pool = pool();
    let mut dice = Dice(SEEDS[1]);
    let mut store = Store::new("check");
    let batch = dice.batch(&pool, 50);
    store.append(&batch);
    store.reopen("an open of a store with no crash before it");
    assert_eq!(store.file_problem(), None, "after an open");
    store.lose_rows_with_number(10, PLAIN_NUMBER);
    let problem = store.file_problem().expect("the number 15 with 10 journal rows after the mark");
    assert!(problem.contains("the schema number is 15"), "{problem}");
    store.lose_rows(10);
    assert_eq!(store.file_problem(), None, "the number 16 with 10 journal rows after the mark");
}

/// A store with journal rows after the mark and the schema number 16.
fn store_with_rows_due(label: &str) -> Store {
    let mut store = Store::new(label);
    let batch = (0..20).map(fixture_subjects).collect::<Vec<_>>();
    store.append(&batch);
    store.lose_rows(10);
    let (_, after, number) = store.file_state();
    assert!(after > 0, "journal rows are after the mark");
    assert_eq!(number, DUE_NUMBER);
    store
}

#[test]
fn the_rollback_check_reads_15_for_a_store_at_16_that_a_running_owner_has() {
    let store = store_with_rows_due("rollback-owned");
    assert_eq!(
        store.rollback_number(),
        15,
        "the owner runs: its stop writes the subject rows and puts the 15 back"
    );
}

// The rows of a store at 16 that no owner has, and of the check while a
// session starts and ends: `late_subject_rows/rollback_check.rs`.

#[test]
fn the_rollback_check_reads_a_number_above_16_as_it_is_with_a_running_owner() {
    let store = store_with_rows_due("rollback-newer");
    let connection =
        open_registry_database_with_flags(&store.database(), OpenFlags::default()).unwrap();
    connection.execute("UPDATE meta SET value = '17' WHERE key = 'schema_version'", []).unwrap();
    assert_eq!(store.rollback_number(), 17);
}

/// The files of `dir` that are product code: no test file and no file of a
/// `tests` directory.
fn product_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if path.is_dir() {
            if name != "tests" {
                product_sources(&path, out);
            }
        } else if name.ends_with(".rs") && !name.ends_with("_tests.rs") && name != "tests.rs" {
            out.push(path);
        }
    }
}

/// One module names the subject table: `subject_rows`. Its statements are
/// private, so a new read or write of the table is a new function there, and
/// each read by subject goes through its one read. The 2 other files name
/// the table in a list of table names only (the tables that an open checks
/// and touches, the tables that an output cleanup makes again).
#[test]
fn no_product_file_outside_the_one_module_names_the_subject_table() {
    const MODULE: &str = "workspace_registry/session_journal/subject_rows.rs";
    const LISTS: [(&str, usize); 2] =
        [("workspace_registry/schema.rs", 2), ("workspace_registry/output_cleanup.rs", 1)];
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    product_sources(&root, &mut files);
    assert!(files.len() > 100, "the crate's sources were read: {}", files.len());
    let mut found = Vec::new();
    for path in files {
        let shown = path.strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/");
        if shown == MODULE {
            continue;
        }
        let text = fs::read_to_string(&path).unwrap();
        let lines = text
            .lines()
            .enumerate()
            .filter(|(_, line)| line.contains(SUBJECT_TREES[0]))
            .map(|(number, line)| format!("{shown}:{}: {}", number + 1, line.trim()))
            .collect::<Vec<_>>();
        let allowed = LISTS.iter().find(|(file, _)| *file == shown).map_or(0, |(_, count)| *count);
        if lines.len() != allowed {
            found.push(format!(
                "{shown}: {} lines, {allowed} allowed\n{}",
                lines.len(),
                lines.join("\n")
            ));
        }
    }
    assert!(
        found.is_empty(),
        "a product file outside `subject_rows` names the subject table; read and write it \
         through that module:\n{}",
        found.join("\n")
    );
}

mod counted_rows;
mod rollback_check;
