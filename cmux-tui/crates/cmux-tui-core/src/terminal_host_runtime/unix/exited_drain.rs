//! A bounded PTY drain after the host's child exited (cx-6so.49, L0).
//!
//! The host reaps its child and writes the exit record only after the PTY
//! is drained (the final bytes reach the parser first). A descendant that
//! escaped the shell (a background job) can keep the PTY slave open after
//! the shell exited; on Linux the master then never reports EOF, while
//! Darwin reports EOF when the session leader exits. Without a bound such a
//! host would keep a terminal whose shell exited "running" forever, with or
//! without an owner. Rule: once the child exited, the host reads the PTY for
//! at most [`HOST_EXITED_PTY_DRAIN_LIMIT`], then force-drains (the same
//! bounded drain an explicit terminate uses), writes the exit record and
//! ends when no client stream is attached. The descendant gets a hangup when
//! the master closes.

use std::sync::{MutexGuard, PoisonError};

use super::*;

/// How long a host keeps draining its PTY after its child exited.
pub(super) const HOST_EXITED_PTY_DRAIN_LIMIT: Duration = Duration::from_secs(30);

/// [`HOST_EXITED_PTY_DRAIN_LIMIT`], or a shorter test value from
/// `CMUX_TUI_TEST_HOST_EXITED_DRAIN_LIMIT_MS` (never longer).
fn limit() -> Duration {
    std::env::var("CMUX_TUI_TEST_HOST_EXITED_DRAIN_LIMIT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(|ms| Duration::from_millis(ms).min(HOST_EXITED_PTY_DRAIN_LIMIT))
        .unwrap_or(HOST_EXITED_PTY_DRAIN_LIMIT)
}

/// The drain deadline of one exited child.
pub(super) struct ExitedDrain {
    deadline: Instant,
    forced: bool,
}

impl ExitedDrain {
    /// Start the bound when the child is observed to have exited.
    pub(super) fn start() -> Self {
        Self { deadline: Instant::now() + limit(), forced: false }
    }

    /// Wait until the child may be reaped (drained, or a terminate finished
    /// its escalation), forcing the drain once the deadline passed.
    pub(super) fn wait(&mut self, host: &HostShared, state: MutexGuard<'_, Option<TerminalExit>>) {
        let waiting = |_: &mut Option<TerminalExit>| {
            !host.group_escalation_complete.load(Ordering::Acquire)
                && (host.termination_started.load(Ordering::Acquire)
                    || !host.pty_drained.load(Ordering::Acquire))
        };
        if self.forced {
            drop(
                host.child_exit
                    .1
                    .wait_while(state, waiting)
                    .unwrap_or_else(PoisonError::into_inner),
            );
            return;
        }
        let timeout = self.deadline.saturating_duration_since(Instant::now());
        let (state, result) = host
            .child_exit
            .1
            .wait_timeout_while(state, timeout, waiting)
            .unwrap_or_else(PoisonError::into_inner);
        drop(state);
        if result.timed_out() {
            self.forced = true;
            host.request_forced_pty_drain();
        }
    }
}
