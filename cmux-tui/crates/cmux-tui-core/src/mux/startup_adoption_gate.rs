//! A start's terminal adoptions take turns (perf100 tui lane, cx-p00l3.1).
//!
//! After a daemon start, each surviving terminal host adopts on its own
//! thread once the owner says ready. All of them began at once: 100 threads
//! took the registry and state locks one after another, each committed, and
//! a client request that came in at the same time (the app's first
//! `identify`, `list-workspaces`, the visible terminal's attach) waited
//! behind all of them: 0.96 s of a 1.41 s start for 100 terminals on rbx.
//!
//! The gate lets at most [`STARTUP_ADOPTION_SLOTS`] first attempts run at
//! once, in ticket order: tickets go out in the order the start scheduled
//! them, with the terminals of the workspace the user sees first. Client
//! requests then find the locks free between turns. A first attempt that
//! fails gives its turn back at once and retries on its own schedule, so a
//! slow or dead host never holds a slot past one attempt.

use std::sync::{Condvar, Mutex, PoisonError};

/// First adoption attempts that run at once after a start.
pub(super) const STARTUP_ADOPTION_SLOTS: usize = 8;

#[derive(Default)]
struct GateState {
    next_ticket: u64,
    serving: u64,
    active: usize,
}

#[derive(Default)]
pub(crate) struct StartupAdoptionGate {
    state: Mutex<GateState>,
    changed: Condvar,
}

/// A place in line, taken when the adoption is scheduled.
pub(crate) struct Ticket(u64);

/// A running first attempt; its drop frees the slot.
pub(crate) struct Turn<'a>(&'a StartupAdoptionGate);

impl StartupAdoptionGate {
    pub(super) fn ticket(&self) -> Ticket {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let ticket = state.next_ticket;
        state.next_ticket += 1;
        Ticket(ticket)
    }

    /// Waits for this ticket's turn and a free slot. `give_up` (shutdown)
    /// is checked whenever the gate changes; then no turn is taken.
    pub(super) fn turn(&self, ticket: Ticket, give_up: impl Fn() -> bool) -> Option<Turn<'_>> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if give_up() {
                // Skip this ticket so later ones are not stuck behind it.
                if state.serving == ticket.0 {
                    state.serving += 1;
                    self.changed.notify_all();
                }
                return None;
            }
            if state.serving == ticket.0 && state.active < STARTUP_ADOPTION_SLOTS {
                state.serving += 1;
                state.active += 1;
                self.changed.notify_all();
                return Some(Turn(self));
            }
            state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Wakes waiters so they re-check `give_up` (shutdown).
    pub(super) fn wake_all(&self) {
        let _state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.changed.notify_all();
    }
}

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.active = state.active.saturating_sub(1);
        self.0.changed.notify_all();
    }
}
