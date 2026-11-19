//! MEASURE, NOT FOR A MERGE. The costs of the late write of the subject rows
//! in a large store: a fixture of 1,000,000 journal rows with 7 subjects each
//! ([`fixture_subjects`]), made by the registry's own append.
//!
//! The period is the product's one constant ([`PERIOD`]); a second commit of
//! this branch changes it to 1,000, and the same test runs again. For that
//! period the test prints:
//!
//! 1. The late write: 3,000 journal rows, each in a commit of its own. The
//!    WAL frames of a journal row, all and those in the subject table and its
//!    index; the time of the commits that end a period and of the others; and
//!    how long a second thread waits for the registry's connection while
//!    these commits run.
//! 2. The write row by row: 1,000 journal rows with the stop's write after
//!    each row, which is what the write at record time wrote in the subject
//!    table and its index. Its frames of a journal row.
//! 3. A full tail (one journal row less than a period after the mark), 5
//!    times: a page by subject over the tail from the rows after the mark and
//!    from the table, and the stop's write of the tail with its frames.
//! 4. An open, 3 times: with nothing to write, and after a close with no stop
//!    step and a full tail.
//!
//! Each line starts with `late_subject_rows size:`. A time is the test's own
//! clock around one call. No assert is on a time or on a count of frames.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use super::*;

/// The journal rows of the store before the first measure.
const STORE_ROWS: u64 = 1_000_000;
/// The journal rows of the late write's part: a multiple of 100 and of 1,000.
const LATE_ROWS: u64 = 3_000;
/// The journal rows of the part with a write after each row.
const ROW_BY_ROW_ROWS: u64 = 1_000;
const TAILS: usize = 5;
const OPENS: usize = 3;
/// The pause of the second thread between 2 asks.
const ASK_PAUSE: Duration = Duration::from_micros(200);

fn line(text: &str) {
    println!("late_subject_rows size: {text}");
}

/// The median and the largest of `times`, in ms.
fn median_and_max(times: &mut [Duration]) -> String {
    times.sort();
    format!(
        "median {:.3} ms, slowest {:.3} ms",
        ms(times[times.len() / 2]),
        ms(times[times.len() - 1])
    )
}

/// Each of `times` in ms.
fn each(times: &[Duration]) -> String {
    times.iter().map(|time| format!("{:.3}", ms(*time))).collect::<Vec<_>>().join(", ")
}

/// `count` for each of `rows`, with 2 decimals.
fn a_row(count: usize, rows: u64) -> String {
    let hundredths = count * 100 / usize::try_from(rows).unwrap();
    format!("{}.{:02}", hundredths / 100, hundredths % 100)
}

/// A second thread that asks the registry's connection for the journal's
/// head in a loop. Each ask waits for the connection's lock, as a request
/// behind a commit does.
struct Asks {
    stop: Arc<AtomicBool>,
    thread: std::thread::JoinHandle<Vec<Duration>>,
}

impl Asks {
    fn start(registry: &WorkspaceRegistry) -> Self {
        let connection = registry.connection.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let thread = std::thread::spawn(move || {
            let mut times = Vec::new();
            while !stopped.load(Ordering::Relaxed) {
                let started = Instant::now();
                let head: i64 = connection
                    .get()
                    .query_row(
                        "SELECT COALESCE(MAX(sequence), 0) FROM session_journal",
                        [],
                        |row| row.get(0),
                    )
                    .unwrap();
                times.push(started.elapsed());
                assert!(head > 0, "the journal has rows");
                std::thread::sleep(ASK_PAUSE);
            }
            times
        });
        Self { stop, thread }
    }

    /// Stops the thread. Returns the time of each ask.
    fn end(self) -> Vec<Duration> {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.join().unwrap()
    }
}

/// Appends the fixture's journal rows `from` to `from + count` in one
/// transaction.
fn append_fixture_rows(store: &Store, from: u64, count: u64) {
    let batch = (from..from + count).map(fixture_subjects).collect::<Vec<_>>();
    store.registry().append_journal_records_for_test(&records(&batch));
}

/// Appends rows to the end of a period, then a full tail in one transaction.
/// Returns the journal's head before the tail: the mark.
fn append_a_full_tail(store: &Store, database: &Path) -> u64 {
    let to_the_end = (PERIOD - store.head() % PERIOD) % PERIOD;
    if to_the_end > 0 {
        append_fixture_rows(store, store.head(), to_the_end);
    }
    let first = store.head();
    append_fixture_rows(store, first, PERIOD - 1);
    let (mark, after, number) = file_state(database, store.head());
    assert_eq!(
        (mark, after, number.as_str()),
        (first, PERIOD - 1, DUE_NUMBER),
        "a full tail (the mark, the journal rows after it, the number)"
    );
    first
}

#[test]
fn the_costs_of_a_period_in_a_fixture_store_of_1_000_000_journal_rows() {
    let tail = PERIOD - 1;
    let mut store = Store::new("size");
    let database = store.database();

    // The store.
    let started = Instant::now();
    let mut next = store.head();
    while next < STORE_ROWS {
        append_fixture_rows(&store, next, 1_000);
        next += 1_000;
    }
    let fill = started.elapsed();
    let head = store.head();
    let (mark, after, number) = file_state(&database, head);
    line(&format!(
        "PERIOD {PERIOD}: a fixture store of {head} journal rows with 7 subjects each, made by \
         the registry's append with 1,000 journal rows in a transaction, in {:.1} s; its file \
         has {} bytes; the mark is {mark}, {after} journal rows are after it, the schema number \
         is {number}",
        fill.as_secs_f64(),
        fs::metadata(&database).unwrap().len()
    ));

    // 1. The late write.
    let mut wal = WalFrames::new(&database);
    let asks = Asks::start(store.registry());
    let (mut late_pages, mut ends, mut others) = (Vec::new(), Vec::new(), Vec::new());
    for row in 0..LATE_ROWS {
        let record = records(&[fixture_subjects(head + row)]);
        let started = Instant::now();
        let sequences = store.registry().append_journal_records_for_test(&record);
        let took = started.elapsed();
        if sequences[0] % PERIOD == 0 {
            ends.push(took);
        } else {
            others.push(took);
        }
        late_pages.extend(wal.new_pages());
    }
    let mut waits = asks.end();
    let slow = waits.iter().filter(|wait| **wait >= Duration::from_millis(1)).count();
    let late_times = format!(
        "the {} commits that end a period: {}; the {} other commits: {}. A second thread asked \
         the registry's connection {} times while these commits ran: {}; {slow} asks took 1 ms \
         or more",
        ends.len(),
        median_and_max(&mut ends),
        others.len(),
        median_and_max(&mut others),
        waits.len(),
        median_and_max(&mut waits)
    );

    // 2. The write row by row.
    let (mut row_by_row_pages, mut row_by_row_times) = (Vec::new(), Vec::new());
    for row in LATE_ROWS..LATE_ROWS + ROW_BY_ROW_ROWS {
        let record = records(&[fixture_subjects(head + row)]);
        let started = Instant::now();
        store.registry().append_journal_records_for_test(&record);
        store.registry().write_journal_subject_tail().unwrap();
        row_by_row_times.push(started.elapsed());
        row_by_row_pages.extend(wal.new_pages());
    }

    // 3. A full tail: the reads over it and the stop's write.
    let limit = usize::try_from(tail).unwrap();
    let session = fixture_subjects(0)[..1].to_vec();
    let (mut session_rows, mut session_table) = (Vec::new(), Vec::new());
    let (mut terminal_rows, mut terminal_table) = (Vec::new(), Vec::new());
    let (mut stops, mut stop_pages, mut found) = (Vec::new(), Vec::new(), Vec::new());
    for _ in 0..TAILS {
        let first = append_a_full_tail(&store, &database);
        wal.new_pages();
        let terminal = fixture_subjects(first)[5..6].to_vec();
        let reader = store.reader();
        let by_session = || Store::page(&reader, first, limit, &session);
        let by_terminal = || Store::page(&reader, first, limit, &terminal);
        let from_the_rows = (by_session(), by_terminal());
        assert_eq!(from_the_rows.0.0.len(), limit, "each journal row names the session");
        found.push(from_the_rows.1.0.len());
        session_rows.push(fastest(20, || drop(by_session())));
        terminal_rows.push(fastest(20, || drop(by_terminal())));
        let started = Instant::now();
        store.registry().write_journal_subject_tail().unwrap();
        stops.push(started.elapsed());
        stop_pages.push(wal.new_pages());
        assert_eq!(
            (by_session(), by_terminal()),
            from_the_rows,
            "the 2 pages from the table after the write are the pages from the rows before it"
        );
        session_table.push(fastest(20, || drop(by_session())));
        terminal_table.push(fastest(20, || drop(by_terminal())));
    }

    // 4. An open with nothing to write, and an open with a full tail.
    let (mut plain, mut repairs, mut states) = (Vec::new(), Vec::new(), Vec::new());
    for _ in 0..OPENS {
        store.registry().write_journal_subject_tail().unwrap();
        drop(store.registry.take());
        let started = Instant::now();
        store.registry = Some(WorkspaceRegistry::open(&store.root, SESSION).unwrap());
        plain.push(started.elapsed());
        append_a_full_tail(&store, &database);
        drop(store.registry.take());
        let started = Instant::now();
        store.registry = Some(WorkspaceRegistry::open(&store.root, SESSION).unwrap());
        repairs.push(started.elapsed());
        let (mark, after, number) = file_state(&database, store.head());
        states.push(format!("mark {mark}, {after} after it, number {number}"));
    }

    // The frames by the b-tree of their page, as the file has it now.
    let trees = page_trees(&database);
    let of_subjects = |pages: &[u32]| {
        let in_a_subject_tree = |page: &&u32| {
            trees.get(*page).is_some_and(|tree| SUBJECT_TREES.contains(&tree.as_str()))
        };
        pages.iter().filter(in_a_subject_tree).count()
    };
    line(&format!(
        "PERIOD {PERIOD}: THE LATE WRITE: {LATE_ROWS} journal rows, each in a commit of its own: \
         {} WAL frames = {} a journal row; {} of them in the subject table and its index = {} a \
         journal row; {late_times}",
        late_pages.len(),
        a_row(late_pages.len(), LATE_ROWS),
        of_subjects(&late_pages),
        a_row(of_subjects(&late_pages), LATE_ROWS)
    ));
    line(&format!(
        "PERIOD {PERIOD}: THE WRITE ROW BY ROW: {ROW_BY_ROW_ROWS} journal rows more, each with \
         the stop's write after it: {} WAL frames = {} a journal row; {} of them in the subject \
         table and its index = {} a journal row; a journal row with its write: {}",
        row_by_row_pages.len(),
        a_row(row_by_row_pages.len(), ROW_BY_ROW_ROWS),
        of_subjects(&row_by_row_pages),
        a_row(of_subjects(&row_by_row_pages), ROW_BY_ROW_ROWS),
        median_and_max(&mut row_by_row_times)
    ));
    let stop_frames = stop_pages
        .iter()
        .map(|pages| format!("{} ({} subject)", pages.len(), of_subjects(pages)))
        .collect::<Vec<_>>()
        .join(", ");
    line(&format!(
        "PERIOD {PERIOD}: A FULL TAIL of {tail} journal rows after the mark, {TAILS} times, each \
         time in ms (a read = the fastest of 20): a page by the session with the limit {tail}: \
         from the rows after the mark [{}], from the table [{}]; a page by one terminal ({found:?} \
         journal rows of the tail name it): from the rows after the mark [{}], from the table \
         [{}]; the stop's write of the tail [{}], its WAL frames [{stop_frames}]",
        each(&session_rows),
        each(&session_table),
        each(&terminal_rows),
        each(&terminal_table),
        each(&stops)
    ));
    line(&format!(
        "PERIOD {PERIOD}: AN OPEN, {OPENS} times, in ms: with nothing to write [{}]; after a \
         close with no stop step and a full tail of {tail} journal rows [{}]; the file after \
         each: {states:?}",
        each(&plain),
        each(&repairs)
    ));
    let head = store.head();
    let rows: i64 = open_registry_database_read_only(&database)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM journal_subject_index", [], |row| row.get(0))
        .unwrap();
    line(&format!(
        "PERIOD {PERIOD}: at the end the journal's head is {head} and the subject table has \
         {rows} rows (7 for each journal row = {})",
        7 * head
    ));
}
