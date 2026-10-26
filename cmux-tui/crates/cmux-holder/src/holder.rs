//! The holder's single-threaded event loop.
//!
//! One `poll` set: the listening socket, the daemon link, connections that
//! have not said HELLO yet, links another daemon superseded that still
//! finish their last frame, a self-pipe for SIGCHLD (and a launchd SIGTERM),
//! the start report of each child that has not run its program yet, and
//! every PTY master. No handler waits: a SPAWN forks and returns, and its
//! SPAWNED (or its error) follows when the child's report arrives. While no
//! daemon is attached to a terminal its output is read as soon as it is
//! ready and its ring keeps the newest bytes. While a daemon is attached
//! nothing is lost: the holder reads a
//! master only while fewer than [`UNSENT_HIGH_WATER`] bytes wait unsent,
//! sends at most [`wire::CREDIT_WINDOW`] past what the daemon acknowledged
//! it parsed, and a shell that prints faster than that blocks in its PTY,
//! as on a direct PTY. Terminals share the link fairly: each pump starts at
//! the next terminal in turn and gives each one an equal share, and a small
//! frame (an echo) goes ahead of queued bulk output. No timers: `poll`
//! waits forever unless a CLOSE grace, a handshake deadline or the idle
//! exit is pending.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::{Duration, Instant};

use crate::ring::Ring;
use crate::wire::{self, Frame, In, Kind, Out};
use crate::{ExitStatus, Listed, SpawnRequest, pty};

/// Output kept per terminal for a daemon that reconnects.
pub const RING_BYTES: usize = 1 << 20;
/// Output queued on the link before the holder stops making DATA frames
/// (the rest waits in the rings).
const LINK_QUEUE_BYTES: usize = 1 << 20;
/// Largest DATA payload.
const DATA_CHUNK: usize = 256 * 1024;
/// A frame this small goes ahead of queued bulk output (unless its own
/// terminal has bulk queued: a terminal's frames never pass each other).
const URGENT_FRAME_BYTES: usize = 4 * 1024;
/// The least share of the link a terminal gets per pump, however many
/// terminals print.
const MIN_SHARE: usize = 16 * 1024;
/// Unsent output an attached terminal may hold in its ring before the
/// holder stops reading its master. Well under [`RING_BYTES`], so the ring
/// never drops a byte an attached daemon has not been sent.
pub const UNSENT_HIGH_WATER: usize = 256 * 1024;
/// Output read from one master per wakeup, so one flooding terminal cannot
/// starve the others.
const READ_PER_TURN: usize = 256 * 1024;
/// How long a new connection may take to authenticate.
const HANDSHAKE: Duration = Duration::from_secs(5);
/// Connections waiting to authenticate at once; the oldest goes first.
const MAX_PENDING: usize = 8;
/// A holder with no terminal and no daemon link exits after this long: it
/// keeps nothing, and the next daemon starts a holder of its own build.
pub const IDLE_EXIT: Duration = Duration::from_secs(30);
/// Poison pill (terminal-host-model-DESIGN.md section 3): a terminal whose
/// stream ended this many times without DETACH within [`STRIKE_WINDOW`]
/// is restored from its prologue without the ring tail, so one byte
/// stream that crashes the daemon's parser cannot crash every restart.
const POISON_STRIKES: usize = 2;
const STRIKE_WINDOW: Duration = Duration::from_secs(10);

/// Reads of the old link a takeover makes to see whether that daemon
/// already ended (`Holder::link_ended`): enough for the frames a dead
/// daemon left (each read takes up to the reader's chunk).
const LINK_END_READS: usize = 16;

/// A child's end ends its terminal once the master has nothing more to
/// read, even while a background job keeps the PTY open. Not on Linux: a
/// slave's last write reaches the master through an asynchronous flip
/// buffer, so "nothing to read" right after the child's end can still miss
/// its last output; there the terminal ends at end of file (which Linux
/// gives only after that buffer drained).
const ENDS_ON_CHILD_EXIT: bool = !cfg!(target_os = "linux");

/// Error codes of [`Kind::Error`].
pub mod error_code {
    pub const UNKNOWN_KIND: u16 = 1;
    pub const BAD_TOKEN: u16 = 2;
    pub const NO_COMMON_VERSION: u16 = 3;
    pub const UNKNOWN_CHAN: u16 = 4;
    pub const BAD_PAYLOAD: u16 = 6;
    pub const SPAWN_FAILED: u16 = 8;
    pub const CHAN_IN_USE: u16 = 9;
    /// Another daemon authenticated and took this link's place.
    pub const SUPERSEDED: u16 = 10;
    /// The holder is out of descriptors (request kind
    /// [`crate::wire::STREAM_FAULT`]): it could not take the descriptors
    /// the daemon's frame passed, and ends that link. Passing descriptors
    /// to a daemon (a WELCOME's listing, a SPAWNED) costs the holder none
    /// ([`Terminal::descriptors`]), so nothing else is refused for want of
    /// them.
    pub const NO_DESCRIPTORS: u16 = 11;
}

struct Terminal {
    id: [u8; 16],
    /// Shared with each frame that passes it ([`Self::descriptors`]).
    master: Arc<OwnedFd>,
    pid: libc::pid_t,
    /// This holder started the child, so it reaps it and reads its status.
    own_child: bool,
    /// The child has not reported its start yet: nothing is sent for the
    /// terminal, and it has not ended, until it did.
    starting: Option<Starting>,
    ring: Ring,
    status: Option<ExitStatus>,
    /// The master read end of file or EIO: every slave closed.
    eof: bool,
    exit_sent: bool,
    /// Next offset to send the attached daemon; `None` while not attached.
    sent: Option<u64>,
    /// A SPAWN's first offset or an ADOPT's `resume`, until its daemon
    /// ATTACHes (or DETACHes, or the link ends): reading stops
    /// [`UNSENT_HIGH_WATER`] past it, as it would attached, so the ring
    /// never runs past the credit the ATTACH sets up and drops no byte the
    /// daemon has not been sent. (The daemon sends SPAWN and its ATTACH
    /// back to back, but as two writes: a holder that reads freely in
    /// between can lose a new terminal's first output to the ring.)
    held: Option<u64>,
    /// Offset the attached daemon acknowledged it parsed up to.
    acked: u64,
    /// A CLOSE asked for its end: the holder forgets it once it ended and
    /// its EXIT went to an attached daemon.
    closing: bool,
    /// Input waiting for the PTY to accept it.
    input: VecDeque<u8>,
    /// SIGKILL the terminal's groups at this time (a CLOSE's grace).
    kill_at: Option<Instant>,
    /// A VT replay of the screen at `prologue_base`, sent before the ring
    /// to a daemon that asks: the daemon's parsed screen when this holder
    /// adopted the terminal, or the newest SNAPSHOT the daemon sent. A
    /// prologue older than the ring still restores modes; the daemon
    /// cancels the sequence the ring's first byte may be inside.
    prologue: Vec<u8>,
    prologue_base: u64,
    /// When daemon links ended without DETACH while they streamed this
    /// terminal (the poison-pill count).
    strikes: Vec<Instant>,
}

/// A terminal whose child was forked and has not reported its start
/// ([`pty::Start`]).
struct Starting {
    start: pty::Start,
    /// The daemon's custody copies, passed with SPAWNED once the program
    /// runs ([`Terminal::descriptors`]).
    custody: Vec<Arc<OwnedFd>>,
    /// The link whose SPAWN started it ([`Link::id`]): only that link gets
    /// its SPAWNED, whose descriptors were made for that link's version.
    link: u64,
}

/// One frame waiting for the link, with the descriptors it passes (shared
/// with their terminal, kept open until the frame's first byte is written).
struct OutFrame {
    chan: u32,
    bytes: Vec<u8>,
    fds: Vec<Arc<OwnedFd>>,
    /// Bytes of it the socket already took.
    written: usize,
}

/// The authenticated daemon link.
struct Link {
    /// This link among every link the holder had (counting from 1).
    id: u64,
    stream: UnixStream,
    reader: wire::Reader,
    /// The daemon acknowledges what it parsed (wire version 2).
    credit: bool,
    /// The daemon takes ring segments and reads ring layout 2
    /// ([`wire::RING_VERSION`], [`wire::FLAG_RING`]).
    rings: bool,
    /// The wire version the link settled on.
    version: u16,
    /// The frame the socket took part of: it finishes first.
    current: Option<OutFrame>,
    /// Small frames, written before `bulk`.
    urgent: VecDeque<OutFrame>,
    bulk: VecDeque<OutFrame>,
    /// Frames each channel has in `bulk`: a small frame of such a channel
    /// queues behind them, so one terminal's frames keep their order.
    bulk_per_chan: HashMap<u32, usize>,
    /// Bytes queued and not yet written.
    out_bytes: usize,
}

impl Link {
    fn push(&mut self, chan: u32, bytes: Vec<u8>, fds: Vec<Arc<OwnedFd>>) {
        self.out_bytes += bytes.len();
        let urgent = bytes.len() <= URGENT_FRAME_BYTES && !self.bulk_per_chan.contains_key(&chan);
        let frame = OutFrame { chan, bytes, fds, written: 0 };
        if urgent {
            self.urgent.push_back(frame);
        } else {
            *self.bulk_per_chan.entry(chan).or_default() += 1;
            self.bulk.push_back(frame);
        }
    }

    fn next(&mut self) -> Option<OutFrame> {
        if let Some(frame) = self.urgent.pop_front() {
            return Some(frame);
        }
        let frame = self.bulk.pop_front()?;
        if let Some(count) = self.bulk_per_chan.get_mut(&frame.chan) {
            *count -= 1;
            if *count == 0 {
                self.bulk_per_chan.remove(&frame.chan);
            }
        }
        Some(frame)
    }

    fn has_output(&self) -> bool {
        self.current.is_some() || !self.urgent.is_empty() || !self.bulk.is_empty()
    }
}

/// A link the holder ends while its daemon is still there to hear why:
/// another daemon of the session took its place (ERROR SUPERSEDED, so it
/// does not take the holder back: two daemons would take it from each
/// other in turn), or its stream could not be read on (ERROR on request
/// kind [`wire::STREAM_FAULT`]: the holder is out of descriptors, or the
/// frames were not frames of the wire). Its queued frames are dropped, as
/// for any link that ends; the frame the socket took part of is finished,
/// so the stream stays well formed, and the ERROR follows as its last
/// frame, whatever was queued. Polled for POLLOUT until it is written: at
/// most a DATA chunk and a header, which the daemon's reader thread drains,
/// or a write error once that daemon is gone.
struct Retiring {
    stream: UnixStream,
    bytes: Vec<u8>,
    written: usize,
}

impl Retiring {
    /// `link`'s last bytes: the rest of the frame its socket took part of,
    /// then ERROR `code` about `request_kind` on channel 0.
    fn new(link: Link, request_kind: u16, code: u16, message: &str) -> Self {
        let mut bytes = link
            .current
            .filter(|frame| frame.written > 0)
            .map(|frame| frame.bytes[frame.written..].to_vec())
            .unwrap_or_default();
        let payload = Out::default().u16(request_kind).u16(code).bytes(message.as_bytes()).0;
        bytes.extend_from_slice(&wire::encode(Kind::Error, 0, &payload));
        Self { stream: link.stream, bytes, written: 0 }
    }

    /// Write what the socket takes. True once there is nothing more to do:
    /// every byte is written (the stream closes as it drops), or the
    /// daemon is gone.
    fn write(&mut self) -> bool {
        while self.written < self.bytes.len() {
            match wire::send_with_fds(self.stream.as_raw_fd(), &self.bytes[self.written..], &[]) {
                Ok(0) => return false,
                Ok(n) => self.written += n,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return false,
                Err(_) => return true,
            }
        }
        true
    }
}

/// A connection that has not authenticated yet. It never touches the
/// current link: a liveness probe, a stale token or any local tool cannot
/// drop the daemon that is attached.
struct Pending {
    stream: UnixStream,
    reader: wire::Reader,
    deadline: Instant,
}

/// Every terminal for a new link's WELCOME: channel, LISTED payload and
/// the descriptors it passes.
type Listing = Vec<(u32, Vec<u8>, Vec<Arc<OwnedFd>>)>;

/// What one [`Holder::read_terminal`] call ended on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReadEnd {
    /// The master has nothing more right now.
    Drained,
    /// The terminal's room or this turn's share ran out; more may wait.
    Stopped,
    /// End of file or EIO: every slave closed.
    Eof,
}

/// Why a link is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LinkDrop {
    /// It ended or broke (a daemon crash or exit): a strike against each
    /// terminal it streamed.
    Lost,
    /// Another daemon of the session took the holder.
    Superseded,
    /// Its stream could not be read on ([`wire::Fault`]): the daemon is
    /// still there and hears why. No strike: it did not die parsing.
    Faulted,
}

/// Why reading the link ends it.
#[derive(Debug)]
enum LinkBreak {
    /// The socket ended or failed: the daemon is gone.
    Lost,
    /// The stream cannot be read on, with what went wrong.
    Fault(wire::Fault, String),
}

impl LinkBreak {
    /// The break an error reading the link stands for.
    fn of(error: &io::Error) -> Self {
        match wire::Fault::of(error) {
            Some(fault) => Self::Fault(fault, error.to_string()),
            None => Self::Lost,
        }
    }
}

/// The holder state.
pub struct Holder {
    listener: UnixListener,
    /// The last accept failed for a want of the holder's (a descriptor,
    /// kernel memory) and left its connection queued: the listener stays
    /// out of the poll set, and each turn ends with another accept
    /// ([`Self::accept`]).
    accept_stalled: bool,
    /// The socket file, removed when the holder exits.
    socket: Option<PathBuf>,
    token: [u8; 32],
    link: Option<Link>,
    /// Links the holder had: the next one's [`Link::id`] is one more.
    links: u64,
    /// Superseded links still writing their last frame.
    retiring: Vec<Retiring>,
    pending: Vec<Pending>,
    terminals: BTreeMap<u32, Terminal>,
    /// Terminals whose child ended but whose master is not at end of file
    /// yet: read what the child printed, then stop reading.
    ending: Vec<u32>,
    /// Terminals with `closing` set.
    closing: usize,
    /// The next pump starts at the first sending terminal at or after this
    /// channel (round robin).
    pump_cursor: u32,
    /// The soft `RLIMIT_NOFILE` children get back.
    child_open_file_limit: Option<u64>,
    /// No terminal and no link since this time.
    idle_since: Option<Instant>,
    idle_exit: Duration,
    /// End every terminal once no daemon was linked for this long (a DEV
    /// build's, debug build's or test's grace, as its terminal hosts get);
    /// `None`: never (normal installs, decision D1).
    orphan_grace: Option<Duration>,
    /// Terminals and no daemon link since this time.
    orphan_since: Option<Instant>,
    sigchld: OwnedFd,
}

static SIGNAL_WRITE: AtomicI32 = AtomicI32::new(-1);
/// launchd (or init) asked the holder to end: logout or shutdown.
static TERMINATE: AtomicBool = AtomicBool::new(false);

fn wake_loop() {
    let fd = SIGNAL_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write is async-signal-safe; a full pipe already wakes the loop.
        unsafe { libc::write(fd, [1u8].as_ptr().cast(), 1) };
    }
}

extern "C" fn on_sigchld(_: libc::c_int) {
    wake_loop();
}

/// SIGTERM ends the holder only when launchd (or init) sends it, at logout
/// or shutdown. A daemon's exit, a test or a cleanup script that signals
/// the whole group cannot end the shells.
extern "C" fn on_sigterm(_: libc::c_int, info: *mut libc::siginfo_t, _: *mut libc::c_void) {
    if info.is_null() {
        return;
    }
    // SAFETY: the kernel passes a valid siginfo to an SA_SIGINFO handler.
    if unsafe { sender_pid(info) } == 1 {
        TERMINATE.store(true, Ordering::Relaxed);
        wake_loop();
    }
}

#[cfg(target_vendor = "apple")]
unsafe fn sender_pid(info: *mut libc::siginfo_t) -> libc::pid_t {
    // SAFETY: the caller passes a valid siginfo.
    unsafe { (*info).si_pid }
}

#[cfg(not(target_vendor = "apple"))]
unsafe fn sender_pid(info: *mut libc::siginfo_t) -> libc::pid_t {
    // SAFETY: the caller passes a valid siginfo of a kill(2) signal.
    unsafe { (*info).si_pid() }
}

impl Holder {
    /// A holder serving `listener`, accepting daemons that present `token`.
    pub fn new(listener: UnixListener, token: [u8; 32]) -> io::Result<Self> {
        listener.set_nonblocking(true)?;
        let socket =
            listener.local_addr().ok().and_then(|addr| addr.as_pathname().map(Path::to_path_buf));
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            pty::set_cloexec(fd);
            pty::set_nonblocking(fd);
        }
        SIGNAL_WRITE.store(fds[1], Ordering::Relaxed);
        // SAFETY: installs async-signal-safe handlers.
        unsafe {
            libc::signal(
                libc::SIGCHLD,
                on_sigchld as extern "C" fn(libc::c_int) as libc::sighandler_t,
            );
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_sigterm
                as extern "C" fn(libc::c_int, *mut libc::siginfo_t, *mut libc::c_void)
                as libc::sighandler_t;
            action.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut());
        }
        // SAFETY: pipe returned fds[0]; fds[1] stays open for the handlers.
        let sigchld = unsafe { std::os::fd::FromRawFd::from_raw_fd(fds[0]) };
        Ok(Self {
            listener,
            accept_stalled: false,
            socket,
            token,
            link: None,
            links: 0,
            retiring: Vec::new(),
            pending: Vec::new(),
            terminals: BTreeMap::new(),
            ending: Vec::new(),
            closing: 0,
            pump_cursor: 0,
            child_open_file_limit: None,
            idle_since: Some(Instant::now()),
            idle_exit: IDLE_EXIT,
            orphan_grace: None,
            orphan_since: None,
            sigchld,
        })
    }

    /// Give every child this soft `RLIMIT_NOFILE` (the one cmux started
    /// with); `None` keeps the holder's own.
    pub fn set_child_open_file_limit(&mut self, soft: Option<u64>) {
        self.child_open_file_limit = soft;
    }

    /// Exit after `idle` with no terminal and no daemon link
    /// (default [`IDLE_EXIT`]).
    pub fn set_idle_exit(&mut self, idle: Duration) {
        self.idle_exit = idle;
    }

    /// End every terminal after `grace` with no daemon link (`None`, the
    /// default: never).
    pub fn set_orphan_grace(&mut self, grace: Option<Duration>) {
        self.orphan_grace = grace;
    }

    /// Serve until launchd ends the holder or it has been idle for its idle
    /// exit, then remove the socket file.
    pub fn run(&mut self) -> io::Result<()> {
        loop {
            self.turn()?;
            let idle_over = self.idle_since.is_some_and(|since| since.elapsed() >= self.idle_exit);
            if idle_over || TERMINATE.load(Ordering::Relaxed) {
                if let Some(socket) = &self.socket {
                    let _ = std::fs::remove_file(socket);
                }
                return Ok(());
            }
        }
    }

    /// One `poll` and the work it reports.
    fn turn(&mut self) -> io::Result<()> {
        let listening = if self.accept_stalled { 0 } else { libc::POLLIN };
        let mut fds = vec![
            pollfd(self.listener.as_raw_fd(), listening),
            pollfd(self.sigchld.as_raw_fd(), libc::POLLIN),
        ];
        let link_at = self.link.as_ref().map(|link| {
            let mut events = libc::POLLIN;
            if link.has_output() || self.unsent_output(link.credit) {
                events |= libc::POLLOUT;
            }
            fds.push(pollfd(link.stream.as_raw_fd(), events));
            fds.len() - 1
        });
        let first_retiring = fds.len();
        for retiring in &self.retiring {
            fds.push(pollfd(retiring.stream.as_raw_fd(), libc::POLLOUT));
        }
        let retiring_count = self.retiring.len();
        let first_pending = fds.len();
        for pending in &self.pending {
            fds.push(pollfd(pending.stream.as_raw_fd(), libc::POLLIN));
        }
        let pending_count = self.pending.len();
        let first_start = fds.len();
        let mut starts = Vec::new();
        for (chan, terminal) in &self.terminals {
            if let Some(starting) = &terminal.starting {
                fds.push(pollfd(starting.start.fd(), libc::POLLIN));
                starts.push(*chan);
            }
        }
        let first_terminal = fds.len();
        // A terminal at end of file stays out of the set: its master would
        // report POLLHUP forever. So does one with no room while it has no
        // input to write: the shell waits in its PTY until the daemon took
        // the output.
        let mut chans = Vec::new();
        for (chan, terminal) in &self.terminals {
            if terminal.eof {
                continue;
            }
            let mut events = 0;
            if terminal.room() > 0 {
                events |= libc::POLLIN;
            }
            if !terminal.input.is_empty() {
                events |= libc::POLLOUT;
            }
            if events == 0 {
                continue;
            }
            fds.push(pollfd(terminal.master.as_raw_fd(), events));
            chans.push(*chan);
        }
        let timeout = self.next_deadline().map_or(-1, |deadline| {
            deadline.saturating_duration_since(Instant::now()).as_millis().min(60_000) as i32 + 1
        });
        // SAFETY: fds is a live array of pollfd.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted { Ok(()) } else { Err(error) };
        }
        if fds[1].revents != 0 {
            self.reap();
        }
        // From the back, before anything adds to `retiring`: swap_remove
        // moves only entries already handled.
        for index in (0..retiring_count).rev() {
            if fds[first_retiring + index].revents != 0 && self.retiring[index].write() {
                self.retiring.swap_remove(index);
            }
        }
        // A child that was reaped wrote its report (or nothing) before it
        // ended: its pipe has the answer even if `poll` saw the exit first.
        for (index, chan) in starts.iter().enumerate() {
            let reaped = self.terminals.get(chan).is_some_and(|terminal| terminal.status.is_some());
            if fds[first_start + index].revents != 0 || reaped {
                self.finish_start(*chan);
            }
        }
        for (index, chan) in chans.iter().enumerate() {
            let revents = fds[first_terminal + index].revents;
            if revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
                && self.terminals.get(chan).is_some_and(|terminal| terminal.room() > 0)
            {
                self.read_terminal(*chan);
            }
            if revents & (libc::POLLOUT | libc::POLLHUP | libc::POLLERR) != 0 {
                self.write_terminal(*chan);
            }
        }
        self.finish_ending();
        if let Some(index) = link_at
            && fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
            && let Err(why) = self.read_link()
        {
            self.break_link(why);
        }
        // From the back: a handled connection leaves with swap_remove,
        // which moves only connections already handled.
        for index in (0..pending_count).rev() {
            if fds[first_pending + index].revents != 0 {
                self.read_pending(index);
            }
        }
        let now = Instant::now();
        self.pending.retain(|pending| pending.deadline > now);
        if fds[0].revents & libc::POLLIN != 0 {
            self.accept();
        }
        self.kill_overdue();
        self.pump();
        self.retire_closed();
        self.end_orphans(now);
        // Last: only a turn frees a descriptor of the holder's, and this
        // turn's work is done.
        if self.accept_stalled {
            self.accept();
        }
        let idle = self.terminals.is_empty() && self.link.is_none();
        self.idle_since = if idle { Some(self.idle_since.unwrap_or(now)) } else { None };
        Ok(())
    }

    /// With an orphan grace: once no daemon was linked for that long, hang
    /// up every terminal (a CLOSE each, its 2 s SIGKILL grace too); the
    /// ended ones are forgotten and the holder exits idle.
    fn end_orphans(&mut self, now: Instant) {
        let orphaned = self.link.is_none() && !self.terminals.is_empty();
        self.orphan_since = if orphaned { Some(self.orphan_since.unwrap_or(now)) } else { None };
        let (Some(grace), Some(since)) = (self.orphan_grace, self.orphan_since) else { return };
        if now.saturating_duration_since(since) < grace {
            return;
        }
        let open: Vec<u32> = self
            .terminals
            .iter()
            .filter(|(_, terminal)| !terminal.closing)
            .map(|(chan, _)| *chan)
            .collect();
        for chan in open {
            let _ = self.close(chan, &2000u32.to_le_bytes());
        }
        self.retire_closed();
    }

    /// Whether some attached terminal has output (or its EXIT) the link may
    /// take now. Output past a terminal's credit does not count: it waits
    /// for an ACK, not for the socket.
    fn unsent_output(&self, credit: bool) -> bool {
        self.terminals.values().any(|terminal| terminal.sendable(credit))
    }

    fn next_deadline(&self) -> Option<Instant> {
        let kill = self.terminals.values().filter_map(|terminal| terminal.kill_at).min();
        let handshake = self.pending.iter().map(|pending| pending.deadline).min();
        let idle = self.idle_since.map(|since| since + self.idle_exit);
        // Only while some terminal is still to be hung up: a past deadline
        // must not spin `poll` while the closed ones end.
        let orphan = self
            .orphan_since
            .zip(self.orphan_grace)
            .filter(|_| self.terminals.values().any(|terminal| !terminal.closing))
            .map(|(since, grace)| since + grace);
        kill.into_iter().chain(handshake).chain(idle).chain(orphan).min()
    }

    /// Take new connections. They wait in `pending` until they authenticate;
    /// the attached daemon keeps its link meanwhile.
    ///
    /// An accept that fails for a want of the holder's (no descriptor left:
    /// EMFILE, ENFILE; no kernel memory) leaves its connection queued on
    /// Linux, so the listener would report it again at once and the loop
    /// would spin for as long as the holder is full. The holder then stops
    /// polling the listener ([`Self::accept_stalled`]) and tries again at
    /// the end of each turn: a descriptor of its own frees only in a turn
    /// (a terminal forgotten, a link, pending connection or retiring link
    /// dropped), so it takes the connection on the first turn after one
    /// did, with no timer and no wakeup of its own.
    fn accept(&mut self) {
        self.accept_stalled = false;
        loop {
            let stream = match self.listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) => match error.kind() {
                    io::ErrorKind::WouldBlock => return,
                    io::ErrorKind::Interrupted | io::ErrorKind::ConnectionAborted => continue,
                    _ => {
                        self.accept_stalled = true;
                        return;
                    }
                },
            };
            if !same_user(&stream) {
                continue;
            }
            if stream.set_nonblocking(true).is_err() {
                continue;
            }
            wire::tune_socket(stream.as_raw_fd());
            if self.pending.len() >= MAX_PENDING {
                self.pending.remove(0);
            }
            self.pending.push(Pending {
                stream,
                reader: wire::Reader::default(),
                deadline: Instant::now() + HANDSHAKE,
            });
        }
    }

    /// Read a connection that has not authenticated. Its first frame must
    /// be a HELLO with the owner token: then it becomes the daemon link
    /// (replacing the old one), else it is dropped. Anything else keeps
    /// the attached daemon's link as it was.
    fn read_pending(&mut self, index: usize) {
        let pending = &mut self.pending[index];
        match pending.reader.fill(pending.stream.as_raw_fd()) {
            Ok(true) => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return,
            Ok(false) | Err(_) => {
                self.pending.swap_remove(index);
                return;
            }
        }
        let frame = match pending.reader.next_frame() {
            Ok(Some(frame)) => frame,
            Ok(None) => return,
            Err(_) => {
                self.pending.swap_remove(index);
                return;
            }
        };
        let pending = self.pending.swap_remove(index);
        if Kind::from_u16(frame.kind) != Some(Kind::Hello) {
            return;
        }
        let code = match self.check_hello(&frame.payload) {
            Ok(version) => {
                let listing = self.listing(version >= wire::RING_VERSION);
                return self.promote(pending, version, listing);
            }
            Err(code) => code,
        };
        // Best effort: the refused peer may already be gone, and dropping
        // it closes the connection either way.
        let payload = Out::default().u16(Kind::Hello as u16).u16(code).0;
        let frame = wire::encode(Kind::Error, 0, &payload);
        let _ = wire::send_with_fds(pending.stream.as_raw_fd(), &frame, &[]);
    }

    /// Make an authenticated connection the daemon link. The daemon it
    /// replaces always hears SUPERSEDED, however much was queued for it
    /// ([`Retiring`]), so it does not take the holder back.
    fn promote(&mut self, pending: Pending, version: u16, listing: Listing) {
        // A daemon that died with frames still unread (its last ACKs) ended
        // before this one connected: its end is a lost link (a strike, the
        // poison pill), not a takeover. A restart after a parser crash
        // connects at once, so the holder can see the new HELLO in the turn
        // that still reads the dead link's last bytes.
        if self.link_ended() {
            self.drop_link(LinkDrop::Lost);
        }
        if let Some(old) = self.drop_link(LinkDrop::Superseded) {
            let message = "another daemon took this holder";
            self.retire(Retiring::new(old, Kind::Hello as u16, error_code::SUPERSEDED, message));
        }
        self.links += 1;
        self.link = Some(Link {
            id: self.links,
            stream: pending.stream,
            reader: pending.reader,
            credit: version >= 2,
            rings: version >= wire::RING_VERSION,
            version,
            current: None,
            urgent: VecDeque::new(),
            bulk: VecDeque::new(),
            bulk_per_chan: HashMap::new(),
            out_bytes: 0,
        });
        self.welcome(version, listing);
        // Frames the daemon sent right behind its HELLO.
        if let Err(why) = self.drain_link_frames() {
            self.break_link(why);
        }
    }

    /// Write what a retiring link's socket takes now; poll it for the rest.
    fn retire(&mut self, mut retiring: Retiring) {
        if !retiring.write() {
            self.retiring.push(retiring);
        }
    }

    /// End the link reading it found broken. A daemon that is still there
    /// (a [`LinkBreak::Fault`]) hears why: ERROR `NO_DESCRIPTORS` when the
    /// holder could not take the descriptors it passed, `BAD_PAYLOAD` when
    /// its bytes were not frames of the wire, on channel 0 with request
    /// kind [`wire::STREAM_FAULT`], after the frame its socket had taken
    /// part of. Only a lost link counts a strike.
    fn break_link(&mut self, why: LinkBreak) {
        match why {
            LinkBreak::Lost => {
                self.drop_link(LinkDrop::Lost);
            }
            LinkBreak::Fault(fault, message) => {
                let code = match fault {
                    wire::Fault::Descriptors => error_code::NO_DESCRIPTORS,
                    wire::Fault::Malformed => error_code::BAD_PAYLOAD,
                };
                if let Some(link) = self.drop_link(LinkDrop::Faulted) {
                    self.retire(Retiring::new(link, wire::STREAM_FAULT, code, &message));
                }
            }
        }
    }

    /// Forget the link and return it (dropping it closes it). A link that
    /// was lost counts a strike against each terminal it was streaming (the
    /// poison pill); a DETACH before it ended, another daemon taking the
    /// holder, or a stream the holder could not read on, does not.
    fn drop_link(&mut self, why: LinkDrop) -> Option<Link> {
        let link = self.link.take()?;
        let now = Instant::now();
        for terminal in self.terminals.values_mut() {
            if why == LinkDrop::Lost && terminal.sent.is_some() {
                terminal.strike(now);
            }
            terminal.sent = None;
            terminal.held = None;
            terminal.exit_sent = false;
        }
        Some(link)
    }

    /// Read and handle the link's frames; an error says why the link ends.
    fn read_link(&mut self) -> Result<(), LinkBreak> {
        let Some(link) = self.link.as_mut() else { return Ok(()) };
        match link.reader.fill(link.stream.as_raw_fd()) {
            Ok(true) => {}
            Ok(false) => return Err(LinkBreak::Lost),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(error) => return Err(LinkBreak::of(&error)),
        }
        self.drain_link_frames()
    }

    /// Read and handle what the link has buffered, up to its end: true when
    /// it ended or broke. A live link stops at the first read that would
    /// block, or after [`LINK_END_READS`] reads (a daemon that keeps
    /// writing is alive).
    fn link_ended(&mut self) -> bool {
        for _ in 0..LINK_END_READS {
            let Some(link) = self.link.as_mut() else { return false };
            match link.reader.fill(link.stream.as_raw_fd()) {
                Ok(true) => {}
                Ok(false) => return true,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return false,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return true,
            }
            if self.drain_link_frames().is_err() {
                return true;
            }
        }
        false
    }

    /// Handle every complete frame the link has buffered; an error says
    /// why the link ends.
    fn drain_link_frames(&mut self) -> Result<(), LinkBreak> {
        loop {
            let Some(link) = self.link.as_mut() else { return Ok(()) };
            let frame = match link.reader.next_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => return Ok(()),
                Err(error) => return Err(LinkBreak::of(&error)),
            };
            self.handle(frame)?;
        }
    }

    /// Handle one frame from the authenticated daemon. An error ends the
    /// link.
    fn handle(&mut self, frame: Frame) -> Result<(), LinkBreak> {
        let (raw_kind, chan) = (frame.kind, frame.chan);
        let result = match Kind::from_u16(raw_kind) {
            // The link authenticated once, as a pending connection.
            Some(Kind::Hello) => {
                let message = "a HELLO on an authenticated link".to_string();
                return Err(LinkBreak::Fault(wire::Fault::Malformed, message));
            }
            Some(Kind::Spawn) => self.spawn(frame.chan, &frame.payload),
            Some(Kind::Adopt) => self.adopt(frame),
            Some(Kind::Attach) => self.attach(frame.chan, frame.flags, &frame.payload),
            Some(Kind::Write) => self.terminal(frame.chan).map(|terminal| {
                terminal.input.extend(&frame.payload);
            }),
            Some(Kind::Resize) => self.resize(frame.chan, &frame.payload),
            Some(Kind::Signal) => self.signal(frame.chan, &frame.payload),
            Some(Kind::Close) => self.close(frame.chan, &frame.payload),
            Some(Kind::Snapshot) => self.snapshot(frame.chan, &frame.payload),
            Some(Kind::Detach) => self.terminal(frame.chan).map(|terminal| {
                terminal.sent = None;
                terminal.held = None;
                terminal.exit_sent = false;
            }),
            Some(Kind::Ack) => {
                // An ACK for a terminal already forgotten is no error.
                if let (Ok(offset), Some(terminal)) =
                    (In(&frame.payload).u64(), self.terminals.get_mut(&frame.chan))
                {
                    terminal.acked = terminal.acked.max(offset);
                }
                Ok(())
            }
            Some(Kind::Ping) => {
                self.queue(Kind::Pong, 0, &frame.payload, Vec::new());
                Ok(())
            }
            _ => Err((error_code::UNKNOWN_KIND, "unknown kind".to_string())),
        };
        if let Err((code, message)) = result {
            let payload = Out::default().u16(raw_kind).u16(code).bytes(message.as_bytes()).0;
            self.queue(Kind::Error, chan, &payload, Vec::new());
        }
        Ok(())
    }

    /// The wire version both peers speak, or the error code that refuses
    /// the HELLO.
    fn check_hello(&self, payload: &[u8]) -> Result<u16, u16> {
        let mut input = In(payload);
        let (Ok(version), Ok(token)) = (input.u16(), input.array::<32>()) else {
            return Err(error_code::BAD_PAYLOAD);
        };
        if !constant_time_eq(&token, &self.token) {
            return Err(error_code::BAD_TOKEN);
        }
        if version < wire::MIN_VERSION {
            return Err(error_code::NO_COMMON_VERSION);
        }
        Ok(version.min(wire::VERSION))
    }

    /// Every terminal for a new link's WELCOME, with its master and
    /// (`rings`: a daemon of [`wire::RING_VERSION`]) its ring segment; an
    /// older daemon gets no segment (it could hand a layout 2 segment to a
    /// holder that knows only layout 1). No dup ([`Terminal::descriptors`]),
    /// so a holder short of descriptors still lists every terminal with both.
    fn listing(&self, rings: bool) -> Listing {
        self.terminals
            .iter()
            .map(|(chan, terminal)| {
                let listed = Listed {
                    chan: *chan,
                    id: terminal.id,
                    pid: terminal.pid,
                    oldest: terminal.ring.oldest(),
                    end: terminal.ring.end(),
                    exited: terminal.ended(),
                    master: None,
                    ring: None,
                };
                (*chan, listed.encode(), terminal.descriptors(rings))
            })
            .collect()
    }

    /// WELCOME the new link with `listing` ([`Self::listing`]).
    fn welcome(&mut self, version: u16, listing: Listing) {
        let welcome = Out::default().u16(version).u32(listing.len() as u32).0;
        self.queue(Kind::Welcome, 0, &welcome, Vec::new());
        for (chan, payload, fds) in listing {
            self.queue_flagged(Kind::Listed, ring_flag(&fds), chan, &payload, fds);
        }
    }

    fn spawn(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        if chan == 0 || self.terminals.contains_key(&chan) {
            return Err((error_code::CHAN_IN_USE, format!("channel {chan} is in use")));
        }
        let request = SpawnRequest::decode(payload)
            .map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let spawned = pty::spawn(&request, self.child_open_file_limit)
            .map_err(|error| (error_code::SPAWN_FAILED, error.to_string()))?;
        let mut terminal = Terminal::new(request.id, spawned.master, spawned.pid, true, 0);
        // Until the daemon's ATTACH (from 0) arrives, read no more than an
        // attached stream would.
        terminal.held = Some(terminal.ring.end());
        let (link, rings) = self.link.as_ref().map_or((0, false), |link| (link.id, link.rings));
        let custody = terminal.descriptors(rings);
        // Known at once, so the ATTACH right behind the SPAWN finds it;
        // nothing is sent for it until its child reported its start.
        terminal.starting = Some(Starting { start: spawned.start, custody, link });
        self.terminals.insert(chan, terminal);
        Ok(())
    }

    /// A starting terminal's child reported ([`pty::Start::poll`]): once
    /// its program runs, the hang-up of a CLOSE that came meanwhile, and
    /// SPAWNED with the custody descriptors to the link that asked; when it could
    /// not start, ERROR SPAWN_FAILED with what it
    /// could not do, and the terminal is forgotten (the child exits 127, or
    /// is killed when its report could not be read, and is reaped like any
    /// other). The error also goes to a link that attached the terminal
    /// meanwhile (a daemon that reconnected while it started), so its
    /// stream ends instead of waiting for ever.
    fn finish_start(&mut self, chan: u32) {
        let Some(terminal) = self.terminals.get_mut(&chan) else { return };
        let Some(result) = terminal.starting.as_mut().and_then(|starting| starting.start.poll())
        else {
            return;
        };
        let Some(starting) = terminal.starting.take() else { return };
        let (pid, attached, reaped) =
            (terminal.pid, terminal.sent.is_some(), terminal.status.is_some());
        let asked = self.link.as_ref().is_some_and(|link| link.id == starting.link);
        match result {
            Ok(()) => {
                // A CLOSE came while it started and its SIGKILL is still
                // due: the program runs now, with its own dispositions (a
                // child reaped already is not signaled: its pid is free).
                if terminal.closing && terminal.kill_at.is_some() && !reaped {
                    terminal.hang_up();
                }
                if asked {
                    let payload = Out::default().i32(pid).0;
                    let flags = ring_flag(&starting.custody);
                    self.queue_flagged(Kind::Spawned, flags, chan, &payload, starting.custody);
                }
            }
            Err(error) => {
                if !reaped {
                    // SAFETY: SIGKILL to this holder's own child, not reaped
                    // yet (its pid is still its own).
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                }
                if self.terminals.remove(&chan).is_some_and(|removed| removed.closing) {
                    self.closing -= 1;
                }
                if asked || attached {
                    let payload = Out::default()
                        .u16(Kind::Spawn as u16)
                        .u16(error_code::SPAWN_FAILED)
                        .bytes(error.to_string().as_bytes())
                        .0;
                    self.queue(Kind::Error, chan, &payload, Vec::new());
                }
            }
        }
    }

    fn adopt(&mut self, mut frame: Frame) -> Result<(), (u16, String)> {
        if frame.chan == 0 || self.terminals.contains_key(&frame.chan) {
            return Err((error_code::CHAN_IN_USE, format!("channel {} is in use", frame.chan)));
        }
        let mut input = In(&frame.payload);
        let parsed = (input.i32(), input.u64(), input.array::<16>());
        let (Ok(pid), Ok(base), Ok(id)) = parsed else {
            return Err((error_code::BAD_PAYLOAD, "short adopt".to_string()));
        };
        let with_ring = frame.flags & wire::FLAG_RING != 0;
        let resume = if with_ring {
            input.u64().map_err(|_| (error_code::BAD_PAYLOAD, "short adopt".to_string()))?
        } else {
            base
        };
        // The master first, then the ring segment.
        let mut fds = std::mem::take(&mut frame.fds).into_iter();
        let Some(master) = fds.next() else {
            return Err((error_code::BAD_PAYLOAD, "adopt carried no descriptor".to_string()));
        };
        pty::set_nonblocking(master.as_raw_fd());
        // The dead holder's ring, with every byte it read: the daemon
        // re-attaches from where it is and gets the bytes nobody sent. Any
        // other segment starts a fresh ring where the stream continues: one
        // that is not a ring, and one that ends before `resume` (a stale
        // segment, say the one the daemon kept after an earlier adoption fell
        // back to a fresh ring it never heard of). Continuing a stale ring
        // would number new output below what the daemon already parsed, and
        // the daemon would drop it as received: a silent splice.
        let mut ring = with_ring
            .then(|| fds.next())
            .flatten()
            .and_then(|segment| Ring::adopt(segment).ok())
            .filter(|ring| ring.end() >= resume)
            .unwrap_or_else(|| Ring::new(resume, RING_BYTES));
        let version = self.link.as_ref().map_or(0, |link| link.version);
        if version >= wire::RING_VERSION {
            // Only a holder of this version continues it from here on.
            ring.upgrade_layout();
        }
        let mut terminal = Terminal::with_ring(id, master, pid, false, ring);
        // The daemon ATTACHes right after its ADOPT: until then read no
        // more than an attached stream from `resume` would.
        terminal.held = Some(resume);
        terminal.prologue = input.rest().to_vec();
        terminal.prologue_base = base;
        // Tell the daemon which ring this holder writes (the one it was
        // handed, or a fresh one), so the custody copy it hands the next
        // holder is never one nobody writes.
        let adopted = (version >= wire::RING_VERSION).then(|| {
            let payload = Out::default().u64(terminal.ring.oldest()).u64(terminal.ring.end()).0;
            let fds: Vec<Arc<OwnedFd>> = terminal.ring.segment().cloned().into_iter().collect();
            (payload, fds)
        });
        self.terminals.insert(frame.chan, terminal);
        if let Some((payload, fds)) = adopted {
            let flags = if fds.is_empty() { 0 } else { wire::FLAG_RING };
            self.queue_flagged(Kind::Adopted, flags, frame.chan, &payload, fds);
        }
        Ok(())
    }

    /// Stream a terminal to the link from `from`. With
    /// [`wire::FLAG_WITH_PROLOGUE`] (a restarted daemon) the prologue goes
    /// first and the stream starts at its base; a terminal whose streams
    /// keep ending without DETACH skips its ring tail (the poison pill).
    /// The credit counts from the offset the daemon says it parsed (version
    /// 5), so bytes it received and has not parsed stay in the window.
    fn attach(&mut self, chan: u32, flags: u16, payload: &[u8]) -> Result<(), (u16, String)> {
        let mut input = In(payload);
        let from = input.u64().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let parsed = input.u64().ok();
        let terminal = self.terminal(chan)?;
        let (oldest, end) = (terminal.ring.oldest(), terminal.ring.end());
        let mut start = from.clamp(oldest, end);
        let mut frames = Vec::new();
        let with_prologue = flags & wire::FLAG_WITH_PROLOGUE != 0;
        if with_prologue && !terminal.prologue.is_empty() {
            let payload = Out::default().u64(terminal.prologue_base).bytes(&terminal.prologue).0;
            frames.push(wire::encode_flagged(Kind::Data, wire::FLAG_PROLOGUE, chan, &payload));
            // The prologue is the screen at its base: the ring before it
            // would replay twice.
            start = start.max(terminal.prologue_base.min(end));
        } else if from < oldest {
            frames.push(wire::encode(Kind::Gap, chan, &Out::default().u64(from).u64(oldest).0));
        }
        if with_prologue && terminal.poisoned(Instant::now()) {
            // Twice within a few seconds a daemon's link ended while it
            // parsed this terminal: its ring tail may be what crashes the
            // parser. Restore without it (the daemon hears a GAP).
            if end > start {
                frames.push(wire::encode(Kind::Gap, chan, &Out::default().u64(start).u64(end).0));
            }
            start = end;
            terminal.strikes.clear();
        }
        terminal.sent = Some(start);
        terminal.held = None;
        // The `from - parsed` bytes the daemon holds unparsed count against
        // its window (moved past a GAP with the stream): after an adoption
        // or a resume the holder sends at most the window past what the
        // daemon parsed, and the ring never holds more than the window plus
        // UNSENT_HIGH_WATER past it.
        terminal.acked = match parsed {
            Some(parsed) => start.saturating_sub(from.saturating_sub(parsed.min(from))),
            None => start,
        };
        terminal.exit_sent = false;
        if let Some(link) = self.link.as_mut() {
            for frame in frames {
                link.push(chan, frame, Vec::new());
            }
        }
        Ok(())
    }

    /// Keep a newer VT replay of the daemon's screen as the terminal's
    /// prologue. An older one, or one past the ring's end, is ignored.
    fn snapshot(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        let mut input = In(payload);
        let base = input.u64().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let terminal = self.terminal(chan)?;
        let newer = base >= terminal.prologue_base || terminal.prologue.is_empty();
        if newer && base <= terminal.ring.end() {
            terminal.prologue = input.rest().to_vec();
            terminal.prologue_base = base;
        }
        Ok(())
    }

    fn resize(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        let mut input = In(payload);
        let size = (input.u16(), input.u16(), input.u16(), input.u16());
        let (Ok(cols), Ok(rows), Ok(px_w), Ok(px_h)) = size else {
            return Err((error_code::BAD_PAYLOAD, "short resize".to_string()));
        };
        let terminal = self.terminal(chan)?;
        pty::resize(terminal.master.as_raw_fd(), cols, rows, px_w, px_h)
            .map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))
    }

    fn signal(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        let signal =
            In(payload).i32().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let terminal = self.terminal(chan)?;
        // SAFETY: signals this terminal's own process group (its session leader's pid).
        unsafe { libc::killpg(terminal.pid, signal) };
        terminal.signal_starting_child(signal);
        Ok(())
    }

    fn close(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        let grace = In(payload).u32().unwrap_or(2000);
        let terminal = self.terminal(chan)?;
        let was_closing = terminal.closing;
        terminal.closing = true;
        if terminal.ended() {
            // An attached daemon still has to get the rest of its output
            // and its EXIT: `retire_closed` forgets it after the pump sent
            // them. Otherwise it goes now.
            let exit_pending = terminal.sent.is_some() && !terminal.exit_sent;
            if !exit_pending {
                self.terminals.remove(&chan);
                if was_closing {
                    self.closing -= 1;
                }
            } else if !was_closing {
                self.closing += 1;
            }
            return Ok(());
        }
        // A child that has not run its program yet still has the holder's
        // signal dispositions (the hang-up ignored) and may lead no group
        // yet: its hang-up goes once the program runs ([`Self::finish_start`]),
        // and the grace's SIGKILL reaches it whatever stage it is at.
        if terminal.starting.is_none() {
            terminal.hang_up();
        }
        terminal.kill_at = Some(Instant::now() + Duration::from_millis(u64::from(grace)));
        if !was_closing {
            self.closing += 1;
        }
        Ok(())
    }

    fn terminal(&mut self, chan: u32) -> Result<&mut Terminal, (u16, String)> {
        self.terminals
            .get_mut(&chan)
            .ok_or_else(|| (error_code::UNKNOWN_CHAN, format!("no terminal on channel {chan}")))
    }

    fn kill_overdue(&mut self) {
        let now = Instant::now();
        for terminal in self.terminals.values_mut() {
            if terminal.kill_at.is_some_and(|at| at <= now) {
                terminal.kill_at = None;
                pty::signal_terminal(terminal.pid, terminal.master.as_raw_fd(), libc::SIGKILL);
                terminal.signal_starting_child(libc::SIGKILL);
            }
        }
    }

    /// Read the master (non-blocking) straight into the ring: at most the
    /// terminal's room, and at most [`READ_PER_TURN`] per wakeup. Each read
    /// is in the ring (a shared segment the daemon keeps a dup of) the
    /// moment it returns, so a holder crash loses no byte it read.
    ///
    /// After a read that returned less than its room, the master is asked
    /// whether it has more (a zero-timeout `poll`) before another read
    /// starts: the read that would only say `EAGAIN` (the last one of
    /// nearly every turn, one per keystroke echo) is never made. Every ring
    /// read publishes `reading` before it starts, so a holder killed inside
    /// such a read left a marker for a loss that did not happen, and the
    /// daemon put a CAN at that read boundary, often inside an escape
    /// sequence. A read is now made only when the master is readable, so a
    /// marker names a read that could take bytes. A flood still reads the
    /// whole turn's share in one turn.
    fn read_terminal(&mut self, chan: u32) -> ReadEnd {
        let Some(terminal) = self.terminals.get_mut(&chan) else { return ReadEnd::Eof };
        let mut read = 0;
        loop {
            let len = (64 * 1024).min(terminal.room()).min(READ_PER_TURN - read);
            if len == 0 {
                return ReadEnd::Stopped;
            }
            let master = terminal.master.as_raw_fd();
            let mut offered = 0;
            let n = terminal.ring.read_with(len, |room| {
                offered = room.len();
                // SAFETY: reads into a live slice of the ring of `room.len()` bytes.
                unsafe { libc::read(master, room.as_mut_ptr().cast(), room.len()) }
            });
            if n > 0 {
                read += n as usize;
                cmux_flow_trace::hop_id("holder.pty.read", 0, &terminal.id);
                if (n as usize) < offered && !readable_now(master) {
                    return ReadEnd::Drained;
                }
                continue;
            }
            if n == 0 {
                terminal.eof = true;
                return ReadEnd::Eof;
            }
            match io::Error::last_os_error().kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => return ReadEnd::Drained,
                // EIO: every slave closed (the child and its group ended).
                _ => {
                    terminal.eof = true;
                    return ReadEnd::Eof;
                }
            }
        }
    }

    /// A child that ended ends its terminal once the holder read what it
    /// printed, as on the local path: a background job that still holds
    /// the PTY open does not keep the terminal, and no master dup the
    /// daemon holds can delay the end.
    fn finish_ending(&mut self) {
        if self.ending.is_empty() {
            return;
        }
        let ending = std::mem::take(&mut self.ending);
        for chan in ending {
            let open =
                self.terminals.get(&chan).map(|terminal| (terminal.eof, terminal.room() > 0));
            let end = match open {
                Some((false, true)) => self.read_terminal(chan),
                Some((false, false)) => ReadEnd::Stopped,
                _ => continue,
            };
            match end {
                ReadEnd::Drained => {
                    if let Some(terminal) = self.terminals.get_mut(&chan) {
                        terminal.eof = true;
                    }
                }
                ReadEnd::Stopped => self.ending.push(chan),
                ReadEnd::Eof => {}
            }
        }
    }

    fn write_terminal(&mut self, chan: u32) {
        let Some(terminal) = self.terminals.get_mut(&chan) else { return };
        while !terminal.input.is_empty() {
            let (head, _) = terminal.input.as_slices();
            // SAFETY: writes from a live slice.
            let n = unsafe {
                libc::write(terminal.master.as_raw_fd(), head.as_ptr().cast(), head.len())
            };
            if n > 0 {
                terminal.input.drain(..n as usize);
                continue;
            }
            match io::Error::last_os_error().kind() {
                _ if n == 0 => return,
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => return,
                // EIO: nobody reads this PTY any more; its input goes nowhere.
                _ => {
                    terminal.input.clear();
                    return;
                }
            }
        }
    }

    /// Reap every exited child this holder started.
    fn reap(&mut self) {
        let mut drain = [0u8; 64];
        // SAFETY: drains the non-blocking self-pipe.
        while unsafe {
            libc::read(self.sigchld.as_raw_fd(), drain.as_mut_ptr().cast(), drain.len())
        } > 0
        {}
        loop {
            let mut status = 0;
            // SAFETY: reaps any exited child of this process.
            let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
            if pid <= 0 {
                return;
            }
            let exit = if libc::WIFSIGNALED(status) {
                ExitStatus::Signaled(libc::WTERMSIG(status))
            } else {
                ExitStatus::Exited(libc::WEXITSTATUS(status))
            };
            if let Some((chan, terminal)) =
                self.terminals.iter_mut().find(|(_, t)| t.pid == pid && t.own_child)
            {
                terminal.status = Some(exit);
                if ENDS_ON_CHILD_EXIT && !terminal.eof {
                    self.ending.push(*chan);
                }
            }
        }
    }

    /// Forget closed terminals that ended, once an attached daemon got
    /// their EXIT. Nothing else frees a terminal no daemon claims.
    fn retire_closed(&mut self) {
        if self.closing == 0 {
            return;
        }
        self.terminals.retain(|_, terminal| {
            !(terminal.closing
                && terminal.ended()
                && (terminal.sent.is_none() || terminal.exit_sent))
        });
        self.closing = self.terminals.values().filter(|terminal| terminal.closing).count();
    }

    /// Make DATA (and EXIT after the last byte) for the attached daemon,
    /// then write what the link takes. Each pump starts at the terminal
    /// after the one the last pump started at and gives every terminal
    /// with output an equal share of the queue, so a quiet terminal's echo
    /// never waits for the lower channels to run dry.
    fn pump(&mut self) {
        let Some(link) = self.link.as_mut() else { return };
        let credit = link.credit;
        let ready: Vec<u32> = self
            .terminals
            .iter()
            .filter(|(_, terminal)| terminal.sendable(credit))
            .map(|(chan, _)| *chan)
            .collect();
        if !ready.is_empty() {
            let mut budget = LINK_QUEUE_BYTES.saturating_sub(link.out_bytes);
            let share = (budget / ready.len()).max(MIN_SHARE);
            let first = ready.iter().position(|chan| *chan >= self.pump_cursor).unwrap_or(0);
            self.pump_cursor = ready[first].wrapping_add(1);
            for chan in ready[first..].iter().chain(&ready[..first]) {
                let Some(terminal) = self.terminals.get_mut(chan) else { continue };
                let Some(mut sent) = terminal.sent else { continue };
                // Never splice output silently: bytes the ring dropped
                // before they were sent are a GAP the daemon hears about.
                let oldest = terminal.ring.oldest();
                if sent < oldest {
                    let gap = Out::default().u64(sent).u64(oldest).0;
                    link.push(*chan, wire::encode(Kind::Gap, *chan, &gap), Vec::new());
                    sent = oldest;
                }
                let limit = terminal.send_limit(credit).min(terminal.ring.end());
                let mut allowed = share.min(budget);
                while allowed > 0 && sent < limit {
                    let max = DATA_CHUNK.min(allowed).min((limit - sent) as usize);
                    let (from, head, tail) = terminal.ring.slices(sent, max);
                    let len = head.len() + tail.len();
                    if len == 0 {
                        break;
                    }
                    let offset = from.to_le_bytes();
                    let frame =
                        wire::encode_parts(Kind::Data, 0, *chan, &[&offset[..], head, tail]);
                    link.push(*chan, frame, Vec::new());
                    allowed -= len;
                    budget = budget.saturating_sub(len);
                    sent = from + len as u64;
                }
                terminal.sent = Some(sent);
                if sent >= terminal.ring.end() && !terminal.exit_sent && terminal.ended() {
                    let (kind, code) = terminal.status.unwrap_or(ExitStatus::Unobserved).encode();
                    let payload = Out::default().u8(kind).i32(code).u64(terminal.ring.end()).0;
                    link.push(*chan, wire::encode(Kind::Exit, *chan, &payload), Vec::new());
                    terminal.exit_sent = true;
                }
            }
        }
        if !self.flush_link() {
            self.drop_link(LinkDrop::Lost);
        }
    }

    fn queue(&mut self, kind: Kind, chan: u32, payload: &[u8], fds: Vec<Arc<OwnedFd>>) {
        self.queue_flagged(kind, 0, chan, payload, fds);
    }

    fn queue_flagged(
        &mut self,
        kind: Kind,
        flags: u16,
        chan: u32,
        payload: &[u8],
        fds: Vec<Arc<OwnedFd>>,
    ) {
        if let Some(link) = self.link.as_mut() {
            let frame = wire::encode_with_fds(kind, flags, chan, payload, fds.len());
            link.push(chan, frame, fds);
        }
    }

    /// Write queued frames until the socket would block: a frame the
    /// socket took part of first, then small frames, then bulk. False when
    /// lost.
    fn flush_link(&mut self) -> bool {
        let Some(link) = self.link.as_mut() else { return true };
        loop {
            if link.current.is_none() {
                link.current = link.next();
            }
            let Some(frame) = link.current.as_mut() else { return true };
            // The descriptors go with the frame's first byte.
            let fds: Vec<RawFd> = if frame.written == 0 {
                frame.fds.iter().map(|fd| fd.as_raw_fd()).collect()
            } else {
                Vec::new()
            };
            match wire::send_with_fds(link.stream.as_raw_fd(), &frame.bytes[frame.written..], &fds)
            {
                Ok(n) => {
                    if n > 0 {
                        frame.fds.clear();
                    }
                    frame.written += n;
                    link.out_bytes -= n;
                    if frame.written < frame.bytes.len() {
                        return true;
                    }
                    link.current = None;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(_) => return false,
            }
        }
    }
}

impl Terminal {
    fn new(id: [u8; 16], master: OwnedFd, pid: libc::pid_t, own_child: bool, base: u64) -> Self {
        Self::with_ring(id, master, pid, own_child, Ring::new(base, RING_BYTES))
    }

    /// A terminal whose output continues `ring` (a dead holder's segment).
    fn with_ring(
        id: [u8; 16],
        master: OwnedFd,
        pid: libc::pid_t,
        own_child: bool,
        ring: Ring,
    ) -> Self {
        let base = ring.end();
        Self {
            id,
            master: Arc::new(master),
            pid,
            own_child,
            starting: None,
            ring,
            status: None,
            eof: false,
            exit_sent: false,
            sent: None,
            held: None,
            acked: base,
            closing: false,
            input: VecDeque::new(),
            kill_at: None,
            prologue: Vec::new(),
            prologue_base: base,
            strikes: Vec::new(),
        }
    }

    /// What a frame passes a daemon for this terminal: the master, then
    /// (with `rings`, when the ring is shared) the ring segment. Handles
    /// shared with the terminal, not dups: the frame keeps both open until
    /// its first byte is written, even if the terminal is forgotten before,
    /// and making them costs the holder no descriptor, so a holder short of
    /// descriptors never lists or answers a SPAWN without one.
    fn descriptors(&self, rings: bool) -> Vec<Arc<OwnedFd>> {
        let mut fds = vec![self.master.clone()];
        if rings && let Some(segment) = self.ring.segment() {
            fds.push(segment.clone());
        }
        fds
    }

    /// The child ended (or, adopted, cannot be waited for) and no more
    /// output will be read. Never before the child reported its start: a
    /// terminal whose child could not start is forgotten with an error, not
    /// ended.
    fn ended(&self) -> bool {
        self.starting.is_none() && self.eof && (self.status.is_some() || !self.own_child)
    }

    /// Bytes the holder may read from the master now. Attached (or adopted
    /// and waiting for its ATTACH), at most [`UNSENT_HIGH_WATER`] bytes wait
    /// unsent; unattached, the ring keeps the newest bytes and reading never
    /// stops.
    fn room(&self) -> usize {
        match self.sent.or(self.held) {
            Some(sent) => {
                let unsent = self.ring.end().saturating_sub(sent);
                UNSENT_HIGH_WATER.saturating_sub(usize::try_from(unsent).unwrap_or(usize::MAX))
            }
            None => usize::MAX,
        }
    }

    /// Offset the attached daemon may be sent up to: its credit, when it
    /// acknowledges (wire version 2).
    fn send_limit(&self, credit: bool) -> u64 {
        if credit { self.acked.saturating_add(wire::CREDIT_WINDOW) } else { u64::MAX }
    }

    /// Whether the attached daemon may be sent something now: a GAP, output
    /// within its credit, or the EXIT after the last byte. Nothing before
    /// its SPAWNED: its child has not reported its start yet.
    fn sendable(&self, credit: bool) -> bool {
        self.starting.is_none()
            && self.sent.is_some_and(|sent| {
                let end = self.ring.end();
                sent < self.ring.oldest()
                    || (sent < end && sent < self.send_limit(credit))
                    || (sent >= end && !self.exit_sent && self.ended())
            })
    }

    /// Hang up the terminal's groups: SIGHUP, then SIGTERM
    /// ([`pty::signal_terminal`]).
    fn hang_up(&self) {
        for signal in [libc::SIGHUP, libc::SIGTERM] {
            pty::signal_terminal(self.pid, self.master.as_raw_fd(), signal);
        }
    }

    /// Send `signal` to the child itself while it has not run its program
    /// yet: before its `setsid` it leads no group and the PTY has no
    /// foreground group, so a group signal misses it (a CLOSE or SIGNAL
    /// right behind its SPAWN). It is this holder's own child and is not
    /// reaped yet, so its pid is still its own.
    fn signal_starting_child(&self, signal: libc::c_int) {
        if self.starting.is_some() && self.status.is_none() {
            // SAFETY: signals this holder's own child, not reaped yet.
            unsafe { libc::kill(self.pid, signal) };
        }
    }

    /// Record a link that ended while it streamed this terminal.
    fn strike(&mut self, now: Instant) {
        self.strikes.retain(|at| now.saturating_duration_since(*at) < STRIKE_WINDOW);
        self.strikes.push(now);
    }

    /// Whether recent streams of this terminal kept ending without DETACH.
    fn poisoned(&self, now: Instant) -> bool {
        self.strikes.iter().filter(|at| now.saturating_duration_since(**at) < STRIKE_WINDOW).count()
            >= POISON_STRIKES
    }
}

/// [`wire::FLAG_RING`] when `fds` carries a ring segment after the master.
fn ring_flag(fds: &[Arc<OwnedFd>]) -> u16 {
    if fds.len() > 1 { wire::FLAG_RING } else { 0 }
}

fn pollfd(fd: RawFd, events: libc::c_short) -> libc::pollfd {
    libc::pollfd { fd, events, revents: 0 }
}

/// Whether a read of `master` would not block now: it has bytes, or its
/// slaves closed (the read then reports the end). Never waits.
fn readable_now(master: RawFd) -> bool {
    let mut fds = [pollfd(master, libc::POLLIN)];
    loop {
        // SAFETY: polls one live pollfd with a zero timeout.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, 0) };
        if ready >= 0 {
            return ready > 0
                && fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0;
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            // Let the read say what is wrong.
            return true;
        }
    }
}

fn constant_time_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The peer runs as this process's user (the threat model: other users only).
fn same_user(stream: &UnixStream) -> bool {
    peer_uid(stream.as_raw_fd()).is_some_and(|uid| {
        // SAFETY: getuid has no failure mode.
        uid == unsafe { libc::getuid() }
    })
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
fn peer_uid(fd: RawFd) -> Option<libc::uid_t> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: out-pointers to live locals.
    (unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0).then_some(uid)
}

#[cfg(target_os = "linux")]
fn peer_uid(fd: RawFd) -> Option<libc::uid_t> {
    // SAFETY: zeroed ucred is a valid out-buffer.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: SO_PEERCRED fills one ucred.
    let ok = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    } == 0;
    ok.then_some(cred.uid)
}
