//! Pause-on-takeover from an idle clock: the person counts as driving while
//! their last deliberate input (a key, a click, a scroll, a drag) is newer
//! than [`IDLE_AFTER`], unless that input was our own injection. An acting
//! call waits for them to stop, up to the engine's limit
//! ([`crate::engine::TAKEOVER_WAIT`]).
//!
//! Platform-free, so the decision is tested on every host; the macOS worker
//! feeds it the HID system's seconds-since-last-event
//! (`platform/macos/idle.rs`). Linux keeps its own copy of the same rule
//! (`platform/linux/idle.rs`).

use std::time::Duration;

use crate::engine::PersonActivity;

/// The person counts as idle after this long without deliberate input.
pub const IDLE_AFTER: Duration = Duration::from_millis(1500);
/// Input this soon after our own injection is ours.
pub const OWN_INPUT_GRACE: Duration = Duration::from_millis(800);
/// How often a waiting call reads the idle clock again.
pub const POLL: Duration = Duration::from_millis(100);

/// Where the idle time comes from, and the clocks around it.
pub trait IdleClock: Send + Sync {
    /// Milliseconds since the person's last deliberate input; `None` when
    /// nothing can read it (the person then counts as idle, as with no
    /// detector at all).
    fn idle_ms(&self) -> Option<u64>;
    /// Now, in milliseconds on the clock [`IdleClock::last_injection_ms`] uses.
    fn now_ms(&self) -> u64;
    /// When this process last posted input (0: never).
    fn last_injection_ms(&self) -> u64;
    /// Waits before the next reading (a poll interval, not a synchronization).
    fn pause(&self, duration: Duration);
}

/// True when the last input was long enough ago, or was our own.
pub fn person_idle(idle_ms: u64, now: u64, last_injection: u64) -> bool {
    if idle_ms >= IDLE_AFTER.as_millis() as u64 {
        return true;
    }
    let last_input = now.saturating_sub(idle_ms);
    last_injection != 0
        && last_input <= last_injection + OWN_INPUT_GRACE.as_millis() as u64
        && last_input + 50 >= last_injection
}

/// [`PersonActivity`] over an [`IdleClock`].
pub struct IdlePoll<C>(pub C);

impl<C: IdleClock> PersonActivity for IdlePoll<C> {
    fn wait_idle(&self, limit: Duration) -> bool {
        let clock = &self.0;
        let deadline = clock.now_ms().saturating_add(limit.as_millis() as u64);
        loop {
            match clock.idle_ms() {
                None => return true,
                Some(idle) if person_idle(idle, clock.now_ms(), clock.last_injection_ms()) => {
                    return true;
                }
                Some(_) => {}
            }
            if clock.now_ms() >= deadline {
                return false;
            }
            clock.pause(POLL);
        }
    }
}

#[cfg(test)]
#[path = "takeover_tests.rs"]
mod tests;
