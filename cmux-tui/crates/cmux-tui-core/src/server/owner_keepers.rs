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
//! - a live terminal (launching, adopting or running): this includes a
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
//! When none holds, it stops as a plain `server stop` does
//! ([`stop_orphaned_owner`]): no terminal is ended (none is live) and no
//! host is signalled. Before the first role-main hello nothing stops it: the
//! process that ran `ensure` is about to connect, and a probe's or a
//! script's `ensure` (which never says `main`) leaves the owner as before.
//!
//! Event-driven, no timer: one thread blocks on the terminal topology events
//! (the reaper's filter) and is woken by client arrivals and departures (and
//! a connection's role-main hello), by browser host starts and stops, and by
//! app server starts and stops. Each wake drains what woke it and reads the
//! keepers cheap-first: the client count, the browser host state and the
//! apps supervisor's count; the terminal count (a registry read) runs only
//! when none of those keeps the owner. All of it runs on the watch thread.
//!
//! The headless owner starts the watch (cmux-tui `headless.rs`) unless
//! `CMUX_TUI_OWNER_KEEPERS=0`, the stage's switch, which is deleted when the
//! stage has passed dogfood (R-LIFECYCLE ORPHANS turned it on by default).

use super::*;
use crate::event_bus::MuxEventReceiver;
use crate::panic_free::RecoverPoison;

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
            && self.terminals == Some(0)
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
    mux.add_client_presence_observer(waker(&shared));
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
        let keepers = owner_keepers(&mux);
        if keepers.none() && stop_orphaned_owner(&mux, || owner_keepers(&mux).none()) {
            stopped(&mux, keepers);
            return;
        }
        // Never hold the mux across the wait.
        drop(mux);
        let Some(events) = shared.events.lock().recover_poison().clone() else { return };
        match events.recv() {
            Ok(_) => while events.try_recv().is_ok() {},
            Err(_) => {
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
mod tests {
    use super::Keepers;

    fn idle() -> Keepers {
        Keepers {
            armed: true,
            clients: 0,
            browser_host: false,
            app_servers: 0,
            chief_brains: 0,
            terminals: Some(0),
        }
    }

    #[test]
    fn an_armed_owner_with_nothing_kept_may_stop() {
        assert!(idle().none());
    }

    #[test]
    fn an_owner_its_app_never_reached_is_kept() {
        assert!(!Keepers { armed: false, ..idle() }.none());
    }

    #[test]
    fn each_keeper_alone_keeps_the_owner() {
        assert!(!Keepers { clients: 1, ..idle() }.none());
        assert!(!Keepers { browser_host: true, ..idle() }.none());
        assert!(!Keepers { app_servers: 1, ..idle() }.none());
        assert!(!Keepers { chief_brains: 1, ..idle() }.none());
        assert!(!Keepers { terminals: Some(1), ..idle() }.none());
    }

    #[test]
    fn an_unread_terminal_count_keeps_the_owner() {
        assert!(!Keepers { terminals: None, ..idle() }.none());
    }

    #[test]
    fn terminals_are_read_only_when_nothing_cheaper_keeps_the_owner() {
        assert!(idle().terminals_decide());
        assert!(!Keepers { armed: false, ..idle() }.terminals_decide());
        assert!(!Keepers { clients: 1, ..idle() }.terminals_decide());
        assert!(!Keepers { browser_host: true, ..idle() }.terminals_decide());
        assert!(!Keepers { app_servers: 2, ..idle() }.terminals_decide());
        assert!(!Keepers { chief_brains: 1, ..idle() }.terminals_decide());
    }
}
