//! The wait between connect attempts (`Peer::run`), and how a client that waits on the peer
//! shortens it. A client's request refused because the link is down (`server/peer_forward.rs`),
//! or a ready link that ended (chats are open on it), marks the peer wanted for `WANTED_FOR`: each
//! wait in that window is bounded by `Backoff::WANTED_CAP`, and a refusal cuts the running wait
//! to that bound at once. Nothing new runs in the background: the bound is read by the wait
//! that is already there, and it lapses by itself `WANTED_FOR` after the last ask.
//!
//! A message for a session on the peer (a `session/prompt` refused because the link is down,
//! from any connection, a peer daemon's included) also marks the peer to wake for `WAKE_FOR`:
//! each connect attempt in that window runs its ssh with `ACPMUX_PEER_WAKE=1` ([`WAKE_ENV`]), so
//! a route that can resume a paused machine (a Freestyle pool slot's ProxyCommand, leo-workspace
//! `tools/cloud-vm-up nc`) resumes it for this attempt only. Background reconnects carry no mark,
//! so a paused machine that nobody sends to stays paused (HQ#5074: passive reads never wake one).

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

/// How long one message keeps the peer marked to wake: a paused VM resumes and its daemon
/// answers within this on the routes that wake one (about a minute, machines/lane-vms.md).
pub(super) const WAKE_FOR: Duration = Duration::from_secs(180);

/// Set on the ssh of each connect attempt while the peer is marked to wake (`Peer::wake`).
pub const WAKE_ENV: &str = "ACPMUX_PEER_WAKE";

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
    /// Until when a connect attempt asks its route to wake a paused machine (`Peer::wake`).
    wake_until: StdMutex<Option<Instant>>,
    asked: Notify,
    /// When an ask last cut a backoff wait short (`Peer::wait_backoff`).
    cut_at: StdMutex<Option<Instant>>,
    /// When the last ask came, so one made before a waiter listens still counts
    /// (`Peer::next_ask_after`); `asked` wakes only the waiters there are.
    asked_at: StdMutex<Option<Instant>>,
}

impl Peer {
    /// A client waits on this peer: for `WANTED_FOR` its reconnects come within
    /// `Backoff::WANTED_CAP`, the wait running now included.
    pub(crate) fn want(&self) {
        self.want_for(WANTED_FOR);
    }

    /// A message waits for this peer: for `WAKE_FOR` each connect attempt asks its route to
    /// wake a paused machine ([`WAKE_ENV`]), and the peer is wanted, so the attempts come within
    /// `Backoff::WANTED_CAP` while it wakes.
    pub(crate) fn wake(&self) {
        let now = Instant::now();
        let until = now.checked_add(WAKE_FOR).unwrap_or(now);
        let mut held = self.wanted.wake_until.lock().unwrap_or_else(|e| e.into_inner());
        *held = Some(held.map_or(until, |was| was.max(until)));
        drop(held);
        self.want_for(WAKE_FOR);
    }

    /// Whether a connect attempt now asks its route to wake a paused machine.
    pub(crate) fn waking(&self) -> bool {
        self.wanted
            .wake_until
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some_and(|until| until > Instant::now())
    }

    /// `ssh`, with [`WAKE_ENV`] set while the peer is marked to wake: the environment reaches
    /// the route's ProxyCommand, which ssh runs as its child.
    pub(super) fn ssh_command(&self) -> tokio::process::Command {
        let mut ssh = tokio::process::Command::new("ssh");
        if self.waking() {
            ssh.env(WAKE_ENV, "1");
        } else {
            ssh.env_remove(WAKE_ENV);
        }
        ssh
    }

    /// The first ask that comes at or after `after` (`Peer::connect_once`), also one that came
    /// before this was first polled; asks before `after`, such as the one that started this
    /// attempt, are not counted.
    pub(super) async fn next_ask_after(&self, after: Instant) {
        loop {
            let asked = self.wanted.asked.notified();
            tokio::pin!(asked);
            asked.as_mut().enable();
            let last = *self.wanted.asked_at.lock().unwrap_or_else(|e| e.into_inner());
            if last.is_some_and(|at| at >= after) {
                return;
            }
            asked.await;
            if Instant::now() >= after {
                return;
            }
        }
    }

    fn want_for(&self, window: Duration) {
        let now = Instant::now();
        let until = now.checked_add(window).unwrap_or(now);
        let mut held = self.wanted.until.lock().unwrap_or_else(|e| e.into_inner());
        *held = Some(held.map_or(until, |was| was.max(until)));
        drop(held);
        *self.wanted.asked_at.lock().unwrap_or_else(|e| e.into_inner()) = Some(now);
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
                () = &mut asked => {
                    // A client asks now: the next attempt goes at once, at most once per
                    // `WANTED_CAP`, so asks that keep coming (a person typing) get one attempt
                    // per cap, not one per ask.
                    let now = Instant::now();
                    let mut cut = self.wanted.cut_at.lock().unwrap_or_else(|e| e.into_inner());
                    if cut.is_none_or(|at| now.saturating_duration_since(at) >= Backoff::WANTED_CAP) {
                        *cut = Some(now);
                        return BackoffWait::Done;
                    }
                }
                _ = self.stop_signal.notified() => return BackoffWait::Stopped,
            }
        }
    }
}

#[cfg(test)]
#[path = "peer_wanted_tests.rs"]
mod tests;
