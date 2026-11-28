//! A peer costs nothing until something needs it. After a crash on a Mac with about 130 saved
//! peers, its daemon dialed every one within seconds of starting (an ssh login each, a second for
//! the token read beside each first dial) and the load reached 214. A cap on concurrent logins
//! (the concurrent-login scheduling proposed in #56369) spreads that out; this removes it (Leo, 2026-11-25: "but why limit
//! peering? why not optimize it on our protools instead?").
//!
//! - A saved peer is not dialed when the daemon starts (`lazily`, `Hub::start_saved_peers`). Its
//!   chats are the peer cache's rows, marked last-known (`hub/peer_cache.rs` `mark_stale`), and
//!   its link reads `idle` (`offline` when it was down at its last record): what the person sees
//!   is what this daemon knows, and using the machine connects it (H16: every state has an action).
//! - What needs a peer dials it at once: a client's request for one of its chats or its trust
//!   (`server/peer_demand_wait.rs`, which holds the request until the link is up), a message for
//!   it (the outbox sends through that same path), a chat of it that was working or asking when
//!   the daemon stopped (`load_peer_cache`), an add, an explicit reconnect, and every `want` and
//!   `wake` (`peer_wanted.rs`).
//! - Listing never dials: a chat's metadata read (`_acpmux/info`, what a list row or a phone's
//!   list asks of each chat) is answered from the peer's last-known row while the peer waits
//!   to be used, and is no use of a link that is up (`server/peer_demand_wait.rs`).
//! - A link nothing used for [`IDLE_CLOSE_AFTER`] closes (`LinkEnd::Idle`): no client request
//!   for it, no chat activity on it (events, row changes, acceptances), no request or prompt in
//!   flight, no ask. Its rows turn last-known, with no outage and no failed attempt counted. A
//!   quiet link still in use stays open: a client attached to one of its chats, or a delivery
//!   for it not settled yet ([`Keeper`], `hub/peer_idle.rs` `Hub::keeps_peer`).
//! - A link that dropped while nothing used it stops redialing once it has gone unused that long:
//!   it is `offline` and reconnects on use, instead of logging in to a machine nobody reads.
//!
//! A peer this daemon lends its GitHub login (`githubBroker`) is dialed at start and kept, as
//! before: that peer asks over this link, and only over it. A dedicated agent VM (`vmBoundary`)
//! too: this daemon reads its chats ahead into copies (`hub/peer_snapshot/warm.rs`), and
//! `session move --from-snapshot` starts them from those copies when that VM dies (RFD 0167 row 4). A leased peer (`peer_lease.rs`) and
//! one a test builds keep the old rule too: dialed at once, kept while it answers.

use super::Peer;
use crate::no_panic::LockExt;
use std::cell::Cell;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::time::Instant;

/// How long a link may go unused before it closes. Past the ssh master's own linger
/// (`peer_ssh_master.rs`, where it lands), the next use logs in again; inside it, it does not.
pub(crate) const IDLE_CLOSE_AFTER: Duration = Duration::from_secs(15 * 60);

/// The link notifications that are a chat's activity: a working chat keeps its link.
const ACTIVITY: &[&str] = &[
    crate::rpc::method::MUX_EVENT,
    crate::rpc::method::SESSION_UPDATE,
    crate::rpc::method::MUX_SESSION_CHANGED,
    crate::rpc::method::MUX_PROMPT_ACCEPTED,
];

/// How a peer built on this thread starts (`Peer::new` reads it through `Demand::default`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Start {
    /// Dialed at once and kept: a test's peer, a lease.
    Dial,
    /// A saved peer: dialed at once, and its link closes once unused.
    Saved,
    /// A saved peer at daemon start: dialed when first used.
    Lazy,
}

thread_local!(static START: Cell<Start> = const { Cell::new(Start::Dial) });

fn starting<T>(start: impl FnOnce(Start) -> Start, f: impl FnOnce() -> T) -> T {
    struct Restore(Start);
    impl Drop for Restore {
        fn drop(&mut self) {
            START.with(|s| s.set(self.0));
        }
    }
    let was = START.with(|s| {
        let was = s.get();
        s.set(start(was));
        was
    });
    let _restore = Restore(was);
    f()
}

/// Runs `f`, in which each peer built is a saved one (`Hub::start_peer`): its link closes once
/// unused. A start inside [`lazily`] stays lazy.
pub(crate) fn saved<T>(f: impl FnOnce() -> T) -> T {
    starting(|was| if was == Start::Dial { Start::Saved } else { was }, f)
}

/// Set (to anything): saved peers dial when the daemon starts, as before this file. The hermetic
/// test environment sets it (`tests/support/daemon_env.rs`), so a test that writes a peer into
/// config.json reads it linked; the lazy start has its own tests (`peer_demand_tests.rs`).
pub const DIAL_AT_START_ENV: &str = "ACPMUX_PEER_DIAL_AT_START";

/// Runs `f`, in which each saved peer built waits to be used before it dials
/// (`Hub::start_saved_peers`), unless [`DIAL_AT_START_ENV`] is set.
pub(crate) fn lazily<T>(f: impl FnOnce() -> T) -> T {
    if std::env::var_os(DIAL_AT_START_ENV).is_some() {
        return saved(f);
    }
    starting(|_| Start::Lazy, f)
}

/// What keeps a quiet link open beside a use (`Hub::keeps_peer`): a client attached to one of
/// its chats, or a delivery for it not settled yet. Asked only once the link is otherwise due
/// to close.
pub(crate) type Keeper = Box<dyn Fn(&Peer) -> bool + Send + Sync>;

/// Whether the peer waits to be used before it dials, and when it was last used.
pub(crate) struct Demand {
    parked: AtomicBool,
    closes_idle: bool,
    used_at: StdMutex<Instant>,
    keeper: std::sync::OnceLock<Keeper>,
    changed: tokio::sync::Notify,
}

impl std::fmt::Debug for Demand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Demand")
            .field("parked", &self.parked)
            .field("closes_idle", &self.closes_idle)
            .field("used_at", &self.used_at)
            .field("keeper", &self.keeper.get().is_some())
            .finish()
    }
}

impl Default for Demand {
    fn default() -> Self {
        let start = START.with(Cell::get);
        Self {
            parked: AtomicBool::new(start == Start::Lazy),
            closes_idle: start != Start::Dial,
            used_at: StdMutex::new(Instant::now()),
            keeper: std::sync::OnceLock::new(),
            changed: tokio::sync::Notify::new(),
        }
    }
}

impl Peer {
    /// Something used the peer now: a client's request for it, or a chat's activity on its link.
    pub(crate) fn note_use(&self) {
        *self.wanted.demand.used_at.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
    }

    /// Hands the peer what keeps its quiet link open ([`Keeper`]; `Hub::spawn_peer`).
    pub(crate) fn set_keeper(&self, keeper: Keeper) {
        let _ = self.wanted.demand.keeper.set(keeper);
    }

    /// Wake a parked demand wait when a setting changes whether this peer must stay connected.
    pub(crate) fn demand_changed(&self) {
        // Retain one wake if the state flips between the loop's check and its select setup.
        self.wanted.demand.changed.notify_one();
    }

    /// The chats of this peer local clients asked to stream (`mark_attached`); a mark outlives
    /// its client, so whether one still listens is the hub's to say (`Hub::keeps_peer`).
    pub(crate) fn attached_chats(&self) -> Vec<String> {
        self.attached.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect()
    }

    /// Whether the peer is left undialed until something uses it (`await_demand`).
    pub(crate) fn idle_parked(&self) -> bool {
        self.wanted.demand.parked.load(Ordering::SeqCst)
    }

    /// A notification read on the link: a chat's activity counts as a use ([`ACTIVITY`]).
    pub(super) fn note_link_activity(&self, method: &str) {
        // An agent byte channel's traffic too (`server/channels.rs`).
        if ACTIVITY.contains(&method) || crate::server::channels::from_peer_method(method) {
            self.note_use();
        }
    }

    fn unused_for(&self) -> Duration {
        let at = *self.wanted.demand.used_at.lock().unwrap_or_else(|e| e.into_inner());
        Instant::now().saturating_duration_since(at)
    }

    /// Something waits on the peer now: an ask (`want`, `wake`), a request or a prompt on it.
    fn in_use(&self) -> bool {
        self.is_wanted()
            || self.waking()
            || !self.prompts.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
            || self.pending.try_lock().map_or(true, |pending| !pending.is_empty())
    }

    /// Whether this peer's link closes, or stops redialing, once unused: a saved peer's does,
    /// unless this daemon lends it its GitHub login (that peer asks over this link alone) or its
    /// config names it a dedicated agent VM (`vmBoundary`): this daemon keeps that peer's copies
    /// (`hub/peer_snapshot/warm.rs` `keeps_copies`), read over this link alone, and a move from a
    /// copy is how its chats outlive its death. Left undialed it held none: a host killed under
    /// 20 chats moved 0 of them (fleet-recovery-bench, 2026-11-27, `copies_at_kill` 0).
    fn closes_idle(&self) -> bool {
        self.wanted.demand.closes_idle && !self.github_broker() && !self.vm_boundary()
    }

    /// Whether the peer has gone unused for [`IDLE_CLOSE_AFTER`] with nothing keeping it: no
    /// ask or request waiting on it, and no attached client or unsettled delivery ([`Keeper`],
    /// asked last, since it reads the hub).
    fn unused(&self) -> bool {
        self.closes_idle()
            && !self.in_use()
            && self.unused_for() >= IDLE_CLOSE_AFTER
            && !self.wanted.demand.keeper.get().is_some_and(|keeps| keeps(self))
    }

    /// Whether the ready link has gone unused for [`IDLE_CLOSE_AFTER`] and closes now
    /// (`serve`, on its ping tick).
    pub(super) fn idle_due(&self) -> bool {
        self.unused()
    }

    /// Before each connect attempt (`Peer::run`): a peer left undialed waits here until
    /// something uses it, reporting `idle` (or `offline`, when it was down) meanwhile; a link
    /// that is down and unused for [`IDLE_CLOSE_AFTER`] stops redialing and waits the same way.
    /// False once the peer is stopped.
    pub(super) async fn await_demand(&self) -> bool {
        let demand = &self.wanted.demand;
        if !demand.parked.load(Ordering::SeqCst) {
            if !self.unused() {
                return true;
            }
            demand.parked.store(true, Ordering::SeqCst);
            // A replacement may have opened while the old link was silent. Once demand parks,
            // that staged socket is no longer useful and must be dropped before we wait.
            self.replacement.lock_or_recover().take();
            tracing::info!(peer = %self.name, "the link is down and unused; it reconnects on use");
        }
        if !self.closes_idle() {
            // Started lazily, but this daemon lends it GitHub: it dials now.
            demand.parked.store(false, Ordering::SeqCst);
            return true;
        }
        let mut stopped = self.stop_changed.subscribe();
        let mut reported = false;
        loop {
            let since = Instant::now();
            if self.stop.load(Ordering::SeqCst) {
                return false;
            }
            if !self.closes_idle() {
                break;
            }
            if self.in_use() {
                break;
            }
            if !reported {
                reported = true;
                self.with_link(crate::peer_link::Link::idle);
            }
            tokio::select! {
                biased;
                _ = stopped.wait_for(|stopped| *stopped) => return false,
                () = demand.changed.notified() => {},
                () = self.next_ask_after(since) => {}
            }
        }
        demand.parked.store(false, Ordering::SeqCst);
        self.note_use();
        // Its dial shows as one: connecting, or reconnecting when it was reached before.
        self.with_link(|link| link.idle = false);
        true
    }

    /// The link closed because nothing used it (`LinkEnd::Idle`, `finish_link`): it ends as a
    /// restart does, with no outage and no failed attempt, and the peer waits to be used.
    pub(super) fn idle_ended(&self) -> Option<super::PeerNotice> {
        tracing::info!(peer = %self.name, "the link went unused for {}s; it closes and reconnects on use", IDLE_CLOSE_AFTER.as_secs());
        // A make-before-break dial may have opened while this link was idle. Parking the peer
        // must drop that socket and its tunnel instead of retaining it until the next demand.
        self.replacement.lock_or_recover().take();
        self.link_ended();
        self.open.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        // The next link reads the list (from its cursor) first, as after an outage.
        self.whole_list.store(false, Ordering::SeqCst);
        self.wanted.demand.parked.store(true, Ordering::SeqCst);
        self.with_link(crate::peer_link::Link::idle);
        Some(super::PeerNotice::Idle)
    }
}

#[cfg(test)]
#[path = "peer_demand_tests.rs"]
mod tests;
