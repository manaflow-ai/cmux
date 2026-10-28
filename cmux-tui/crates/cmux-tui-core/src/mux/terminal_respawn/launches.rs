//! How respawns launch: a few at a time, the restored ones in the
//! background, and the one a person waits on first.
//!
//! A cold start respawns every restored terminal (each host is dead after a
//! reboot): 600 shells starting together held the visible ones back. As
//! Chrome's session restore loads the shown tab first and throttles the
//! background tabs it restores (chrome/browser/sessions/tab_loader.cc):
//! - at most [`RESPAWN_LAUNCHES`] respawns launch at once (`Permits`);
//! - a respawn with no runtime in this owner yet (a restored terminal, which
//!   no one has seen since the start) runs at `BestEffort`; one that had a
//!   runtime here (a host lost while it ran, a restart a person asked for)
//!   runs at `UserVisible`, as before;
//! - a request that waits on a respawn ([`Mux::wait_for_terminal_respawn`],
//!   an attach to a tab the app shows) promotes it: it goes before the
//!   queued ones, at `UserBlocking`.

use super::*;
use crate::mux::mux_work::{Permits, Retry};
use cmux_threads::work::{Lane, Priority};

/// Respawns that may launch at once: each spawns a host and its shell and
/// waits for the host's handshake.
const RESPAWN_LAUNCHES: usize = 4;

/// The owner's respawn launches and their waiters.
pub(crate) struct RespawnLaunches {
    permits: Arc<Permits>,
    // Lock carve-out: guards nothing; it pairs `ended` with its waiters. A
    // waiter takes `pending_terminals` (a leaf) under it, never the reverse.
    waits: Mutex<()>,
    /// Notified when a respawn ends (its `Respawning` marker left).
    ended: Condvar,
}

impl Default for RespawnLaunches {
    fn default() -> Self {
        Self {
            permits: Permits::new(RESPAWN_LAUNCHES),
            waits: Mutex::new(()),
            ended: Condvar::new(),
        }
    }
}

impl std::fmt::Debug for RespawnLaunches {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("RespawnLaunches").finish_non_exhaustive()
    }
}

impl Mux {
    /// Posts `pending`'s respawn after `delay`, under the launch permits.
    #[cfg(any(unix, windows))]
    pub(super) fn post_terminal_respawn(
        &self,
        terminal_id: &str,
        delay: Duration,
        mut pending: supervisor::PendingRespawn,
    ) -> Result<(), cmux_threads::work::Refused> {
        let restored = pending
            .plan
            .as_ref()
            .is_some_and(|plan| plan.old_runtime.is_none() && !plan.user_restart);
        let priority = if restored { Priority::BestEffort } else { Priority::UserVisible };
        let launches = &self.terminal_respawns.launches;
        // Dropped unrun (shutdown, or the mux is gone), `PendingRespawn`
        // abandons the attempt.
        self.post_mux_retry_limited(
            delay,
            priority,
            Lane::System,
            (&launches.permits, Some(Arc::from(terminal_id))),
            move |mux| {
                if mux.respawn_stopping() {
                    return Retry::Done;
                }
                let Some(plan) = pending.plan.take() else { return Retry::Done };
                // The launch waits for the new host's handshake.
                cmux_threads::work::will_block(|| mux.run_terminal_respawn(plan));
                Retry::Done
            },
        )
    }

    /// A respawn of `terminal_id` ended: wake the requests waiting on it.
    #[cfg(any(unix, windows))]
    pub(super) fn terminal_respawn_ended(&self) {
        let launches = &self.terminal_respawns.launches;
        drop(launches.waits.lock().unwrap_or_else(PoisonError::into_inner));
        launches.ended.notify_all();
    }

    /// Waits, at most `bound` in all, until the adoption of `terminal_id` (a
    /// host id) and then the respawn that may follow it ended, each first in
    /// its queue: an attach to a restored tab the app shows.
    #[cfg(any(unix, windows))]
    pub(crate) fn wait_for_restored_terminal(&self, terminal_id: &str, bound: Duration) {
        let deadline = Instant::now() + bound;
        self.wait_for_terminal_adoption(terminal_id, bound);
        self.wait_for_terminal_respawn(
            terminal_id,
            deadline.saturating_duration_since(Instant::now()),
        );
    }

    /// Waits, at most `bound`, until the respawn of `terminal_id` (a host id)
    /// ended, and has it launch before the queued ones. Holds no other lock
    /// while it waits.
    #[cfg(any(unix, windows))]
    pub(crate) fn wait_for_terminal_respawn(&self, terminal_id: &str, bound: Duration) {
        let launches = &self.terminal_respawns.launches;
        launches.permits.promote(terminal_id);
        let deadline = Instant::now() + bound;
        let mut waits = launches.waits.lock().unwrap_or_else(PoisonError::into_inner);
        while self.terminal_is_respawning(terminal_id) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            // wakeup-allow: deadline the attach's one bound; the respawn's end wakes it first
            waits = cmux_threads::checked::sync::wait_timeout(&launches.ended, waits, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        drop(waits);
        launches.permits.demote(terminal_id);
    }
}
