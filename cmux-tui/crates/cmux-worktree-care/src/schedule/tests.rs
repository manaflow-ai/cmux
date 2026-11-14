use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FOLDER: AtomicU64 = AtomicU64::new(0);

fn folder(name: &str) -> PathBuf {
    let serial = NEXT_FOLDER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "care-schedule-{name}-{}-{}-{serial}",
        std::process::id(),
        crate::inventory::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

const HOUR: u64 = 60 * 60 * 1000;

#[test]
fn a_second_daemon_waits_while_one_runs_a_pass() {
    let dir = folder("busy");
    let held = claim(&dir, 1_000, Some(HOUR), true).expect("first pass");
    // Another process opens its own descriptor: flock is per open file.
    assert_eq!(claim(&dir, 1_000, Some(HOUR), true).unwrap_err(), Refused::Busy);
    assert_eq!(claim(&dir, 1_000, None, false).unwrap_err(), Refused::Busy);
    drop(held);
    assert!(claim(&dir, 1_000, None, false).is_ok(), "the lock goes with the claim");
}

#[test]
fn the_next_automatic_pass_waits_a_spacing_after_the_last_ended() {
    let dir = folder("spacing");
    claim(&dir, 0, Some(HOUR), true).expect("first pass").finish(2 * HOUR).unwrap();
    assert_eq!(last(&dir), Some(Stamp { started_ms: 0, finished_ms: Some(2 * HOUR) }));
    // A daemon that starts (or wakes) an hour after the start, but before
    // an hour after the end, does not scan again.
    assert_eq!(claim(&dir, 2 * HOUR + HOUR / 2, Some(HOUR), true).unwrap_err(), Refused::NotDue);
    assert!(claim(&dir, 3 * HOUR, Some(HOUR), true).is_ok());
}

#[test]
fn a_pass_that_never_finished_still_spaces_the_next() {
    let dir = folder("crash");
    drop(claim(&dir, 10, Some(HOUR), true).expect("pass"));
    assert_eq!(claim(&dir, HOUR / 2, Some(HOUR), true).unwrap_err(), Refused::NotDue);
}

#[test]
fn a_stamp_from_the_future_does_not_hold_cleanup_back() {
    let dir = folder("future");
    claim(&dir, 10 * HOUR, Some(HOUR), true).expect("pass").finish(10 * HOUR).unwrap();
    assert!(claim(&dir, HOUR, Some(HOUR), true).is_ok());
}

#[test]
fn an_asked_for_pass_ignores_the_spacing_and_a_report_records_nothing() {
    let dir = folder("asked");
    claim(&dir, 0, Some(HOUR), true).expect("pass").finish(5).unwrap();
    claim(&dir, 6, None, false).expect("report now").finish(7).unwrap();
    assert_eq!(last(&dir), Some(Stamp { started_ms: 0, finished_ms: Some(5) }));
    claim(&dir, 8, None, true).expect("clean up now").finish(9).unwrap();
    assert_eq!(last(&dir), Some(Stamp { started_ms: 8, finished_ms: Some(9) }));
}

/// A pass that is not due lets go of the pass lock, also while a child the daemon forked
/// meanwhile has the descriptor: else a pass someone asks for next fails with "a worktree
/// cleanup pass or report is already running".
#[cfg(unix)]
#[test]
fn a_pass_not_due_leaves_the_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = folder("forked");
    claim(&dir, 0, Some(HOUR), true).expect("first pass").finish(0).unwrap();
    let lock = open_lock(&dir.join(LOCK)).unwrap();
    let keeper = crate::test_fork::Keeper::fork();
    let not_due = claim_on(lock, &dir, 1, Some(HOUR), true);
    let asked = claim(&dir, 1, None, false);
    drop(keeper);
    assert_eq!(not_due.unwrap_err(), Refused::NotDue);
    assert!(asked.is_ok(), "a pass that was not due left the pass lock held");
    let _ = std::fs::remove_dir_all(&dir);
}
