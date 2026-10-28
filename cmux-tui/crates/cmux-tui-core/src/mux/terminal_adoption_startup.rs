//! When a start's adoptions begin, and a request that waits on one: they
//! wait for the owner to say ready (`StartupAdoptions`), except the ones a
//! request waits on, which start at once and go first.

use super::super::*;
use super::{HeldAdoption, REOPEN_ADOPTION_WAIT, STARTUP_READY_WAIT};
use cmux_threads::work::{Lane, Priority, Shutdown};

impl Mux {
    /// Holds a start's adoption of `terminal_id` until the owner says ready
    /// ([`Self::release_startup_adoptions`]), a request waits on it
    /// ([`Self::wait_for_terminal_adoption`]) or [`STARTUP_READY_WAIT`]
    /// passes (a bare test mux never says ready): their registry and state
    /// locks held the rest of the start back (230 ms for 60 hosts).
    pub(in crate::mux) fn hold_startup_adoption(&self, terminal_id: String, start: HeldAdoption) {
        let mut startup = self.startup_adoptions.lock().unwrap_or_else(PoisonError::into_inner);
        if startup.released || startup.now.contains(&terminal_id) {
            drop(startup);
            start(self);
            return;
        }
        startup.held.insert(terminal_id, start);
        let post_deadline = !std::mem::replace(&mut startup.deadline_posted, true);
        drop(startup);
        if post_deadline {
            // Refused: shutdown began, and it releases the held ones itself.
            let _ = self.post_mux_work_after(
                STARTUP_READY_WAIT,
                Priority::UserVisible,
                Lane::Cpu,
                Shutdown::ContinueOnShutdown,
                |mux| {
                    if let Some(mux) = mux.upgrade() {
                        mux.release_startup_adoptions();
                    }
                },
            );
        }
    }

    /// Starts every held start adoption, and every later one at once: the
    /// owner said ready, a creation the crash interrupted waits on its host,
    /// [`STARTUP_READY_WAIT`] passed or shutdown began (each then ends).
    pub(in crate::mux) fn release_startup_adoptions(&self) {
        let held = {
            let mut startup = self.startup_adoptions.lock().unwrap_or_else(PoisonError::into_inner);
            startup.released = true;
            std::mem::take(&mut startup.held)
        };
        for start in held.into_values() {
            start(self);
        }
    }

    /// Waits, at most `bound`, until the adoption of `terminal_id` (a host id)
    /// ended, and has it start at once instead of after the owner says ready,
    /// ahead of every queued adoption (`Permits::promote`). Holds no other
    /// lock while it waits.
    pub(crate) fn wait_for_terminal_adoption(&self, terminal_id: &str, bound: Duration) {
        self.terminal_replays.promote(terminal_id);
        let held = {
            let mut startup = self.startup_adoptions.lock().unwrap_or_else(PoisonError::into_inner);
            startup.now.insert(terminal_id.to_owned());
            startup.held.remove(terminal_id)
        };
        if let Some(start) = held {
            start(self);
        }
        let deadline = Instant::now() + bound;
        let mut adoptions = self.terminal_adoptions.lock().unwrap_or_else(PoisonError::into_inner);
        while adoptions.contains(terminal_id) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            adoptions = cmux_threads::checked::sync::wait_timeout(
                &self.terminal_adoption_ended,
                adoptions,
                left,
            )
            .unwrap_or_else(PoisonError::into_inner)
            .0;
        }
        drop(adoptions);
        self.terminal_replays.demote(terminal_id);
        self.startup_adoptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .now
            .remove(terminal_id);
    }

    /// The running terminal `terminal_id` names, for a reopen that gives it a
    /// new view instead of a new process. A restarted owner answers before it
    /// adopted its surviving terminals (#23561): a terminal that still adopts
    /// is waited for (at most `REOPEN_ADOPTION_WAIT`), not taken for gone.
    #[track_caller]
    pub(crate) fn resolve_running_terminal(&self, terminal_id: &str) -> Option<TerminalResolution> {
        let resolution = self.resolve_terminal(terminal_id).ok().flatten()?;
        let resolution = if resolution.terminal.lifecycle == TerminalLifecycle::Adopting {
            self.wait_for_terminal_adoption(&resolution.terminal.terminal_id, REOPEN_ADOPTION_WAIT);
            self.resolve_terminal(terminal_id).ok().flatten()?
        } else {
            resolution
        };
        (resolution.terminal.lifecycle == TerminalLifecycle::Running).then_some(resolution)
    }
}
