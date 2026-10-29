//! A leftover headless owner exits (behind the default-off
//! `leftoverDaemonIdleExit` feature in `schemas/features/features.d`).
//!
//! With the feature on, a headless owner stops once it has had, for
//! [`IDLE_EXIT_GRACE`], no client of any kind, no live terminal (own PTYs and
//! holder-hosted ones alike: every launching, adopting or running terminal in
//! the registry), no live agent (a Chief brain supervisor counts as one) and
//! no owning app (`CMUX_TUI_OWNER_APP_PID`, taken at start by
//! `startup_env.rs`). An app that restarts for an update reconnects within
//! the grace and keeps the owner. The stop is the DEV orphan
//! exit's (`server::stop_orphaned_owner`): fenced against a client that
//! connects meanwhile, and it ends no terminal.
//!
//! Chromium ends a process host the same way once nothing refers to it
//! (`content/browser/renderer_host/render_process_host_impl.cc`,
//! `RenderProcessHostImpl::Cleanup`); acpmux has the same rule
//! (`acpmux/src/daemon_lifecycle.rs`).
//!
//! The watcher is the DEV orphan exit's (`headless/dev_orphan_exit.rs`): one
//! thread woken by client arrivals and departures or by its deadline on an
//! injected clock. Past the grace with something still live it looks again
//! one grace later.

use std::sync::{Arc, Weak};
use std::time::Duration;

use super::dev_orphan_exit::{self, OrphanExit, OrphanFacts, OrphanWatch, SystemClock, Timing};
use acpmux::daemon_lifecycle::OwnerApp;
use cmux_tui_core::Mux;

/// How long the owner stays with nothing that needs it.
pub(crate) const IDLE_EXIT_GRACE: Duration = acpmux::daemon_lifecycle::IDLE_EXIT_GRACE;

/// The watcher's intervals: the grace, and the grace again after a look that
/// found something live.
pub(crate) const IDLE_TIMING: Timing = Timing { delay: IDLE_EXIT_GRACE, recheck: IDLE_EXIT_GRACE };

/// The rule past the grace: nothing live and no owning app. An unreadable
/// terminal registry keeps the owner.
pub(crate) fn idle_exits(
    live_terminals: Option<usize>,
    live_agents: bool,
    owner_alive: bool,
) -> bool {
    live_terminals == Some(0) && !live_agents && !owner_alive
}

/// The headless owner's facts.
pub(crate) struct IdleFacts {
    pub(crate) mux: Weak<Mux>,
    /// A Chief brain supervisor runs: its brains are agents.
    pub(crate) chief_brains: bool,
    pub(crate) owner: OwnerApp,
}

impl OrphanFacts for IdleFacts {
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
        idle_exits(self.live_terminals(), self.chief_brains, self.owner.alive())
    }
}

/// Whether `leftoverDaemonIdleExit` is on for this owner (off on every
/// channel by default; `CMUX_ENABLE_FEATURES` turns it on).
fn enabled() -> bool {
    crate::feature_flags::daemon_features()
        .is_enabled(cmux_features::feature::LEFTOVER_DAEMON_IDLE_EXIT)
}

/// Starts the idle exit for a headless owner when the feature is on.
pub(crate) fn start_for_owner(mux: &Arc<Mux>, chief_brains: bool) -> Option<OrphanExit> {
    if !enabled() {
        return None;
    }
    let owner = OwnerApp::parse(crate::startup_env::owner_app_pid().as_deref());
    let facts = Arc::new(IdleFacts { mux: Arc::downgrade(mux), chief_brains, owner });
    let watch = OrphanWatch::with_timing(Arc::new(SystemClock), facts, IDLE_TIMING);
    let session = mux.session.clone();
    let stopping = Arc::downgrade(mux);
    Some(dev_orphan_exit::spawn("idle-exit", watch, mux, move |facts| {
        let Some(mux) = stopping.upgrade() else { return true };
        let stopped = cmux_tui_core::server::stop_orphaned_owner(&mux, || facts.exits());
        if stopped {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: stopped idle owner {session} (no client, terminal, agent or app for {} min)",
                IDLE_EXIT_GRACE.as_secs() / 60
            );
        }
        stopped
    }))
}

#[cfg(test)]
#[path = "server_lifecycle_tests.rs"]
mod idle_exit_tests;
