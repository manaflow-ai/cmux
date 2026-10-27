//! The client heartbeat's schedule: a probe only after `interval` with no
//! inbound frame. Inbound traffic already proves the carrier alive, so a
//! busy connection sends no probe and an idle one sends one per interval.
//! Chromium's HTTP/2 session pings the same way: only when no frame arrived
//! for the ping interval (net/spdy/spdy_session.cc, `MaybeSendPrefacePing`
//! and `CheckPingStatus` against `last_read_time_`).

use std::time::Duration;

use tokio::time::Instant;

#[derive(Debug)]
pub(super) struct SilenceKeepalive {
    interval: Duration,
    /// The silence window runs from here: the last inbound frame seen at a
    /// deadline, or the end of the last probe.
    armed_from: Instant,
}

impl SilenceKeepalive {
    pub(super) fn new(interval: Duration, now: Instant) -> Self {
        Self { interval, armed_from: now }
    }

    /// When the window ends with no inbound frame.
    pub(super) fn due_at(&self) -> Instant {
        self.armed_from + self.interval
    }

    /// At the deadline: probe when nothing arrived in the window; otherwise
    /// the window starts again from the last inbound frame.
    pub(super) fn should_probe(&mut self, last_inbound: Instant) -> bool {
        if last_inbound > self.armed_from {
            self.armed_from = last_inbound;
            return false;
        }
        true
    }

    /// A probe ended at `now` (its answer, if any, is inbound traffic at or
    /// before `now`): the next window starts here.
    pub(super) fn probed(&mut self, now: Instant) {
        self.armed_from = self.armed_from.max(now);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::time::Instant;

    use super::SilenceKeepalive;

    const INTERVAL: Duration = Duration::from_secs(5);

    /// Drives the schedule over `span` with inbound frames at `frames`
    /// (offsets from the start) and counts deadlines and probes. A probe is
    /// answered at once.
    fn run(frames: &[Duration], span: Duration) -> (u32, u32) {
        let start = Instant::now();
        let mut keepalive = SilenceKeepalive::new(INTERVAL, start);
        let mut last_inbound = start;
        let (mut wakes, mut probes) = (0, 0);
        loop {
            let due = keepalive.due_at();
            if due > start + span {
                return (wakes, probes);
            }
            wakes += 1;
            if let Some(latest) =
                frames.iter().map(|offset| start + *offset).filter(|at| *at <= due).max()
            {
                last_inbound = last_inbound.max(latest);
            }
            if keepalive.should_probe(last_inbound) {
                probes += 1;
                last_inbound = due;
                keepalive.probed(due);
            }
        }
    }

    #[test]
    fn steady_inbound_traffic_sends_no_probe() {
        let frames: Vec<_> = (1..=12).map(|n| Duration::from_secs(n * 4)).collect();
        let (_, probes) = run(&frames, Duration::from_secs(48));
        assert_eq!(probes, 0);
    }

    #[test]
    fn silence_sends_one_probe_per_interval_and_one_wake_each() {
        let (wakes, probes) = run(&[], Duration::from_secs(60));
        assert_eq!(probes, 12);
        assert_eq!(wakes, 12, "the probe's own answer must not add a wake");
    }

    #[test]
    fn a_frame_moves_the_deadline_to_one_interval_after_it() {
        let start = Instant::now();
        let mut keepalive = SilenceKeepalive::new(INTERVAL, start);
        let frame = start + Duration::from_secs(3);
        assert!(!keepalive.should_probe(frame));
        assert_eq!(keepalive.due_at(), frame + INTERVAL);
        assert!(keepalive.should_probe(frame), "no frame since: probe at the new deadline");
    }
}
