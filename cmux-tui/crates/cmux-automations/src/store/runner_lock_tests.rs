use super::*;

/// A forked child that keeps a copy of every descriptor of this process, the way a child that
/// another thread forks keeps them until it execs; dropping this kills and reaps it.
///
/// Fork safety: a test binary runs many threads, so the child of `fork` may make only
/// async-signal-safe calls. It calls `pause` in a loop and nothing else: it never returns
/// from [`Keeper::fork`], allocates, takes a lock, unwinds or calls `_exit` or `exit` itself.
/// The parent's drop ends it with SIGKILL (from outside the child) and reaps it with
/// `waitpid`.
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

/// A runner lock let go (the `cmux automation` probe takes one and drops it at once) is free,
/// also while a child forked meanwhile keeps its descriptor: else the next probe reports a
/// runner that does not exist and the next runner start exits as "runner is running".
#[test]
fn a_dropped_runner_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let root = std::env::temp_dir().join(format!(
        "cmux-automations-runner-lock-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
    ));
    let store = Store::open(&root).unwrap();
    let lock = RunnerLock::acquire(&store).unwrap().expect("a free runner lock");
    let keeper = Keeper::fork();
    drop(lock);
    let again = RunnerLock::acquire(&store).unwrap();
    drop(keeper);
    let _ = fs::remove_dir_all(&root);
    assert!(again.is_some(), "a dropped runner lock stayed held through a forked child's copy");
}
