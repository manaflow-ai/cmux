//! The wait between connect attempts (`Peer::run`), and how a client that waits on the peer
//! shortens it. A client's request refused because the link is down (`server/peer_forward.rs`),
//! or a ready link that ended (chats are open on it), marks the peer wanted for the outage window:
//! each wait in that window is bounded by `Backoff::WANTED_CAP`, and a refusal cuts the running wait
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
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::Instant;

/// Every ssh of a peer shares its host's master (`ssh_command`).
#[path = "peer_ssh_master.rs"]
mod ssh_master;
#[cfg(test)]
pub(super) use ssh_master::SshMux;

/// How long one ask keeps the peer wanted.
pub(super) const WANTED_FOR: Duration = Duration::from_secs(60);

/// How long a restart (Close 1012) keeps it wanted: a loaded host's daemon can take a minute or
/// more to listen again (huge-blue's updates, 2026-10-30).
pub(super) const RESTART_WANTED_FOR: Duration = Duration::from_secs(180);

/// How long into an outage a client's ask still shortens the reconnect wait
/// (`Peer::asks_shorten`): a restart's window, so a daemon that takes minutes to listen again
/// is still re-dialed within a second while chats wait on it.
pub(super) const WANTED_OUTAGE_FOR: Duration = RESTART_WANTED_FOR;

/// How long one message keeps the peer marked to wake: a paused VM resumes and its daemon
/// answers within this on the routes that wake one (about a minute, machines/lane-vms.md).
pub(super) const WAKE_FOR: Duration = Duration::from_secs(180);

/// Set on the ssh of each connect attempt while the peer is marked to wake (`Peer::wake`).
pub const WAKE_ENV: &str = "ACPMUX_PEER_WAKE";

/// The daemon's `peerWake` argv (config `peerWake`), or none: the machine layer's resume for
/// a peer's machine, whatever its provider. `Peer::wake` runs it with the peer's name appended.
pub type WakeHook = Arc<StdMutex<Option<Vec<String>>>>;

/// The longest one `peerWake` run may take before it is killed: a resume that has not come
/// back within the wake window is no longer what the message waits on.
pub(super) const WAKE_HOOK_FOR: Duration = WAKE_FOR;

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
    /// When `peerWake` last ran for a message (`Peer::wake`): it runs again once `WAKE_FOR` has
    /// passed since, while messages still wait.
    hook_at: StdMutex<Option<Instant>>,
    asked: Notify,
    /// When an ask last cut a backoff wait short (`Peer::wait_backoff`).
    cut_at: StdMutex<Option<Instant>>,
    /// When the last ask came, so one made before a waiter listens still counts
    /// (`Peer::next_ask_after`); `asked` wakes only the waiters there are.
    asked_at: StdMutex<Option<Instant>>,
    /// When a sleep or a network change last sent an attempt at once, and which (`"sleep"`,
    /// `"network"`): the next ready link logs the time since as `reconnect_ms`, the reconnect's
    /// duration that NOW's paths row reads (leo-workspace tools/now_paths_source.py).
    reconnect_at: StdMutex<Option<(Instant, &'static str)>>,
    /// Whether the peer waits to be used before it dials, and when it was last used
    /// (`peer_demand.rs`).
    pub(super) demand: super::demand::Demand,
}

impl Peer {
    /// A sleep or network change sends an attempt now: remember when, for `reconnect_took`.
    fn reconnect_started(&self, cause: &'static str) {
        *self.wanted.reconnect_at.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((Instant::now(), cause));
    }

    /// The link is ready: how long since the sleep or network change that sent the attempt, and
    /// which, once; None when no such trigger is pending.
    pub(super) fn reconnect_took(&self) -> Option<(Duration, &'static str)> {
        let (at, cause) =
            self.wanted.reconnect_at.lock().unwrap_or_else(|e| e.into_inner()).take()?;
        Some((at.elapsed(), cause))
    }

    /// A client waits on this peer: for `WANTED_FOR` its reconnects come within
    /// `Backoff::WANTED_CAP`, the wait running now included.
    pub(crate) fn want(&self) {
        self.want_for(WANTED_FOR);
    }

    /// A message waits for this peer: for `WAKE_FOR` each connect attempt asks its route to
    /// wake a paused machine ([`WAKE_ENV`]), and the peer is wanted, so the attempts come within
    /// `Backoff::WANTED_CAP` while it wakes.
    ///
    /// A message also runs the daemon's `peerWake` command ([`WakeHook`]), whatever route the
    /// peer has: an ssh route with no ProxyCommand that wakes (a VM its idle guard powered off) is
    /// resumed by it too. Once per `WAKE_FOR`: the first message runs it, and a message still
    /// waiting runs it again each `WAKE_FOR` (its outbox's retries mark the peer again), so a
    /// machine parked again before the message went in is resumed again (cmuxterm-hq#17784: the
    /// retries kept the window open, and the hook never ran a second time).
    pub(crate) fn wake(&self) {
        let now = Instant::now();
        let until = now.checked_add(WAKE_FOR).unwrap_or(now);
        let mut held = self.wanted.wake_until.lock().unwrap_or_else(|e| e.into_inner());
        *held = Some(held.map_or(until, |was| was.max(until)));
        drop(held);
        self.want_for(WAKE_FOR);
        let mut ran = self.wanted.hook_at.lock().unwrap_or_else(|e| e.into_inner());
        let due = ran.is_none_or(|at| at.checked_add(WAKE_FOR).is_none_or(|next| next <= now));
        if due {
            *ran = Some(now);
            drop(ran);
            self.run_wake_hook();
        }
    }

    /// Hands the peer the daemon's `peerWake` command (`hub/peers.rs`).
    pub(crate) fn set_wake_hook(&self, hook: WakeHook) {
        let _ = self.wake_hook.set(hook);
    }

    /// The `peerWake` argv for this peer (the peer's name appended), when one is configured.
    pub(super) fn wake_argv(&self) -> Option<Vec<String>> {
        let hook = self.wake_hook.get()?;
        let mut argv = hook.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        if argv.first().is_none_or(|program| program.is_empty()) {
            return None;
        }
        argv.push(self.name.clone());
        Some(argv)
    }

    /// Runs `peerWake` once, as one of the peer's own tasks, detached from the request that
    /// asked: bounded by `WAKE_HOOK_FOR` (a run past it is ended), its exit logged. The
    /// command keeps its own log. The message itself waits in the sender's outbox and goes once
    /// the link is back, as with a route that wakes.
    fn run_wake_hook(&self) {
        let Some(argv) = self.wake_argv() else { return };
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let peer = self.name.clone();
        self.scope.spawn_named("peer-wake", async move {
            let started = std::time::Instant::now();
            let outcome = tokio::task::spawn_blocking(move || {
                crate::machine_wake::run_peer_wake(&argv, WAKE_HOOK_FOR)
            })
            .await
            .unwrap_or_else(|e| Err(format!("its task ended: {e}")));
            let ms = started.elapsed().as_millis() as u64;
            match outcome {
                Ok(()) => tracing::info!(peer = %peer, ms, "peerWake: resumed for a message"),
                Err(why) => tracing::warn!(peer = %peer, ms, "peerWake failed: {why}"),
            }
        });
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
    /// the route's ProxyCommand, which ssh runs as its child. It shares the host's one master
    /// connection (`peer_ssh_master.rs`): a master that is up runs no ProxyCommand, and needs none.
    pub(super) fn ssh_command(&self) -> tokio::process::Command {
        let mut ssh = self.ssh_with_master();
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
            self.want_for(if restarting { RESTART_WANTED_FOR } else { WANTED_OUTAGE_FOR });
        }
    }

    pub(crate) fn is_wanted(&self) -> bool {
        self.wanted
            .until
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some_and(|until| until > Instant::now())
    }

    /// Whether a client's ask still shortens the wait between attempts at `now` (ms): for the
    /// first [`WANTED_OUTAGE_FOR`] of an outage, and whenever a message wakes the peer. Past
    /// that, a peer whose link is still down is a machine that is gone or off, and reads that keep
    /// asking about it (a list, a history refresh) would otherwise re-dial ssh about once a
    /// second for as long as they last: each one a login, its key exchange and the user and
    /// service lookups behind it. The plain backoff (up to `Backoff::CAP`) still runs, and a
    /// network change still tries at once.
    pub(super) fn asks_shorten(&self, now: u64) -> bool {
        let young = |at: u64| now.saturating_sub(at) < WANTED_OUTAGE_FOR.as_millis() as u64;
        self.waking() || self.link().down_since.is_none_or(young)
    }

    /// Whether a client that waits on the peer now gets a connect attempt within about
    /// `Backoff::WANTED_CAP`: the outage is young enough for its ask to cut the wait
    /// (`asks_shorten`), and no refused ssh login holds the attempts back. A new chat for it
    /// (`server/requests.rs` `new_on_peer`) waits for the link only then; a machine long gone is
    /// refused at once, as before.
    pub(crate) fn reconnects_soon(&self) -> bool {
        !self.login_refused.load(std::sync::atomic::Ordering::SeqCst)
            && self.asks_shorten(crate::store::now_ms())
    }

    /// Waits out one backoff delay, or its `Backoff::wanted` bound while the peer is wanted
    /// (read again at each ask and each clock check, so an ask mid-wait cuts it). A wait that
    /// this computer slept through ends at the wake, with the backoff started over: the delay
    /// ran on the monotonic clock, which stood still, so the attempt would otherwise come up to
    /// a minute after the wake, while the network that failed before the sleep is likely back.
    pub(super) async fn wait_backoff(&self, delay: Duration) -> BackoffWait {
        let started = Instant::now();
        let wanted = Backoff::wanted(delay, crate::peer_link::jitter());
        // After a refused ssh login no ask shortens the wait: a chat that keeps asking would
        // otherwise send the remote one refused login a second (`Backoff::login_refused`).
        let heed_asks = !self.login_refused.load(std::sync::atomic::Ordering::SeqCst);
        let mut watch = SleepWatch::now();
        loop {
            // Listening before the read: an ask between the two still wakes this wait.
            let asked = self.wanted.asked.notified();
            tokio::pin!(asked);
            asked.as_mut().enable();
            // Read each turn: a message mid-wait (`Peer::wake`) makes asks count again.
            let heed = heed_asks && self.asks_shorten(crate::store::now_ms());
            let deadline = started + if heed && self.is_wanted() { wanted } else { delay };
            if Instant::now() >= deadline {
                return BackoffWait::Done;
            }
            let check = (Instant::now() + SleepWatch::EVERY).min(deadline);
            tokio::select! {
                _ = tokio::time::sleep_until(check) => {
                    if let Some(slept) = watch.check() {
                        tracing::info!(peer = %self.name, "this computer slept {}s; reconnecting now", slept.as_secs());
                        self.reconnect_started("sleep");
                        return BackoffWait::Woke;
                    }
                }
                () = &mut asked, if heed_asks => {
                    if !self.asks_shorten(crate::store::now_ms()) {
                        continue;
                    }
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
                // The network changed (`peer_network.rs`), often the one this peer failed on coming
                // back: one attempt now. The backoff is not started over, so a network that keeps
                // changing while the peer is down costs one attempt per change, not quick retries.
                () = self.network_changed() => {
                    tracing::info!(peer = %self.name, "this computer's network changed; reconnecting now");
                    self.reconnect_started("network");
                    return BackoffWait::Done;
                }
                _ = self.stop_signal.notified() => return BackoffWait::Stopped,
            }
        }
    }
}

#[cfg(test)]
#[path = "peer_wanted_tests.rs"]
mod tests;
