//! The queue and drain locks are let go by an unlock, not only by a close: a child that another
//! daemon thread forks (the owner's `resume` drain runs in the daemon) shares the open file
//! description until it execs, and a close alone leaves that copy holding the lock.

use std::os::fd::AsRawFd as _;

use super::*;

/// A forked child that keeps a copy of every descriptor of this process; dropping this kills and
/// reaps it.
///
/// Fork safety: a test binary runs many threads, so the child of `fork` may make only
/// async-signal-safe calls. It calls `pause` in a loop and nothing else: it never returns from
/// [`Keeper::fork`], allocates, takes a lock, unwinds or calls `_exit` or `exit` itself. The
/// parent's drop ends it with SIGKILL (from outside the child) and reaps it with `waitpid`.
struct Keeper(libc::pid_t);

impl Keeper {
    fn fork() -> Keeper {
        // SAFETY: the child runs only async-signal-safe `pause` until SIGKILL ends it.
        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed");
        if child == 0 {
            loop {
                // SAFETY: as above.
                unsafe { libc::pause() };
            }
        }
        Keeper(child)
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        let mut status = 0;
        // SAFETY: `self.0` is this test's own child and `status` outlives the call.
        unsafe {
            libc::kill(self.0, libc::SIGKILL);
            libc::waitpid(self.0, &mut status, 0);
        }
    }
}

/// Whether an exclusive flock on a new description of `path` is taken now; one taken is unlocked
/// before the close, so a child another test forks meanwhile keeps nothing.
fn free(path: &Path) -> bool {
    let file = std::fs::OpenOptions::new().read(true).open(path).unwrap();
    // SAFETY: flock on a descriptor `file` keeps open through both calls.
    unsafe {
        let taken = libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0;
        if taken {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
        taken
    }
}

fn spool(name: &str) -> Spool {
    let directory = env::temp_dir().join(format!(
        "cmux-hook-spool-lock-{name}-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
    ));
    std::fs::create_dir_all(&directory).unwrap();
    Spool::named(&directory, "queue")
}

#[test]
fn a_dropped_drain_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let spool = spool("drain");
    let lock = spool.try_drain().unwrap().expect("a free drain lock");
    let keeper = Keeper::fork();
    drop(lock);
    let free = free(&spool.drain);
    drop(keeper);
    let _ = std::fs::remove_dir_all(spool.drain.parent().unwrap());
    assert!(free, "a dropped drain lock stayed held through a forked child's copy");
}

#[test]
fn a_dropped_queue_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let spool = spool("queue");
    let held = spool.open_locked().unwrap();
    let keeper = Keeper::fork();
    drop(held);
    let free = free(&spool.lines);
    drop(keeper);
    let _ = std::fs::remove_dir_all(spool.lines.parent().unwrap());
    assert!(free, "a dropped queue lock stayed held through a forked child's copy");
}
