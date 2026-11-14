use super::*;
use std::os::fd::AsRawFd as _;
use std::path::{Path, PathBuf};

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-file-lock-{name}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn open(path: &Path) -> File {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .unwrap()
}

fn raw_try(file: &File, op: i32) -> bool {
    // SAFETY: flock on a descriptor `file` keeps open through the call.
    unsafe { libc::flock(file.as_raw_fd(), op | libc::LOCK_NB) == 0 }
}

/// Whether a raw `flock` of `op` on a description of its own is taken now; one taken is
/// unlocked before the close (a child another test forks meanwhile keeps nothing).
fn raw_can(path: &Path, op: i32) -> bool {
    let file = open(path);
    let taken = raw_try(&file, op);
    if taken {
        raw_try(&file, libc::LOCK_UN);
    }
    taken
}

/// The lock is the `flock` that every cmux build in the field takes on these files: each
/// kind excludes and admits a raw `flock` as a raw `flock` does, both ways. std leaves the
/// lock's kind to each platform; if it ever stops being `flock` here, this fails first.
#[test]
fn it_is_the_flock_older_builds_take() {
    let path = scratch("flock");
    let raw = open(&path);
    assert!(raw_try(&raw, libc::LOCK_EX));
    assert!(matches!(FileLock::try_take(open(&path), Kind::Exclusive), Err(LockError::Busy(_))));
    assert!(matches!(FileLock::try_take(open(&path), Kind::Shared), Err(LockError::Busy(_))));
    assert!(raw_try(&raw, libc::LOCK_SH), "a raw flock converts to shared");
    let shared = FileLock::try_take(open(&path), Kind::Shared).expect("shared beside shared");
    assert!(matches!(FileLock::try_take(open(&path), Kind::Exclusive), Err(LockError::Busy(_))));
    assert!(raw_try(&raw, libc::LOCK_UN));
    assert!(!raw_can(&path, libc::LOCK_EX), "a raw flock sees the shared FileLock");
    assert!(raw_can(&path, libc::LOCK_SH), "and admits a raw shared flock beside it");
    drop(shared);
    let exclusive = FileLock::try_take(open(&path), Kind::Exclusive).expect("free");
    assert!(!raw_can(&path, libc::LOCK_SH), "a raw flock sees the exclusive FileLock");
    assert!(!raw_can(&path, libc::LOCK_EX));
    drop(exclusive);
    assert!(raw_can(&path, libc::LOCK_EX), "a dropped FileLock leaves the file free");
    let _ = std::fs::remove_file(&path);
}

/// Forks a child that keeps a copy of every descriptor of this process until it is killed.
fn forked_keeper() -> libc::pid_t {
    // SAFETY: the child calls only pause, which is async-signal-safe, until SIGKILL ends it.
    let child = unsafe { libc::fork() };
    assert!(child >= 0, "fork failed");
    if child == 0 {
        loop {
            // SAFETY: as above.
            unsafe { libc::pause() };
        }
    }
    child
}

fn end(child: libc::pid_t) {
    let mut status = 0;
    // SAFETY: `child` is this test's own child and `status` outlives the call.
    unsafe {
        libc::kill(child, libc::SIGKILL);
        libc::waitpid(child, &mut status, 0);
    }
}

/// A dropped lock is free at once, also while a child forked meanwhile still has its
/// descriptor: the drop unlocks, it does not only close.
#[test]
fn a_dropped_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let path = scratch("forked");
    for kind in [Kind::Exclusive, Kind::Shared] {
        let lock = FileLock::take(open(&path), kind).unwrap();
        let child = forked_keeper();
        drop(lock);
        let free = raw_can(&path, libc::LOCK_EX);
        end(child);
        assert!(free, "a dropped {kind:?} lock stayed held through a forked child's copy");
    }
    let _ = std::fs::remove_file(&path);
}

/// A look leaves no lock behind, also while a child forked meanwhile has the descriptor.
#[test]
fn held_elsewhere_leaves_no_lock() {
    let path = scratch("look");
    let probe = open(&path);
    let child = forked_keeper();
    let held = FileLock::held_elsewhere(&probe, Kind::Exclusive);
    let free = raw_can(&path, libc::LOCK_EX);
    end(child);
    assert!(!held.unwrap(), "a free file read as held");
    assert!(free, "the look left its lock behind");
    let holder = FileLock::take(open(&path), Kind::Shared).unwrap();
    assert!(FileLock::held_elsewhere(&probe, Kind::Exclusive).unwrap());
    assert!(!FileLock::held_elsewhere(&probe, Kind::Shared).unwrap());
    drop(holder);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn take_within_waits_for_the_holder_then_gives_up_at_its_budget() {
    let path = scratch("within");
    let holder = FileLock::take(open(&path), Kind::Exclusive).unwrap();
    let started = Instant::now();
    let refused = FileLock::take_within(
        open(&path),
        Kind::Exclusive,
        Duration::from_millis(50),
        Duration::ZERO,
    );
    assert!(matches!(refused, Err(LockError::Busy(_))));
    assert!(started.elapsed() >= Duration::from_millis(50));
    // The holder lets go on a scoped thread, which the scope joins.
    let taken = std::thread::scope(|scope| {
        scope.spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            drop(holder);
        });
        FileLock::take_within(
            open(&path),
            Kind::Exclusive,
            Duration::from_secs(10),
            Duration::from_millis(5),
        )
    });
    assert!(taken.is_ok(), "the lock came free within the budget");
    let _ = std::fs::remove_file(&path);
}
