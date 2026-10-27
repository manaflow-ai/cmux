//! The relay socket's timed work as one deadline: the heartbeat the server
//! set in hello_accepted, the read-liveness deadline (no inbound traffic for
//! 3 heartbeats + 10 s) and the suspend check. An idle socket wakes once per
//! heartbeat, not on a sampling period.
//!
//! The suspend check samples the wall and monotonic clocks on every wake of
//! the socket loop. The monotonic clock stops while the host sleeps, so the
//! first wake after a resume (traffic or this deadline, at most one
//! heartbeat later) sees the wall clock ahead and redials. Chromium re-reads
//! wall time on resume the same way (base/timer/wall_clock_timer.h).

use std::time::Duration;

use tokio::time::Instant;

/// Wall clock moving more than this relative to the monotonic clock between
/// two samples means the host slept under us (or the guest clock was
/// stepped); either way the peer likely closed the socket while this process
/// was not running, and no FIN/RST will ever arrive.
const SUSPEND_CLOCK_JUMP: Duration = Duration::from_secs(30);
/// The server answers every heartbeat with `heartbeat_ack` and marks a relay
/// stale after 3 heartbeat intervals + 10s (the Relay DO `presence()` rule).
/// Use the same budget here: a socket with no inbound traffic for that long
/// is dead, whatever the OS says about the TCP connection.
const READ_LIVENESS_HEARTBEATS: u32 = 3;
const READ_LIVENESS_GRACE: Duration = Duration::from_secs(10);
/// Before hello_accepted names the negotiated cadence, budget for the
/// server-default 20s heartbeat interval.
const PRE_HELLO_READ_DEADLINE: Duration = Duration::from_secs(70);

/// Why the socket is presumed dead.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Dead {
    /// The wall clock moved `wall_delta_ms` across `monotonic` of run time.
    ClockJumped { wall_delta_ms: i64, monotonic: Duration },
    /// No inbound traffic for `idle`, past `deadline`.
    Silent { idle: Duration, deadline: Duration },
}

/// What the deadline asks for when it fires.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Due {
    Heartbeat,
    Nothing,
}

pub(super) struct SocketLiveness {
    heartbeat: Option<Duration>,
    last_heartbeat: Instant,
    last_inbound: Instant,
    last_wall_ms: i64,
    last_monotonic: Instant,
}

impl SocketLiveness {
    pub(super) fn new(now: Instant, wall_ms: i64) -> Self {
        Self {
            heartbeat: None,
            last_heartbeat: now,
            last_inbound: now,
            last_wall_ms: wall_ms,
            last_monotonic: now,
        }
    }

    /// hello_accepted named the cadence: the first heartbeat is due one
    /// cadence from `now`.
    pub(super) fn heartbeat_negotiated(&mut self, cadence: Duration, now: Instant) {
        self.heartbeat = Some(cadence);
        self.last_heartbeat = now;
    }

    pub(super) fn heartbeat_sent(&mut self, now: Instant) {
        self.last_heartbeat = now;
    }

    /// Any inbound frame (heartbeat_ack included) proves the socket alive.
    pub(super) fn inbound(&mut self, now: Instant) {
        self.last_inbound = now;
    }

    fn read_deadline(&self) -> Duration {
        match self.heartbeat {
            Some(cadence) => {
                cadence.saturating_mul(READ_LIVENESS_HEARTBEATS).saturating_add(READ_LIVENESS_GRACE)
            }
            None => PRE_HELLO_READ_DEADLINE,
        }
    }

    /// The one instant the socket has timed work: the next heartbeat or the
    /// read-liveness deadline, whichever is first.
    pub(super) fn next_deadline(&self) -> Instant {
        let silent = self.last_inbound + self.read_deadline();
        match self.heartbeat {
            Some(cadence) => silent.min(self.last_heartbeat + cadence),
            None => silent,
        }
    }

    /// Samples both clocks. A wall clock that is wrong but ticking advances
    /// in step with the monotonic clock and never trips this; a host suspend
    /// advances the wall clock while the monotonic clock stands still, and a
    /// clock step moves it without any monotonic time passing.
    pub(super) fn sample_clocks(&mut self, now: Instant, wall_ms: i64) -> Result<(), Dead> {
        let wall_delta_ms = wall_ms.saturating_sub(self.last_wall_ms);
        let monotonic = now.saturating_duration_since(self.last_monotonic);
        self.last_wall_ms = wall_ms;
        self.last_monotonic = now;
        let monotonic_ms = i64::try_from(monotonic.as_millis()).unwrap_or(i64::MAX);
        let threshold_ms = i64::try_from(SUSPEND_CLOCK_JUMP.as_millis()).unwrap_or(i64::MAX);
        if wall_delta_ms.saturating_sub(monotonic_ms).saturating_abs() > threshold_ms {
            return Err(Dead::ClockJumped { wall_delta_ms, monotonic });
        }
        Ok(())
    }

    /// What is due at `now`: a dead socket first, then the heartbeat.
    pub(super) fn due(&self, now: Instant) -> Result<Due, Dead> {
        let idle = now.saturating_duration_since(self.last_inbound);
        let deadline = self.read_deadline();
        if idle >= deadline {
            return Err(Dead::Silent { idle, deadline });
        }
        match self.heartbeat {
            Some(cadence) if now >= self.last_heartbeat + cadence => Ok(Due::Heartbeat),
            _ => Ok(Due::Nothing),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CADENCE: Duration = Duration::from_secs(20);

    fn negotiated(start: Instant) -> SocketLiveness {
        let mut liveness = SocketLiveness::new(start, 1_000_000);
        liveness.heartbeat_negotiated(CADENCE, start);
        liveness
    }

    #[test]
    fn an_idle_socket_wakes_once_per_heartbeat_and_never_in_between() {
        let start = Instant::now();
        let mut liveness = negotiated(start);
        let mut now = start;
        for _ in 0..10 {
            let next = liveness.next_deadline();
            assert_eq!(next, now + CADENCE, "the only timed work is the next heartbeat");
            now = next;
            assert_eq!(liveness.due(now), Ok(Due::Heartbeat));
            liveness.heartbeat_sent(now);
            // The server acknowledges the heartbeat.
            liveness.inbound(now + Duration::from_millis(30));
        }
    }

    #[test]
    fn before_hello_the_only_deadline_is_the_read_deadline() {
        let start = Instant::now();
        let liveness = SocketLiveness::new(start, 0);
        assert_eq!(liveness.next_deadline(), start + PRE_HELLO_READ_DEADLINE);
        assert_eq!(liveness.due(start + Duration::from_secs(69)), Ok(Due::Nothing));
        assert_eq!(
            liveness.due(start + PRE_HELLO_READ_DEADLINE),
            Err(Dead::Silent { idle: PRE_HELLO_READ_DEADLINE, deadline: PRE_HELLO_READ_DEADLINE })
        );
    }

    #[test]
    fn a_socket_with_no_inbound_traffic_dies_at_three_heartbeats_and_grace() {
        let start = Instant::now();
        let mut liveness = negotiated(start);
        let deadline = CADENCE * 3 + READ_LIVENESS_GRACE;
        let mut now = start;
        // Heartbeats go out, no ack comes back.
        while now + CADENCE < start + deadline {
            now = liveness.next_deadline();
            assert_eq!(liveness.due(now), Ok(Due::Heartbeat));
            liveness.heartbeat_sent(now);
        }
        assert_eq!(liveness.next_deadline(), start + deadline, "the read deadline comes first");
        assert_eq!(liveness.due(start + deadline), Err(Dead::Silent { idle: deadline, deadline }));
    }

    #[test]
    fn inbound_traffic_moves_the_read_deadline() {
        let start = Instant::now();
        let mut liveness = SocketLiveness::new(start, 0);
        let later = start + Duration::from_secs(60);
        liveness.inbound(later);
        assert_eq!(liveness.next_deadline(), later + PRE_HELLO_READ_DEADLINE);
        assert_eq!(liveness.due(start + PRE_HELLO_READ_DEADLINE), Ok(Due::Nothing));
    }

    #[test]
    fn a_suspend_shows_as_wall_time_without_monotonic_time() {
        let start = Instant::now();
        let mut liveness = negotiated(start);
        // Ticking clocks, including a wrong but steady wall clock.
        assert_eq!(liveness.sample_clocks(start + Duration::from_secs(5), 1_005_000), Ok(()));
        assert_eq!(liveness.sample_clocks(start + Duration::from_secs(25), 1_025_100), Ok(()));
        // The host slept for 10 minutes: the monotonic clock moved 1 s.
        let resumed = start + Duration::from_secs(26);
        assert_eq!(
            liveness.sample_clocks(resumed, 1_626_100),
            Err(Dead::ClockJumped { wall_delta_ms: 601_000, monotonic: Duration::from_secs(1) })
        );
        // A backwards step trips it too.
        assert_eq!(
            liveness.sample_clocks(resumed + Duration::from_secs(1), 1_500_000),
            Err(Dead::ClockJumped { wall_delta_ms: -126_100, monotonic: Duration::from_secs(1) })
        );
    }
}
