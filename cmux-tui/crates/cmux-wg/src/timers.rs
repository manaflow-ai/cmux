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
pub const TIMER_TICK: Duration = Duration::from_millis(250);
/// How long after the last activity boringtun's timers can still fire:
/// KEEPALIVE_TIMEOUT + REKEY_TIMEOUT (15 s) plus margin.
pub const ACTIVE_WINDOW: Duration = Duration::from_secs(20);
/// REJECT_AFTER_TIME * 3 (540 s) plus margin: one tick after this zeroes
/// the session keys.
pub const EXPIRY_SWEEP: Duration = Duration::from_secs(541);
/// A session younger than REKEY_AFTER_TIME (120 s) is used as it is after a
/// network change; an older one is replaced by a handshake at once.
pub const SESSION_FRESH: Duration = Duration::from_secs(120);
/// Resolution of a persistent keepalive on an otherwise idle tunnel.
pub const KEEPALIVE_TICK: Duration = Duration::from_secs(1);

#[derive(Debug)]
pub struct TimerSchedule {
    last_activity: Instant,
    last_tick: Instant,
    swept: bool,
    persistent_keepalive: bool,
}

impl TimerSchedule {
    pub fn new(now: Instant, persistent_keepalive: bool) -> Self {
        Self { last_activity: now, last_tick: now, swept: false, persistent_keepalive }
    }

    /// Tick for the persistent keepalive or not (off while the tunnel is
    /// held: `WgNet::hold`).
    pub fn set_persistent_keepalive(&mut self, on: bool) {
        self.persistent_keepalive = on;
    }

    /// A datagram was authenticated, or a data or handshake datagram left.
    pub fn on_activity(&mut self, now: Instant) {
        if now > self.last_activity {
            self.last_activity = now;
        }
        self.swept = false;
    }

    /// Whether boringtun's timers can still fire: the session carried
    /// traffic within the active window.
    pub fn is_active(&self, now: Instant) -> bool {
        now < self.last_activity + ACTIVE_WINDOW
    }

    /// Whether `update_timers` must run at `now`: a tick or more has passed
    /// since it last ran, or the scheduled tick (a sweep or a keepalive that
    /// can fall less than a tick after an event-driven run) has come. The
    /// second condition matters: without it a scheduled tick that is not
    /// overdue never runs, `next_tick` stays in the past, and the driver
    /// wakes for it without pause.
    pub fn due(&self, now: Instant) -> bool {
        now >= self.last_tick + TIMER_TICK || self.next_tick().is_some_and(|tick| tick <= now)
    }

    /// `update_timers` ran at `now`.
    pub fn on_tick(&mut self, now: Instant) {
        self.last_tick = now;
        if now >= self.last_activity + EXPIRY_SWEEP {
            self.swept = true;
        }
    }

    /// When `update_timers` must run next, or `None` to wait for an event.
    pub fn next_tick(&self) -> Option<Instant> {
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

/// When the driver's persistent keepalive is due: an interval after the
/// last datagram the session sent. The driver sees sends as boringtun's
/// byte counter (which leaves keepalives out) moving between two timer
/// runs, and dates such a send at the earlier run, so the gap it allows is
/// never longer than the interval.
#[derive(Debug)]
pub struct QuietKeepalive {
    every: Duration,
    tx_bytes: usize,
    last_sent: Instant,
    last_check: Instant,
}

impl QuietKeepalive {
    pub fn new(every: Duration, now: Instant) -> Self {
        Self { every, tx_bytes: 0, last_sent: now, last_check: now }
    }

    /// A timer run at `now` with the session's sent byte count: whether a
    /// keepalive is due.
    pub fn due(&mut self, tx_bytes: usize, now: Instant) -> bool {
        if tx_bytes != self.tx_bytes {
            self.tx_bytes = tx_bytes;
            self.last_sent = self.last_sent.max(self.last_check);
        }
        self.last_check = now;
        now >= self.last_sent + self.every
    }

    /// A keepalive or handshake datagram left at `now`.
    pub fn sent(&mut self, now: Instant) {
        self.last_sent = self.last_sent.max(now);
    }

    /// The longest gap it allows from now on (`WgNet::set_air_floor`).
    pub fn set_every(&mut self, every: Duration) {
        self.every = every;
    }
}

/// The link's idle air gap (`WgNet::set_idle_air_gap`): the shortest gap
/// between two of the tunnel's own unsolicited sends (routine path probes
/// and their off-path notes) while no data flows, so a radio that went back
/// to sleep is woken once a gap, not once a probe. When the session sent
/// anything else in a pass (data, an answer), the radio is awake: a probe
/// due then rides along at once.
#[derive(Debug, Default)]
pub struct AirGap {
    gap: Option<Duration>,
    last_own: Option<Instant>,
    tx_bytes: usize,
}

impl AirGap {
    pub fn set(&mut self, gap: Option<Duration>) {
        self.gap = gap;
    }

    /// Until when routine probes wait, at a pass that starts with the
    /// session's sent byte count at `tx_bytes`. `None`: they go when due.
    pub fn floor(&self, tx_bytes: usize) -> Option<Instant> {
        let gap = self.gap?;
        if tx_bytes != self.tx_bytes {
            return None;
        }
        Some(self.last_own? + gap)
    }

    /// The probes of a pass are out: `before` and `after` are the sent
    /// byte counts around them.
    pub fn probed(&mut self, (before, after): (usize, usize), now: Instant) {
        if after != before {
            self.last_own = Some(now);
        }
        self.tx_bytes = after;
    }
}

#[cfg(test)]
mod air_gap_tests {
    use super::*;

    const GAP: Duration = Duration::from_secs(20);

    #[test]
    fn no_gap_holds_nothing() {
        let mut gap = AirGap::default();
        gap.probed((0, 100), Instant::now());
        assert_eq!(gap.floor(100), None);
    }

    #[test]
    fn own_sends_hold_the_next_until_the_gap_passed() {
        let now = Instant::now();
        let mut gap = AirGap::default();
        gap.set(Some(GAP));
        assert_eq!(gap.floor(0), None, "nothing sent yet");
        gap.probed((0, 100), now);
        assert_eq!(gap.floor(100), Some(now + GAP));
        // A pass that sent nothing of its own keeps the floor.
        gap.probed((100, 100), now + Duration::from_secs(5));
        assert_eq!(gap.floor(100), Some(now + GAP));
    }

    #[test]
    fn data_since_the_last_pass_lifts_it() {
        let now = Instant::now();
        let mut gap = AirGap::default();
        gap.set(Some(GAP));
        gap.probed((0, 100), now);
        assert_eq!(gap.floor(180), None, "data left: probes ride along");
        gap.set(None);
        assert_eq!(gap.floor(100), None);
    }
}

#[cfg(test)]
mod quiet_keepalive_tests {
    use super::*;

    const EVERY: Duration = Duration::from_secs(10);
    const TICK: Duration = Duration::from_secs(1);

    #[test]
    fn an_idle_session_keeps_the_interval() {
        let start = Instant::now();
        let mut keepalive = QuietKeepalive::new(EVERY, start);
        assert!(!keepalive.due(0, start + EVERY - TICK));
        assert!(keepalive.due(0, start + EVERY));
        keepalive.sent(start + EVERY);
        assert!(!keepalive.due(0, start + EVERY * 2 - TICK));
        assert!(keepalive.due(0, start + EVERY * 2));
    }

    #[test]
    fn other_traffic_holds_it_and_the_gap_never_passes_the_interval() {
        let start = Instant::now();
        let mut keepalive = QuietKeepalive::new(EVERY, start);
        // Something leaves every 5 s: no keepalive ever.
        let mut tx = 0;
        for second in 1..=60 {
            if second % 5 == 0 {
                tx += 100;
            }
            assert!(!keepalive.due(tx, start + TICK * second), "second {second}");
        }
        // Then silence: the send seen at 60 s may have left just after the
        // 59 s run, so the keepalive is due by 69 s.
        assert!(!keepalive.due(tx, start + TICK * 68));
        assert!(keepalive.due(tx, start + TICK * 69));
    }

    #[test]
    fn an_air_floor_shortens_the_gap_from_the_last_send() {
        const FLOOR: Duration = Duration::from_secs(4);
        let start = Instant::now();
        let mut keepalive = QuietKeepalive::new(EVERY, start);
        assert!(!keepalive.due(0, start + TICK * 3));
        keepalive.set_every(FLOOR);
        assert!(!keepalive.due(0, start + FLOOR - TICK));
        assert!(keepalive.due(0, start + FLOOR));
        keepalive.sent(start + FLOOR);
        assert!(!keepalive.due(0, start + FLOOR * 2 - TICK));
        assert!(keepalive.due(0, start + FLOOR * 2));
        // Back to the persistent interval.
        keepalive.sent(start + FLOOR * 2);
        keepalive.set_every(EVERY);
        assert!(!keepalive.due(0, start + FLOOR * 2 + EVERY - TICK));
        assert!(keepalive.due(0, start + FLOOR * 2 + EVERY));
    }
}
