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
//! when the runtime is dropped ([`TerminalSeat`]). The accept loop asks this
//! set, under its own lock, held for one insert, remove or lookup, and never
//! the session state. For a session with no seat, while a host starts a
//! terminal, it also reads the parent of one process (below). A seat names
//! its terminal, so the accept also reads from it which terminal a client is
//! in ([`ConnectionStats::seated_terminal`]).
//!
//! A terminal's process starts before the daemon has its process id, so it
//! can connect before the seat is taken. A terminal host that the daemon
//! starts closes that gap: the daemon knows the host's process before it
//! tells the host to start the shell, and the shell is the host's child. The
//! host takes a seat first ([`HostSeat`]), and a client whose session has no
//! seat is in that terminal when the parent of its session's leader is a
//! seated host. A terminal that starts another way takes over the
//! connections that came first at the moment it takes its seat
//! (`seat_terminal`, `ConnectionLease::join_terminal`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use super::ConnectionStats;

/// The terminal a seat is for, by its public id. Nil: the terminal has none.
type Terminal = Option<Arc<str>>;

/// The seats under one key (a process session or a host's process).
type Seats = HashMap<u32, Vec<Terminal>>;

#[derive(Default)]
struct Seated {
    /// By the process session of the terminal's child. One session can hold
    /// two for a moment: a terminal that moves to another host has its old
    /// and its new runtime.
    sessions: Seats,
    /// By the process of a terminal host, from before the host starts its
    /// terminal's child to the moment the terminal has the seat of that
    /// child's session ([`HostSeat`]).
    hosts: Seats,
}

/// The seats of the session's terminals and of the hosts that start one.
#[derive(Default)]
pub(super) struct TerminalSeats {
    seated: Mutex<Seated>,
}

fn take(seats: &mut Seats, key: u32, terminal: Terminal) {
    seats.entry(key).or_default().push(terminal);
}

fn leave(seats: &mut Seats, key: u32, terminal: &Terminal) {
    let Some(held) = seats.get_mut(&key) else { return };
    if let Some(seat) = held.iter().rposition(|seat| seat == terminal) {
        held.remove(seat);
    }
    if held.is_empty() {
        seats.remove(&key);
    }
}

/// The terminal of the seats under one key: the newest seat that names one.
fn seated(seats: &[Terminal]) -> SeatedTerminal {
    SeatedTerminal { id: seats.iter().rev().find_map(Clone::clone) }
}

impl TerminalSeats {
    fn lock(&self) -> MutexGuard<'_, Seated> {
        self.seated.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The terminal that a client's process session is in
/// ([`ConnectionStats::seated_terminal`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeatedTerminal {
    /// The terminal's public id. Nil: the terminal has none.
    pub id: Option<Arc<str>>,
}

/// A terminal's process id and, while this value lives, its seat among the
/// session's terminals. The terminal's runtime owns it, so the seat is held
/// from the moment the runtime is made (before the terminal enters the
/// session state) to its drop.
#[derive(Default)]
#[must_use = "the seat ends when this value is dropped"]
pub struct TerminalSeat {
    process: Option<u32>,
    terminal: Terminal,
    /// Where the seat is held. Not set: no process, or no session to seat it.
    seated: Option<Arc<ConnectionStats>>,
}

impl TerminalSeat {
    /// The process a terminal's runtime was made for (it leads the terminal's
    /// process session), without a seat: the terminal has no session.
    pub fn unseated(process: Option<u32>) -> Self {
        Self { process, terminal: None, seated: None }
    }

    /// The terminal's process.
    pub fn process_id(&self) -> Option<u32> {
        self.process
    }
}

impl Drop for TerminalSeat {
    fn drop(&mut self) {
        if let (Some(session), Some(connections)) = (self.process, &self.seated) {
            leave(&mut connections.terminal_seats.lock().sessions, session, &self.terminal);
        }
    }
}

/// The seat of a terminal host that starts its terminal, while this value
/// lives ([`HostSeating::seat`]).
///
/// The owner holds it only while it also holds the host's process, not yet
/// waited for. The system keeps the process id of an ended child for its
/// parent until the parent waits for it, so the seat never names another
/// process. A daemon for which the system does not keep that id (`SIGCHLD`
/// ignored) seats no host ([`HostSeating::seat`]).
#[derive(Default)]
#[must_use = "the seat ends when this value is dropped"]
pub struct HostSeat {
    seated: Option<(Arc<ConnectionStats>, u32, Terminal)>,
}

impl Drop for HostSeat {
    fn drop(&mut self) {
        if let Some((connections, host, terminal)) = &self.seated {
            leave(&mut connections.terminal_seats.lock().hosts, *host, terminal);
        }
    }
}

/// Where a terminal host that starts takes its seat, and for which terminal.
/// The default seats no host (a terminal with no session).
#[derive(Default, Clone)]
pub struct HostSeating {
    connections: Option<Arc<ConnectionStats>>,
    terminal: Terminal,
}

impl HostSeating {
    /// A host of a terminal of the session of `connections`. `terminal`: the
    /// terminal's public id, when it has one.
    pub fn of(connections: Arc<ConnectionStats>, terminal: Option<&str>) -> Self {
        Self { connections: Some(connections), terminal: terminal.map(Arc::from) }
    }

    /// The seat of the host whose process is `host`. The caller takes it
    /// before it tells the host to start the terminal's child, and holds the
    /// host's process for as long as the seat ([`HostSeat`]).
    ///
    /// No seat is taken when the system does not keep the process id of an
    /// ended child for this process: the id could then name another process
    /// while the seat is there.
    pub fn seat(&self, host: u32) -> HostSeat {
        self.seat_when(host, cmux_tui_platform::ended_children::keep_their_ids())
    }

    /// [`Self::seat`] for a process whose ended children keep their process
    /// ids (`id_is_kept`) or do not.
    pub(crate) fn seat_when(&self, host: u32, id_is_kept: bool) -> HostSeat {
        if !id_is_kept {
            return HostSeat::default();
        }
        let Some(connections) = &self.connections else { return HostSeat::default() };
        take(&mut connections.terminal_seats.lock().hosts, host, self.terminal.clone());
        HostSeat { seated: Some((connections.clone(), host, self.terminal.clone())) }
    }
}

impl ConnectionStats {
    /// The seat of the terminal whose process (and process session) is
    /// `process`. From now on the accept loop counts each connection from
    /// that session as the terminal's. `terminal`: the terminal's public id,
    /// when it has one.
    ///
    /// The connections that the session opened before this moment and that
    /// were admitted as ones from outside the terminals join the terminal
    /// here (`ConnectionLease::join_terminal`). The seat is taken first, so a
    /// connection admitted at this moment either finds the seat or is found
    /// here (`ConnectionLease::admitted_outside`).
    pub fn seat_terminal(
        self: &Arc<Self>,
        process: Option<u32>,
        terminal: Option<&str>,
    ) -> TerminalSeat {
        let Some(session) = process else { return TerminalSeat::unseated(None) };
        let terminal: Terminal = terminal.map(Arc::from);
        take(&mut self.terminal_seats.lock().sessions, session, terminal.clone());
        for lease in self.open_leases() {
            lease.join_terminal(session);
        }
        TerminalSeat { process, terminal, seated: Some(self.clone()) }
    }

    /// Whether a terminal of the session has its seat for process session
    /// `session`. One lookup under the seats' own lock.
    pub fn terminal_seated(&self, session: u32) -> bool {
        self.terminal_seats.lock().sessions.contains_key(&session)
    }

    /// The terminal that a client in process session `session` is in, by the
    /// seats: the terminal with the seat of that session, or the terminal of
    /// a host that starts and that is the parent of the session's leader.
    /// Nil: the client is in no terminal that has a seat.
    ///
    /// `parent_of`: the parent of a process. One call asks it at most one
    /// time, only while a host starts a terminal, and not under the seats'
    /// lock. A connection makes two calls, one for its lane and one for its
    /// class, each with its own read.
    /// The leader's process id is the session's id, and the system gives
    /// that id to no other process while the session has a process.
    ///
    /// A host's seat ends after its terminal has the seat of its session, so
    /// the second look finds one of the two for a client of that terminal.
    pub fn seated_terminal(
        &self,
        session: u32,
        parent_of: impl FnOnce(u32) -> Option<u32>,
    ) -> Option<SeatedTerminal> {
        {
            let seats = self.terminal_seats.lock();
            if let Some(held) = seats.sessions.get(&session) {
                return Some(seated(held));
            }
            if seats.hosts.is_empty() {
                return None;
            }
        }
        let host = parent_of(session);
        let seats = self.terminal_seats.lock();
        let held = seats
            .sessions
            .get(&session)
            .or_else(|| host.and_then(|host| seats.hosts.get(&host)))?;
        Some(seated(held))
    }

    /// The connections the terminals hold in their short lane now (of
    /// `active`).
    pub fn terminal_active(&self) -> u64 {
        self.terminal_lane.active()
    }
}
