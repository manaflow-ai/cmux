//! The restarts that are not started yet, and what starts or holds them.
//!
//! A restore of a session restarts every kept agent terminal, each in its
//! turn of the respawn gate's line (`worker.rs`). The person's session had
//! 170 of them: the restore started all 170 again on a Mac that then had no
//! memory left for what the person did (34 GB resident on a 48 GB bench
//! Mac, measured). So:
//!
//! - With no memory pressure nothing changes: every kept agent starts again
//!   by itself, a turn at a time.
//! - While the kernel's memory pressure level is above normal, the line is
//!   stopped: the restarts that have a turn go on, the others stay "not
//!   started". When the level is normal again the line goes on by itself.
//!   It is not one decision at launch.
//! - A restart that is not started yet starts at once, in front of the
//!   line and also while the line is stopped, when somebody needs its
//!   terminal ([`Mux::start_waiting_respawn_now`]): the person shows it
//!   or asks for it again (`restart-tab`, `manual.rs`).
//!
//! Chromium's session restore stops its tab loader under memory pressure
//! too (`TabLoader::OnMemoryPressure`, `tab_loader.cc`) and loads a tab that
//! was not loaded when the person selects it. cmux differs in one point:
//! Chrome's stop is final for that restore, and here the line goes on when
//! the pressure ends, because other agents write to an agent in a hidden
//! workspace and it must not stay stopped for the rest of the session.
//!
//! The level is read on macOS only; on other systems the line never stops.

use super::*;

impl TerminalRespawns {
    /// A restart of `terminal_id` waits for its turn from now on.
    pub(super) fn wait_in_line(&self, terminal_id: &str) {
        self.waiting
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(terminal_id.to_string())
            .or_insert(false);
    }

    /// The restart of `terminal_id` waits no longer (it has its turn, or it
    /// was given up). True when somebody needed the terminal while it
    /// waited.
    pub(super) fn left_line(&self, terminal_id: &str) -> bool {
        self.waiting
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id)
            .unwrap_or(false)
    }

    /// Whether somebody needed `terminal_id` while its restart waits. A leaf
    /// lock: the gate's waiters read it with no other lock held.
    pub(super) fn needed_now(&self, terminal_id: &str) -> bool {
        self.waiting
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(terminal_id)
            .copied()
            .unwrap_or(false)
    }

    /// Mark the waiting restart of `terminal_id` as needed. False when no
    /// restart of it waits.
    fn need(&self, terminal_id: &str) -> bool {
        match self.waiting.lock().unwrap_or_else(PoisonError::into_inner).get_mut(terminal_id) {
            Some(needed) => {
                *needed = true;
                true
            }
            None => false,
        }
    }
}

impl Mux {
    /// Somebody needs the terminal `terminal_id` whose restart is not
    /// started yet: it takes its turn at once, in front of the respawn
    /// gate's line and also while the line is stopped. False when no restart
    /// of it waits (it runs, it has its turn, or it is dead with no restart).
    pub(in crate::mux) fn start_waiting_respawn_now(&self, terminal_id: &str) -> bool {
        let waits = self.terminal_respawns.need(terminal_id);
        if waits {
            self.respawn_gate.wake_all();
        }
        waits
    }

    /// Stop the respawn gate's line while the memory pressure is above
    /// normal, from the first restart of this owner on (an owner that
    /// restarts nothing watches nothing).
    pub(super) fn hold_respawn_line_under_memory_pressure(&self) {
        #[cfg(target_os = "macos")]
        self.terminal_respawns.pressure_watch.get_or_init(|| {
            // One read and one write of the gate at a time, so the level
            // read last is the one the gate keeps. Poison is not unwrapped:
            // the handler runs in a C callback.
            let order = Arc::new(Mutex::new(()));
            let gate = Arc::downgrade(&self.respawn_gate);
            let handler_order = Arc::clone(&order);
            crate::mux::memory_pressure::watch(move |event_says_above| {
                let Some(gate) = gate.upgrade() else { return };
                let _one = handler_order.lock().unwrap_or_else(PoisonError::into_inner);
                let above = crate::mux::memory_pressure::above_normal_now();
                gate.set_line_paused(above.unwrap_or(event_says_above));
            });
            // The source reports changes only: read the level that holds now.
            let _one = order.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(above) = crate::mux::memory_pressure::above_normal_now() {
                self.respawn_gate.set_line_paused(above);
            }
        });
    }
}
