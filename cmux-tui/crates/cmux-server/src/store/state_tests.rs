use super::*;
use std::time::Instant;

#[test]
fn a_second_apply_waits_for_the_first_to_end_instead_of_failing() {
    let dir = tempfile::tempdir().unwrap();
    let first = StoreLock::acquire(dir.path()).unwrap();
    let release = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        drop(first);
    });
    let started = Instant::now();
    let second = StoreLock::acquire_within(dir.path(), Duration::from_secs(10));
    release.join().unwrap();
    assert!(second.is_ok(), "the second apply should get the lock once the first ends");
    assert!(started.elapsed() >= Duration::from_millis(250));
}

#[test]
fn a_lock_still_held_at_the_deadline_names_the_other_apply() {
    let dir = tempfile::tempdir().unwrap();
    let _first = StoreLock::acquire(dir.path()).unwrap();
    let err = StoreLock::acquire_within(dir.path(), Duration::from_millis(200)).unwrap_err();
    let text = err.to_string();
    assert!(text.contains("another cmux server apply still holds"), "{text}");
    assert!(!text.contains("try again"), "{text}");
}
