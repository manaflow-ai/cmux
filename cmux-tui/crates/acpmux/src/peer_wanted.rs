//! The wait between connect attempts (`Peer::run`), and how a client that waits on the peer
//! shortens it. A client's request refused because the link is down (`server/peer_forward.rs`),
//! or a ready link that ended (chats are open on it), marks the peer wanted for `WANTED_FOR`: each
//! wait in that window is bounded by `Backoff::WANTED_CAP`, and a refusal cuts the running wait
//! to that bound at once. Nothing new runs in the background: the bound is read by the wait
//! that is already there, and it lapses by itself `WANTED_FOR` after the last ask.

use super::Peer;
use crate::peer_link::{Backoff, SleepWatch};
use std::sync::Mutex as StdMutex;
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::Instant;

/// How long one ask keeps the peer wanted.
pub(super) const WANTED_FOR: Duration = Duration::from_secs(60);

/// How long a restart (Close 1012) keeps it wanted: a loaded host's daemon can take a minute or
/// more to listen again (huge-blue's updates, 2026-10-30).
pub(super) const RESTART_WANTED_FOR: Duration = Duration::from_secs(180);

/// A link that ends sooner after its handshake is crash-looping: it keeps its backoff.
pub(super) const READY_FOR: Duration = Duration::from_secs(10);

/// How a backoff wait between attempts ended (`Peer::wait_backoff`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BackoffWait {
    /// The delay passed.
    Done,
    /// This computer slept through it: the attempt goes now.
    Woke,
    /// The peer was stopped.
    Stopped,
}

/// Until when a client waits on the peer, and the wake of a wait when one starts to.
#[derive(Debug, Default)]
pub(super) struct Wanted {
    until: StdMutex<Option<Instant>>,
    asked: Notify,
}

impl Peer {
    /// A client waits on this peer: for `WANTED_FOR` its reconnects come within
    /// `Backoff::WANTED_CAP`, the wait running now included.
    pub(crate) fn want(&self) {
        self.want_for(WANTED_FOR);
    }

    fn want_for(&self, window: Duration) {
        let now = Instant::now();
        let until = now.checked_add(window).unwrap_or(now);
        let mut held = self.wanted.until.lock().unwrap_or_else(|e| e.into_inner());
        *held = Some(held.map_or(until, |was| was.max(until)));
        drop(held);
        self.wanted.asked.notify_waiters();
    }

    /// The link ends (`Peer::finish_link`, before it is marked down). A ready link has chats
    /// open on it: after a restart (Close 1012), or once it stayed ready `READY_FOR`, the peer
    /// is wanted. One that drops right after each handshake keeps its backoff.
    pub(super) fn link_ending(&self, restarting: bool) {
        let ready_for = self.link().ready_for(crate::store::now_ms());
        if ready_for.is_some_and(|up| restarting || up >= READY_FOR) {
            self.want_for(if restarting { RESTART_WANTED_FOR } else { WANTED_FOR });
        }
    }

    pub(crate) fn is_wanted(&self) -> bool {
        self.wanted
            .until
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some_and(|until| until > Instant::now())
    }

    /// Waits out one backoff delay, or its `Backoff::wanted` bound while the peer is wanted
    /// (read again at each ask and each clock check, so an ask mid-wait cuts it). A wait that
    /// this computer slept through ends at the wake, with the backoff started over: the delay
    /// ran on the monotonic clock, which stood still, so the attempt would otherwise come up to
    /// a minute after the wake, while the network that failed before the sleep is likely back.
    pub(super) async fn wait_backoff(&self, delay: Duration) -> BackoffWait {
        let started = Instant::now();
        let wanted = Backoff::wanted(delay, crate::peer_link::jitter());
        let mut watch = SleepWatch::now();
        loop {
            // Listening before the read: an ask between the two still wakes this wait.
            let asked = self.wanted.asked.notified();
            tokio::pin!(asked);
            asked.as_mut().enable();
            let deadline = started + if self.is_wanted() { wanted } else { delay };
            if Instant::now() >= deadline {
                return BackoffWait::Done;
            }
            let check = (Instant::now() + SleepWatch::EVERY).min(deadline);
            tokio::select! {
                _ = tokio::time::sleep_until(check) => {
                    if let Some(slept) = watch.check() {
                        tracing::info!(peer = %self.name, "this computer slept {}s; reconnecting now", slept.as_secs());
                        return BackoffWait::Woke;
                    }
                }
                () = &mut asked => {}
                _ = self.stop_signal.notified() => return BackoffWait::Stopped,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    fn peer() -> std::sync::Arc<Peer> {
        let (tx, _notices) = mpsc::channel(64);
        Peer::new("huge-blue", "ws://127.0.0.1:9", None, None, tx)
    }

    #[tokio::test(start_paused = true)]
    async fn a_refusal_cuts_a_long_backoff_wait_to_the_wanted_bound() {
        let peer = peer();
        let waiting = peer.clone();
        let started = Instant::now();
        let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!wait.is_finished());
        // A client opens a chat on the peer while its link is down.
        peer.want();
        assert_eq!(wait.await.unwrap(), BackoffWait::Done);
        assert!(started.elapsed() <= Backoff::WANTED_CAP, "{:?}", started.elapsed());
    }

    #[tokio::test(start_paused = true)]
    async fn an_unwanted_peer_waits_its_whole_delay_and_a_stop_ends_any_wait() {
        let peer = peer();
        let started = Instant::now();
        assert_eq!(peer.wait_backoff(Duration::from_secs(20)).await, BackoffWait::Done);
        assert!(started.elapsed() >= Duration::from_secs(20));

        peer.want();
        tokio::time::advance(WANTED_FOR).await;
        assert!(!peer.is_wanted(), "an ask lapses by itself");

        let waiting = peer.clone();
        let wait =
            tokio::spawn(async move { waiting.wait_backoff(Duration::from_secs(3_600)).await });
        tokio::time::sleep(Duration::from_millis(100)).await;
        peer.stop();
        assert_eq!(wait.await.unwrap(), BackoffWait::Stopped);
    }

    #[test]
    fn a_ready_link_that_ends_is_wanted_unless_it_died_right_after_its_handshake() {
        let now = crate::store::now_ms();
        let ended = |ready_ms_ago: Option<u64>, restarting: bool| {
            let peer = peer();
            if let Some(ago) = ready_ms_ago {
                peer.with_link(|l| {
                    l.opened(now - ago);
                    l.ready(now - ago);
                });
            }
            peer.link_ending(restarting);
            peer.is_wanted()
        };
        assert!(ended(Some(20_000), false), "a link up 20 s drops: its chats wait on it");
        let restarted = peer();
        restarted.with_link(|l| {
            l.opened(now);
            l.ready(now);
        });
        restarted.link_ending(true);
        restarted.want();
        let until = restarted.wanted.until.lock().unwrap().unwrap();
        assert!(until > Instant::now() + WANTED_FOR, "an ask never shortens a restart's window");
        assert!(ended(Some(1_000), true), "a restart (Close 1012), however short the link");
        assert!(!ended(Some(1_000), false), "a crash loop keeps its backoff");
        assert!(!ended(None, false), "a handshake that failed is no open chat");
    }
}
