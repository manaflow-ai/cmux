use super::*;
use std::os::unix::io::AsRawFd as _;
use std::path::Path;

/// Forks a child that keeps a copy of every descriptor of this process until [`end`].
pub(in crate::updater) fn forked_keeper() -> libc::pid_t {
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

pub(in crate::updater) fn end(child: libc::pid_t) {
    let mut status = 0;
    // SAFETY: `child` is this test's own child and `status` outlives the call.
    unsafe {
        libc::kill(child, libc::SIGKILL);
        libc::waitpid(child, &mut status, 0);
    }
}

/// Whether an exclusive flock on a description of its own is taken now; one taken is
/// unlocked before the close, so a child another test forks meanwhile keeps nothing.
fn free(path: &Path) -> bool {
    let file = fs::OpenOptions::new().write(true).open(path).unwrap();
    // SAFETY: flock on a descriptor `file` keeps open through both calls.
    unsafe {
        let taken = libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0;
        if taken {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
        taken
    }
}

/// The gate's flock is free once its holder lets go, also while a child the service
/// forked meanwhile (a session host, `wg`, systemctl) still has the descriptor: else the
/// next bind's hold, flip or `service_started` waits for that child.
#[test]
fn a_dropped_gate_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = tempfile::tempdir().unwrap();
    let gate = Gate::new(&Paths::new(dir.path()));
    let path = gate.paths.at(GATE_LOCK);
    let locked = gate.lock();
    assert!(!free(&path), "the gate took its lock");
    let child = forked_keeper();
    drop(locked);
    let freed = free(&path);
    end(child);
    assert!(freed, "a dropped gate lock stayed held through a forked child's copy");
}
