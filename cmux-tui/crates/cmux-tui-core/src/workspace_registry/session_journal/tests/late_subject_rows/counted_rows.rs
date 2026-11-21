//! Rows with a count of the journal rows that a read by subject or a write
//! of subject rows takes from the store.
//!
//! The counts are those of the thread that reads or writes
//! (`subject_rows::rows_read_after_the_mark`,
//! `subject_rows::rows_taken_by_writes`), so another test of the binary does
//! not move them. No row here takes the period: the journal rows after the
//! mark are a fixed count, made on the file ([`lose_rows`]).

use super::*;

/// The journal rows after the mark of the page row.
const TAIL: u64 = 99;
/// The limit of each page of the page row.
const LIMIT: usize = 64;
/// The journal rows of the stores of the 2 rows of a first open.
const FIRST_OPEN_ROWS: u64 = 250;

/// A page by subject takes the journal rows after the mark only when the
/// table gives fewer rows than the page's limit. The table holds the subject
/// rows of each journal row to the mark, so each row that the journal rows
/// after the mark give is after each row of the table: a page that the table
/// fills has none of them.
#[test]
fn a_page_that_the_table_fills_takes_no_journal_row_after_the_mark() {
    let store = fixture("full-page", 2_000);
    let head = store.head();
    let mark = store.lose_rows(TAIL);
    assert_eq!(mark, head - TAIL, "the mark of the crash file");
    // Each journal row of the fixture names the session, so the table has
    // one row of this subject for each journal row to the mark.
    let session = fixture_subjects(0)[..1].to_vec();
    let reader = store.reader();
    let limit = u64::try_from(LIMIT).unwrap();
    // What the page is, its cursor, and the journal rows after the mark
    // that the read must take.
    let pages = [
        ("a cursor far before the mark", 0, 0),
        ("the table has one row more than the page", mark - limit - 1, 0),
        ("the table has the rows of the page and no more", mark - limit, 0),
        ("the table has one row less than the page", mark - limit + 1, TAIL),
        ("the table has 10 rows", mark - 10, TAIL),
        ("the cursor is the mark", mark, TAIL),
        ("the cursor is 50 journal rows after the mark", mark + 50, TAIL - 50),
    ];
    let mut got = Vec::new();
    for (what, cursor, _) in pages {
        let before = subject_rows::rows_read_after_the_mark();
        store.check_page(what, &reader, cursor, LIMIT, &session);
        got.push((what, cursor, subject_rows::rows_read_after_the_mark() - before));
    }
    println!(
        "late_subject_rows: pages by one subject with the limit {LIMIT} in a fixture store of \
         {head} journal rows, {TAIL} of them after the mark {mark} (the page, its cursor, the \
         journal rows after the mark that the read took): {got:?}"
    );
    assert_eq!(
        got,
        pages.to_vec(),
        "the journal rows after the mark that each page took (the page, its cursor, the count); \
         a page that the table fills must take none"
    );
    store.check_file("after the pages");
}

/// The mark as the `meta` row has it: `None` for a store with no mark row.
fn stored_mark(database: &Path) -> Option<u64> {
    open_registry_database_read_only(database)
        .unwrap()
        .query_row("SELECT value FROM meta WHERE key = ?1", [MARK_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()
        .unwrap()
        .map(|value| value.parse().unwrap())
}

/// A fixture store after a stop, closed: each journal row has its subject
/// rows, the mark is the head and the schema number is 15. Returns the store,
/// its file and its head.
fn stopped_fixture(label: &str) -> (Store, PathBuf, u64) {
    let mut store = fixture(label, FIRST_OPEN_ROWS);
    store.registry().write_journal_subject_tail().unwrap();
    let (database, head) = (store.database(), store.head());
    assert_eq!(
        store.file_state(),
        (head, 0, PLAIN_NUMBER.to_string()),
        "after the stop's write (the mark, the journal rows after it, the number)"
    );
    drop(store.registry.take());
    (store, database, head)
}

/// What each open of the 2 rows below must leave: the mark row at the head,
/// the number 15, the subject rows of the record-time table, and each read
/// by subject as that table gives it.
fn check_after_an_open(store: &Store, database: &Path, what: &str) {
    let head = store.head();
    let number = store.file_state().2;
    assert_eq!(
        (stored_mark(database), number.as_str()),
        (Some(head), PLAIN_NUMBER),
        "{what}: (the mark row, the schema number) with the journal's head at {head}"
    );
    store.check_table(what, head);
    store.check_file(what);
    store.check_reads(what, &fixture_subjects(FIRST_OPEN_ROWS - 1), 64);
}

/// A store of a build that writes the subject rows at record time has the
/// table and no mark. Its first open with this build takes the newest
/// journal row as the mark: it writes no subject row a second time, and no
/// journal row is left with none.
#[test]
fn the_first_open_of_a_store_with_the_table_and_no_mark_writes_no_subject_row_again() {
    let (mut store, database, mut head) = stopped_fixture("no-mark");
    let connection = open_registry_database_with_flags(&database, OpenFlags::default()).unwrap();
    let removed = connection.execute("DELETE FROM meta WHERE key = ?1", [MARK_KEY]).unwrap();
    drop(connection);
    assert_eq!((removed, stored_mark(&database)), (1, None), "the store has no mark row now");
    for what in ["the first open of a store with the table and no mark", "the open after it"] {
        let before = subject_rows::rows_taken_by_writes();
        store.reopen(what);
        let taken = subject_rows::rows_taken_by_writes() - before;
        let added = store.head() - head;
        println!(
            "late_subject_rows: {what}, {head} journal rows: the open added {added} journal \
             rows and its writes of subject rows took {taken} journal rows"
        );
        assert!(
            taken <= added,
            "{what}: the writes of subject rows took {taken} journal rows of a store whose \
             {head} journal rows have their subject rows; the open added {added} journal rows"
        );
        check_after_an_open(&store, &database, what);
        head = store.head();
    }
}

/// A store with no subject table gets the subject rows of each journal row
/// at its open, also when a mark row says that the table holds them: a mark
/// of a store with no table names rows that no table has.
#[test]
fn the_first_open_of_a_store_with_no_subject_table_writes_the_rows_of_each_journal_row() {
    let (mut store, database, head) = stopped_fixture("no-table");
    let connection = open_registry_database_with_flags(&database, OpenFlags::default()).unwrap();
    connection.execute_batch(&format!("DROP TABLE {};", SUBJECT_TREES[0])).unwrap();
    let left: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE tbl_name = ?1",
            [SUBJECT_TREES[0]],
            |row| row.get(0),
        )
        .unwrap();
    drop(connection);
    assert_eq!(
        (left, stored_mark(&database)),
        (0, Some(head)),
        "the store has no subject table, no index and no trigger of it, and its mark row is at \
         the head"
    );
    let what = "the first open of a store with no subject table and the mark at the head";
    let before = subject_rows::rows_taken_by_writes();
    store.reopen(what);
    let taken = subject_rows::rows_taken_by_writes() - before;
    println!(
        "late_subject_rows: {what}, {head} journal rows: the writes of subject rows took {taken} \
         journal rows"
    );
    assert!(
        taken >= head,
        "{what}: the writes of subject rows took {taken} journal rows; the store had {head} \
         journal rows and no subject row"
    );
    check_after_an_open(&store, &database, what);
}
