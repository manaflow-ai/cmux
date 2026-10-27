//! Part of `peer.rs`, also used by the hand link (`hand/link.rs`). The
//! keepalive deadline of a socket: a ping is due only after `every` without
//! a frame from the far side, so a busy link sends none and its task does not
//! wake for them. This is QUIC's ping alarm in Chromium
//! (`net/third_party/quiche/src/quiche/quic/core/quic_connection.cc`,
//! `SetPingAlarm`, re-armed on each packet through `QuicAlarm::Update` with a
//! granularity): every frame moves the deadline, but the timer is re-armed
//! only when the deadline moved by more than the slack (10% of `every`), so a
//! stream of frames re-arms it at most once per slack.
//!
//! Only frames from the far side move it. A frame this end sends proves
//! nothing about the path, and the dead-path checks run on the keepalive's
//! own deadline, so they stay as they were.
//!
//! A ping is due after silence, so the silence alone does not say the far
//! side is late: an idle healthy peer is silent for a whole interval before
//! each ping. Late means a ping went out and no frame came since
//! (`unanswered`), as QUIC counts a probe without an ack, not idle time.

use std::pin::Pin;
use std::time::Duration;
use tokio::time::{Instant, Sleep};

pub struct SilenceDeadline {
    every: Duration,
    slack: Duration,
    /// When the far side was last heard from.
    heard: Instant,
    /// The deadline `timer` is armed at.
    armed: Instant,
    /// A ping went out after the last frame from the far side.
    unanswered: bool,
    timer: Pin<Box<Sleep>>,
}

impl SilenceDeadline {
    /// Armed `every` from now, as if a frame was just heard.
    pub fn new(every: Duration) -> Self {
        let now = Instant::now();
        let armed = now + every;
        Self {
            every,
            slack: every / 10,
            heard: now,
            armed,
            unanswered: false,
            timer: Box::pin(tokio::time::sleep_until(armed)),
        }
    }

    /// A frame came from the far side.
    pub fn heard(&mut self) {
        let now = Instant::now();
        self.heard = now;
        self.unanswered = false;
        let due = now + self.every;
        if due >= self.armed + self.slack {
            self.arm(due);
        }
    }

    /// A ping went out: the next one is due at the next whole `every` of
    /// silence unless a frame comes first, so the silence the dead-path
    /// checks read is a whole number of intervals, as it was with the
    /// fixed interval.
    pub fn pinged(&mut self) {
        let every = self.every.as_nanos().max(1);
        let intervals = (self.silence() + self.slack).as_nanos() / every + 1;
        let next = Duration::from_nanos(u64::try_from(intervals * every).unwrap_or(u64::MAX));
        self.arm(self.heard + next);
        self.unanswered = true;
    }

    /// A ping went out and no frame came since: the far side is late.
    pub fn unanswered(&self) -> bool {
        self.unanswered
    }

    /// How long the far side has been silent.
    pub fn silence(&self) -> Duration {
        self.heard.elapsed()
    }

    /// Resolves once a ping is due: at least `every` less the slack of
    /// silence (or `every` after the last ping). Returns the silence.
    /// Cancel-safe: dropping it in a `select!` loses nothing.
    pub async fn due(&mut self) -> Duration {
        loop {
            self.timer.as_mut().await;
            let silent = self.silence();
            if silent + self.slack >= self.every {
                return silent;
            }
            // A frame came since it was armed: wait out the rest.
            self.arm(self.heard + self.every);
        }
    }

    fn arm(&mut self, at: Instant) {
        self.armed = at;
        self.timer.as_mut().reset(at);
    }
}

#[cfg(test)]
mod tests {
    use super::SilenceDeadline;
    use std::time::Duration;

    const EVERY: Duration = Duration::from_secs(15);

    /// Drives a link for `total`: a frame every `frame_every` (none when
    /// `None`), and counts the pings that went out.
    async fn pings_over(total: Duration, frame_every: Option<Duration>) -> u32 {
        let mut keepalive = SilenceDeadline::new(EVERY);
        let end = tokio::time::Instant::now() + total;
        let mut next_frame = frame_every.map(|every| tokio::time::Instant::now() + every);
        let mut pings = 0;
        loop {
            tokio::select! {
                biased;
                _ = tokio::time::sleep_until(end) => return pings,
                _ = tokio::time::sleep_until(next_frame.unwrap_or(end)), if next_frame.is_some() => {
                    keepalive.heard();
                    next_frame = frame_every.map(|every| tokio::time::Instant::now() + every);
                }
                _ = keepalive.due() => {
                    pings += 1;
                    keepalive.pinged();
                }
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_a_frame_every_5s_sends_no_ping() {
        assert_eq!(pings_over(Duration::from_secs(600), Some(Duration::from_secs(5))).await, 0);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_16s_of_silence_sends_one_ping() {
        assert_eq!(pings_over(Duration::from_secs(16), None).await, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_a_silent_link_pings_once_per_interval() {
        // 61 s: pings at 15, 30, 45 and 60 s, as the old interval did.
        assert_eq!(pings_over(Duration::from_secs(61), None).await, 4);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_a_frame_rearms_the_whole_interval() {
        let mut keepalive = SilenceDeadline::new(EVERY);
        tokio::time::advance(Duration::from_secs(10)).await;
        keepalive.heard();
        let start = tokio::time::Instant::now();
        let silent = keepalive.due().await;
        assert_eq!(start.elapsed(), EVERY);
        assert_eq!(silent, EVERY);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_a_frame_within_the_slack_does_not_rearm() {
        // A frame 1 s after arming moves the deadline by 1 s, less than the
        // 1.5 s slack: the timer stays and the ping goes out 1 s early.
        let mut keepalive = SilenceDeadline::new(EVERY);
        tokio::time::advance(Duration::from_secs(1)).await;
        keepalive.heard();
        let start = tokio::time::Instant::now();
        let silent = keepalive.due().await;
        assert_eq!(start.elapsed(), Duration::from_secs(14));
        assert_eq!(silent, Duration::from_secs(14));
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_an_early_ping_keeps_later_ones_on_whole_intervals() {
        // The first ping comes 1 s early (a frame within the slack); the next
        // ones still come at 30 s and 45 s of silence, so a dead-path check at
        // a whole number of intervals runs when it did before.
        let mut keepalive = SilenceDeadline::new(EVERY);
        tokio::time::advance(Duration::from_secs(1)).await;
        keepalive.heard();
        assert_eq!(keepalive.due().await, Duration::from_secs(14));
        keepalive.pinged();
        assert_eq!(keepalive.due().await, EVERY * 2);
        keepalive.pinged();
        assert_eq!(keepalive.due().await, EVERY * 3);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_silence_counts_from_the_last_frame_across_pings() {
        let mut keepalive = SilenceDeadline::new(EVERY);
        assert_eq!(keepalive.due().await, EVERY);
        keepalive.pinged();
        assert_eq!(keepalive.due().await, EVERY * 2);
        keepalive.pinged();
        assert_eq!(keepalive.due().await, EVERY * 3);
    }

    /// What the peer link loop (`peer.rs`) saw: when the link was marked
    /// overdue, as silence, and the silence it dropped at.
    #[derive(Debug, Default)]
    struct PeerRun {
        overdue_at: Vec<Duration>,
        dropped_at: Option<Duration>,
    }

    /// Runs the peer arm's keepalive rules on a real `Link` for `total`. The
    /// far side sends a frame every second for `burst`, then answers each
    /// ping after `rtt` (never when `None`).
    async fn peer_link_over(total: Duration, burst: Duration, rtt: Option<Duration>) -> PeerRun {
        use crate::peer_link::{Link, PeerState};
        let budget = EVERY * 4;
        let mut link = Link::default();
        link.opened(0);
        link.ready(0);
        let mut keepalive = SilenceDeadline::new(EVERY);
        let start = tokio::time::Instant::now();
        let end = start + total;
        let burst_end = start + burst;
        let mut next_frame = Some(start + Duration::from_secs(1)).filter(|at| *at < burst_end);
        let mut pong_at: Option<tokio::time::Instant> = None;
        let mut run = PeerRun::default();
        loop {
            let frame_at = match (next_frame, pong_at) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
            tokio::select! {
                biased;
                _ = tokio::time::sleep_until(end) => return run,
                _ = tokio::time::sleep_until(frame_at.unwrap_or(end)), if frame_at.is_some() => {
                    let now = tokio::time::Instant::now();
                    if pong_at.is_some_and(|at| at <= now) {
                        pong_at = None;
                    }
                    if next_frame.is_some_and(|at| at <= now) {
                        next_frame = Some(now + Duration::from_secs(1)).filter(|at| *at < burst_end);
                    }
                    keepalive.heard();
                    link.heard(0);
                }
                silent = keepalive.due() => {
                    if silent >= budget {
                        run.dropped_at = Some(silent);
                        return run;
                    }
                    if keepalive.unanswered() {
                        link.overdue();
                    }
                    if link.state() == PeerState::Degraded {
                        run.overdue_at.push(silent);
                    }
                    keepalive.pinged();
                    pong_at = rtt.map(|rtt| tokio::time::Instant::now() + rtt);
                }
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_an_idle_answering_peer_is_never_overdue() {
        for rtt in [Duration::from_millis(1), Duration::from_millis(50), Duration::from_secs(1)] {
            let run = peer_link_over(Duration::from_secs(600), Duration::ZERO, Some(rtt)).await;
            assert!(run.overdue_at.is_empty(), "rtt {rtt:?}: {run:?}");
            assert_eq!(run.dropped_at, None, "rtt {rtt:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_a_burst_then_silence_is_never_overdue() {
        // Frames each second for a while, then the peer only answers pings:
        // the first ping comes a whole interval after the last frame.
        for burst in [Duration::from_secs(37), Duration::from_millis(37_500)] {
            let run =
                peer_link_over(Duration::from_secs(600), burst, Some(Duration::from_millis(50)))
                    .await;
            assert!(run.overdue_at.is_empty(), "burst {burst:?}: {run:?}");
            assert_eq!(run.dropped_at, None, "burst {burst:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_an_unanswered_ping_marks_overdue_then_drops() {
        // Ping at 15 s, unanswered: overdue at the next due (30 s), and the
        // link drops at the silence budget (60 s).
        let run = peer_link_over(Duration::from_secs(600), Duration::ZERO, None).await;
        assert_eq!(run.overdue_at, [EVERY * 2, EVERY * 3]);
        assert_eq!(run.dropped_at, Some(EVERY * 4));
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_unanswered_until_a_frame() {
        let mut keepalive = SilenceDeadline::new(EVERY);
        assert!(!keepalive.unanswered());
        keepalive.due().await;
        assert!(!keepalive.unanswered());
        keepalive.pinged();
        assert!(keepalive.unanswered());
        tokio::time::advance(Duration::from_millis(50)).await;
        keepalive.heard();
        assert!(!keepalive.unanswered());
    }
}
