//! An app session's owner stops the moment its app has left and nothing
//! else keeps it (R-LIFECYCLE stage 1, handoff/rewrites/R-LIFECYCLE/DESIGN.md).
//!
//! `server ensure` starts the owner of an app session (`cmux-app`,
//! `cmux-app-*`) and of the app's Chief session (`cmux-chief-*`) detached,
//! so that terminals outlive the app (pty-holder.md D1). With nothing to keep, that owner ran until reboot: after a quit, a
//! crash or a deleted bundle, for every build and tag a person ran (STATUS
//! 1370: 105 such processes on 8 fleet hosts; STATUS 8519: the cmux20
//! nightly's owner after its app quit). Its state is durable, so a stop
//! loses nothing: the next `ensure` (the app's launch, an interactive `cmux`)
//! starts an owner that restores the session.
//!
//! The app's connections declare role `main` in `client-hello` (Swift
//! `HandshakeLines`, the Rust daemon client). From the first such hello the
//! owner is kept only by:
//!
//! - a connected client of any role (the app, a CLI command, a viewer),
//!   except the owner's own journal plugin;
//! - a live terminal (launching, adopting or running), for at most
//!   [`UNATTENDED_TERMINAL_KEEP`] with no client (see below): this includes a
//!   closed terminal in its Reopen hold until the reaper ends it, and a
//!   terminal marked `keep`; a terminal whose new shell is on its way (a
//!   lost host's respawn in its backoff, or an `on_exit` shell restart); an
//!   ended `on_exit` keep or shell terminal whose tabs and final screen
//!   only this owner holds (a new owner detaches them); and a signal exit
//!   whose detach waits out the session shutdown lead (a stop in that wait
//!   would make it a host loss, and the next owner would respawn a shell the
//!   person killed);
//! - its running browser host (an agent in one of its terminals may use it);
//! - a running app server (an `always` server, or an on-demand server until
//!   its idle stop), and an `always` server that crashed and waits for its
//!   restart;
//! - in a Chief session, a brain the owner supervises (`chief_brains.rs`)
//!   that runs or waits for its restart, and a signal that may start one:
//!   the owner's stop ends every brain and cuts its turn, and a brain is a
//!   client only while its link is up.
//!
//! Terminals alone keep an owner only while a client came within
//! [`UNATTENDED_TERMINAL_KEEP`]. Before that bound an owner whose app never
//! came back (a deleted DEV tag, a thrown-away bundle, an old tag of a
//! renamed build) ran forever: it held a stream to each of its terminal
//! hosts, so no host ever counted as orphaned (their own no-client grace,
//! `ABANDONED_HOST_GRACE`, never started), and the live hosts kept the
//! owner. On a developer Mac (2026-11-21) that loop had left such owners and
//! their hosts running for up to 34 days. Once the bound passes, the owner
//! stops like any other orphan stop: no terminal ends, its hosts keep
//! running for the next owner of the session to adopt, and with no peer
//! left each host's own orphan grace now runs (10 minutes in DEV, staging
//! and debug builds, `ABANDONED_HOST_GRACE` in every other build). A
//! browser host, an app server or a Chief brain still keeps the owner
//! however long no client came.
//!
//! When none holds, it stops as a plain `server stop` does
//! ([`stop_orphaned_owner`]): no terminal is ended (none is live) and no
//! host is signalled. Before the first role-main hello nothing stops it: the
//! process that ran `ensure` is about to connect, and a probe's or a
//! script's `ensure` (which never says `main`) leaves the owner as before.
//!
//! Event-driven, with one deadline: one thread blocks on the terminal topology events
//! (the reaper's filter) and is woken by client arrivals and departures (and
//! a connection's role-main hello), by browser host starts and stops, and by
//! app server starts and stops. Each wake drains what woke it and reads the
//! keepers cheap-first: the client count, the browser host state and the
//! apps supervisor's count; the terminal count (a registry read) runs only
//! when none of those keeps the owner. All of it runs on the watch thread.
//! While terminals are all that keep an owner with no client, the wait also
//! ends at the [`UNATTENDED_TERMINAL_KEEP`] deadline.
//!
//! The headless owner of an app session always starts the watch (cmux-tui
//! `headless.rs`). The stage's switch `CMUX_TUI_OWNER_KEEPERS` is deleted
//! (R-LIFECYCLE ORPHANS turned it on by default; PERF FLAGS removed the off path).

use super::*;
use crate::event_bus::MuxEventReceiver;
use crate::panic_free::RecoverPoison;

/// How long live terminals alone keep an owner no client has reached. A
/// day, the same bound the unowned host reaper gives a live shell of a
/// session that did not start (`mux/unowned_hosts.rs` `LIVE_SHELL_GRACE`):
/// an app that has not connected for a day is taken as gone. Its stop loses
/// nothing (the terminals keep running; the app's next launch starts an
/// owner that adopts them); it only lets the hosts' own orphan grace start.
/// Leo, 2026-11-21, on owners and hosts weeks old: "if it has tons of
/// processes tbats a prkduct bug".
pub(crate) const UNATTENDED_TERMINAL_KEEP: Duration = Duration::from_secs(24 * 60 * 60);

/// Debug builds only (a test seam; release builds ignore it): replaces
/// [`UNATTENDED_TERMINAL_KEEP`], in milliseconds.
#[cfg(debug_assertions)]
const TEST_UNATTENDED_TERMINAL_KEEP_ENV: &str = "CMUX_TUI_TEST_UNATTENDED_TERMINAL_KEEP_MS";

fn unattended_terminal_keep() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(keep) = std::env::var(TEST_UNATTENDED_TERMINAL_KEEP_ENV)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(keep);
    }
    UNATTENDED_TERMINAL_KEEP
}

/// When the owner has had no client since `idle_since` (`None` while one is
/// connected or before the app's first hello): whether `keep` has passed by
/// `now`, and if not, how long until it does.
pub(crate) fn unattended_after(
    idle_since: Option<Instant>,
    now: Instant,
    keep: Duration,
) -> (bool, Option<Duration>) {
    let Some(since) = idle_since else { return (false, None) };
    let idle = now.saturating_duration_since(since);
    if idle >= keep { (true, None) } else { (false, Some(keep - idle)) }
}

/// What keeps an owner running now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Keepers {
    /// A role-main hello came since the owner started.
    pub armed: bool,
    /// Connected clients other than the owner's own journal plugin.
    pub clients: usize,
    /// The running browser host.
    pub browser_host: bool,
    /// Running app server processes.
    pub app_servers: usize,
    /// Supervised Chief brains that run or wait for a start ([`crate::chief_brains`]).
    pub chief_brains: usize,
    /// Terminals that keep the owner (`Mux::kept_terminal_count`: 0 exactly
    /// when none does); `None` when not read (a cheaper keeper held, or the
    /// owner is not armed) or unreadable.
    pub terminals: Option<usize>,
    /// No client has come for [`UNATTENDED_TERMINAL_KEEP`]: live terminals
    /// no longer keep the owner (a read count still must exist).
    pub unattended: bool,
}

impl Keepers {
    /// Whether nothing keeps the owner. An unread or unreadable terminal
    /// count keeps it.
    pub fn none(&self) -> bool {
        self.armed
            && self.clients == 0
            && !self.browser_host
            && self.app_servers == 0
            && self.chief_brains == 0
            && (self.terminals == Some(0) || (self.unattended && self.terminals.is_some()))
    }

    /// Whether every keeper but the terminals is gone, so the terminal count
    /// decides.
    fn terminals_decide(&self) -> bool {
        self.armed
            && self.clients == 0
            && !self.browser_host
            && self.app_servers == 0
            && self.chief_brains == 0
    }
}

/// The keepers of `mux`'s owner now, cheap-first: the registry is read for
/// terminals only when nothing else keeps the owner.
pub(crate) fn owner_keepers(mux: &Mux) -> Keepers {
    let mut keepers = Keepers {
        armed: mux.control_clients.frontend_seen(),
        clients: mux.control_clients.user_client_count(),
        browser_host: mux.control_clients.browser_host.is_running(),
        app_servers: mux.control_clients.apps().kept_servers(),
        chief_brains: mux.chiefs().brains.kept(),
        terminals: None,
        unattended: false,
    };
    if keepers.terminals_decide() {
        keepers.terminals = mux.kept_terminal_count().ok();
    }
    keepers
}

/// What the watch thread and its wakers share. The Chief brain supervisor
/// wakes the watch through the client presence observers when its count
/// changes (`chief_brains.rs` `publish_kept`).
struct Shared {
    stopping: AtomicBool,
    /// The last client arrival or departure: a client was connected then,
    /// even one that came and went between two reads of the watch thread.
    client_presence_at: Mutex<Option<Instant>>,
    /// The thread's event subscription: wakers push into it. Replaced when
    /// its mailbox overflows; `None` once the watch stops.
    events: Mutex<Option<MuxEventReceiver>>,
}

impl Shared {
    fn wake(&self) {
        if let Some(events) = self.events.lock().recover_poison().as_ref() {
            events.wake();
        }
    }
}

/// The running watch; [`OwnerKeepersWatch::stop`] ends and joins it.
pub struct OwnerKeepersWatch {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl OwnerKeepersWatch {
    /// Ends the watch thread and waits for it.
    pub fn stop(mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        if let Some(events) = self.shared.events.lock().recover_poison().take() {
            events.close();
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Starts the watch for `mux`'s owner. The subscription and the wakers exist
/// before the thread reads anything, so no change before its first read is
/// missed. `stopped` runs on the watch thread once the owner is stopping,
/// with the keepers it last read (all gone), for the caller's log.
pub fn watch_owner_keepers(
    mux: &Arc<Mux>,
    stopped: impl FnOnce(&Mux, Keepers) + Send + 'static,
) -> std::io::Result<OwnerKeepersWatch> {
    let shared = Arc::new(Shared {
        stopping: AtomicBool::new(false),
        client_presence_at: Mutex::new(None),
        events: Mutex::new(Some(mux.subscribe_terminal_lifecycle())),
    });
    let waker = |shared: &Arc<Shared>| {
        let shared = Arc::downgrade(shared);
        move || {
            if let Some(shared) = shared.upgrade() {
                shared.wake();
            }
        }
    };
    let presence = Arc::downgrade(&shared);
    mux.add_client_presence_observer(move || {
        if let Some(shared) = presence.upgrade() {
            *shared.client_presence_at.lock().recover_poison() = Some(Instant::now());
            shared.wake();
        }
    });
    mux.control_clients.browser_host.add_state_observer(waker(&shared));
    mux.control_clients.apps().add_server_observer(waker(&shared));
    let owner = Arc::downgrade(mux);
    let watched = shared.clone();
    let thread = std::thread::Builder::new()
        .name("owner-keepers".into())
        .spawn(move || run(&owner, &watched, stopped))?;
    Ok(OwnerKeepersWatch { shared, thread: Some(thread) })
}

fn run(owner: &Weak<Mux>, shared: &Shared, stopped: impl FnOnce(&Mux, Keepers)) {
    let keep = unattended_terminal_keep();
    // Since when no client has been connected (after the app's first hello).
    let mut idle_since: Option<Instant> = None;
    loop {
        if shared.stopping.load(Ordering::Acquire) {
            return;
        }
        let Some(mux) = owner.upgrade() else { return };
        if mux.daemon_shutdown_requested() {
            return;
        }
        // The fence repeats the check: a client or terminal that came since
        // this read keeps the owner.
        let mut keepers = owner_keepers(&mux);
        let now = Instant::now();
        if !keepers.armed || keepers.clients > 0 {
            idle_since = None;
        } else {
            let presence = *shared.client_presence_at.lock().recover_poison();
            idle_since = [idle_since, presence].into_iter().flatten().max().or(Some(now));
        }
        let (unattended, deadline) = unattended_after(idle_since, now, keep);
        keepers.unattended = unattended;
        // The fence's own check refuses while any client is connected, so a
        // client that came since this read keeps the owner.
        if keepers.none()
            && stop_orphaned_owner(&mux, || Keepers { unattended, ..owner_keepers(&mux) }.none())
        {
            stopped(&mux, keepers);
            return;
        }
        // Wait for the deadline only while terminals are what keep the owner.
        let deadline = deadline.filter(|_| keepers.terminals_decide());
        // Never hold the mux across the wait.
        drop(mux);
        let Some(events) = shared.events.lock().recover_poison().clone() else { return };
        let received = match deadline {
            Some(timeout) => match events.recv_timeout(timeout) {
                Ok(event) => Ok(Some(event)),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Ok(None),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(()),
            },
            None => events.recv().map(Some).map_err(|_| ()),
        };
        match received {
            Ok(_) => while events.try_recv().is_ok() {},
            Err(()) => {
                if shared.stopping.load(Ordering::Acquire) {
                    return;
                }
                // The mailbox overflowed: subscribe again, then look again.
                let Some(mux) = owner.upgrade() else { return };
                *shared.events.lock().recover_poison() = Some(mux.subscribe_terminal_lifecycle());
            }
        }
    }
}

#[cfg(test)]
#[path = "owner_keepers_tests.rs"]
mod tests;
