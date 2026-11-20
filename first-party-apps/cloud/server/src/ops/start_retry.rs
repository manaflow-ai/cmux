//! How the serve loop resumes a paused machine when the provider fails
//! (design remote-cloud-durability row F11, fault `pause-vm` + `http 503`).
//!
//! A `cloud.machine.start` that fails (Resume Machine, which is also what the
//! app's Reconnect runs on a paused machine, or the start inside a connect)
//! ends one of two ways:
//!
//! - **Transient** (a 503 `cloud.provider.unavailable`, `cloud.machine.busy`,
//!   a 502 `owner.unreachable`, a lost relay answer, an unknown outcome):
//!   the loop parks the op and runs it again after [`delay`] (0.5 s, doubling,
//!   at most [`MAX_DELAY`]), with the same request, until it succeeds or the
//!   waits would pass [`BOUND`]. The backend keeps no record of a retryable
//!   refusal (cmux-platform ownership engine: "a retryable reject is not
//!   decided"), so each try is evaluated again. Past the bound the answer
//!   is [`stopped`]: the step, the tries and the last refusal.
//! - **Final** (a 404 `cloud.machine.not_found`, a plan or quota refusal, a
//!   forbidden machine): never retried. The backend records a final refusal
//!   under its key, so a same-key retry could only replay it, and a new key
//!   would get the same answer. The answer is [`refused`]: the step and why
//!   a retry would not help; for a 404 whose id is a machine's name, which
//!   machine it names.
//!
//! The policy is pure (no clock, no I/O); `link/park.rs` keeps the timers.

use crate::api::{CloudError, codes};
use crate::ops::Projection;
use std::time::Duration;

/// The step a resume failed at, as its answers name it.
pub(crate) const STEP: &str = "start";

/// The first wait before a retry.
pub(crate) const FIRST_DELAY: Duration = Duration::from_millis(500);

/// The longest wait between two tries.
pub(crate) const MAX_DELAY: Duration = Duration::from_secs(8);

/// The sum of waits a resume spends on transient refusals before it answers
/// [`stopped`]: inside the app's 40 s result deadline of Resume Machine and
/// its 120 s bound on a connect, so the answer reaches the caller.
pub(crate) const BOUND: Duration = Duration::from_secs(30);

/// Refusals that say "not now" but must not be retried on a timer: a person
/// has to act (`approval_pending`), the machine never bound
/// (`not_bound`: delete it), or the sign-in ended.
const NEVER_ON_A_TIMER: &[&str] =
    &[codes::APPROVAL_PENDING, codes::NOT_BOUND, codes::AUTH_REQUIRED, codes::INVALID_ARGS];

/// A resume's tries so far.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Tries {
    /// Tries that failed transiently (the first try is 1).
    pub failed: u32,
    /// The waits already spent between them.
    pub waited: Duration,
}

/// Whether `error`, the answer of a start, may succeed when asked again.
pub(crate) fn transient(error: &CloudError) -> bool {
    error.retryable && !NEVER_ON_A_TIMER.contains(&error.code)
}

/// The wait before retry `failed` (from 1): 0.5 s, 1 s, 2 s, 4 s, then
/// [`MAX_DELAY`].
pub(crate) fn delay(failed: u32) -> Duration {
    let doublings = failed.saturating_sub(1).min(16);
    FIRST_DELAY.saturating_mul(1 << doublings).min(MAX_DELAY)
}

/// The tries after one more transient failure, with the wait before the
/// next try; `None` when that wait would pass [`BOUND`].
pub(crate) fn next(tries: Tries) -> Option<(Tries, Duration)> {
    let failed = tries.failed + 1;
    let wait = delay(failed);
    let waited = tries.waited + wait;
    (waited <= BOUND).then_some((Tries { failed, waited }, wait))
}

/// A start whose refusal is final: the step, the refusal, and that the
/// loop did not retry it. A 404 for an id that is a machine's name says
/// which machine has that name.
pub(crate) fn refused(machine: &str, error: CloudError, projection: &Projection) -> CloudError {
    let mut why = format!(
        "Resuming {machine} failed at its {STEP} step: {}. Not retried: the same request gets the same answer",
        error.message
    );
    if error.code == codes::NOT_FOUND
        && let Some(named) = projection
            .machines()
            .find(|m| m.id() != machine && m.record.name.as_deref() == Some(machine))
    {
        why.push_str(&format!(
            "; `{machine}` is the name of machine {}: resume it by that id",
            named.id()
        ));
    }
    CloudError { message: why, step: Some(STEP), ..error }
}

/// A start that kept failing transiently until its waits reached [`BOUND`]:
/// the step, the tries and the last refusal. Still retryable: a later
/// Resume or Reconnect asks again.
pub(crate) fn stopped(machine: &str, error: CloudError, tries: Tries) -> CloudError {
    let message = format!(
        "Resuming {machine} stopped at its {STEP} step after {} tries in {} s: {}. Resume or Reconnect asks again",
        tries.failed + 1,
        tries.waited.as_secs(),
        error.message
    );
    CloudError { message, step: Some(STEP), retryable: true, ..error }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_waits_double_up_to_their_cap_and_stay_inside_the_bound() {
        let delays: Vec<_> = (1..=7).map(delay).collect();
        assert_eq!(
            delays,
            [500, 1000, 2000, 4000, 8000, 8000, 8000].map(Duration::from_millis).to_vec()
        );
        let mut tries = Tries::default();
        let mut waits = Vec::new();
        while let Some((next_tries, wait)) = next(tries) {
            waits.push(wait);
            tries = next_tries;
        }
        assert!(tries.waited <= BOUND, "{tries:?}");
        assert_eq!(waits.len(), 6, "six retries fit in 30 s: {waits:?}");
        assert_eq!(tries.waited, Duration::from_millis(23_500));
    }

    #[test]
    fn only_a_retryable_refusal_that_needs_no_person_is_transient() {
        let busy =
            CloudError { retryable: true, ..CloudError::new(codes::PROVIDER_UNAVAILABLE, "x") };
        assert!(transient(&busy));
        assert!(!transient(&CloudError::new(codes::NOT_FOUND, "gone")));
        let approval =
            CloudError { retryable: true, ..CloudError::new(codes::APPROVAL_PENDING, "x") };
        assert!(!transient(&approval));
        let unbound = CloudError { retryable: true, ..CloudError::new(codes::NOT_BOUND, "x") };
        assert!(!transient(&unbound));
    }
}
