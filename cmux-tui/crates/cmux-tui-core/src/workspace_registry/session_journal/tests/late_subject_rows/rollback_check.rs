//! The rollback's check and a store at the number 16 that no owner has.
//!
//! A store stays at 16 when its owner ends with no stop step. No stop will
//! write its subject rows, so a build that does not know the mark refuses
//! the store until a build that knows it opens the session. The rollback's
//! check (`store_schemas::stored`) reads the number of each session of a
//! state root, and one such session refuses the rollback for all. So the
//! check writes the subject rows of that store itself, as an open does, and
//! then reads 15. These rows hold what that write must keep:
//!
//! - It runs with the session's guard held, and a session that an owner has
//!   gets no write: the owner's stop writes.
//! - A write that fails reads 16 and leaves the store as it was: the store
//!   gave 16 while the check held the guard.
//! - A doubt gives no number, never 16: the lock of the lock folder is busy,
//!   a lock file is not there, or the store's write lock is busy. No read
//!   with the guard held said 16 then, and the caller says that it does not
//!   know.
//! - The check makes no file of its own.
//! - Its cost for a state root of many sessions is a count of parts, and the
//!   count for N sessions is N times the count for one: each part runs one
//!   time for each session. The times are prints, and no row asserts on one.
//!
//! The counts are those of the thread that runs the check
//! (`subject_rows::rows_taken_by_writes`,
//! `subject_rows::stores_opened_for_a_write`, `store_schemas::take_parts`).

use std::sync::atomic::{AtomicBool, Ordering::Relaxed};

use super::*;
use crate::workspace_registry::session_guard::{SESSION_GUARD_DIR, SessionLease};

/// The starts of the loop row.
const STARTS: u64 = 100;
/// The file of the lock that a start holds while it makes or takes a guard.
const LOCK_OF_THE_LOCK_FOLDER: &str = ".coordinator.lock";
/// Fails the last statement of the write of a stop, an open and the check:
/// the update that puts the number 15 back.
const FAIL_THE_NUMBER: &str = "CREATE TRIGGER late_subject_rows_test_fails_the_number
       BEFORE UPDATE ON meta WHEN NEW.key = 'schema_version' AND NEW.value = '15'
     BEGIN
       SELECT RAISE(ABORT, 'the test fails this write');
     END;";

/// A store at the number 16 whose owner ended with no stop step.
struct Crashed {
    store: Store,
    database: PathBuf,
    head: u64,
    /// The journal rows after the mark.
    after: u64,
}

fn crashed(label: &str) -> Crashed {
    let mut store = store_with_rows_due(label);
    let (database, head) = (store.database(), store.head());
    let after = store.file_state().1;
    drop(store.registry.take());
    Crashed { store, database, head, after }
}

/// One check of the state root `root`: the number that it gives for the
/// registry, the journal rows that its writes of subject rows took, and the
/// stores that it opened for a write.
fn check(root: &Path) -> (i64, u64, u64) {
    let rows = subject_rows::rows_taken_by_writes();
    let opened = subject_rows::stores_opened_for_a_write();
    let number = crate::store_schemas::stored(root).unwrap()["workspace_registry"];
    (
        number,
        subject_rows::rows_taken_by_writes() - rows,
        subject_rows::stores_opened_for_a_write() - opened,
    )
}

impl Crashed {
    fn check(&self) -> (i64, u64, u64) {
        check(&self.store.root)
    }

    fn file_state(&self) -> (u64, u64, String) {
        file_state(&self.database, self.head)
    }

    fn subject_rows(&self) -> Vec<(i64, String, String)> {
        rows_through(&open_registry_database_read_only(&self.database).unwrap(), self.head)
    }
}

#[test]
fn the_rollback_check_writes_the_subject_rows_of_a_store_at_16_that_no_owner_has() {
    let crashed = crashed("rollback-heals");
    let first = crashed.check();
    let problem = stopped_file_problem(&crashed.database);
    let second = crashed.check();
    assert_eq!(
        (first, problem, second),
        ((15, crashed.after, 1), None, (15, 0, 0)),
        "a store at 16 with {} journal rows after the mark and no owner: (the first check: its \
         number, the journal rows that its write took, the stores that it opened for a write), \
         what is wrong with the file after it, (the second check)",
        crashed.after
    );
}

#[test]
fn the_rollback_check_of_a_store_at_16_that_an_owner_has_writes_nothing() {
    let store = store_with_rows_due("rollback-owner-writes-nothing");
    let state = store.file_state();
    let got = check(&store.root);
    assert_eq!(
        (got, store.file_state()),
        ((15, 0, 0), state),
        "the owner runs, and its stop writes the subject rows: (the check: its number, the \
         journal rows that its write took, the stores that it opened for a write), (the mark, \
         the journal rows after it, the number in the file)"
    );
    store.check_file("after the check of a store that an owner has");
}

/// The write of the check is one transaction. The test fails its last
/// statement, after the subject rows and the mark: the check reads 16, and
/// the file has the mark, the number and the subject rows of before. Then
/// the failure's cause goes, and an open writes the rows.
#[test]
fn a_write_of_the_rollback_check_that_fails_reads_16_and_leaves_the_store_as_it_was() {
    let mut crashed = crashed("rollback-write-fails");
    let connection =
        open_registry_database_with_flags(&crashed.database, OpenFlags::default()).unwrap();
    connection.execute_batch(FAIL_THE_NUMBER).unwrap();
    drop(connection);
    let (state, rows) = (crashed.file_state(), crashed.subject_rows());
    let got = crashed.check();
    assert_eq!(
        (got, crashed.file_state()),
        ((16, crashed.after, 1), state),
        "a write that fails at its last statement: (the check: its number, the journal rows \
         that its write took, the stores that it opened for a write), (the mark, the journal \
         rows after it, the number in the file)"
    );
    assert_eq!(crashed.subject_rows(), rows, "the subject rows of the file after the failed write");
    let connection =
        open_registry_database_with_flags(&crashed.database, OpenFlags::default()).unwrap();
    connection.execute_batch("DROP TRIGGER late_subject_rows_test_fails_the_number;").unwrap();
    drop(connection);
    let what = "an open after a write of the check that failed";
    crashed.store.reopen(what);
    crashed.store.check_table(what, crashed.head);
    crashed.store.check_file(what);
    crashed.store.check_reads(what, &fixture_subjects(0), 64);
}

/// The name of each file and each folder under `root`, from `root`.
fn names_under(root: &Path) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let mut folders = vec![root.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in fs::read_dir(&folder).unwrap() {
            let path = entry.unwrap().path();
            names.insert(path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/"));
            if path.is_dir() {
                folders.push(path);
            }
        }
    }
    names
}

/// The names under `root` that are new after `act`. The 2 files that SQLite
/// keeps beside a store in WAL mode while a connection has it open are not
/// in the answer: a connection that only reads makes them too, and can leave
/// them.
fn new_names(what: &str, root: &Path, act: impl FnOnce()) -> Vec<String> {
    let before = names_under(root);
    act();
    let after = names_under(root);
    println!(
        "late_subject_rows: the names under the state root, {what}: before a rollback's check \
         {before:?}; after it {after:?}"
    );
    after
        .difference(&before)
        .filter(|name| !name.ends_with("-wal") && !name.ends_with("-shm"))
        .cloned()
        .collect()
}

/// The check of `root` when it must give no number: the text of its error.
/// A check that gives a number fails the row with that number.
fn check_gives_no_number(what: &str, root: &Path) -> String {
    match crate::store_schemas::stored(root) {
        Ok(found) => panic!("{what}: the check must give no number, and it gave {found:?}"),
        Err(error) => format!("{error:#}"),
    }
}

/// The check takes the lock of the lock folder with a short bound. While
/// another process holds that lock, the check does not know whether a daemon
/// owns the session, so it gives no number: 16 would say that an older build
/// cannot read the store, and nothing read that. It writes nothing. When the
/// lock is free, the next check writes the store.
#[test]
fn a_rollback_check_that_does_not_get_the_lock_folders_lock_gives_no_number() {
    let busy = crashed("rollback-busy-lock");
    let lock = busy.store.root.join(SESSION_GUARD_DIR).join(LOCK_OF_THE_LOCK_FOLDER);
    let state = busy.file_state();
    let rows = subject_rows::rows_taken_by_writes();
    let opened = subject_rows::stores_opened_for_a_write();
    let held = SessionLease::acquire_coordinator(&lock).unwrap();
    let error = check_gives_no_number("the lock folder's lock is busy", &busy.store.root);
    drop(held);
    println!("late_subject_rows: the check's error while the lock folder's lock is busy: {error}");
    assert!(error.contains(LOCK_OF_THE_LOCK_FOLDER), "the error names the lock's file: {error}");
    assert_eq!(
        (
            subject_rows::rows_taken_by_writes() - rows,
            subject_rows::stores_opened_for_a_write() - opened,
            busy.file_state()
        ),
        (0, 0, state),
        "the lock folder's lock is busy: the journal rows that the check's write took, the \
         stores that it opened for a write, (the mark, the journal rows after it, the number in \
         the file)"
    );
    assert_eq!(busy.check(), (15, busy.after, 1), "the check after the lock is free again");
}

/// A daemon's start makes the lock of the lock folder and the session's
/// guard before it makes the session's folder, and no code removes them. A
/// state root with a store at 16 and without one of the 2 files is one that
/// a person or a tool changed: the check cannot ask the guard, so it gives no
/// number, and it makes no file. A start of the session in this build makes
/// the files again and writes the rows, and then the check reads 15.
#[test]
fn a_rollback_check_with_a_lock_file_that_is_not_there_gives_no_number() {
    for file in ["the lock folder's lock", "the session's guard"] {
        let mut crashed = crashed("rollback-no-lock-file");
        let locks = crashed.store.root.join(SESSION_GUARD_DIR);
        let session = crashed.database.parent().unwrap().file_name().unwrap().to_str().unwrap();
        let name = if file == "the session's guard" {
            format!("{session}.lock")
        } else {
            LOCK_OF_THE_LOCK_FOLDER.to_string()
        };
        let path = locks.join(&name);
        fs::remove_file(&path).unwrap();
        let state = crashed.file_state();
        let what = format!("a store at 16 with no owner and no file of {file}");
        let error = check_gives_no_number(&what, &crashed.store.root);
        println!("late_subject_rows: the check's error for {what}: {error}");
        assert!(error.contains(&name), "{what}: the error names the file {name}: {error}");
        assert!(!path.exists(), "{what}: the check made the file");
        assert_eq!(crashed.file_state(), state, "{what}: the store's file");
        crashed.store.reopen(&what);
        assert!(path.exists(), "{what}: a start of the session makes the file");
        assert_eq!(crashed.check(), (15, 0, 0), "{what}: the check after a start of the session");
    }
}

/// The check opens a store at 16 that no daemon owns and takes the store's
/// write lock before it reads the number again. While another connection
/// holds that lock for the whole wait of the check, the store opens for a
/// read and not for a write: the check did not read the number with the
/// guard held, so it gives no number. It writes nothing. When the lock is
/// free, the next check writes the store.
#[test]
fn a_rollback_check_that_does_not_get_the_stores_write_lock_gives_no_number() {
    let locked = crashed("rollback-write-lock");
    let state = locked.file_state();
    let rows = subject_rows::rows_taken_by_writes();
    let holder = open_registry_database_with_flags(&locked.database, OpenFlags::default()).unwrap();
    holder.execute_batch("BEGIN IMMEDIATE;").unwrap();
    let started = Instant::now();
    let error = check_gives_no_number(
        "another connection holds the write lock of a store at 16 with no owner",
        &locked.store.root,
    );
    let waited = started.elapsed();
    holder.execute_batch("ROLLBACK;").unwrap();
    drop(holder);
    println!(
        "late_subject_rows: the check's error while another connection holds the store's write \
         lock, after {:.3} ms: {error}",
        ms(waited)
    );
    assert!(error.contains("locked"), "the error says that the store is locked: {error}");
    assert_eq!(
        (subject_rows::rows_taken_by_writes() - rows, locked.file_state()),
        (0, state),
        "the store's write lock is busy: the journal rows that the check's write took, (the \
         mark, the journal rows after it, the number in the file)"
    );
    assert_eq!(locked.check(), (15, locked.after, 1), "the check after the lock is free again");
}

/// The check is a read command for its caller. It makes no file and no
/// folder in the state root: not the lock of the lock folder when that file
/// is not there, and not the folder of the waiters for that lock when the
/// lock is busy.
#[test]
fn the_rollback_check_makes_no_file_of_its_own() {
    let mut stopped = store_with_rows_due("rollback-files-stopped");
    stopped.registry().write_journal_subject_tail().unwrap();
    let database = stopped.database();
    drop(stopped.registry.take());
    let bytes = fs::read(&database).unwrap();
    let after_a_stop = new_names("a store after a stop", &stopped.root, || {
        assert_eq!(check(&stopped.root), (15, 0, 0), "the check of a store after a stop");
    });
    // A store with nothing to write: the check writes no byte into its file.
    let bytes_after = fs::read(&database).unwrap();
    println!(
        "late_subject_rows: the file of a store after a stop has {} bytes before a rollback's \
         check and {} after it",
        bytes.len(),
        bytes_after.len()
    );
    assert!(
        bytes == bytes_after,
        "the check of a store after a stop changed the store's file: {} bytes before, {} after, \
         and the bytes are not the same",
        bytes.len(),
        bytes_after.len()
    );

    let no_owner = crashed("rollback-files-no-owner");
    let with_no_owner = new_names("a store at 16 with no owner", &no_owner.store.root, || {
        no_owner.check();
    });

    let no_lock = crashed("rollback-files-no-lock");
    let lock = no_lock.store.root.join(SESSION_GUARD_DIR).join(LOCK_OF_THE_LOCK_FOLDER);
    fs::remove_file(&lock).unwrap();
    let with_no_lock_file = new_names(
        "a store at 16 with no owner and no file of the lock folder's lock",
        &no_lock.store.root,
        || {
            // The check gives no number here: another row asserts that.
            let _ = crate::store_schemas::stored(&no_lock.store.root);
        },
    );

    let busy = crashed("rollback-files-busy");
    let lock = busy.store.root.join(SESSION_GUARD_DIR).join(LOCK_OF_THE_LOCK_FOLDER);
    let held = SessionLease::acquire_coordinator(&lock).unwrap();
    let with_a_busy_lock = new_names(
        "a store at 16 with no owner while the lock folder's lock is busy",
        &busy.store.root,
        || {
            let _ = crate::store_schemas::stored(&busy.store.root);
        },
    );
    drop(held);

    let none = Vec::<String>::new();
    assert_eq!(
        (after_a_stop, with_no_owner, with_no_lock_file, with_a_busy_lock),
        (none.clone(), none.clone(), none.clone(), none),
        "the names that a rollback's check made under the state root, SQLite's own 2 files \
         beside a store not counted: (a store after a stop, a store at 16 with no owner, the \
         same with no file of the lock folder's lock, the same while that lock is busy)"
    );
}

/// The check takes the session's guard for its write, and a start tries
/// that guard with no wait. The check runs in a loop on a thread of its own
/// while the session starts, gets a journal row and ends with no stop step,
/// 100 times: no start fails, each answer is 15 or 16, and at the end the
/// store has the subject rows of the record-time table.
#[test]
fn no_start_fails_and_no_subject_row_is_lost_while_the_rollback_check_runs_in_a_loop() {
    let mut crashed = crashed("rollback-loop");
    let root = crashed.store.root.clone();
    let done = AtomicBool::new(false);
    let ((plain, due, wrong, errors), failed) = std::thread::scope(|scope| {
        let check = scope.spawn(|| {
            let (mut plain, mut due) = (0_u64, 0_u64);
            let (mut wrong, mut errors) = (Vec::new(), Vec::new());
            while !done.load(Relaxed) {
                match crate::store_schemas::stored(&root) {
                    Ok(found) => match found.get("workspace_registry").copied() {
                        Some(15) => plain += 1,
                        Some(16) => due += 1,
                        number => wrong.push(format!("{number:?}")),
                    },
                    Err(error) => errors.push(format!("{error:#}")),
                }
            }
            (plain, due, wrong, errors)
        });
        let mut failed = Vec::new();
        for start in 0..STARTS {
            match WorkspaceRegistry::open(&root, SESSION) {
                Ok(registry) => {
                    registry.append_journal_records_for_test(&records(&[fixture_subjects(start)]));
                }
                Err(error) => failed.push(format!("start {start}: {error:#}")),
            }
        }
        done.store(true, Relaxed);
        (check.join().unwrap(), failed)
    });
    println!(
        "late_subject_rows: {STARTS} starts of a session, each with one journal row and no stop \
         step, while the rollback's check ran in a loop: {} starts failed; the check gave 15 \
         {plain} times and 16 {due} times, another number {} times, and an error {} times (the \
         first: {:?})",
        failed.len(),
        wrong.len(),
        errors.len(),
        errors.first()
    );
    assert!(
        failed.is_empty(),
        "{} of {STARTS} starts failed:\n{}",
        failed.len(),
        failed.join("\n")
    );
    assert!(wrong.is_empty(), "the check gave a number that is not 15 and not 16: {wrong:?}");
    assert!(plain + due > 0, "the check gave a number while the session started and ended");
    let what = "after the starts with the rollback's check in a loop";
    crashed.store.reopen(what);
    let head = crashed.store.head();
    assert!(head >= crashed.head + STARTS, "{what}: the journal's head is {head}");
    crashed.store.check_table(what, head);
    crashed.store.check_file(what);
    crashed.store.check_reads(what, &fixture_subjects(0), 64);
}

/// From this count of sessions each copy is a small store. The file of a
/// registry is never below the pages of its schema (more than 1 MB), so a
/// state root of 800 real stores is more than 1,000 MB in each run.
const SMALL_COPIES_FROM: usize = 800;
/// The tables of a small store: those that the check, its write (the mark,
/// the journal's head, the rows due, the subject rows, the number) and
/// `file_state` read. A write that reads one table more fails the 800 row
/// with the name of that table: add it here.
const TABLES_OF_A_SMALL_STORE: [&str; 4] =
    ["meta", "session_journal", "journal_segments", "journal_subject_index"];

/// Copies each file of the session folder `from` into the new folder `to`.
fn copy_the_files(from: &Path, to: &Path) {
    fs::create_dir(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            fs::copy(&path, to.join(path.file_name().unwrap())).unwrap();
        }
    }
}

/// A session folder beside the state root, with a small store: a copy of
/// the session of `crashed` whose store keeps only the tables of
/// [`TABLES_OF_A_SMALL_STORE`], each with its rows, indexes and triggers.
/// The check reads and writes no other table. It is not a store that the
/// product makes: the time of a check of small stores is not the time of
/// real ones.
fn small_session(crashed: &Crashed) -> PathBuf {
    let root = &crashed.store.root;
    let name = format!("{}-small", root.file_name().unwrap().to_str().unwrap());
    let to = root.with_file_name(name);
    copy_the_files(crashed.database.parent().unwrap(), &to);
    let database = to.join(crashed.database.file_name().unwrap());
    let connection = open_registry_database_with_flags(&database, OpenFlags::default()).unwrap();
    connection.execute_batch("PRAGMA foreign_keys=OFF;").unwrap();
    let names = |kind: &str| -> Vec<String> {
        connection
            .prepare("SELECT name FROM sqlite_master WHERE type = ?1 AND name NOT LIKE 'sqlite_%'")
            .unwrap()
            .query_map([kind], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    };
    for view in names("view") {
        connection.execute_batch(&format!("DROP VIEW IF EXISTS \"{view}\";")).unwrap();
    }
    for table in names("table") {
        if !TABLES_OF_A_SMALL_STORE.contains(&table.as_str()) {
            connection.execute_batch(&format!("DROP TABLE IF EXISTS \"{table}\";")).unwrap();
        }
    }
    // The checkpoint puts the small store in the main file and cuts that file.
    connection.execute_batch("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    drop(connection);
    assert_eq!(
        file_state(&database, crashed.head),
        (crashed.head - crashed.after, crashed.after, DUE_NUMBER.to_string()),
        "the small store has the mark, the journal rows after it and the number of the real one"
    );
    to
}

/// The sessions of a state root that [`copy_the_session`] made.
struct Sessions {
    /// The store's file of each session.
    databases: Vec<PathBuf>,
    /// The guard file of each session.
    guards: Vec<PathBuf>,
    /// The size of a small store's file, when the copies are small.
    small_size: Option<u64>,
}

/// Makes the state root of `crashed` one of `sessions` sessions: copies of
/// the one session's folder and of its guard file. Each is at 16 with no
/// owner. From [`SMALL_COPIES_FROM`] sessions the copies are of a small
/// store ([`small_session`]); the first session is the real one.
fn copy_the_session(crashed: &Crashed, sessions: usize) -> Sessions {
    let root = &crashed.store.root;
    let folder = crashed.database.parent().unwrap();
    let session = folder.file_name().unwrap().to_str().unwrap();
    let file = crashed.database.file_name().unwrap();
    let locks = root.join(SESSION_GUARD_DIR);
    let guard = locks.join(format!("{session}.lock"));
    let small = (sessions >= SMALL_COPIES_FROM).then(|| small_session(crashed));
    let from = small.as_deref().unwrap_or(folder);
    let mut databases = vec![crashed.database.clone()];
    let mut guards = vec![guard.clone()];
    for copy in 1..sessions {
        let name = format!("{session}-{copy:03}");
        let to = root.join(&name);
        copy_the_files(from, &to);
        let guard_of_the_copy = locks.join(format!("{name}.lock"));
        fs::copy(&guard, &guard_of_the_copy).unwrap();
        databases.push(to.join(file));
        guards.push(guard_of_the_copy);
    }
    let small_size = small.map(|small| {
        let size = fs::metadata(small.join(file)).unwrap().len();
        fs::remove_dir_all(&small).unwrap();
        size
    });
    Sessions { databases, guards, small_size }
}

/// The parts of a check, by the names that the product gives them
/// (`store_schemas::Part`): how many times each ran, and its time in all.
type Parts = BTreeMap<&'static str, (u64, Duration)>;

/// The parts of the read of one store's number: each session pays them in
/// each check.
const READ_PARTS: [&str; 4] = [
    "read: the open",
    "read: the schema and the meta table's name",
    "read: the number",
    "read: the close",
];
/// The part of a store at 16 that asks the session's guard. The write runs
/// in it when no daemon owns the session.
const GUARD_PART: &str = "16: the 2 locks, with the write in them";
/// The parts of the write of one store at 16 that no daemon owns.
const WRITE_PARTS: [&str; 5] = [
    "write: the open",
    "write: the write lock and the number",
    "write: the rows",
    "write: the commit",
    "write: the close",
];
/// To this count of sessions a row also checks the sessions while a holder
/// has each guard, as a daemon has. A test process cannot hold 800 files
/// open on each machine.
const OWNED_UP_TO: usize = 80;

/// One check with its time and its parts.
struct Checked {
    /// The number, the journal rows that the writes took, the stores that
    /// were opened for a write.
    got: (i64, u64, u64),
    time: Duration,
    parts: Parts,
}

fn checked(root: &Path) -> Checked {
    drop(crate::store_schemas::take_parts());
    let started = Instant::now();
    let got = check(root);
    let time = started.elapsed();
    Checked { got, time, parts: crate::store_schemas::take_parts() }
}

impl Checked {
    /// How many times each part ran.
    fn counts(&self) -> Vec<(&'static str, u64)> {
        self.parts.iter().map(|(name, part)| (*name, part.0)).collect()
    }

    /// Where the time went, the longest part first: each part's time in all
    /// and for one session. The time of the 2 locks is the guard's part less
    /// the write's parts; the rest is the walk of the folders.
    fn split(&self, sessions: usize) -> String {
        let of = |name: &str| self.parts.get(name).map_or(Duration::ZERO, |part| part.1);
        let read: Duration = READ_PARTS.iter().copied().map(&of).sum();
        let write: Duration = WRITE_PARTS.iter().copied().map(&of).sum();
        let guard = of(GUARD_PART);
        let mut lines: Vec<(String, Duration)> = self
            .parts
            .iter()
            .filter(|(name, _)| **name != GUARD_PART)
            .map(|(name, part)| ((*name).to_string(), part.1))
            .collect();
        lines.push(("the 2 locks alone".to_string(), guard.saturating_sub(write)));
        lines.push((
            "the walk of the folders and the rest".to_string(),
            self.time.saturating_sub(read + guard),
        ));
        lines.sort_by(|one, other| other.1.cmp(&one.1));
        let each = u32::try_from(sessions).unwrap();
        let lines: Vec<String> = lines
            .iter()
            .map(|(name, time)| format!("{name} {:.3} ms ({:.4})", ms(*time), ms(*time / each)))
            .collect();
        format!(
            "{:.3} ms = {:.4} ms a session; its parts, the longest first, with the ms in all \
             and (for one session): {}",
            ms(self.time),
            ms(self.time / each),
            lines.join("; ")
        )
    }
}

/// The count of each part of `names` for `sessions` sessions: one time for
/// each session.
fn one_time_each(names: &[&'static str], sessions: u64) -> Vec<(&'static str, u64)> {
    let mut counts: Vec<_> = names.iter().map(|name| (*name, sessions)).collect();
    counts.sort_unstable();
    counts
}

/// The cost of the check for a state root of `sessions` sessions, as counts.
/// A count is the same in each run on each machine; a time is not, so the
/// times are prints for a reader and no row asserts on one. The stores of a
/// test have no full fsync, and from [`SMALL_COPIES_FROM`] sessions they are
/// small stores, so the time of the product's binary is not this one.
///
/// - Each session at 16 with a holder of its guard, as a daemon is (to
///   [`OWNED_UP_TO`] sessions): the check reads the number and asks the
///   guard, one time for each session, and writes nothing.
/// - Each session at 16 with no owner (a machine that lost power), the worst
///   case: the first check also opens each store for a write one time, and
///   writes the subject rows of its journal rows after the mark in one
///   commit.
/// - The check after it, each session at 15: it reads the number of each
///   store one time and no more.
///
/// So the cost for `sessions` sessions is `sessions` times the cost for one.
fn the_check_of_sessions_at_16_with_no_owner(sessions: usize) {
    let crashed = crashed(&format!("rollback-cost-{sessions}"));
    let root = &crashed.store.root;
    let Sessions { databases, guards, small_size } = copy_the_session(&crashed, sessions);
    let count = u64::try_from(sessions).unwrap();
    let size = fs::metadata(&crashed.database).unwrap().len();
    let all: u64 = databases.iter().map(|database| fs::metadata(database).unwrap().len()).sum();
    let sizes = match small_size {
        Some(small) => format!(
            "SMALL STORES: the first store's file has {size} bytes, each other store is a small \
             store of {small} bytes with the journal's tables only, so the times are not those \
             of real stores; the {sessions} files have {all} bytes"
        ),
        None => format!("a store's file has {size} bytes; the {sessions} files have {all} bytes"),
    };
    let what = format!(
        "late_subject_rows: the rollback's check of a state root of {sessions} fixture sessions \
         ({sizes}; the stores of a test have no full fsync)"
    );
    let with_the_guard = [&READ_PARTS[..], &[GUARD_PART][..]].concat();
    let with_the_write = [&READ_PARTS[..], &[GUARD_PART][..], &WRITE_PARTS[..]].concat();

    if sessions <= OWNED_UP_TO {
        let held: Vec<SessionLease> =
            guards.iter().map(|guard| SessionLease::acquire(guard).unwrap()).collect();
        let owned = checked(root);
        drop(held);
        println!(
            "{what}: each at 16 while a holder has its guard: {} (its number, the journal rows \
             that its writes took, the stores that it opened for a write: {:?})",
            owned.split(sessions),
            owned.got
        );
        assert_eq!(
            (owned.got, owned.counts()),
            ((15, 0, 0), one_time_each(&with_the_guard, count)),
            "{sessions} sessions, each at 16 while a holder has its guard: (the check: its \
             number, the journal rows that its writes took, the stores that it opened for a \
             write), how many times each part ran"
        );
    }

    let first = checked(root);
    let second = checked(root);
    let plain = (crashed.head, 0, PLAIN_NUMBER.to_string());
    let written =
        databases.iter().filter(|database| file_state(database, crashed.head) == plain).count();
    println!(
        "{what}: each at 16 with {} journal rows after the mark and no owner, the first check: \
         {} (its number, the journal rows that its writes took, the stores that it opened for a \
         write: {:?}); {written} of {sessions} stores are at 15 with no journal row after the \
         mark",
        crashed.after,
        first.split(sessions),
        first.got
    );
    println!(
        "{what}: the check after it, each at 15: {} ({:?})",
        second.split(sessions),
        second.got
    );
    assert_eq!(
        (first.got, second.got, written),
        ((15, count * crashed.after, count), (15, 0, 0), sessions),
        "{sessions} sessions, each at 16 with {} journal rows after the mark and no owner: \
         (the first check: its number, the journal rows that its writes took, the stores that \
         it opened for a write), (the check after it), the stores at 15 with no journal row \
         after the mark",
        crashed.after
    );
    assert_eq!(
        (first.counts(), second.counts()),
        (one_time_each(&with_the_write, count), one_time_each(&READ_PARTS, count)),
        "{sessions} sessions: how many times each part ran in (the first check of the sessions \
         at 16 with no owner, the check after it); each part runs one time for each session"
    );
    // A small store has no table for the journal's reader: the real store is
    // the first one then.
    let real = if small_size.is_some() { databases.first() } else { databases.last() };
    let problem = stopped_file_problem(real.unwrap());
    assert!(problem.is_none(), "a real store of the state root after the check: {problem:?}");
}

#[test]
fn the_rollback_check_of_8_sessions_at_16_with_no_owner_writes_each_store_one_time() {
    the_check_of_sessions_at_16_with_no_owner(8);
}

#[test]
fn the_rollback_check_of_80_sessions_at_16_with_no_owner_writes_each_store_one_time() {
    the_check_of_sessions_at_16_with_no_owner(80);
}

#[test]
fn the_rollback_check_of_800_sessions_at_16_with_no_owner_writes_each_store_one_time() {
    the_check_of_sessions_at_16_with_no_owner(800);
}
