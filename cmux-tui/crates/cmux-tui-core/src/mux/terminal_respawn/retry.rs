//! The next try after a failed respawn launch (KEPT RESTORE).
//!
//! A respawn launch can fail for a cause that passes a moment later: macOS
//! refuses a PTY master open for a moment while many open at once, a fork
//! fails at the process limit, a host does not answer in time. Such a launch
//! used to end the terminal as `restart_failed` for good, and the person had
//! to use Restart Shell Here on each dead tab (8 to 16 of 170 kept agent
//! terminals after each app update).
//!
//! The rule, for every respawn worker (a lost host's respawn, a restart, a
//! kept tab of a restored session):
//!
//! - A failed launch commits its end (`restart_failed`, with the cause) as
//!   before, so an owner that stops meanwhile leaves the terminal ended, not
//!   launching. Its tabs keep the respawning mark: they read `adopting`,
//!   never dead, while a next try is on its way.
//! - The supervisor admits the next try (`supervisor.rs`): it waits the
//!   backoff of the terminal's attempts in the last 10 minutes (0 s, 2 s,
//!   10 s, 30 s, 60 s). A try takes a new place at the end of the respawn
//!   gate's line: one with no wait at once, one with a wait when the wait
//!   is over (it holds no place and no turn while it waits). A try for a
//!   terminal the person sees or asked for does not wait for that line, as
//!   its first try did not.
//! - At most [`LAUNCH_SECOND_TRIES`] next tries per restart. After the last
//!   one, or when the supervisor admits no further attempt, the tab shows
//!   the terminal ended with the cause of its last failure, as before.
//! - A launch that found no free PTY (`kern.tty.ptmx_max`) is not tried
//!   again: a full table does not pass by itself. Its tabs are parked or
//!   show the end, as before.
//! - No next try once the owner shuts down, or when the terminal was closed.

use super::*;

/// The next tries of one restart after its first launch failed.
const LAUNCH_SECOND_TRIES: u32 = 3;

impl RespawnPlan {
    /// The plan of the next try, should this launch fail: the same terminal,
    /// tabs and kept rows, with no runtime to replace. [`Mux::plan_launch_retry`]
    /// completes it from the row the failed launch left.
    pub(super) fn after_failed_launch(&self) -> RespawnPlan {
        RespawnPlan {
            terminal_id: self.terminal_id.clone(),
            public_id: self.public_id.clone(),
            old_incarnation: self.old_incarnation.clone(),
            cause: self.cause.clone(),
            slot: self.slot,
            identity: self.identity.clone(),
            old_runtime: None,
            delay: Duration::ZERO,
            recorded: self.recorded.clone(),
            user_restart: self.user_restart,
            asked: self.asked,
            kept: self.kept.clone(),
            screen_incarnation: self.screen_incarnation.clone(),
            failed_launches: self.failed_launches.saturating_add(1),
        }
    }
}

impl Mux {
    /// Decide the next try of a launch that just failed and whose end is
    /// committed, and take the failed launch's dead runtime (one that failed
    /// after it was put in the tabs) out of them, as the other plans do.
    /// `None`: no further try, and the tab shows that end.
    pub(super) fn plan_launch_retry(&self, mut again: RespawnPlan) -> Option<RespawnPlan> {
        if again.failed_launches > LAUNCH_SECOND_TRIES
            || self.shutting_down.load(Ordering::Acquire)
            || self.session_shutdown.began()
        {
            return None;
        }
        // The plans' lock order: registry, pinned state, then the leaf locks.
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        // The row as the failed launch left it: exited, with the incarnation
        // and the receipt the next try must find (`begin_terminal_respawn`).
        // A closed terminal has no exited row, and no tab.
        let record = registry.terminal_record(&again.terminal_id).ok()??;
        let content = ContentPublicId::Terminal(again.public_id.clone());
        let placements = state.placements_of_content(&content).to_vec();
        if record.lifecycle != TerminalLifecycle::Exited || !placements.contains(&again.slot) {
            return None;
        }
        again.delay = self
            .terminal_respawns
            .guard
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit(&again.terminal_id, Instant::now())?;
        again.recorded = TerminalEnd::from_receipt(record.exit.as_ref()).exit().clone();
        again.old_incarnation = record.incarnation;
        again.old_runtime = state.remove_catalog_terminal(&again.public_id);
        for placement in &placements {
            state.surfaces.remove(placement);
        }
        Some(again)
    }
}
