//! The terminal host's parser thread guard.

use super::*;

/// How long a host whose parser panicked waits for its exit to be
/// published before it ends anyway: the termination escalation (SIGHUP,
/// grace, SIGKILL, child wait) plus the launch-owner deadline.
const PARSER_FAILURE_EXIT_BOUND: Duration = Duration::from_secs(10);
/// The process exit status of a host whose parser panicked (EX_SOFTWARE).
pub(super) const PARSER_FAILURE_EXIT_CODE: i32 = 70;

/// Runs the parser worker `parse` (production: the loop in
/// `spawn_host_runtime`) on the calling thread. If it panics, the terminal
/// can no longer apply output and nothing else marks the PTY drained, so the
/// host would live forever without an exit. Instead the host ends its child,
/// publishes its exit (bounded wait), and then `end_process` ends the host
/// process.
pub(super) fn run_guarded_host_parser(
    host: &Arc<HostShared>,
    parse: impl FnOnce(),
    end_process: impl FnOnce(),
) {
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(parse)).is_ok() {
        return;
    }
    eprintln!("terminal-host: the parser thread panicked; publishing the exit and ending the host");
    if !host.end_after_parser_failure(PARSER_FAILURE_EXIT_BOUND) {
        eprintln!("terminal-host: the exit was not published in time; ending the host anyway");
    }
    end_process();
}

impl HostShared {
    /// Ends a host whose parser is gone. No later byte can be applied, so
    /// the PTY stream counts as drained; the child is ended (the usual
    /// termination escalation), and its reap publishes the exit. True when
    /// the exit was published within `bound`.
    fn end_after_parser_failure(self: &Arc<Self>, bound: Duration) -> bool {
        self.mark_pty_drained();
        self.request_termination();
        self.publish_exit_if_drained();
        self.wait_until_dead(bound)
    }

    /// Waits until the exit is published (`dead`), at most `bound`.
    fn wait_until_dead(&self, bound: Duration) -> bool {
        let deadline = Instant::now() + bound;
        let (lock, published) = &self.parser_progress;
        // Exit publication sets `dead`, then bumps parser progress under
        // this lock, so a check made under the lock cannot miss the wake.
        let mut generation = lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while !self.dead.load(Ordering::Acquire) {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            generation = published
                .wait_timeout(generation, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        true
    }
}
