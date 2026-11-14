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
//!
//! A host that an earlier daemon of the session started lives on when that
//! daemon ends, and the daemon that starts next adopts it. That daemon
//! holds no process of the host, so the system does not keep the host's
//! process id for it: the id alone is no proof. Such a host is seated by
//! its process id and its start ([`KeptHost`]). The daemon reads the start
//! when it starts, and a client is in the host's terminal only when the
//! parent of its session's leader has that id and, at the accept, that
//! start. The seat is held from the daemon's start to the end of the host's
//! adoption. An adoption that gives the terminal the seat of its session
//! ends the host's seat after that. Each other end of an adoption leaves the
//! terminal with no seat.
//!
//! The class that a client has from a kept host's seat ends with that seat
//! ([`KeptSeatClass`]). The client's record keeps which seat gave the class,
//! and at the seat's end the record gets the class that the seats give at
//! that moment: the terminal of the seat of the client's session, when the
//! session has one.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use cmux_tui_platform::process_resources::{ProcessStart, process_start};

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
    /// By the process of a terminal host that an earlier daemon started,
    /// from this daemon's start to the end of the host's adoption
    /// ([`KeptHostSeat`]).
    kept_hosts: HashMap<u32, KeptSeats>,
    /// How many entries `kept_hosts` got: the number of the newest
    /// (`KeptSeats::entry`).
    kept_entries: u64,
}

/// The seats under the process of one kept host.
struct KeptSeats {
    host: KeptHost,
    terminal: Terminal,
    /// How many [`KeptHostSeat`] values hold this entry.
    held: usize,
    /// Two seats were taken for this one process. One host has one terminal,
    /// so one of the two is wrong: the entry names no terminal while it
    /// lives.
    taken_twice: bool,
    /// The number of this entry. A later entry for the same process has
    /// another.
    entry: u64,
    /// A lookup gave this entry's terminal ([`KeptSeatClass`]).
    gave_class: bool,
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

/// The seat of a kept host that gave a client its terminal, and the client's
/// process session ([`ConnectionStats::seated_terminal_from`]). The terminal
/// is the client's class only while that seat gives it
/// ([`ConnectionStats::kept_seat_class_now`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeptSeatClass {
    host: u32,
    entry: u64,
    session: u32,
}

/// What a class from the seat of a kept host is now
/// ([`ConnectionStats::kept_seat_class_now`]).
#[derive(Debug, PartialEq, Eq)]
pub enum KeptSeatClassNow {
    /// The seat is there and names its terminal.
    Held,
    /// The seat ended, or its host was seated twice. The value is the
    /// terminal of the seat of the client's session now. Nil: the session
    /// has no seat.
    Ended(Option<SeatedTerminal>),
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

/// A terminal host that an earlier daemon of the session started: its
/// process id and its start, as this daemon read them when it started
/// ([`KeptHost::read`]).
///
/// A later process can have the same id, but it starts after this daemon
/// did, so it does not have this start: [`KeptHost::read`] gives a value
/// only for a start before this daemon's own.
#[derive(Clone, Copy)]
pub struct KeptHost {
    process: u32,
    started: ProcessStart,
    /// The read of a process's start (`process_start`; a test gives its own).
    start_of: fn(u32) -> Option<ProcessStart>,
}

impl KeptHost {
    /// The process `process` with its start, read now. The caller reads it
    /// BEFORE it asks if the host of a record lives: when the answer is that
    /// the host lives, the host had this process id for the whole time
    /// between the two, so the start is the host's.
    ///
    /// Nil: the process is gone, or a start is not read (this daemon's own
    /// too), or the process did not start before this daemon.
    pub fn read(process: u32) -> Option<Self> {
        static DAEMON_STARTED: OnceLock<Option<ProcessStart>> = OnceLock::new();
        let daemon_started = *DAEMON_STARTED.get_or_init(|| process_start(std::process::id()));
        Self::read_by(process, daemon_started, process_start)
    }

    /// [`Self::read`] with the daemon's own start and the read of a start
    /// given.
    pub(crate) fn read_by(
        process: u32,
        daemon_started: Option<ProcessStart>,
        start_of: fn(u32) -> Option<ProcessStart>,
    ) -> Option<Self> {
        let started = start_of(process)?;
        (started < daemon_started?).then_some(Self { process, started, start_of })
    }

    /// The process with this id now is the host: it has the host's start.
    /// One read of one process.
    fn is_there(&self) -> bool {
        (self.start_of)(self.process) == Some(self.started)
    }
}

/// The seat of a kept host, while this value lives
/// ([`HostSeating::seat_kept`]). The default is no seat.
#[derive(Default)]
#[must_use = "the seat ends when this value is dropped"]
pub struct KeptHostSeat {
    seated: Option<(Arc<ConnectionStats>, u32)>,
    /// This seat was the second for its host, and the host's entry had given
    /// its terminal before.
    ended_a_class: bool,
}

impl KeptHostSeat {
    /// This seat made its host name no terminal (a second seat for one
    /// process) after a lookup had the terminal from the host's seat. The
    /// owner then has the classes from that seat read again.
    pub fn ended_a_class(&self) -> bool {
        self.ended_a_class
    }

    /// Ends the seat now; the drop does the same. True: the host's entry
    /// ended with this seat, and a lookup had the terminal from it. The
    /// owner then has the classes from that seat read again.
    pub fn end(&mut self) -> bool {
        let Some((connections, host)) = self.seated.take() else { return false };
        let mut seats = connections.terminal_seats.lock();
        let ended = seats.kept_hosts.get_mut(&host).is_some_and(|kept| {
            kept.held = kept.held.saturating_sub(1);
            kept.held == 0
        });
        ended && seats.kept_hosts.remove(&host).is_some_and(|kept| kept.gave_class)
    }
}

impl Drop for KeptHostSeat {
    fn drop(&mut self) {
        let _ = self.end();
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

    /// The seat of a host that an earlier daemon started and that lives
    /// (`host`: [`KeptHost::read`], read before the caller knew that the
    /// host lives). The owner holds it to the end of the host's adoption.
    ///
    /// No seat: `host` is nil, or the terminal has no session. A second seat
    /// for one process makes that process name no terminal.
    pub fn seat_kept(&self, host: Option<KeptHost>) -> KeptHostSeat {
        let (Some(connections), Some(host)) = (&self.connections, host) else {
            return KeptHostSeat::default();
        };
        let mut seats = connections.terminal_seats.lock();
        let Seated { kept_hosts, kept_entries, .. } = &mut *seats;
        let kept = kept_hosts.entry(host.process).or_insert_with(|| {
            *kept_entries = kept_entries.wrapping_add(1);
            KeptSeats {
                host,
                terminal: self.terminal.clone(),
                held: 0,
                taken_twice: false,
                entry: *kept_entries,
                gave_class: false,
            }
        });
        let ended_a_class = kept.held > 0 && !kept.taken_twice && kept.gave_class;
        kept.taken_twice |= kept.held > 0;
        kept.held = kept.held.saturating_add(1);
        KeptHostSeat { seated: Some((connections.clone(), host.process)), ended_a_class }
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
    /// a host that is the parent of the session's leader and that starts, or
    /// that an earlier daemon started ([`KeptHost`]). Nil: the client is in
    /// no terminal that has a seat.
    ///
    /// `parent_of`: the parent of a process. One call asks it at most one
    /// time, only while a host has a seat, and not under the seats' lock. A
    /// connection makes two calls, one for its lane and one for its class,
    /// each with its own read.
    /// The leader's process id is the session's id, and the system gives
    /// that id to no other process while the session has a process.
    ///
    /// A host's seat ends after its terminal has the seat of its session, so
    /// the second look finds one of the two for a client of that terminal.
    ///
    /// For a kept host the call also reads the start of the leader's parent,
    /// one time, after the read of the parent and not under the lock. The
    /// start is the kept host's only when the process with that id is the
    /// host at that read, and then it was the host at the read of the parent
    /// too: the host had the id for the whole time before.
    pub fn seated_terminal(
        &self,
        session: u32,
        parent_of: impl FnOnce(u32) -> Option<u32>,
    ) -> Option<SeatedTerminal> {
        self.seated_terminal_from(session, parent_of).map(|(seated, _)| seated)
    }

    /// [`Self::seated_terminal`] and, when the terminal is from the seat of
    /// a kept host, that seat. The caller that keeps the terminal as a
    /// client's class keeps the seat with it, and reads the class again at
    /// the seat's end ([`Self::kept_seat_class_now`]).
    pub fn seated_terminal_from(
        &self,
        session: u32,
        parent_of: impl FnOnce(u32) -> Option<u32>,
    ) -> Option<(SeatedTerminal, Option<KeptSeatClass>)> {
        {
            let seats = self.terminal_seats.lock();
            if let Some(held) = seats.sessions.get(&session) {
                return Some((seated(held), None));
            }
            if seats.hosts.is_empty() && seats.kept_hosts.is_empty() {
                return None;
            }
        }
        let host = parent_of(session);
        let (kept, terminal, class) = {
            let mut seats = self.terminal_seats.lock();
            let held = seats
                .sessions
                .get(&session)
                .or_else(|| host.and_then(|host| seats.hosts.get(&host)));
            if let Some(held) = held {
                return Some((seated(held), None));
            }
            let kept = seats.kept_hosts.get_mut(&host?).filter(|kept| !kept.taken_twice)?;
            // Before the read of the host's start: an end of the seat from
            // here on has the classes read again.
            kept.gave_class = true;
            let class = KeptSeatClass { host: kept.host.process, entry: kept.entry, session };
            (kept.host, kept.terminal.clone(), class)
        };
        kept.is_there().then_some((SeatedTerminal { id: terminal }, Some(class)))
    }

    /// What the class `class` is now. One hold of the seats' lock, and no
    /// read of a process.
    pub fn kept_seat_class_now(&self, class: KeptSeatClass) -> KeptSeatClassNow {
        let seats = self.terminal_seats.lock();
        let held = seats
            .kept_hosts
            .get(&class.host)
            .is_some_and(|kept| kept.entry == class.entry && !kept.taken_twice);
        if held {
            return KeptSeatClassNow::Held;
        }
        KeptSeatClassNow::Ended(seats.sessions.get(&class.session).map(Vec::as_slice).map(seated))
    }

    /// The connections the terminals hold in their short lane now (of
    /// `active`).
    pub fn terminal_active(&self) -> u64 {
        self.terminal_lane.active()
    }
}
