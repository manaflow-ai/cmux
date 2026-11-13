//! The long connections of the session's terminals.
//!
//! A connection from a terminal holds one of the terminals' short places
//! (`ConnectionStats::try_claim_terminal`) from its accept to its end. That is
//! right for a hook or a typed command, which ends in milliseconds. A
//! connection that reads the session's events for hours (`cmux terminal
//! wait`, an MCP watch, a nested cmux) held the same place: 48 of them filled
//! the lane, and every hook and every typed command of every other terminal
//! was refused until one of them closed.
//!
//! So a terminal's connection that starts work that outlives a request (a
//! stream, a wait, a follow) becomes a long one at that moment
//! (`ConnectionLease::become_long`): it takes a place here, then gives back
//! its two short slots. It stays long until it ends; the lease's drop frees
//! the place. The short lane is then full only for the time of short
//! requests.
//!
//! Connections from outside the terminals (the app, a relay, a remote link)
//! are in neither lane and do not change.
//!
//! A connection that came before its terminal had its seat was admitted as
//! an outside one. If it started such work, it takes its place here at the
//! moment the terminal takes its seat (`ConnectionLease::join_terminal`),
//! with no limit: it is open already and cannot be refused then. The lane
//! can thus hold more than its limit while such connections live; each
//! later claim counts them and is refused until the lane is under the limit
//! again.

use super::terminal_lane::TerminalLane;
use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

#[derive(Default)]
pub(super) struct LongConnections {
    lane: TerminalLane,
    /// NEVER MERGE: of the lane, the connections that came in by `enter`, by
    /// terminal. A claim on this branch does not count them.
    early: Mutex<HashMap<u32, u64>>,
}

impl LongConnections {
    /// A long place for a connection of terminal `client`, under `limit` and
    /// within the terminal's fair share (`TerminalLane::claim`).
    pub(super) fn claim(&self, limit: u64, client: Option<u32>) -> Result<(), LongConnectionsFull> {
        // NEVER MERGE: the fault for the proof of the test. The claim's
        // limit grows by the early connections, so it counts only the
        // connections that claimed.
        let early: u64 = self
            .early
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .fold(0u64, |sum, held| sum.saturating_add(*held));
        if self.lane.claim(limit.saturating_add(early), client) {
            Ok(())
        } else {
            Err(LongConnectionsFull { limit })
        }
    }

    /// A long place for a connection that holds its long work already
    /// (`ConnectionLease::join_terminal`): no bound applies, see
    /// `TerminalLane::enter`.
    pub(super) fn enter(&self, client: Option<u32>) {
        if let Some(client) = client {
            let mut early = self.early.lock().unwrap_or_else(PoisonError::into_inner);
            let held = early.entry(client).or_insert(0);
            *held = held.saturating_add(1);
        }
        self.lane.enter(client);
    }

    pub(super) fn release(&self, client: Option<u32>) {
        if let Some(client) = client {
            let mut early = self.early.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(held) = early.get_mut(&client) {
                *held = held.saturating_sub(1);
                if *held == 0 {
                    early.remove(&client);
                }
            }
        }
        self.lane.release(client);
    }

    pub(super) fn active(&self) -> u64 {
        self.lane.active()
    }
}

/// The terminals' long connections are at their bound (or one terminal is at
/// its share of it): the stream, wait or follow that asked was not started.
/// The connection itself stays open and stays a short one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LongConnectionsFull {
    pub limit: u64,
}

impl std::fmt::Display for LongConnectionsFull {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "the terminals of this session hold too many long-lived connections (limit {}); \
             end a `cmux` wait, an MCP watch or a nested cmux in a terminal, then try again",
            self.limit
        )
    }
}

impl std::error::Error for LongConnectionsFull {}

impl super::ConnectionStats {
    /// The terminals' connections that hold a stream, a wait or a follow now.
    /// They are not in `active`.
    pub fn long_active(&self) -> u64 {
        self.long.active()
    }
}
