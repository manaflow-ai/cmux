//! A connection's slot, taken back when its client hangs up.
//!
//! The daemon admits `limit` connections at once, each served on its own
//! thread. A thread parked on the registry lock (held for tens of seconds by a
//! maintenance pass or a commit on a loaded Mac) outlives its client: the CLI
//! gave up, the slot stayed taken, and once dead clients held every slot the
//! app's own reconnects were refused `server.busy` (#27669). At the limit,
//! `ConnectionStats::try_claim` asks each watched connection whether its client
//! closed; one that did moves to a hung-up pool and its slot serves the next
//! client. The pool is bounded by the same limit, so connection threads stay
//! bounded at twice it. The thread itself is untouched: it finishes its request
//! and exits as before.
//!
//! On macOS `poll` reports a hang-up as soon as the read side is at EOF, so a
//! client that only shut down its writing half (`cmux-tui relay`) also moves to
//! the pool. It is still served to the end; only its slot is counted in the
//! pool instead of the limit. Linux reports it once both halves are closed.

use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, PoisonError, Weak};

use super::{ConnectionStats, LongConnectionsFull};

/// The connection holds its slot of the limit (and, from a terminal, a slot
/// of the terminals' short lane).
const SHORT: u8 = 0;
/// The client hung up: the slots went back, the connection is in the hung-up
/// pool until its thread ends.
const HUNG_UP: u8 = 1;
/// A terminal's connection that holds a stream, a wait or a follow: the slots
/// went back, it holds a place among the long connections
/// (`long_connections`) until it ends.
const LONG: u8 = 2;

/// Whether the client at the other end closed its socket. Polled without
/// blocking, from the accept loop.
pub type PeerClosed = Box<dyn Fn() -> bool + Send + Sync>;

/// One admitted connection's slot. Dropping it frees the slot, or its place in
/// the hung-up pool once the slot was taken back, or its place among the long
/// connections once it became one.
pub struct ConnectionLease {
    stats: Arc<ConnectionStats>,
    /// `SHORT`, then at most one change, to `HUNG_UP` or to `LONG`.
    state: AtomicU8,
    peer_closed: Option<PeerClosed>,
    /// Also holds a terminal slot (`ConnectionStats::try_claim_terminal`,
    /// #27698), given back with the main slot; inside, the terminal it came
    /// from (nil when unknown).
    terminal: Option<Option<u32>>,
}

impl ConnectionLease {
    /// The lease of a slot `stats.try_claim` just gave (and, with `terminal`, a
    /// terminal slot `stats.try_claim_terminal` gave). With `peer_closed`, the
    /// slots are taken back when the client hangs up before the connection ends.
    pub fn new(
        stats: Arc<ConnectionStats>,
        peer_closed: Option<PeerClosed>,
        terminal: Option<Option<u32>>,
    ) -> Arc<Self> {
        let watched = peer_closed.is_some();
        let lease = Arc::new(Self { stats, state: AtomicU8::new(SHORT), peer_closed, terminal });
        if watched {
            let mut leases = lease.stats.leases.lock().unwrap_or_else(PoisonError::into_inner);
            leases.retain(|lease| lease.strong_count() > 0);
            leases.push(Arc::downgrade(&lease));
        }
        lease
    }

    /// The client hung up and this connection no longer holds a slot.
    pub fn is_hung_up(&self) -> bool {
        self.state.load(Ordering::Acquire) == HUNG_UP
    }

    /// The connection starts work that outlives a request (a stream, a wait,
    /// a follow): a terminal's connection leaves the short lane for a place
    /// among at most `limit` long ones (`long_connections`). It takes the long
    /// place first and gives its two short slots back after, so it is never
    /// in neither count. There is no way back: it stays long until it ends.
    ///
    /// `Err` at the bound (or at this terminal's share of it): nothing
    /// changed, the connection is still a short one and the caller does not
    /// start the work.
    ///
    /// No change for a connection from outside the terminals (it holds no
    /// terminal slot), for one that is long already, and for one whose client
    /// hung up (its slots went back before).
    pub fn become_long(&self, limit: u64) -> Result<(), LongConnectionsFull> {
        let Some(client) = self.terminal else { return Ok(()) };
        if self.state.load(Ordering::Acquire) != SHORT {
            return Ok(());
        }
        self.stats.long.claim(limit, client)?;
        let moved =
            self.state.compare_exchange(SHORT, LONG, Ordering::AcqRel, Ordering::Acquire).is_ok();
        if !moved {
            // Another stream of this connection made it long, or the accept
            // loop took its slots back, between the load and here.
            self.stats.long.release(client);
            return Ok(());
        }
        self.stats.release();
        self.stats.release_terminal(client);
        Ok(())
    }

    /// The connection holds a place among the long connections.
    pub fn is_long(&self) -> bool {
        self.state.load(Ordering::Acquire) == LONG
    }
}

impl Drop for ConnectionLease {
    fn drop(&mut self) {
        match (*self.state.get_mut(), self.terminal) {
            (HUNG_UP, _) => {
                self.stats.hung_up.fetch_sub(1, Ordering::AcqRel);
            }
            (LONG, Some(client)) => self.stats.long.release(client),
            (_, terminal) => {
                self.stats.release();
                if let Some(client) = terminal {
                    self.stats.release_terminal(client);
                }
            }
        }
    }
}

impl ConnectionStats {
    /// Moves every watched connection whose client closed into the hung-up
    /// pool (while it has room) and frees its slot. Returns the slots freed.
    /// A long connection holds no slot to free: it keeps its long place until
    /// its thread ends.
    pub(super) fn reclaim_hung_up(&self, limit: u64) -> u64 {
        let leases: Vec<Arc<ConnectionLease>> = {
            let mut leases = self.leases.lock().unwrap_or_else(PoisonError::into_inner);
            leases.retain(|lease| lease.strong_count() > 0);
            leases.iter().filter_map(Weak::upgrade).collect()
        };
        let mut freed = 0;
        for lease in &leases {
            let Some(peer_closed) = &lease.peer_closed else { continue };
            if lease.state.load(Ordering::Acquire) != SHORT || !peer_closed() {
                continue;
            }
            let pooled = self
                .hung_up
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                    (count < limit).then_some(count + 1)
                })
                .is_ok();
            if !pooled {
                break;
            }
            // Another accept loop may have taken this one back first, or the
            // connection became a long one.
            let taken =
                lease.state.compare_exchange(SHORT, HUNG_UP, Ordering::AcqRel, Ordering::Acquire);
            if taken.is_err() {
                self.hung_up.fetch_sub(1, Ordering::AcqRel);
                continue;
            }
            self.release();
            if let Some(client) = lease.terminal {
                self.release_terminal(client);
            }
            freed += 1;
        }
        self.reclaimed.fetch_add(freed, Ordering::Relaxed);
        freed
    }
}
