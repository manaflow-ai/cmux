//! How often sends try a team hub that is failing (RFD 0049 R1). A hub answering 503 is usually
//! overloaded (2026-11-22: two unindexed scans), so every queued send trying it on its own
//! schedule would add to that load. Once a post fails in a way that passes (a 5xx, a 429, no
//! answer, no connection) the gate is shut. From then on one post may probe the hub per window,
//! and the window doubles with each failure from [`FIRST_WINDOW`] up to [`MAX_WINDOW`] (or the
//! hub's own `retryAfterSeconds` when that is longer). Every other send is queued in the outbox
//! without asking the hub. The first post the hub takes opens the gate again, and wakes every
//! queued delivery waiting on its back-off ([`Gate::opened`], RFD 0086 item 2): the outbox drains
//! the moment the hub is back instead of each send's next scheduled try (up to minutes later).
//!
//! A hub that answers ok never pays for this: an open gate is one atomic load.

use crate::no_panic::LockExt;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering::SeqCst};
use std::time::Duration;
use tokio::time::Instant;

/// The window after the first failure.
pub const FIRST_WINDOW: Duration = Duration::from_secs(1);
/// The longest window, however many failures came before.
pub const MAX_WINDOW: Duration = Duration::from_secs(60);

#[derive(Default, Debug)]
pub struct Gate {
    /// Failures in a row; 0 means the gate is open.
    failures: AtomicU32,
    /// Until when no post may go; a probe moves it on as it claims its slot.
    until: Mutex<Option<Instant>>,
    /// Woken when a shut gate opens: the outbox's hub deliveries end their retry wait on it.
    pub opened: tokio::sync::Notify,
}

impl Gate {
    /// Whether a post may go now. An open gate says yes at once. A shut gate says yes to one
    /// caller per window, the probe, and claims that window so no other caller probes in it.
    pub fn may_try(&self) -> bool {
        self.may_try_at(Instant::now())
    }

    fn may_try_at(&self, now: Instant) -> bool {
        let failures = self.failures.load(SeqCst);
        if failures == 0 {
            return true;
        }
        let mut until = self.until.lock_or_recover();
        if until.is_some_and(|u| now < u) {
            return false;
        }
        *until = Some(now + window(failures));
        true
    }

    /// The hub took a post (or answered with a refusal of its own): open.
    pub fn answered(&self) {
        if self.failures.swap(0, SeqCst) != 0 {
            *self.until.lock_or_recover() = None;
            self.opened.notify_waiters();
        }
    }

    /// A post failed in a way that passes: shut it for the next window, or `retry_after` when the
    /// hub asked for longer.
    pub fn failed(&self, retry_after: Option<Duration>) {
        self.failed_at(Instant::now(), retry_after);
    }

    fn failed_at(&self, now: Instant, retry_after: Option<Duration>) {
        let failures = self.failures.fetch_add(1, SeqCst).saturating_add(1);
        let wait = window(failures).max(retry_after.unwrap_or_default().min(MAX_WINDOW));
        let mut until = self.until.lock_or_recover();
        *until = Some(until.map_or(now + wait, |u| u.max(now + wait)));
    }

    /// Whether it is shut now, for a send's reason.
    pub fn shut(&self) -> bool {
        self.failures.load(SeqCst) != 0
    }
}

/// The window after `failures` failures in a row: 1 s, 2 s, 4 s, ... up to [`MAX_WINDOW`].
fn window(failures: u32) -> Duration {
    FIRST_WINDOW.saturating_mul(1 << failures.saturating_sub(1).min(16)).min(MAX_WINDOW)
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::FutureExt;

    /// `ms` milliseconds after a fixed start.
    fn at(ms: u64) -> Instant {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *START.get_or_init(Instant::now) + Duration::from_millis(ms)
    }

    fn ms(d: Duration) -> u64 {
        u64::try_from(d.as_millis()).unwrap()
    }

    #[test]
    fn an_open_gate_lets_every_post_go() {
        let gate = Gate::default();
        assert!((0..100).all(|_| gate.may_try_at(at(5))));
    }

    #[test]
    fn a_shut_gate_lets_one_probe_go_per_window_and_the_window_doubles() {
        let gate = Gate::default();
        gate.failed_at(at(1_000), None);
        // Within the first window nothing goes.
        assert!(!gate.may_try_at(at(1_500)));
        // At its end one probe goes; the others in that window do not.
        assert!(gate.may_try_at(at(2_000)));
        assert!(!gate.may_try_at(at(2_000)));
        assert!(!gate.may_try_at(at(2_900)));
        // The probe failed too: two seconds now.
        gate.failed_at(at(2_100), None);
        assert!(!gate.may_try_at(at(3_500)));
        assert!(gate.may_try_at(at(4_100)));
        // A hundred failures in a row still wait one minute at most.
        for _ in 0..100 {
            gate.failed_at(at(10_000), None);
        }
        assert!(gate.may_try_at(at(10_000 + ms(MAX_WINDOW))));
        // An answer opens it.
        let opened = gate.opened.notified();
        tokio::pin!(opened);
        assert!(opened.as_mut().now_or_never().is_none(), "a shut gate has not opened yet");
        gate.answered();
        assert!(!gate.shut());
        assert!(opened.now_or_never().is_some(), "opening it wakes the waits armed before");
        assert!((0..10).all(|_| gate.may_try_at(at(10_001))));
    }

    #[test]
    fn the_hubs_retry_after_is_kept_up_to_the_cap() {
        let gate = Gate::default();
        gate.failed_at(at(0), Some(Duration::from_secs(10)));
        assert!(!gate.may_try_at(at(9_999)));
        assert!(gate.may_try_at(at(10_000)));
        let gate = Gate::default();
        gate.failed_at(at(0), Some(Duration::from_secs(3_600)));
        assert!(gate.may_try_at(at(ms(MAX_WINDOW))));
    }
}
