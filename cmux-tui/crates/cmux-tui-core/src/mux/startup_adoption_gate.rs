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
//! slow or dead host never holds a slot past one attempt. A terminal that a
//! request waits on (a reopen, `wait_for_terminal_adoption`) gives its place
//! up and adopts at once, without a turn.

use std::collections::BTreeSet;
use std::sync::{Arc, Condvar, Mutex, PoisonError};

/// First adoption attempts that run at once after a start.
pub(super) const STARTUP_ADOPTION_SLOTS: usize = 8;

#[derive(Default)]
struct GateState {
    next_ticket: u64,
    serving: u64,
    active: usize,
    /// Tickets dropped before their turn (a thread that never started, an
    /// adoption that ended first); `serving` steps over them.
    abandoned: BTreeSet<u64>,
}

impl GateState {
    fn skip_abandoned(&mut self) {
        while self.abandoned.remove(&self.serving) {
            self.serving += 1;
        }
    }
}

#[derive(Default)]
pub(crate) struct StartupAdoptionGate {
    state: Mutex<GateState>,
    changed: Condvar,
}

/// A place in line, taken when the adoption is scheduled. Dropping it before
/// its turn gives the place up, so no later ticket waits on it.
pub(crate) struct Ticket {
    number: u64,
    gate: Arc<StartupAdoptionGate>,
    used: bool,
}

impl Drop for Ticket {
    fn drop(&mut self) {
        if self.used {
            return;
        }
        let mut state = self.gate.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.serving == self.number {
            state.serving += 1;
        } else if self.number > state.serving {
            state.abandoned.insert(self.number);
        }
        state.skip_abandoned();
        self.gate.changed.notify_all();
    }
}

/// A running first attempt; its drop frees the slot.
pub(crate) struct Turn<'a>(&'a StartupAdoptionGate);

impl StartupAdoptionGate {
    pub(super) fn ticket(self: &Arc<Self>) -> Ticket {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let number = state.next_ticket;
        state.next_ticket += 1;
        Ticket { number, gate: self.clone(), used: false }
    }

    /// Waits for this ticket's turn and a free slot. `give_up` (shutdown, or
    /// a request waits on this terminal) is checked whenever the gate changes
    /// or [`Self::wake_all`] runs; then no turn is taken. It runs under the
    /// gate's lock, so it may take only leaf locks.
    pub(super) fn turn(&self, mut ticket: Ticket, give_up: impl Fn() -> bool) -> Option<Turn<'_>> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if give_up() {
                // The ticket's drop gives its place up.
                drop(state);
                return None;
            }
            if state.serving == ticket.number && state.active < STARTUP_ADOPTION_SLOTS {
                ticket.used = true;
                state.serving += 1;
                state.skip_abandoned();
                state.active += 1;
                self.changed.notify_all();
                return Some(Turn(self));
            }
            state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Wakes waiters so they re-check `give_up` (shutdown, a waited-on terminal).
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
