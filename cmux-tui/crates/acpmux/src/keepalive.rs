//! A keepalive that pings only after silence, for the peer link (`peer.rs`)
//! and the hand's Cloud socket (`hand/link.rs`).
//!
//! Chromium's HTTP/2 session does the same: `SpdySession::MaybeSendPrefacePing`
//! (net/spdy/spdy_session.cc) sends a PING only when nothing was read for
//! `connection_at_risk_of_loss_time_`, and `CheckPingStatus` drops the session
//! when the answer does not come in time. A link that carries traffic never
//! pings; an idle one pings once per `every`.
//!
//! One timer: a frame only records its time (no re-arm per frame), and when
//! the timer fires it either pings, drops the link, or re-arms at the new
//! deadline. A ping may go up to 10% of `every` early, so a wake that lands
//! just short of the deadline pings at once instead of arming a second wake
//! (`kFlexiblePreferEarly`, base/task/delay_policy.h).

use std::time::Duration;
use tokio::time::Instant;

/// What the link does when the keepalive timer fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fire {
    /// Send a ping. `unanswered` is true when the previous ping got no frame back.
    Ping { unanswered: bool },
    /// Nothing was heard for the whole dead budget: drop the link.
    Dead { silent: Duration },
    /// A frame came since the timer was armed: wait for the new deadline.
    Wait,
}

/// The silence clock of one connection.
#[derive(Debug, Clone)]
pub struct Keepalive {
    every: Duration,
    dead_after: Duration,
    heard_at: Instant,
    pinged_at: Option<Instant>,
}

impl Keepalive {
    /// A connection that opened (or was last heard) at `now`. It pings after
    /// `every` of silence and is dead after `dead_after` of it.
    pub fn new(every: Duration, dead_after: Duration, now: Instant) -> Self {
        Self { every, dead_after, heard_at: now, pinged_at: None }
    }

    /// A frame arrived from the other side.
    pub fn heard(&mut self, now: Instant) {
        self.heard_at = now;
    }

    /// How long the other side has been silent.
    pub fn silent(&self, now: Instant) -> Duration {
        now.saturating_duration_since(self.heard_at)
    }

    /// When the timer should fire next: the ping deadline or the dead
    /// deadline, whichever comes first.
    pub fn deadline(&self) -> Instant {
        self.ping_due().min(self.heard_at + self.dead_after)
    }

    /// The timer fired at `now`. Call `deadline` afterwards to re-arm it.
    pub fn fire(&mut self, now: Instant) -> Fire {
        let silent = self.silent(now);
        if silent >= self.dead_after {
            return Fire::Dead { silent };
        }
        if now + self.slack() < self.ping_due() {
            return Fire::Wait;
        }
        let unanswered = self.pinged_at.is_some_and(|at| at >= self.heard_at);
        self.pinged_at = Some(now);
        Fire::Ping { unanswered }
    }

    /// `every` after the last frame, or after the last ping while silent.
    fn ping_due(&self) -> Instant {
        let since = self.pinged_at.map_or(self.heard_at, |at| at.max(self.heard_at));
        since + self.every
    }

    /// How early a fire may act: 10% of `every`.
    pub fn slack(&self) -> Duration {
        self.every / 10
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    const EVERY: Duration = Duration::from_secs(15);
    const DEAD: Duration = Duration::from_secs(60);

    /// The link loop's shape: one sleep re-armed only when it fires, frames
    /// recorded as they come. Returns the pings sent and how it ended.
    async fn drive(mut frames: mpsc::Receiver<()>, run_for: Duration) -> (u32, Option<Fire>) {
        let start = Instant::now();
        let mut keep = Keepalive::new(EVERY, DEAD, start);
        let timer = tokio::time::sleep_until(keep.deadline());
        tokio::pin!(timer);
        let end = tokio::time::sleep_until(start + run_for);
        tokio::pin!(end);
        let mut pings = 0;
        let mut open = true;
        loop {
            tokio::select! {
                _ = &mut end => return (pings, None),
                _ = &mut timer => {
                    match keep.fire(Instant::now()) {
                        Fire::Ping { .. } => pings += 1,
                        dead @ Fire::Dead { .. } => return (pings, Some(dead)),
                        Fire::Wait => {}
                    }
                    timer.as_mut().reset(keep.deadline());
                }
                frame = frames.recv(), if open => match frame {
                    Some(()) => keep.heard(Instant::now()),
                    None => open = false,
                },
            }
        }
    }

    fn frames_every(gap: Duration, count: u32) -> mpsc::Receiver<()> {
        let (tx, rx) = mpsc::channel(4);
        tokio::spawn(async move {
            for _ in 0..count {
                tokio::time::sleep(gap).await;
                if tx.send(()).await.is_err() {
                    return;
                }
            }
            // Keep the channel open (silence, not a close) until the test ends.
            std::future::pending::<()>().await;
        });
        rx
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_frame_every_5s_sends_no_ping() {
        let frames = frames_every(Duration::from_secs(5), 12);
        // 60 s of frames every 5 s, stopped before the first silent deadline.
        let (pings, ended) = drive(frames, Duration::from_secs(60) + EVERY / 2).await;
        assert_eq!(pings, 0);
        assert_eq!(ended, None);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_16s_silence_sends_one_ping() {
        let frames = frames_every(Duration::from_secs(5), 1);
        // Last frame at 5 s, then 16 s of silence.
        let (pings, ended) = drive(frames, Duration::from_secs(5 + 16)).await;
        assert_eq!(pings, 1);
        assert_eq!(ended, None);
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_silent_link_pings_each_interval_then_dies_at_budget() {
        let frames = frames_every(Duration::from_secs(1), 0);
        let (pings, ended) = drive(frames, Duration::from_secs(120)).await;
        // Pings at 15, 30 and 45 s; at 60 s the dead budget is spent.
        assert_eq!(pings, 3);
        assert_eq!(ended, Some(Fire::Dead { silent: DEAD }));
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_marks_a_ping_unanswered_only_without_a_frame_since() {
        let start = Instant::now();
        let mut keep = Keepalive::new(EVERY, DEAD, start);
        assert_eq!(keep.fire(start + EVERY), Fire::Ping { unanswered: false });
        assert_eq!(keep.deadline(), start + EVERY * 2);
        assert_eq!(keep.fire(start + EVERY * 2), Fire::Ping { unanswered: true });
        keep.heard(start + EVERY * 2 + Duration::from_secs(1));
        assert_eq!(keep.deadline(), start + EVERY * 3 + Duration::from_secs(1));
        assert_eq!(
            keep.fire(start + EVERY * 3 + Duration::from_secs(1)),
            Fire::Ping { unanswered: false }
        );
    }

    #[tokio::test(start_paused = true)]
    async fn peer_keepalive_pings_within_10_percent_early_and_not_sooner() {
        let start = Instant::now();
        let mut keep = Keepalive::new(EVERY, DEAD, start);
        keep.heard(start + Duration::from_secs(2));
        // Armed for 15 s, fired with 2 s left: more than the 1.5 s slack, so wait.
        assert_eq!(keep.fire(start + EVERY), Fire::Wait);
        assert_eq!(keep.deadline(), start + Duration::from_secs(17));
        let mut keep = Keepalive::new(EVERY, DEAD, start);
        keep.heard(start + Duration::from_secs(1));
        // 1 s left is inside the slack: ping now instead of a second wake.
        assert_eq!(keep.fire(start + EVERY), Fire::Ping { unanswered: false });
    }
}
