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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use super::ConnectionStats;

/// Whether the client at the other end closed its socket. Polled without
/// blocking, from the accept loop.
pub type PeerClosed = Box<dyn Fn() -> bool + Send + Sync>;

/// One admitted connection's slot. Dropping it frees the slot, or its place in
/// the hung-up pool once the slot was taken back.
pub struct ConnectionLease {
    stats: Arc<ConnectionStats>,
    hung_up: AtomicBool,
    peer_closed: Option<PeerClosed>,
    /// Also holds a terminal slot (`ConnectionStats::try_claim_terminal`,
    /// #27698), given back with the main slot; inside, the terminal it came
    /// from (nil when unknown). Set at accept, or later by
    /// `enter_terminal_lane`. A change of it and the take-back of the slots
    /// (`reclaim_hung_up`) exclude each other under this lock.
    terminal: Mutex<Option<Option<u32>>>,
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
        let lease = Arc::new(Self {
            stats,
            hung_up: AtomicBool::new(false),
            peer_closed,
            terminal: Mutex::new(terminal),
        });
        if watched {
            let mut leases = lease.stats.leases.lock().unwrap_or_else(PoisonError::into_inner);
            leases.retain(|lease| lease.strong_count() > 0);
            leases.push(Arc::downgrade(&lease));
        }
        lease
    }

    /// The client hung up and this connection no longer holds a slot.
    pub fn is_hung_up(&self) -> bool {
        self.hung_up.load(Ordering::Acquire)
    }

    /// Counts this admitted connection as one from terminal `client` (nil
    /// when unknown): it takes a terminal slot too, under `limit` and the
    /// terminal's fair share (`ConnectionStats::try_claim_terminal`). False
    /// when the terminal lane has no room: the caller refuses the connection,
    /// whose main slot goes back when the lease drops. A connection that is
    /// in the lane already, or whose slot was taken back after a hang-up,
    /// changes nothing.
    ///
    /// For a connection the accept loop could not place: an agent hook's
    /// sending child is in a process session of its own, so the accept loop
    /// sees an outside client; its first line says what it is.
    pub fn enter_terminal_lane(&self, limit: u64, pool_limit: u64, client: Option<u32>) -> bool {
        if self.is_hung_up() || self.terminal().is_some() {
            return true;
        }
        // Not under the lock: at the limit the claim asks every lease,
        // this one too, whether its client hung up.
        if !self.stats.try_claim_terminal(limit, pool_limit, client) {
            return false;
        }
        let mut terminal = self.terminal.lock().unwrap_or_else(PoisonError::into_inner);
        if self.is_hung_up() || terminal.is_some() {
            // The slots went back in between; this one goes back too.
            drop(terminal);
            self.stats.release_terminal(client);
        } else {
            *terminal = Some(client);
        }
        true
    }

    /// `Some` while this connection holds a terminal slot.
    fn terminal(&self) -> Option<Option<u32>> {
        *self.terminal.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for ConnectionLease {
    fn drop(&mut self) {
        if *self.hung_up.get_mut() {
            self.stats.hung_up.fetch_sub(1, Ordering::AcqRel);
        } else {
            self.stats.release();
            let terminal = *self.terminal.get_mut().unwrap_or_else(PoisonError::into_inner);
            if let Some(client) = terminal {
                self.stats.release_terminal(client);
            }
        }
    }
}

impl ConnectionStats {
    /// Moves every watched connection whose client closed into the hung-up
    /// pool (while it has room) and frees its slot. Returns the slots freed.
    pub(super) fn reclaim_hung_up(&self, limit: u64) -> u64 {
        let leases: Vec<Arc<ConnectionLease>> = {
            let mut leases = self.leases.lock().unwrap_or_else(PoisonError::into_inner);
            leases.retain(|lease| lease.strong_count() > 0);
            leases.iter().filter_map(Weak::upgrade).collect()
        };
        let mut freed = 0;
        for lease in &leases {
            let Some(peer_closed) = &lease.peer_closed else { continue };
            if lease.is_hung_up() || !peer_closed() {
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
            // Another accept loop may have taken this one back first. Under
            // the lease's lock, so a terminal slot the connection takes at
            // this moment (`enter_terminal_lane`) is either seen here or
            // given back there.
            let terminal = {
                let terminal = lease.terminal.lock().unwrap_or_else(PoisonError::into_inner);
                let taken = lease.hung_up.compare_exchange(
                    false,
                    true,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
                taken.is_ok().then_some(*terminal)
            };
            let Some(terminal) = terminal else {
                self.hung_up.fetch_sub(1, Ordering::AcqRel);
                continue;
            };
            self.release();
            if let Some(client) = terminal {
                self.release_terminal(client);
            }
            freed += 1;
        }
        self.reclaimed.fetch_add(freed, Ordering::Relaxed);
        freed
    }
}
