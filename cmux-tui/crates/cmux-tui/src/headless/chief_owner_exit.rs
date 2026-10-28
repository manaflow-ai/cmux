//! The Chief's conversation owner stops soon after the app that started it
//! exits, when nothing needs it (cp/quit-chief-idle, 2026-10-27: a Cmd-Q
//! left the Chief's owner, its brain host and the host's acpmux running,
//! about 300 MB; from the person's view the same leak as the app's acpmux).
//!
//! The owner of a Chief home's conversations (`cmux-chief-<hash>`,
//! `ChiefHome.session` in the app) holds no terminal of the person's: those
//! are in the app's own daemon, which stays after a quit
//! (plans/cmux-next/quit-persistence.md). Its clients are the app's Home,
//! the Chief's brain host and the brains of the other Chiefs; its state is
//! on disk, and the next app starts it again (`ChiefConversationOwner`).
//! So once the owning app (`CMUX_TUI_OWNER_APP_PID`, which the app sets for
//! this owner too) has exited, it stops after [`OWNER_EXIT_GRACE`] with no
//! client, no live terminal and no live brain of another Chief. A brain host
//! at work (a turn, a subagent, a pending permission) is a client and keeps
//! it: Keep Sessions Running keeps the Chief working, and the owner stops
//! once that host has stopped too (optchat-chief `owner_app.rs`).
//!
//! Not behind `leftoverDaemonIdleExit`, like acpmux's owner exit
//! (`acpmux/src/daemon_lifecycle.rs`): Chromium's child processes end when
//! the browser process goes. Before the app exits nothing is watched but the
//! app's process: one thread blocks in the kernel for its exit
//! ([`OwnerApp::wait_for_exit`], kqueue `NOTE_EXIT` on macOS, a pidfd on
//! Linux), then arms the client watch of `dev_orphan_exit.rs`. A newer app
//! that reuses this owner names itself in `<Chief home>/state/owner-app.pid`
//! ([`owner_app_file`]); at an exit the watch follows it instead. A Chief
//! owner with no owning app (one `cmux chief` started) is unchanged.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use super::dev_orphan_exit::{self, OrphanExit, OrphanFacts, OrphanWatch, SystemClock, Timing};
use acpmux::daemon_lifecycle::{OWNER_EXIT_GRACE, OwnerApp};
use cmux_tui_core::Mux;

/// The session prefix of a Chief home's conversation owner (the app's
/// `ChiefHome.sessionName`, the CLI's `cli/chief/home.rs`).
pub(crate) const CHIEF_SESSION_PREFIX: &str = "cmux-chief-";

/// After the app's exit: the wait with no client, and the wait again after
/// a look that found a live terminal or brain with no client (a brain that
/// starts again after a failure connects within its backoff).
pub(crate) const CHIEF_OWNER_TIMING: Timing =
    Timing { delay: OWNER_EXIT_GRACE, recheck: Duration::from_secs(30) };

/// Whether this owner stops with its app: a Chief owner that an app started.
pub(crate) fn applies(session: &str, owner: OwnerApp) -> bool {
    session.starts_with(CHIEF_SESSION_PREFIX) && owner.is_named()
}

/// The rule past the grace, once the app exited: no live terminal (an
/// unreadable registry keeps the owner) and no live brain.
pub(crate) fn chief_owner_exits(live_terminals: Option<usize>, live_brains: usize) -> bool {
    live_terminals == Some(0) && live_brains == 0
}

/// The Chief owner's facts.
pub(crate) struct ChiefOwnerFacts {
    pub(crate) mux: Weak<Mux>,
    /// `ChiefBrains::live`: the other Chiefs' brains that run or restart.
    pub(crate) brains: Arc<AtomicUsize>,
}

impl OrphanFacts for ChiefOwnerFacts {
    fn clients(&self) -> usize {
        self.mux.upgrade().map_or(0, |mux| mux.client_count())
    }

    fn executable_present(&self) -> bool {
        true
    }

    fn live_terminals(&self) -> Option<usize> {
        self.mux.upgrade()?.live_terminal_count().ok()
    }

    fn exits(&self) -> bool {
        chief_owner_exits(self.live_terminals(), self.brains.load(Ordering::Acquire))
    }
}

/// The watch, disarmed until the app exits.
pub(crate) fn watch(
    clock: Arc<dyn dev_orphan_exit::OrphanClock>,
    facts: Arc<dyn OrphanFacts>,
) -> Arc<OrphanWatch> {
    OrphanWatch::disarmed(clock, facts, CHIEF_OWNER_TIMING)
}

/// The owning app exited: the grace starts (from now when no client is
/// connected, else when the last one leaves).
pub(crate) fn owner_exited(watch: &OrphanWatch) {
    watch.arm();
}

/// `<Chief home>/state/owner-app.pid`, which each app writes before it
/// ensures this owner (`ChiefHome.recordOwnerApp` in the app): the home is
/// the parent of this owner's state root (`ChiefHome.daemonStateDirectory`).
pub(crate) fn owner_app_file(state_root: &Path) -> Option<PathBuf> {
    Some(state_root.parent()?.join("state/owner-app.pid"))
}

/// The app to follow after `gone` exited: the pid `file` names when it is
/// another process that still runs (a newer app that reused this owner).
pub(crate) fn next_owner(
    gone: OwnerApp,
    file: Option<&Path>,
    alive: &dyn Fn(OwnerApp) -> bool,
) -> Option<OwnerApp> {
    let text = cmux_blocking::fs::read_to_string(file?).ok()?;
    let next = OwnerApp::parse(Some(&text));
    (next.is_named() && next != gone && alive(next)).then_some(next)
}

/// One thread blocks in the kernel until `owner` exits, then follows each
/// newer app [`next_owner`] names; once none is left it arms `watch`.
/// Without a watchable owner nothing arms it and the owner stays, as before.
pub(crate) fn watch_owner(owner: OwnerApp, file: Option<PathBuf>, watch: &Arc<OrphanWatch>) {
    let watch = Arc::downgrade(watch);
    let spawned =
        std::thread::Builder::new().name("chief-owner-app-exit".into()).spawn(move || {
            let mut owner = owner;
            loop {
                if !owner.wait_for_exit() {
                    return;
                }
                match next_owner(owner, file.as_deref(), &|app: OwnerApp| app.alive()) {
                    Some(next) => owner = next,
                    None => break,
                }
            }
            if let Some(watch) = watch.upgrade() {
                owner_exited(&watch);
            }
        });
    if let Err(error) = spawned {
        crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: no watch of the owning app ({error}); this Chief owner stays after it quits"
        );
    }
}

/// Starts the exit for a Chief owner an app started; `None` for any other.
pub(crate) fn start_for_owner(mux: &Arc<Mux>, brains: Arc<AtomicUsize>) -> Option<OrphanExit> {
    let owner = OwnerApp::parse(crate::startup_env::owner_app_pid().as_deref());
    if !applies(&mux.session, owner) {
        return None;
    }
    let facts = Arc::new(ChiefOwnerFacts { mux: Arc::downgrade(mux), brains });
    let watch = watch(Arc::new(SystemClock), facts);
    let file =
        cmux_tui_core::platform::workspace_state_dir().and_then(|root| owner_app_file(&root));
    watch_owner(owner, file, &watch);
    let session = mux.session.clone();
    let stopping = Arc::downgrade(mux);
    Some(dev_orphan_exit::spawn("chief-owner-exit", watch, mux, move |facts| {
        let Some(mux) = stopping.upgrade() else { return true };
        let stopped = cmux_tui_core::server::stop_orphaned_owner(&mux, || facts.exits());
        if stopped {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: stopped Chief owner {session}: its app quit and no client, terminal or brain needs it"
            );
        }
        stopped
    }))
}

#[cfg(test)]
#[path = "chief_owner_exit_tests.rs"]
mod tests;
