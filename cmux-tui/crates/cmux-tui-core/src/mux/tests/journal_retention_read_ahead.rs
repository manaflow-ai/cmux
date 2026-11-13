//! The retention pass reads what a hold needs BEFORE the hold, with the
//! registry lock free.
//!
//! One hold of the delete of a sealed segment read about 10,500 pages of the
//! registry file under the registry lock, on a generated registry of a
//! long-lived session (2026-11-13: 85 % to 93 % of a hold was the seek into
//! an index for a row that the delete takes, each seek a read of the file).
//! The read of the records at or below the floor (a row seek for each sealed
//! segment) was 22 s under that lock at 13 GB. A rename waited behind both.
//!
//! These tests run the worker's own tick on a registry on disk and look at
//! each step of the pass through a seam. They time nothing: at each read of
//! the pass a second thread must get the registry lock.
#![cfg(unix)]

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use super::journal_retention_bound::{RECORDS, head, write_through};
use super::journal_retention_holds::session_with_a_big_segment;
use super::*;
use crate::workspace_registry::journal_retention::{
    RETENTION_ROWS_PER_HOLD, RETENTION_STEP_FOR_TEST, RetentionStep,
};

/// How long a second thread tries to take the registry lock at a step.
const LOCK_WAIT: Duration = Duration::from_secs(10);

/// One step of the pass, and whether a second thread got the registry lock
/// there. `None`: the test did not try at this step (it is not one of the
/// steps the test looks at, or an earlier step already had no lock and the
/// test does not wait again).
type Seen = (RetentionStep, Option<bool>);

/// True when a second thread got the registry lock in [`LOCK_WAIT`]. The
/// caller's thread is the one that runs the pass: while it holds the lock,
/// no try ends.
fn a_second_thread_gets_the_registry_lock(mux: &Mux) -> bool {
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let deadline = Instant::now() + LOCK_WAIT;
                loop {
                    match mux.workspace_registry.try_lock() {
                        Ok(_registry) => return true,
                        Err(_) if Instant::now() < deadline => std::thread::yield_now(),
                        Err(_) => return false,
                    }
                }
            })
            .join()
            .expect("the second thread ran")
    })
}

/// Records each step of the pass on this thread from now on. At a step that
/// `tried` accepts, a second thread tries to take the registry lock.
fn watch_the_pass(mux: &Arc<Mux>, tried: fn(RetentionStep) -> bool) -> Rc<RefCell<Vec<Seen>>> {
    let seen: Rc<RefCell<Vec<Seen>>> = Rc::default();
    let (mux, steps) = (Arc::clone(mux), Rc::clone(&seen));
    RETENTION_STEP_FOR_TEST.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(move |step: RetentionStep| {
            let refused = steps.borrow().iter().any(|(_, free)| *free == Some(false));
            let free =
                (tried(step) && !refused).then(|| a_second_thread_gets_the_registry_lock(&mux));
            steps.borrow_mut().push((step, free));
        }));
    });
    seen
}

/// A session on disk with a sealed segment of more than two holds of
/// records, and each step of the pass that then deleted that segment.
fn steps_of_a_pass_that_deletes_a_big_segment(
    name: &str,
    tried: fn(RetentionStep) -> bool,
) -> (Vec<Seen>, bool) {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-{name}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mut next_step = 0;
    let (mux, agents, big) = session_with_a_big_segment(&root, &mut next_step);
    let seen = watch_the_pass(&mux, tried);
    write_through(&mux, &agents, &mut next_step, head(&mux) + RECORDS);
    for _ in 0..32 {
        mux.run_journal_maintenance_for_test();
    }
    // The seam holds the mux: it goes before the shutdown.
    RETENTION_STEP_FOR_TEST.with(|slot| slot.borrow_mut().take());
    let deleted = mux.journal_pruned_through().unwrap() >= big.end;
    let steps = seen.borrow().clone();
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
    (steps, deleted)
}

#[test]
fn each_row_hold_of_the_retention_pass_follows_a_read_of_its_rows_with_the_registry_lock_free() {
    let (steps, deleted) = steps_of_a_pass_that_deletes_a_big_segment("read-before-hold", |step| {
        matches!(step, RetentionStep::ReadBeforeHold { .. })
    });
    let mut problems = Vec::new();
    let mut holds = 0;
    // The rows of the read that no hold has used yet, and whether a second
    // thread got the registry lock at it.
    let mut read: Option<(u64, Option<bool>)> = None;
    for (step, free) in &steps {
        match *step {
            RetentionStep::FloorCut => {}
            RetentionStep::ReadBeforeHold { rows } => read = Some((rows, *free)),
            RetentionStep::RowsDeleted { rows } => {
                holds += 1;
                match read.take() {
                    Some((read_rows, Some(true))) if read_rows == rows => {}
                    Some((read_rows, free)) => problems.push(format!(
                        "row hold {holds} deleted {rows} rows: the read before it was of \
                         {read_rows} rows; a second thread got the registry lock at that read: \
                         {free:?}"
                    )),
                    None => problems.push(format!(
                        "row hold {holds} deleted {rows} rows: the pass read no row of it \
                         before it took the registry lock"
                    )),
                }
            }
        }
    }
    println!("journal_retention_read_ahead: {holds} row holds, {} steps", steps.len());
    if !deleted || holds < 3 {
        problems.push(format!(
            "the setup: the pass did not delete the big segment in 3 or more row holds \
             (deleted: {deleted}, row holds: {holds})"
        ));
    }
    assert!(problems.is_empty(), "{problems:#?}");
}

/// The bound of a hold is a count of rows, not of records: a record of a
/// long-lived session has about 15 subject rows, and one hold of 256
/// records was 24.6 s of the registry lock on a generated registry of 13 GB
/// (2026-11-13; a rename waited 25 s behind it). So a hold deletes at most
/// [`RETENTION_ROWS_PER_HOLD`] rows, and between two holds a second thread
/// gets the registry lock. The test counts the rows of each hold of the
/// worker's own tick; it times nothing.
#[test]
fn a_row_hold_deletes_at_most_the_bound_of_rows_and_gives_the_registry_lock_back() {
    let (steps, deleted) = steps_of_a_pass_that_deletes_a_big_segment("row-bound", |step| {
        matches!(step, RetentionStep::ReadBeforeHold { .. })
    });
    let mut problems = Vec::new();
    // The rows of each row hold, in order.
    let mut holds: Vec<u64> = Vec::new();
    // True when a second thread got the registry lock at a step after the
    // last row hold.
    let mut free_since_the_last_hold = false;
    for (step, free) in &steps {
        let RetentionStep::RowsDeleted { rows } = *step else {
            free_since_the_last_hold |= *free == Some(true);
            continue;
        };
        if !holds.is_empty() && !free_since_the_last_hold {
            problems.push(format!(
                "between row hold {} and row hold {} no second thread got the registry lock",
                holds.len(),
                holds.len() + 1
            ));
        }
        free_since_the_last_hold = false;
        holds.push(rows);
    }
    let whole: u64 = holds.iter().sum();
    let most = holds.iter().copied().max().unwrap_or(0);
    println!(
        "journal_retention_read_ahead: {} row holds deleted {whole} rows, the most in one hold \
         {most}; {} steps",
        holds.len(),
        steps.len()
    );
    if !deleted || whole <= 2 * RETENTION_ROWS_PER_HOLD {
        problems.push(format!(
            "the setup: the pass did not delete a big segment of more rows than two holds take \
             (deleted: {deleted}, rows: {whole})"
        ));
    }
    let over = holds.iter().filter(|rows| **rows > RETENTION_ROWS_PER_HOLD).count();
    if over > 0 {
        problems.push(format!(
            "{over} of {} row holds deleted more than {RETENTION_ROWS_PER_HOLD} rows under the \
             registry lock (the most: {most} rows in one hold)",
            holds.len()
        ));
    }
    assert!(problems.is_empty(), "{problems:#?}");
}

#[test]
fn the_retention_pass_reads_the_records_below_the_floor_with_the_registry_lock_free() {
    let (steps, deleted) = steps_of_a_pass_that_deletes_a_big_segment("floor-cut", |step| {
        matches!(step, RetentionStep::FloorCut)
    });
    let reads: Vec<Option<bool>> = steps
        .iter()
        .filter(|(step, _)| matches!(step, RetentionStep::FloorCut))
        .map(|(_, free)| *free)
        .collect();
    let under_the_lock = reads.iter().filter(|free| **free != Some(true)).count();
    println!(
        "journal_retention_read_ahead: {} reads of the records below the floor, {} steps",
        reads.len(),
        steps.len()
    );
    let mut problems = Vec::new();
    if !deleted || reads.is_empty() {
        problems.push(format!(
            "the setup: the pass did not delete the big segment, or it never read the records \
             below the floor (deleted: {deleted}, reads: {})",
            reads.len()
        ));
    }
    if under_the_lock > 0 {
        problems.push(format!(
            "the pass read the records of the sealed segments below the floor {} times; at the \
             first of {under_the_lock} of them a second thread did not get the registry lock in \
             {LOCK_WAIT:?} (the test does not wait again at the later ones)",
            reads.len()
        ));
    }
    assert!(problems.is_empty(), "{problems:#?}");
}
