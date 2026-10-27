//! Heals a dropped connection by sending the request again
//! (plans/cmux-next/state-ownership.md, section 4; DESIGN in
//! cmux-worktrees/self-healing).
//!
//! A mutation is resent with the idempotency key of its first try, so the
//! daemon replays the committed result instead of running it twice (the
//! daemon's resource receipts, `terminal.input.write`'s input receipts). A
//! read is always safe to resend. What is never resent:
//! - a stream (it may have shown items already);
//! - a mutation whose read timed out: the daemon may still be running it, and
//!   only its own replay, not a second run, may answer the key;
//! - a protocol error: the next try would get the same answer.

use std::cell::{Cell, RefCell};
use std::time::Duration;

use cmux_tui_core::resource::{OperationClass, ResourceOperation};

use super::super::command::{RequestPlan, WireOperation};

/// The exit code `run_once` returns when the request should be sent again.
/// Never a process exit code (those are 0..=255).
pub(super) const AGAIN: i32 = i32::MIN;

/// The waits before the 2nd, 3rd and 4th try. Short on purpose: a busy
/// session answers within a second once the burst passes, and a person waits
/// on the CLI.
const BACKOFF: [Duration; 3] =
    [Duration::from_millis(200), Duration::from_millis(600), Duration::from_millis(1500)];

/// Why a try failed, for [`Tries::may_retry`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Failure {
    /// The connection closed or reset after the request was sent (or while
    /// it was written): the daemon dropped it, restarted, or refused it at its
    /// connection limit.
    Dropped,
    /// The response did not come in time.
    Timeout,
    /// Anything else (a protocol error): resending would not help.
    Other,
}

impl Failure {
    /// The failure a `read_envelope` error string describes.
    pub(super) fn from_read_error(message: &str) -> Self {
        if message == super::hints::no_answer() {
            Self::Timeout
        } else if message.starts_with("transport ") {
            Self::Dropped
        } else {
            Self::Other
        }
    }
}

/// The tries of one request.
pub(super) struct Tries {
    mutation: bool,
    /// A wait (`terminal.wait`) whose timeout is the caller's own: a resend
    /// would only make it wait longer than asked.
    waits: bool,
    stream: bool,
    /// Tries made so far, the current one included.
    made: Cell<usize>,
    disabled: bool,
    previous: RefCell<Option<Failure>>,
}

impl Tries {
    pub(super) fn new(plan: &RequestPlan) -> Self {
        Self {
            mutation: plan.operation.class() == OperationClass::Mutation,
            waits: matches!(
                &plan.operation,
                WireOperation::Typed(
                    ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit
                )
            ),
            stream: plan.stream,
            made: Cell::new(1),
            disabled: std::env::var_os("CMUX_CLI_NO_RETRY").is_some_and(|value| !value.is_empty()),
            previous: RefCell::new(None),
        }
    }

    /// Whether the current try, which failed with `failure`, may be made
    /// again. Records the failure when it may.
    pub(super) fn may_retry(&self, failure: Failure) -> bool {
        let allowed = decide(self.mutation || self.waits, self.stream, failure)
            && !self.disabled
            && self.made.get() <= BACKOFF.len();
        if allowed {
            *self.previous.borrow_mut() = Some(failure);
        }
        allowed
    }

    /// Whether an earlier try sent the request and failed: a later try that
    /// cannot even connect must still report that the outcome is unknown.
    pub(super) fn sent_before(&self) -> bool {
        self.previous.borrow().is_some()
    }

    /// Waits before the next try and counts it.
    pub(super) fn wait_before_next(&mut self) {
        let index = self.made.get().saturating_sub(1).min(BACKOFF.len() - 1);
        cmux_blocking::thread::sleep(backoff(BACKOFF[index]));
        self.made.set(self.made.get() + 1);
    }
}

/// The policy: which failures of which requests are resent. `no_timeout_retry`:
/// a mutation, or a wait with its own timeout.
fn decide(no_timeout_retry: bool, stream: bool, failure: Failure) -> bool {
    if stream {
        return false;
    }
    match failure {
        Failure::Dropped => true,
        Failure::Timeout => !no_timeout_retry,
        Failure::Other => false,
    }
}

/// `wait`, or the debug build's `CMUX_TEST_RETRY_BACKOFF_MS` (a release build
/// ignores it), so tests do not sleep.
fn backoff(wait: Duration) -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("CMUX_TEST_RETRY_BACKOFF_MS").ok().and_then(|value| value.parse().ok())
    {
        return Duration::from_millis(ms);
    }
    wait
}

#[cfg(test)]
mod tests {
    use super::{Failure, decide};

    #[test]
    fn a_dropped_mutation_is_resent_with_its_key() {
        assert!(decide(true, false, Failure::Dropped));
    }

    #[test]
    fn a_timed_out_mutation_is_not_resent() {
        // The daemon may still run it; a resend could only join, never help.
        assert!(!decide(true, false, Failure::Timeout));
    }

    #[test]
    fn a_read_is_resent_after_a_drop_or_a_timeout() {
        assert!(decide(false, false, Failure::Dropped));
        assert!(decide(false, false, Failure::Timeout));
    }

    #[test]
    fn streams_and_protocol_errors_are_never_resent() {
        assert!(!decide(false, true, Failure::Dropped));
        assert!(!decide(false, false, Failure::Other));
        assert!(!decide(true, false, Failure::Other));
    }
}
