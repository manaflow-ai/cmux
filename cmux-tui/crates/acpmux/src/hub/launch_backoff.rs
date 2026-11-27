//! A chat whose harness exits while it starts, with the same error each time, is not started
//! again on every wake. A Linux host, 2026-11-24: the cmux-tui the `chief` harness runs had no
//! `chief` verb, and every wake (every 30 s) spawned it again and logged `wake failed: agent
//! process closed (chief): cmux: unknown resource scope "chief"`, for days. The first failure is
//! retried as before (most are passing); from the second identical one on, a start fails with
//! that error, starting nothing and logging nothing, until a window that doubles from
//! [`FIRST_HOLD`] up to [`MAX_HOLD`] has passed. The window is bounded so a fix underneath (a
//! self-update that replaced the binary) is picked up within it; a start that works, another
//! error, or the person's own prompt (`Session::person_wrote`) ends it at once.

use crate::rpc::RpcError;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub(super) const FIRST_HOLD: Duration = Duration::from_secs(30);
pub(super) const MAX_HOLD: Duration = Duration::from_secs(30 * 60);

/// Whether `e` is a launch failure this holds back: the harness process went away while it
/// started (`agent::AGENT_CLOSED`).
pub(super) fn is_launch_failure(e: &RpcError) -> bool {
    e.message.starts_with(crate::agent::AGENT_CLOSED)
}

struct Held {
    error: RpcError,
    fails: u32,
    until: Instant,
}

/// A chat's last launch failure: how many times in a row it repeated, and until when a start
/// fails with it (`Session::launch_backoff`).
#[derive(Default)]
pub(crate) struct LaunchBackoff(Mutex<Option<Held>>);

impl LaunchBackoff {
    /// The error a start at `now` fails with, starting nothing, or None.
    pub(super) fn held(&self, now: Instant) -> Option<RpcError> {
        let held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        held.as_ref().filter(|h| now < h.until).map(|h| h.error.clone())
    }

    /// A start failed at `now` with `e`. Returns the window the next starts are held for, None
    /// for a first failure (or a new error), which is retried as before.
    pub(super) fn failed(&self, e: &RpcError, now: Instant) -> Option<(u32, Duration)> {
        let mut held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let fails = match held.as_ref() {
            Some(h) if h.error.message == e.message => h.fails.saturating_add(1),
            _ => 1,
        };
        let hold = (fails >= 2).then(|| {
            let doublings = (fails - 2).min(16);
            FIRST_HOLD.saturating_mul(1 << doublings).min(MAX_HOLD)
        });
        *held = Some(Held { error: e.clone(), fails, until: now + hold.unwrap_or_default() });
        hold.map(|hold| (fails, hold))
    }

    /// A start worked, or the person wrote: the next start goes ahead.
    pub(crate) fn clear(&self) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn closed(why: &str) -> RpcError {
        RpcError::internal(format!("{} (chief): {why}", crate::agent::AGENT_CLOSED))
    }

    #[test]
    fn a_repeated_launch_failure_backs_off_up_to_a_bound_and_a_change_or_success_ends_it() {
        let backoff = LaunchBackoff::default();
        let t0 = Instant::now();
        let e = closed("cmux: unknown resource scope \"chief\"");
        assert!(is_launch_failure(&e));
        assert!(!is_launch_failure(&RpcError::internal("session/new refused")));
        // The first failure is retried as before.
        assert_eq!(backoff.failed(&e, t0), None);
        assert!(backoff.held(t0).is_none());
        // The second identical one holds starts for 30 s, then 60 s, ... up to 30 min.
        assert_eq!(backoff.failed(&e, t0), Some((2, FIRST_HOLD)));
        assert_eq!(backoff.held(t0 + Duration::from_secs(29)).unwrap().message, e.message);
        assert!(backoff.held(t0 + FIRST_HOLD).is_none());
        assert_eq!(backoff.failed(&e, t0), Some((3, Duration::from_secs(60))));
        let mut last = Duration::ZERO;
        for _ in 0..40 {
            last = backoff.failed(&e, t0).unwrap().1;
        }
        assert_eq!(last, MAX_HOLD);
        assert!(backoff.held(t0 + MAX_HOLD).is_none(), "a fix underneath is picked up");
        // Another error starts over: retried once.
        assert_eq!(backoff.failed(&closed("segfault"), t0), None);
        assert!(backoff.held(t0).is_none());
        backoff.failed(&closed("segfault"), t0);
        assert!(backoff.held(t0).is_some());
        backoff.clear();
        assert!(backoff.held(t0).is_none());
        assert_eq!(backoff.failed(&closed("segfault"), t0), None);
    }
}
