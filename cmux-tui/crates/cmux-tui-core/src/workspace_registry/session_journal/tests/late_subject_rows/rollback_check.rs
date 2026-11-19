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
//! - A write that fails, and each doubt, reads 16 and leaves the store as it
//!   was.
//! - The check makes no file of its own.
//! - Its cost for a state root with many such sessions has a count: one open
//!   for a write and one write for each session, one time.
//!
//! The counts are those of the thread that runs the check
//! (`subject_rows::rows_taken_by_writes`,
//! `subject_rows::stores_opened_for_a_write`).

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

/// The check is a read command for its caller. It makes no file and no
/// folder in the state root: not the lock of the lock folder when that file
/// is not there, and not the folder of the waiters for that lock when the
/// lock is busy. A check that cannot take the lock reads 16 and writes
/// nothing.
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
            no_lock.check();
        },
    );

    let busy = crashed("rollback-files-busy");
    let lock = busy.store.root.join(SESSION_GUARD_DIR).join(LOCK_OF_THE_LOCK_FOLDER);
    let state = busy.file_state();
    let held = SessionLease::acquire_coordinator(&lock).unwrap();
    let mut got = (0, 0, 0);
    let with_a_busy_lock = new_names(
        "a store at 16 with no owner while the lock folder's lock is busy",
        &busy.store.root,
        || got = busy.check(),
    );
    drop(held);
    assert_eq!(
        (got, busy.file_state()),
        ((16, 0, 0), state),
        "the lock folder's lock is busy: (the check: its number, the journal rows that its \
         write took, the stores that it opened for a write), (the mark, the journal rows after \
         it, the number in the file)"
    );

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

/// Makes the state root of `crashed` one of `sessions` sessions: copies of
/// the one session's folder and of its guard file. Each is at 16 with no
/// owner. Returns the store's file of each session.
fn copy_the_session(crashed: &Crashed, sessions: usize) -> Vec<PathBuf> {
    let root = &crashed.store.root;
    let folder = crashed.database.parent().unwrap();
    let session = folder.file_name().unwrap().to_str().unwrap();
    let file = crashed.database.file_name().unwrap();
    let locks = root.join(SESSION_GUARD_DIR);
    let guard = locks.join(format!("{session}.lock"));
    let mut databases = vec![crashed.database.clone()];
    for copy in 1..sessions {
        let name = format!("{session}-{copy:03}");
        let to = root.join(&name);
        fs::create_dir(&to).unwrap();
        for entry in fs::read_dir(folder).unwrap() {
            let path = entry.unwrap().path();
            if path.is_file() {
                fs::copy(&path, to.join(path.file_name().unwrap())).unwrap();
            }
        }
        fs::copy(&guard, locks.join(format!("{name}.lock"))).unwrap();
        databases.push(to.join(file));
    }
    databases
}

/// The worst case of the check: each session of a state root is at 16 with
/// no owner (a machine that lost power). The first check opens each store
/// for a write one time and writes the subject rows of its journal rows
/// after the mark; the check after it opens none and writes none. The 2
/// times are prints for a reader: the stores of a test have no full fsync,
/// so the time of the product's binary is not this one.
fn the_check_of_sessions_at_16_with_no_owner(sessions: usize) {
    let crashed = crashed(&format!("rollback-cost-{sessions}"));
    let databases = copy_the_session(&crashed, sessions);
    let count = u64::try_from(sessions).unwrap();
    let size = fs::metadata(&crashed.database).unwrap().len();
    let started = Instant::now();
    let first = crashed.check();
    let first_time = started.elapsed();
    let started = Instant::now();
    let second = crashed.check();
    let second_time = started.elapsed();
    let plain = (crashed.head, 0, PLAIN_NUMBER.to_string());
    let written =
        databases.iter().filter(|database| file_state(database, crashed.head) == plain).count();
    println!(
        "late_subject_rows: the rollback's check of a state root of {sessions} fixture sessions, \
         each at 16 with {} journal rows after the mark and no owner (a store's file has {size} \
         bytes; the stores of a test have no full fsync): the first check {:.3} ms (its number, \
         the journal rows that its writes took, the stores that it opened for a write: \
         {first:?}); the check after it {:.3} ms ({second:?}); {written} of {sessions} stores \
         are at 15 with no journal row after the mark",
        crashed.after,
        ms(first_time),
        ms(second_time)
    );
    assert_eq!(
        (first, second, written),
        ((15, count * crashed.after, count), (15, 0, 0), sessions),
        "{sessions} sessions, each at 16 with {} journal rows after the mark and no owner: \
         (the first check: its number, the journal rows that its writes took, the stores that \
         it opened for a write), (the check after it), the stores at 15 with no journal row \
         after the mark",
        crashed.after
    );
    let problem = stopped_file_problem(databases.last().unwrap());
    assert!(problem.is_none(), "the last session's store after the check: {problem:?}");
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
