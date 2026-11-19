//! MEASURE, NOT FOR A MERGE. The costs of the late write of the subject rows
//! in a large store: a fixture of 1,000,000 journal rows with 7 subjects each
//! ([`fixture_subjects`]), made by the registry's own append.
//!
//! The period is the product's one constant ([`PERIOD`]); a commit of this
//! branch changes it, and the same test runs again. For that period the test
//! prints:
//!
//! 1. The late write: 3,000 journal rows, each in a commit of its own. The
//!    bytes and the frames that the commits put in the WAL, all and those in
//!    the subject table and its index; the time of the commits that end a
//!    period and of the others; and how long a second thread waits for the
//!    registry's connection while these commits run.
//! 2. The write row by row: 1,000 journal rows with the stop's write after
//!    each row, which is what the write at record time wrote in the subject
//!    table and its index. Its bytes and frames.
//! 3. A full tail (one journal row less than a period after the mark), 5
//!    times: a page by subject over the tail from the rows after the mark and
//!    from the table, and the stop's write of the tail with its frames.
//! 4. An open, 3 times: with nothing to write, and after a close with no stop
//!    step and a full tail.
//!
//! The store is in the state of a daemon's store: a flush request follows
//! each commit, as the journal writer makes one after a batch that no request
//! waits for and the server makes one after a reply, so the registry's syncer
//! checkpoints the WAL as it does in a daemon. While the store is made, the
//! test also waits for the syncer after each transaction; in the measured
//! parts it does not wait.
//!
//! Each line starts with `late_subject_rows size:` and prints when its part
//! ends. A time is the test's own clock around one call. No assert is on a
//! time or on a count. A part that runs longer than [`PART_LIMIT`] ends the
//! test with the parts that it has.
//!
//! The store's folder has one name ([`FOLDER`]) under the temp folder: the
//! test removes a folder of that name at its start (what a killed run left)
//! and at its end.

use std::collections::BTreeSet;
use std::io::{Read, Seek, SeekFrom};
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
/// The longest time of one part.
const PART_LIMIT: Duration = Duration::from_secs(600);
/// The longest time of the test before a new step of a part starts. It is
/// below the limit of the test's run, so the run ends by the test.
const TEST_LIMIT: Duration = Duration::from_secs(1_440);
/// The store's folder under the temp folder.
const FOLDER: &str = "cmux-late-subject-rows-size-measure";

fn line(text: &str) {
    println!("late_subject_rows size: PERIOD {PERIOD}, fixture: {text}");
}

/// The minimum, the median and the largest of `times` in ms, with their
/// count.
fn times_of(times: &mut [Duration]) -> String {
    times.sort();
    match times.len() {
        0 => "no sample".to_string(),
        1 => format!("{:.3} ms, 1 sample", ms(times[0])),
        count => format!(
            "minimum {:.3} ms, median {:.3} ms, slowest {:.3} ms of {count} samples",
            ms(times[0]),
            ms(times[count / 2]),
            ms(times[count - 1])
        ),
    }
}

/// Each of `times` in ms.
fn each(times: &[Duration]) -> String {
    times.iter().map(|time| format!("{:.3}", ms(*time))).collect::<Vec<_>>().join(", ")
}

/// `count` for each of `rows`, with 2 decimals.
fn a_row(count: usize, rows: u64) -> String {
    let hundredths = count * 100 / usize::try_from(rows.max(1)).unwrap();
    format!("{}.{:02}", hundredths / 100, hundredths % 100)
}

/// The start of the test and of the part in work.
struct Limits {
    test: Instant,
    part: Instant,
}

impl Limits {
    fn new() -> Self {
        let now = Instant::now();
        Self { test: now, part: now }
    }

    fn next_part(&mut self) {
        self.part = Instant::now();
    }

    /// Why the test ends now, if a limit is passed.
    fn passed(&self) -> Option<String> {
        if self.part.elapsed() > PART_LIMIT {
            return Some(format!("the part ran for more than {} s", PART_LIMIT.as_secs()));
        }
        (self.test.elapsed() > TEST_LIMIT)
            .then(|| format!("the test ran for more than {} s", TEST_LIMIT.as_secs()))
    }
}

/// The last line of a test that a limit ended.
fn ended_by_a_limit(part: &str, why: &str) {
    line(&format!(
        "THE TEST ENDS HERE: {part} was slow ({why}); the lines above are the parts that it has"
    ));
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

/// The frames that the store's WAL file got after the last read of it. A read
/// is of the new frames' headers only: the file of a large store is large.
struct NewFrames {
    path: PathBuf,
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: [u8; 8],
    seen: u64,
}

impl NewFrames {
    fn new(database: &Path) -> Self {
        let mut path = database.as_os_str().to_owned();
        path.push("-wal");
        let mut frames = Self { path: path.into(), salts: [0; 8], seen: 0 };
        frames.pages();
        frames
    }

    /// The page of each new frame. A frame after the header is 24 bytes and
    /// one page: its first 4 bytes are the page's number, and bytes 8 to 16
    /// are the salts of the header.
    fn pages(&mut self) -> Vec<u32> {
        let mut pages = Vec::new();
        let Ok(mut file) = fs::File::open(&self.path) else { return pages };
        let mut header = [0_u8; WAL_HEADER];
        if file.read_exact(&mut header).is_err() {
            return pages;
        }
        let page = u64::from(u32::from_be_bytes(header[8..12].try_into().unwrap()));
        if page == 0 {
            return pages;
        }
        let salts: [u8; 8] = header[16..24].try_into().unwrap();
        if salts != self.salts {
            self.salts = salts;
            self.seen = 0;
        }
        let first = u64::try_from(WAL_HEADER).unwrap();
        let frame = u64::try_from(WAL_FRAME_HEADER).unwrap() + page;
        let mut frame_header = [0_u8; WAL_FRAME_HEADER];
        loop {
            let offset = first + self.seen * frame;
            if file.seek(SeekFrom::Start(offset)).is_err()
                || file.read_exact(&mut frame_header).is_err()
                || frame_header[8..16] != salts[..]
            {
                return pages;
            }
            pages.push(u32::from_be_bytes(frame_header[..4].try_into().unwrap()));
            self.seen += 1;
        }
    }
}

/// The bytes of one WAL frame of the store: 24 bytes and one page.
fn frame_bytes(database: &Path) -> u64 {
    let page: i64 = open_registry_database_read_only(database)
        .unwrap()
        .query_row("PRAGMA page_size", [], |row| row.get(0))
        .unwrap();
    u64::try_from(page).unwrap() + u64::try_from(WAL_FRAME_HEADER).unwrap()
}

/// The pages of the subject table and of its index, as the file has them
/// now, by `dbstat`; and the time of the read.
fn subject_pages(database: &Path) -> (BTreeSet<u32>, Duration) {
    let started = Instant::now();
    let connection = open_registry_database_read_only(database).unwrap();
    let mut pages = BTreeSet::new();
    for tree in SUBJECT_TREES {
        let mut statement =
            connection.prepare("SELECT pageno FROM dbstat WHERE name = ?1").unwrap();
        let found = statement.query_map([tree], |row| row.get::<_, i64>(0)).unwrap();
        for page in found {
            pages.insert(u32::try_from(page.unwrap()).unwrap());
        }
    }
    (pages, started.elapsed())
}

/// The registry's own counts at one point, after its syncer finished with
/// each commit made to it.
struct Counts {
    /// The bytes of the WAL frames that the commits appended.
    frame_bytes: u64,
    commits: u64,
    /// The checkpoints of the syncer.
    checkpoints: u64,
}

fn counts(store: &Store) -> Counts {
    let connection = &store.registry().connection;
    let checkpoints = connection.checkpoints_after_flush_for_test();
    Counts {
        frame_bytes: connection.wal_frame_bytes(),
        commits: connection.durability_counts().0,
        checkpoints,
    }
}

/// The bytes of the store's 2 files now.
fn files(store: &Store, database: &Path) -> String {
    let (wal, largest) = store.registry().connection.wal_file_bytes();
    format!(
        "the main file has {} bytes and the WAL file has {wal} bytes (its largest: {largest})",
        fs::metadata(database).unwrap().len()
    )
}

/// The counts of a part of `rows` journal rows that started at `before`:
/// `read` is the count of frames that the test read in the WAL file.
fn counted(store: &Store, database: &Path, before: &Counts, rows: u64, read: usize) -> String {
    let now = counts(store);
    let frame = frame_bytes(database);
    let bytes = now.frame_bytes - before.frame_bytes;
    format!(
        "{rows} journal rows in {} commits put {bytes} bytes of frames in the WAL by the \
         registry's own count = {} frames of {frame} bytes = {} bytes a journal row (the test \
         read {read} new frames in the WAL file); the syncer made {} checkpoints; {}",
        now.commits - before.commits,
        bytes / frame,
        bytes / rows.max(1),
        now.checkpoints - before.checkpoints,
        files(store, database)
    )
}

/// The line of the frames of a part by their b-tree.
fn subject_line(database: &Path, part: &str, pages: &[u32], rows: u64) {
    let (subject, took) = subject_pages(database);
    let of_subjects = pages.iter().filter(|page| subject.contains(*page)).count();
    line(&format!(
        "{part}, ITS FRAMES BY THE B-TREE: {} frames = {} a journal row; {of_subjects} of them \
         in the subject table and its index = {} a journal row (the read of the pages of these \
         2 b-trees took {:.1} s)",
        pages.len(),
        a_row(pages.len(), rows),
        a_row(of_subjects, rows),
        took.as_secs_f64()
    ));
}

/// Asks for a flush of the commits made so far, as the journal writer does
/// after a batch that no request waits for.
fn ask_for_a_flush(store: &Store) {
    store.registry().connection.request_flush();
}

/// Appends the fixture's journal rows `from` to `from + count` in one
/// transaction, and asks for a flush.
fn append_fixture_rows(store: &Store, from: u64, count: u64) {
    let batch = (from..from + count).map(fixture_subjects).collect::<Vec<_>>();
    store.registry().append_journal_records_for_test(&records(&batch));
    ask_for_a_flush(store);
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
    let mut limits = Limits::new();
    let tail = PERIOD - 1;
    let root = std::env::temp_dir().join(FOLDER);
    let left = root.exists();
    if left {
        fs::remove_dir_all(&root).unwrap();
    }
    let registry = WorkspaceRegistry::open(&root, SESSION).unwrap();
    let mut store = Store {
        root: root.clone(),
        registry: Some(registry),
        table: RecordTimeTable::new(),
        recorded: 0,
        seals: 0,
    };
    let database = store.database();
    line(&format!(
        "the store's folder is {}; a folder of that name from an earlier run: {}",
        root.display(),
        if left { "removed" } else { "none" }
    ));

    // The store.
    let started = Instant::now();
    let mut next = store.head();
    while next < STORE_ROWS {
        if let Some(why) = limits.passed() {
            line(&format!("THE STORE: {next} journal rows of {STORE_ROWS} are made"));
            return ended_by_a_limit("the making of the store", &why);
        }
        append_fixture_rows(&store, next, 1_000);
        // The syncer ends its work for this transaction before the next one,
        // as it does in a daemon, where a journal row comes long after it.
        store.registry().connection.checkpoints_after_flush_for_test();
        next += 1_000;
    }
    let fill = started.elapsed();
    let made = counts(&store);
    let head = store.head();
    let (mark, after, number) = file_state(&database, head);
    line(&format!(
        "THE STORE: {head} journal rows with 7 subjects each, made by the registry's append \
         with 1,000 journal rows in a transaction, each with a flush request and a wait for the \
         syncer after it, in {:.1} s; {} commits, {} checkpoints of the syncer; {}; the mark is \
         {mark}, {after} journal rows are after it, the schema number is {number}",
        fill.as_secs_f64(),
        made.commits,
        made.checkpoints,
        files(&store, &database)
    ));

    // 1. The late write.
    limits.next_part();
    let mut wal = NewFrames::new(&database);
    let before = counts(&store);
    let asks = Asks::start(store.registry());
    let (mut late_pages, mut ends, mut others) = (Vec::new(), Vec::new(), Vec::new());
    let mut late_rows = 0;
    let mut slow: Option<String> = None;
    while late_rows < LATE_ROWS && slow.is_none() {
        let record = records(&[fixture_subjects(head + late_rows)]);
        let started = Instant::now();
        let sequences = store.registry().append_journal_records_for_test(&record);
        let took = started.elapsed();
        ask_for_a_flush(&store);
        if sequences[0] % PERIOD == 0 {
            ends.push(took);
        } else {
            others.push(took);
        }
        late_pages.extend(wal.pages());
        late_rows += 1;
        slow = limits.passed();
    }
    let mut waits = asks.end();
    let slow_asks = waits.iter().filter(|wait| **wait >= Duration::from_millis(1)).count();
    line(&format!(
        "THE LATE WRITE, each journal row in a commit of its own with a flush request after it: \
         {}; the {} commits that end a period: {}; the {} other commits: {}; a second thread \
         asked the registry's connection {} times while these commits ran: {}; {slow_asks} of \
         these asks took 1 ms or more",
        counted(&store, &database, &before, late_rows, late_pages.len()),
        ends.len(),
        times_of(&mut ends),
        others.len(),
        times_of(&mut others),
        waits.len(),
        times_of(&mut waits)
    ));
    subject_line(&database, "THE LATE WRITE", &late_pages, late_rows);
    if let Some(why) = &slow {
        return ended_by_a_limit("the late write", &why);
    }

    // 2. The write row by row.
    limits.next_part();
    let before = counts(&store);
    let (mut row_by_row_pages, mut row_by_row_times) = (Vec::new(), Vec::new());
    let mut row_by_row_rows = 0;
    while row_by_row_rows < ROW_BY_ROW_ROWS && slow.is_none() {
        let record = records(&[fixture_subjects(head + LATE_ROWS + row_by_row_rows)]);
        let started = Instant::now();
        store.registry().append_journal_records_for_test(&record);
        store.registry().write_journal_subject_tail().unwrap();
        row_by_row_times.push(started.elapsed());
        ask_for_a_flush(&store);
        row_by_row_pages.extend(wal.pages());
        row_by_row_rows += 1;
        slow = limits.passed();
    }
    line(&format!(
        "THE WRITE ROW BY ROW, each journal row with the stop's write and a flush request after \
         it: {}; a journal row with its write: {}",
        counted(&store, &database, &before, row_by_row_rows, row_by_row_pages.len()),
        times_of(&mut row_by_row_times)
    ));
    subject_line(&database, "THE WRITE ROW BY ROW", &row_by_row_pages, row_by_row_rows);
    if let Some(why) = &slow {
        return ended_by_a_limit("the write row by row", &why);
    }

    // 3. A full tail: the reads over it and the stop's write.
    limits.next_part();
    let limit = usize::try_from(tail).unwrap();
    let session = fixture_subjects(0)[..1].to_vec();
    let (mut session_rows, mut session_table) = (Vec::new(), Vec::new());
    let (mut terminal_rows, mut terminal_table) = (Vec::new(), Vec::new());
    let (mut stops, mut stop_pages, mut found) = (Vec::new(), Vec::new(), Vec::new());
    while stops.len() < TAILS && slow.is_none() {
        let first = append_a_full_tail(&store, &database);
        wal.pages();
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
        ask_for_a_flush(&store);
        stop_pages.push(wal.pages());
        assert_eq!(
            (by_session(), by_terminal()),
            from_the_rows,
            "the 2 pages from the table after the write are the pages from the rows before it"
        );
        session_table.push(fastest(20, || drop(by_session())));
        terminal_table.push(fastest(20, || drop(by_terminal())));
        slow = limits.passed();
    }
    let (subject, took) = subject_pages(&database);
    let stop_frames = stop_pages
        .iter()
        .map(|pages| {
            let of_subjects = pages.iter().filter(|page| subject.contains(*page)).count();
            format!("{} ({of_subjects} subject)", pages.len())
        })
        .collect::<Vec<_>>()
        .join(", ");
    line(&format!(
        "A FULL TAIL of {tail} journal rows after the mark, {} times, each time in ms (a read = \
         the minimum of 20 calls): a page by the session with the limit {tail}: from the rows \
         after the mark [{}], from the table [{}]; a page by one terminal ({found:?} journal \
         rows of the tail name it): from the rows after the mark [{}], from the table [{}]; the \
         stop's write of the tail [{}] = {}; its WAL frames [{stop_frames}] (the read of the \
         pages of the 2 b-trees took {:.1} s); {}",
        stops.len(),
        each(&session_rows),
        each(&session_table),
        each(&terminal_rows),
        each(&terminal_table),
        each(&stops),
        times_of(&mut stops.clone()),
        took.as_secs_f64(),
        files(&store, &database)
    ));
    if let Some(why) = &slow {
        return ended_by_a_limit("the full tails", &why);
    }

    // 4. An open with nothing to write, and an open with a full tail.
    limits.next_part();
    let (mut plain, mut repairs, mut states) = (Vec::new(), Vec::new(), Vec::new());
    while plain.len() < OPENS && slow.is_none() {
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
        slow = limits.passed();
    }
    line(&format!(
        "AN OPEN, {} times, in ms: with nothing to write [{}] = {}; after a close with no stop \
         step and a full tail of {tail} journal rows [{}] = {}; the file after each: {states:?}",
        plain.len(),
        each(&plain),
        times_of(&mut plain.clone()),
        each(&repairs),
        times_of(&mut repairs.clone())
    ));
    if let Some(why) = &slow {
        return ended_by_a_limit("the opens", &why);
    }

    let head = store.head();
    let rows: i64 = open_registry_database_read_only(&database)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM journal_subject_index", [], |row| row.get(0))
        .unwrap();
    line(&format!(
        "at the end the journal's head is {head} and the subject table has {rows} rows (7 for \
         each journal row = {}); {}; the test ran for {:.1} s",
        7 * head,
        files(&store, &database),
        limits.test.elapsed().as_secs_f64()
    ));
}
