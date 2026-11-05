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
use std::sync::atomic::{AtomicUsize, Ordering};
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
    /// Counts every wake-up, so a waiter that checked outside the lock
    /// ([`StartupAdoptionGate::turn_first_if`]) sees one it would have missed.
    wakes: u64,
    /// Waiters the person now sees: they take the next free slot before any
    /// ticket in line ([`StartupAdoptionGate::turn_first_if`]).
    first: usize,
}

impl GateState {
    fn skip_abandoned(&mut self) {
        while self.abandoned.remove(&self.serving) {
            self.serving += 1;
        }
    }
}

/// Also the respawn gate after a kill of everything (`Mux::respawn_gate`,
/// mux/terminal_respawn.rs), with its own slot count.
pub(crate) struct StartupAdoptionGate {
    state: Mutex<GateState>,
    changed: Condvar,
    slots: usize,
    /// Threads in [`Self::turn`] or [`Self::turn_first_if`]: a wake-up with
    /// none waiting takes no lock ([`Self::wake_waiters`]).
    waiting: AtomicUsize,
}

impl Default for StartupAdoptionGate {
    fn default() -> Self {
        Self::with_slots(STARTUP_ADOPTION_SLOTS)
    }
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
        state.wakes += 1;
        self.gate.changed.notify_all();
    }
}

/// A running first attempt; its drop frees the slot.
pub(crate) struct Turn<'a>(&'a StartupAdoptionGate);

impl StartupAdoptionGate {
    /// A gate that lets `slots` turns run at once (at least one).
    pub(super) fn with_slots(slots: usize) -> Self {
        Self {
            state: Mutex::default(),
            changed: Condvar::new(),
            slots: slots.max(1),
            waiting: AtomicUsize::new(0),
        }
    }

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
    pub(super) fn turn(&self, ticket: Ticket, give_up: impl Fn() -> bool) -> Option<Turn<'_>> {
        self.turn_first_if(ticket, give_up, || false)
    }

    /// [`Self::turn`], and once `first` holds the waiter takes the next free
    /// slot before every ticket in line (the person now sees its terminal).
    /// It still takes a slot: the slots bound the waiters that go first too.
    /// Once `first` held the waiter keeps its priority, also if the person
    /// looks away again (bounded: it still waits for a slot).
    /// `first` runs with the gate's lock released (it may take the mux's
    /// locks), at the start and after each wake-up, until it holds; a wake-up
    /// while it runs is not lost (the waiter checks again before it sleeps).
    pub(super) fn turn_first_if(
        &self,
        mut ticket: Ticket,
        give_up: impl Fn() -> bool,
        first: impl Fn() -> bool,
    ) -> Option<Turn<'_>> {
        self.waiting.fetch_add(1, Ordering::AcqRel);
        let _waiting = WaitingGuard(&self.waiting);
        let mut goes_first = false;
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if give_up() {
                if goes_first {
                    state.first -= 1;
                    state.wakes += 1;
                    self.changed.notify_all();
                }
                // The ticket's drop gives its place up.
                drop(state);
                return None;
            }
            let admitted = state.active < self.slots
                && (goes_first || (state.first == 0 && state.serving == ticket.number));
            if admitted {
                ticket.used = true;
                if goes_first {
                    state.first -= 1;
                }
                // Out of order (a waiter that goes first): `serving` steps over
                // this place when it gets there.
                if state.serving == ticket.number {
                    state.serving += 1;
                } else {
                    state.abandoned.insert(ticket.number);
                }
                state.skip_abandoned();
                state.active += 1;
                state.wakes += 1;
                self.changed.notify_all();
                return Some(Turn(self));
            }
            if !goes_first {
                let wakes = state.wakes;
                drop(state);
                let now_first = first();
                state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
                if now_first {
                    goes_first = true;
                    state.first += 1;
                    continue;
                }
                if state.wakes != wakes {
                    continue;
                }
            }
            state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Wakes waiters so they re-check `give_up` (shutdown, a waited-on terminal).
    pub(super) fn wake_all(&self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.wakes += 1;
        self.changed.notify_all();
    }

    /// [`Self::wake_all`] when a thread waits; otherwise one atomic load and
    /// no lock (it runs on every tree change).
    pub(super) fn wake_waiters(&self) {
        if self.waiting.load(Ordering::Acquire) > 0 {
            self.wake_all();
        }
    }
}

struct WaitingGuard<'a>(&'a AtomicUsize);

impl Drop for WaitingGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.active = state.active.saturating_sub(1);
        state.wakes += 1;
        self.0.changed.notify_all();
    }
}
