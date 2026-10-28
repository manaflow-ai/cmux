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
//! - a request that waits on a respawn ([`Mux::wait_for_restored_terminal`],
//!   an attach to a tab the app shows) promotes it before its end commits:
//!   it is posted at `UserBlocking` and goes before the queued ones. It does
//!   not wait for a respawn whose backoff ends after its bound.

use super::*;
use crate::mux::mux_work::{Permits, Retry};
use cmux_threads::work::{Lane, Priority};

/// Respawns that may launch at once: each spawns a host and its shell and
/// waits for the host's handshake.
const RESPAWN_LAUNCHES: usize = 4;

/// The owner's respawn launches and their waiters.
pub(crate) struct RespawnLaunches {
    permits: Arc<Permits>,
    /// When each posted respawn is due to launch (its backoff's end), by host
    /// id; it pairs `ended` with its waiters. A waiter takes
    /// `pending_terminals` (a leaf) under it, never the reverse.
    due: Mutex<HashMap<String, Instant>>,
    /// Notified when a respawn ends (its `Respawning` marker left).
    ended: Condvar,
}

impl Default for RespawnLaunches {
    fn default() -> Self {
        Self {
            permits: Permits::new(RESPAWN_LAUNCHES),
            due: Mutex::default(),
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
        launches
            .due
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal_id.to_owned(), Instant::now() + delay);
        // Dropped unrun (shutdown, or the mux is gone), `PendingRespawn`
        // abandons the attempt. A waiter that promoted the key first
        // (`wait_for_restored_terminal`) has it posted at `UserBlocking`.
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
    pub(super) fn terminal_respawn_ended(&self, terminal_id: &str) {
        let launches = &self.terminal_respawns.launches;
        launches.due.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
        launches.ended.notify_all();
    }

    /// Waits, at most `bound` in all, until the adoption of `terminal_id` (a
    /// host id) and then the respawn that may follow it ended, each first in
    /// its queue: an attach to a restored tab the app shows.
    #[cfg(any(unix, windows))]
    pub(crate) fn wait_for_restored_terminal(&self, terminal_id: &str, bound: Duration) {
        let deadline = Instant::now() + bound;
        // Promoted before the end commits: the respawn that end posts runs
        // at `UserBlocking` and ahead of the queued launches. Posted at its
        // background priority first, it waited in the System lane behind
        // every queued end (cp/restore-cold-start review, item 1).
        let launches = &self.terminal_respawns.launches;
        launches.permits.promote(terminal_id);
        self.wait_for_terminal_adoption(terminal_id, bound);
        self.wait_for_promoted_respawn(terminal_id, deadline);
        launches.permits.demote(terminal_id);
    }

    /// Waits, until `deadline`, for the respawn of `terminal_id` (a host id)
    /// whose launch key the caller promoted. Returns at once when that
    /// respawn is due only after `deadline` (its backoff: 2, 10, 30 or 60 s
    /// after a repeated loss): waiting could not see it. Holds no other lock
    /// while it waits.
    #[cfg(any(unix, windows))]
    fn wait_for_promoted_respawn(&self, terminal_id: &str, deadline: Instant) {
        let launches = &self.terminal_respawns.launches;
        let mut due = launches.due.lock().unwrap_or_else(PoisonError::into_inner);
        while self.terminal_is_respawning(terminal_id) {
            if due.get(terminal_id).is_some_and(|at| *at > deadline) {
                break;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            // wakeup-allow: deadline the attach's one bound; the respawn's end wakes it first
            due = cmux_threads::checked::sync::wait_timeout(&launches.ended, due, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}
