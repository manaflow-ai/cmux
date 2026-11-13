//! The process sessions of the session's terminals, as the accept loop reads
//! them.
//!
//! A terminal's PTY child leads its own process session, so an agent in it,
//! a hook that stays in that session and a `cmux` run in the pane all share it
//! (`getsid`), whatever started the shell (login(1) on macOS, an adopted or
//! held child). A connection from such a process is counted in the terminals'
//! lanes (`ConnectionStats::try_claim_terminal`, #27698).
//!
//! The accept loop read that from the session state when its lock was free,
//! and answered from the last set it had read when the lock was held. In a
//! burst of new terminals the lock is held: a new terminal's first connection
//! was then counted as one from outside the terminals for its whole life, a
//! stream on it never left the short slots, and 63 such streams held every
//! slot of the session while hooks and typed commands were refused.
//!
//! A terminal now takes a seat here when its runtime is made and leaves it
//! when the runtime is dropped ([`TerminalSeat`]). The accept loop asks only
//! this set, under its own lock, held for one insert, remove or lookup. It
//! never reads the session state.
//!
//! A terminal's process starts before the daemon has its process id, so it
//! can connect before the seat is taken. The terminal then takes over its
//! connections at the moment it takes its seat (`seat_terminal`,
//! `ConnectionLease::join_terminal`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use super::ConnectionStats;

/// The seats, by process session. One session can hold two for a moment: a
/// terminal that moves to another host has its old and its new runtime.
#[derive(Default)]
pub(super) struct TerminalSeats {
    seats: Mutex<HashMap<u32, usize>>,
}

impl TerminalSeats {
    fn take(&self, session: u32) {
        let mut seats = self.seats.lock().unwrap_or_else(PoisonError::into_inner);
        let held = seats.entry(session).or_insert(0);
        *held = held.saturating_add(1);
    }

    fn leave(&self, session: u32) {
        let mut seats = self.seats.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(held) = seats.get_mut(&session) {
            *held = held.saturating_sub(1);
            if *held == 0 {
                seats.remove(&session);
            }
        }
    }

    fn holds(&self, session: u32) -> bool {
        self.seats.lock().unwrap_or_else(PoisonError::into_inner).contains_key(&session)
    }
}

/// A terminal's process id and, while this value lives, its seat among the
/// session's terminals. The terminal's runtime owns it, so the seat is held
/// from the moment the runtime is made (before the terminal enters the
/// session state) to its drop.
#[derive(Default)]
#[must_use = "the seat ends when this value is dropped"]
pub struct TerminalSeat {
    process: Option<u32>,
    /// Where the seat is held. Not set: no process, or no session to seat it.
    seated: Option<Arc<ConnectionStats>>,
}

impl TerminalSeat {
    /// The process a terminal's runtime was made for (it leads the terminal's
    /// process session), without a seat: the terminal has no session.
    pub fn unseated(process: Option<u32>) -> Self {
        Self { process, seated: None }
    }

    /// The terminal's process.
    pub fn process_id(&self) -> Option<u32> {
        self.process
    }
}

impl Drop for TerminalSeat {
    fn drop(&mut self) {
        if let (Some(session), Some(connections)) = (self.process, &self.seated) {
            connections.terminal_seats.leave(session);
        }
    }
}

impl ConnectionStats {
    /// The seat of the terminal whose process (and process session) is
    /// `process`. From now on the accept loop counts each connection from
    /// that session as the terminal's.
    ///
    /// The connections that the session opened before this moment were
    /// admitted as ones from outside the terminals: they join the terminal
    /// here (`ConnectionLease::join_terminal`). The seat is taken first, so a
    /// connection admitted at this moment either finds the seat or is found
    /// here (`ConnectionLease::admitted_outside`).
    pub fn seat_terminal(self: &Arc<Self>, process: Option<u32>) -> TerminalSeat {
        let Some(session) = process else { return TerminalSeat::unseated(None) };
        self.terminal_seats.take(session);
        for lease in self.open_leases() {
            lease.join_terminal(session);
        }
        TerminalSeat { process, seated: Some(self.clone()) }
    }

    /// Whether a terminal of the session has its seat for process session
    /// `session`. One lookup under the seats' own lock.
    pub fn terminal_seated(&self, session: u32) -> bool {
        self.terminal_seats.holds(session)
    }

    /// The connections the terminals hold in their short lane now (of
    /// `active`).
    pub fn terminal_active(&self) -> u64 {
        self.terminal_lane.active()
    }
}
