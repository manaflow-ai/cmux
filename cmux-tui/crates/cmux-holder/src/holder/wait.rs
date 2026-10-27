//! The loop's one timed wait: `poll` until the earliest deadline, never on a
//! period. As Chromium's `MessagePumpEpoll::Run` (base/message_loop/
//! message_pump_epoll.cc) the timeout is the next delayed work's, or none;
//! every other wake (a SIGCHLD, launchd's SIGTERM) comes through a
//! descriptor in the set.

use std::time::Instant;

/// `poll`'s timeout for `deadline`: -1 (no timeout) without one, else the
/// milliseconds left plus one, so the wait never ends before the deadline,
/// however far it is.
pub(super) fn poll_timeout(deadline: Option<Instant>, now: Instant) -> libc::c_int {
    let Some(deadline) = deadline else { return -1 };
    let left = deadline.saturating_duration_since(now).as_millis();
    let max = (libc::c_int::MAX - 1) as u128;
    // The `min` keeps the cast in range.
    left.min(max) as libc::c_int + 1
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn no_deadline_waits_with_no_timeout() {
        assert_eq!(poll_timeout(None, Instant::now()), -1);
    }

    /// A far deadline (an idle exit or a cold ring minutes away) is one
    /// wake, not one a minute until it comes.
    #[test]
    fn a_far_deadline_is_one_wait_to_it() {
        let now = Instant::now();
        assert_eq!(poll_timeout(Some(now + Duration::from_secs(600)), now), 600_001);
        assert_eq!(poll_timeout(Some(now + Duration::from_secs(30)), now), 30_001);
    }

    #[test]
    fn the_wait_never_ends_before_the_deadline() {
        let now = Instant::now();
        assert_eq!(poll_timeout(Some(now + Duration::from_micros(1_500)), now), 2);
        assert_eq!(poll_timeout(Some(now), now), 1);
        assert_eq!(poll_timeout(Some(now), now + Duration::from_secs(1)), 1);
    }

    #[test]
    fn a_deadline_past_the_poll_range_saturates() {
        let now = Instant::now();
        let far = now + Duration::from_secs(u64::from(u32::MAX));
        assert_eq!(poll_timeout(Some(far), now), libc::c_int::MAX);
    }
}
