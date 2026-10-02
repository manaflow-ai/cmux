//! When the driver runs boringtun's timers.
//!
//! boringtun has no deadline API: its `update_timers` must be called often,
//! and it compares the time since the last handshake, packet sent and packet
//! received against the protocol constants. Calling it every 250 ms forever
//! costs four wakeups a second on an idle device. Every timer it evaluates
//! is anchored on a recent event, so the driver only needs to tick while one
//! of them can still fire:
//!
//! - For [`ACTIVE_WINDOW`] after the last activity (any authenticated datagram
//!   received, any data or handshake datagram sent). That covers the passive
//!   keepalive (10 s after receiving), the dead-peer handshake (15 s after a
//!   send with no answer), the rekey checks while traffic flows, and every
//!   handshake retry, because each retry is itself a send that extends the
//!   window until boringtun gives up after 90 s.
//! - Once at [`EXPIRY_SWEEP`] after the last activity, which is past the
//!   540 s after which boringtun zeroes every session key. The tunnel then
//!   holds no key material and needs a fresh handshake, as it would have
//!   with the fixed tick.
//! - Every [`KEEPALIVE_TICK`] while a persistent keepalive is configured,
//!   because the configuration asks for traffic on an idle link.
//!
//! Outside those, the driver waits only for a datagram, a command, a stream
//! write or a TCP deadline: zero wakeups when idle.

use std::time::Duration;

use tokio::time::Instant;

/// Tick resolution while active; boringtun's own device uses the same.
pub(crate) const TIMER_TICK: Duration = Duration::from_millis(250);
/// How long after the last activity boringtun's timers can still fire:
/// KEEPALIVE_TIMEOUT + REKEY_TIMEOUT (15 s) plus margin.
pub(crate) const ACTIVE_WINDOW: Duration = Duration::from_secs(20);
/// REJECT_AFTER_TIME * 3 (540 s) plus margin: one tick after this zeroes
/// the session keys.
pub(crate) const EXPIRY_SWEEP: Duration = Duration::from_secs(541);
/// Resolution of a persistent keepalive on an otherwise idle tunnel.
pub(crate) const KEEPALIVE_TICK: Duration = Duration::from_secs(1);

#[derive(Debug)]
pub(crate) struct TimerSchedule {
    last_activity: Instant,
    last_tick: Instant,
    swept: bool,
    persistent_keepalive: bool,
}

impl TimerSchedule {
    pub(crate) fn new(now: Instant, persistent_keepalive: bool) -> Self {
        Self { last_activity: now, last_tick: now, swept: false, persistent_keepalive }
    }

    /// A datagram was authenticated, or a data or handshake datagram left.
    pub(crate) fn on_activity(&mut self, now: Instant) {
        if now > self.last_activity {
            self.last_activity = now;
        }
        self.swept = false;
    }

    /// `update_timers` ran at `now`.
    pub(crate) fn on_tick(&mut self, now: Instant) {
        self.last_tick = now;
        if now >= self.last_activity + EXPIRY_SWEEP {
            self.swept = true;
        }
    }

    /// When `update_timers` must run next, or `None` to wait for an event.
    pub(crate) fn next_tick(&self) -> Option<Instant> {
        let regular = self.last_tick + TIMER_TICK;
        if regular <= self.last_activity + ACTIVE_WINDOW {
            return Some(regular);
        }
        let keepalive = self.persistent_keepalive.then(|| self.last_tick + KEEPALIVE_TICK);
        let sweep = (!self.swept).then(|| self.last_activity + EXPIRY_SWEEP);
        match (keepalive, sweep) {
            (Some(keepalive), Some(sweep)) => Some(keepalive.min(sweep)),
            (one, other) => one.or(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticks_until(schedule: &mut TimerSchedule, end: Instant) -> Vec<Duration> {
        let start = schedule.last_activity;
        let mut ticks = Vec::new();
        while let Some(next) = schedule.next_tick() {
            if next > end {
                break;
            }
            schedule.on_tick(next);
            ticks.push(next - start);
        }
        ticks
    }

    #[test]
    fn ticks_while_active_then_once_for_key_expiry_then_never() {
        let start = Instant::now();
        let mut schedule = TimerSchedule::new(start, false);
        let ticks = ticks_until(&mut schedule, start + Duration::from_secs(3600));
        let active = ticks.iter().filter(|tick| **tick <= ACTIVE_WINDOW).count();
        assert_eq!(active, 80, "four ticks a second for the active window");
        assert_eq!(ticks.last(), Some(&EXPIRY_SWEEP), "one sweep zeroes the keys");
        assert_eq!(ticks.len(), 81);
        assert_eq!(schedule.next_tick(), None, "idle after the sweep");
    }

    #[test]
    fn activity_restarts_ticking_at_once() {
        let start = Instant::now();
        let mut schedule = TimerSchedule::new(start, false);
        ticks_until(&mut schedule, start + Duration::from_secs(3600));
        let later = start + Duration::from_secs(4000);
        schedule.on_activity(later);
        let next = schedule.next_tick().expect("active again");
        assert!(next <= later, "the first tick after an idle period is due now");
        schedule.on_tick(later);
        assert_eq!(schedule.next_tick(), Some(later + TIMER_TICK));
    }

    #[test]
    fn a_persistent_keepalive_keeps_a_slow_tick() {
        let start = Instant::now();
        let mut schedule = TimerSchedule::new(start, true);
        let ticks = ticks_until(&mut schedule, start + Duration::from_secs(120));
        let idle: Vec<_> = ticks.iter().filter(|tick| **tick > ACTIVE_WINDOW).collect();
        assert_eq!(idle.len(), 100, "one tick a second after the active window");
    }

    #[test]
    fn retries_inside_the_window_keep_it_open() {
        // A handshake retry every 5 s is a send, so the window never closes
        // while boringtun is still retrying.
        let start = Instant::now();
        let mut schedule = TimerSchedule::new(start, false);
        for retry in 1..=18 {
            let at = start + Duration::from_secs(5 * retry);
            ticks_until(&mut schedule, at);
            schedule.on_activity(at);
        }
        let last_retry = start + Duration::from_secs(90);
        assert!(schedule.next_tick().unwrap() <= last_retry + TIMER_TICK);
    }
}
