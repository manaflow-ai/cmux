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
//!
//! A connection's terminal is set one time: at accept, when its terminal has
//! its seat (`terminal_seats`), or at the moment the terminal takes its seat
//! (`join_terminal`). Each change of a lease's state or terminal is made
//! under the lease's `turning` lock, so each slot goes back one time, to the
//! count that holds it.

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};

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
    /// `SHORT`, then at most one change, to `HUNG_UP` or to `LONG`. Changed
    /// only under `turning`.
    state: AtomicU8,
    /// Held for each change of `state` and of `terminal`: the connection
    /// becomes long (`become_long`), joins its terminal (`join_terminal`) or
    /// gives its slots back after a hang-up (`reclaim_hung_up`). Two starts
    /// on one connection at the same moment take one long place, and a slot
    /// that one of them takes is seen by the next. Never held across a wait.
    turning: Mutex<()>,
    peer_closed: Option<PeerClosed>,
    /// Set one time, when the connection is counted as one from a terminal:
    /// it holds a terminal slot (`ConnectionStats::try_claim_terminal`,
    /// #27698), given back with the main slot, or a long place. Inside, the
    /// terminal it came from (its process session; nil when unknown). Not
    /// set: a connection from outside the terminals.
    terminal: OnceLock<Option<u32>>,
    /// The process session of the client of a connection that was admitted
    /// as one from outside the terminals (`admitted_outside`). A terminal
    /// that takes its seat later finds its connections by it.
    outside_session: OnceLock<u32>,
    /// The connection started long work while it was counted as one from
    /// outside the terminals (`become_long` made no change then).
    long_work: AtomicBool,
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
        let lease = Arc::new(Self {
            stats,
            state: AtomicU8::new(SHORT),
            turning: Mutex::new(()),
            peer_closed,
            terminal: terminal.map(OnceLock::from).unwrap_or_default(),
            outside_session: OnceLock::new(),
            long_work: AtomicBool::new(false),
        });
        let mut leases = lease.stats.leases.lock().unwrap_or_else(PoisonError::into_inner);
        leases.retain(|lease| lease.strong_count() > 0);
        leases.push(Arc::downgrade(&lease));
        drop(leases);
        lease
    }

    /// The accept loop admitted this connection as one from outside the
    /// terminals, and its client runs in process session `session`. If that
    /// session is a terminal's, the connection joins the terminal: now, or
    /// when the terminal takes its seat (`ConnectionStats::seat_terminal`).
    ///
    /// A terminal's process can connect before the daemon knows the terminal:
    /// the process starts first. The seat is taken before the terminal looks
    /// at the open connections, and the session is written here before the
    /// look at the seats, so one of the two sees the other in each order.
    pub fn admitted_outside(&self, session: u32) {
        let _ = self.outside_session.set(session);
        if self.stats.terminal_seated(session) {
            self.join_terminal(session);
        }
    }

    /// The terminal of process session `session` has its seat: a connection
    /// from that session that was admitted as an outside one is counted as
    /// the terminal's from now on. A short one enters the terminals' short
    /// lane. One that started long work (`long_work`) becomes long: it takes
    /// the long place first and gives its short slot back after.
    ///
    /// No limit and no share apply (`TerminalLane::enter`): the connection is
    /// open already, and each later claim sees it. No change for a connection
    /// from another session, for one that has a terminal, and for one whose
    /// client hung up (its slot went back before).
    pub(super) fn join_terminal(&self, session: u32) {
        if self.outside_session.get() != Some(&session) {
            return;
        }
        let _turn = self.turning.lock().unwrap_or_else(PoisonError::into_inner);
        if self.terminal.get().is_some() || self.state.load(Ordering::Acquire) != SHORT {
            return;
        }
        let client = Some(session);
        if self.long_work.load(Ordering::Acquire) {
            self.stats.long.enter(client);
            self.state.store(LONG, Ordering::Release);
            self.stats.release();
        } else {
            self.stats.terminal_lane.enter(client);
        }
        let _ = self.terminal.set(client);
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
    /// terminal slot; the start is kept in `long_work` for `join_terminal`),
    /// for one that is long already, and for one whose client hung up (its
    /// slots went back before).
    pub fn become_long(&self, limit: u64) -> Result<(), LongConnectionsFull> {
        // One start at a time. A connection's reader can start a stream while
        // its dispatcher hands over a wait: the second one must see what the
        // first one did. Without this, both took a long place for a moment,
        // and at the bound the second one was refused though the connection
        // was long.
        let _turn = self.turning.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(&client) = self.terminal.get() else {
            self.long_work.store(true, Ordering::Release);
            return Ok(());
        };
        if self.state.load(Ordering::Acquire) != SHORT {
            return Ok(());
        }
        self.stats.long.claim(limit, client)?;
        self.state.store(LONG, Ordering::Release);
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
        match (*self.state.get_mut(), self.terminal.get().copied()) {
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
        let mut freed = 0;
        for lease in &self.open_leases() {
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
            // Under the lease's lock: another accept loop may have taken this
            // one back first, or the connection became a long one, or it joins
            // its terminal at this moment. The terminal slot is read after.
            let _turn = lease.turning.lock().unwrap_or_else(PoisonError::into_inner);
            if lease.state.load(Ordering::Acquire) != SHORT {
                self.hung_up.fetch_sub(1, Ordering::AcqRel);
                continue;
            }
            lease.state.store(HUNG_UP, Ordering::Release);
            self.release();
            if let Some(&client) = lease.terminal.get() {
                self.release_terminal(client);
            }
            freed += 1;
        }
        self.reclaimed.fetch_add(freed, Ordering::Relaxed);
        freed
    }

    /// The leases of the connections that are open now.
    pub(super) fn open_leases(&self) -> Vec<Arc<ConnectionLease>> {
        let mut leases = self.leases.lock().unwrap_or_else(PoisonError::into_inner);
        leases.retain(|lease| lease.strong_count() > 0);
        leases.iter().filter_map(Weak::upgrade).collect()
    }
}
