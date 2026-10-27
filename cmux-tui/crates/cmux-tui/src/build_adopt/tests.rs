//! The adoption locks wait on the kernel's lock release, bounded once.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::{lock_within, try_lock};

#[test]
fn lock_within_takes_a_free_lock_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("nested").join(".adopt-x.lock");
    assert!(lock_within(&path, Duration::from_secs(5)).unwrap().is_some());
}

#[test]
fn lock_within_gives_up_after_its_limit_while_the_holder_keeps_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(".adopt-x.lock");
    let _holder = try_lock(&path).unwrap().expect("the first lock is free");
    let started = Instant::now();
    assert!(lock_within(&path, Duration::from_millis(100)).unwrap().is_none());
    assert!(started.elapsed() >= Duration::from_millis(100));
}

#[test]
fn lock_within_wakes_when_the_holder_releases_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(".adopt-x.lock");
    let holder = try_lock(&path).unwrap().expect("the first lock is free");
    let (release, released) = mpsc::channel::<()>();
    let releaser = std::thread::spawn(move || {
        let _ = released.recv();
        drop(holder);
    });
    let waiter_path = path.clone();
    let waiter = std::thread::spawn(move || {
        let started = Instant::now();
        let locked = lock_within(&waiter_path, Duration::from_secs(30)).unwrap();
        (locked.is_some(), started.elapsed())
    });
    release.send(()).unwrap();
    releaser.join().unwrap();
    let (locked, waited) = waiter.join().unwrap();
    assert!(locked, "the released lock is taken");
    assert!(
        waited < Duration::from_secs(10),
        "the release ended the wait, not the limit: {waited:?}"
    );
    assert!(try_lock(&path).unwrap().is_some(), "the waiter dropped its lock with its result");
}
