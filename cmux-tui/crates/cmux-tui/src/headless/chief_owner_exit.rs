//! The Chief's conversation owner stops soon after the app that started it
//! has gone, when nothing needs it (cp/quit-chief-idle, 2026-10-27: a Cmd-Q
//! left the Chief's owner, its brain host and the host's acpmux running,
//! about 300 MB; from the person's view the same leak as the app's acpmux).
//!
//! The owner of a Chief home's conversations (`cmux-chief-<hash>`,
//! `ChiefHome.session` in the app) holds no terminal of the person's: those
//! are in the app's own daemon, which stays after a quit
//! (plans/cmux-next/quit-persistence.md). Its clients are the app's Home,
//! the Chief's brain host and the brains of the other Chiefs; its state is
//! on disk, and the next app starts it again (`ChiefConversationOwner`).
//!
//! It follows the stop rule every app helper follows (`cmux-owner-liveness`,
//! principled audit lagQuitHelpers, 2026-10-29): it stops when it has no
//! client, no live owner app and no live work (a live terminal, or a live
//! brain of another Chief), once that has held for [`OWNER_EXIT_GRACE`]. A
//! brain host at work (a turn, a subagent, a pending permission) is a client
//! and keeps it: Keep Sessions Running keeps the Chief working, and the
//! owner stops once that host has stopped too (optchat-chief `owner_app.rs`).
//!
//! The owner app (`CMUX_TUI_OWNER_APP_PID`, which the app sets for this owner
//! too) is a level ([`OwnerLiveness`]): one kernel handle follows it, and
//! when it has exited, a newer app that reused this owner and named itself in
//! `<Chief home>/state/owner-app.pid` ([`owner_app_file`]) is followed
//! instead, also when it started after the quit. Not behind
//! `leftoverDaemonIdleExit`, like acpmux's owner exit: Chromium's child
//! processes end when the browser process goes. A Chief owner with no owning
//! app (one `cmux chief` started) is unchanged.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use super::dev_orphan_exit::{self, OrphanExit, OrphanFacts, OrphanWatch, SystemClock, Timing};
use cmux_owner_liveness::{Keeps, OWNER_EXIT_GRACE, OwnerApp, OwnerLiveness, OwnerState, Watch};
use cmux_tui_core::Mux;

/// The session prefix of a Chief home's conversation owner (the app's
/// `ChiefHome.sessionName`, the CLI's `cli/chief/home.rs`).
pub(crate) const CHIEF_SESSION_PREFIX: &str = "cmux-chief-";

/// The wait with no client and nothing else that keeps the owner, and the
/// wait again after a look that found a live terminal or brain with no
/// client (a brain that starts again after a failure connects within its
/// backoff). While only the owner app keeps it, the watch waits for that
/// app's exit instead (the kernel reports it).
pub(crate) const CHIEF_OWNER_TIMING: Timing =
    Timing { delay: OWNER_EXIT_GRACE, recheck: Duration::from_secs(30) };

/// Whether this owner stops with its app: a Chief owner that an app started.
pub(crate) fn applies(session: &str, owner: OwnerApp) -> bool {
    session.starts_with(CHIEF_SESSION_PREFIX) && owner.is_named()
}

/// What keeps the owner, from current truth: an unreadable terminal
/// registry counts as live work.
pub(crate) fn chief_owner_keeps(
    clients: usize,
    owner: OwnerState,
    live_terminals: Option<usize>,
    live_brains: usize,
) -> Keeps {
    Keeps { clients: clients > 0, owner, live_work: live_terminals != Some(0) || live_brains > 0 }
}

/// The Chief owner's facts.
pub(crate) struct ChiefOwnerFacts {
    pub(crate) mux: Weak<Mux>,
    /// `ChiefBrains::live`: the other Chiefs' brains that run or restart.
    pub(crate) brains: Arc<AtomicUsize>,
    pub(crate) owner: Arc<OwnerLiveness>,
}

impl ChiefOwnerFacts {
    /// What keeps the owner now.
    pub(crate) fn keeps(&self) -> Keeps {
        chief_owner_keeps(
            self.clients(),
            self.owner.state(),
            self.live_terminals(),
            self.brains.load(Ordering::Acquire),
        )
    }
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
        // A Chief owner no app named never gets here (`applies`).
        self.keeps().exits(true)
    }

    fn kept_by_reported_fact(&self) -> bool {
        // Without a follow thread the owner's exit is not reported: the watch
        // looks again after its recheck interval.
        self.owner.state() == OwnerState::Alive && self.owner.reports_changes()
    }
}

/// The watch: the owner follows its app's exit as a fact (the follow thread
/// calls [`OrphanWatch::facts_changed`]).
pub(crate) fn watch(
    clock: Arc<dyn dev_orphan_exit::OrphanClock>,
    facts: Arc<dyn OrphanFacts>,
    owner: &OwnerLiveness,
) -> Arc<OrphanWatch> {
    let watch = OrphanWatch::with_timing(clock, facts, CHIEF_OWNER_TIMING);
    let observer = Arc::downgrade(&watch);
    owner.observe(move || {
        if let Some(watch) = observer.upgrade() {
            watch.facts_changed();
        }
    });
    watch
}

/// `<Chief home>/state/owner-app.pid`, which each app writes before it
/// ensures this owner (`ChiefHome.recordOwnerApp` in the app): the home is
/// the parent of this owner's state root (`ChiefHome.daemonStateDirectory`).
pub(crate) fn owner_app_file(state_root: &Path) -> Option<PathBuf> {
    Some(state_root.parent()?.join("state/owner-app.pid"))
}

/// Follows `app` (then each newer app `file` names) for `owner`; logs when
/// no kernel handle follows it.
pub(crate) fn follow(owner: &OwnerLiveness, app: OwnerApp) {
    match owner.follow(app) {
        Watch::Polled(error) => crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: the owning app is checked every second (no kernel handle: {error})"
        ),
        Watch::Unwatched(error) => crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: no watch of the owning app ({error}); its exit is read at the next change"
        ),
        Watch::Unnamed | Watch::Kernel | Watch::Gone => {}
    }
}

/// Starts the exit for a Chief owner an app started; `None` for any other.
pub(crate) fn start_for_owner(mux: &Arc<Mux>, brains: Arc<AtomicUsize>) -> Option<OrphanExit> {
    let app = OwnerApp::parse(crate::startup_env::owner_app_pid().as_deref());
    if !applies(&mux.session, app) {
        return None;
    }
    let file =
        cmux_tui_core::platform::workspace_state_dir().and_then(|root| owner_app_file(&root));
    let owner = OwnerLiveness::new(file);
    let facts =
        Arc::new(ChiefOwnerFacts { mux: Arc::downgrade(mux), brains, owner: owner.clone() });
    let watch = watch(Arc::new(SystemClock), facts.clone(), &owner);
    follow(&owner, app);
    let session = mux.session.clone();
    let stopping = Arc::downgrade(mux);
    Some(dev_orphan_exit::spawn("chief-owner-exit", watch, mux, move |_| {
        let Some(mux) = stopping.upgrade() else { return true };
        // What the fence decided on (the owner and the work, read once there).
        let decided = std::cell::Cell::new(None);
        let stopped = cmux_tui_core::server::stop_orphaned_owner(&mux, || {
            let keeps = facts.keeps();
            decided.set(Some(keeps));
            keeps.exits(true)
        });
        if stopped && let Some(keeps) = decided.get() {
            // The clients read again after the fenced stop: none can come now.
            let keeps = Keeps { clients: facts.clients() > 0, ..keeps };
            cmux_owner_liveness::check("chief owner", true, keeps, true);
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
