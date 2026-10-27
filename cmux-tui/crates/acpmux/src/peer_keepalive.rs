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
            timer: Box::pin(tokio::time::sleep_until(armed)),
        }
    }

    /// A frame came from the far side.
    pub fn heard(&mut self) {
        let now = Instant::now();
        self.heard = now;
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
}
