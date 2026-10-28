//! The holder's single-threaded event loop.
//!
//! One `poll` set: the listening socket, the daemon link, connections that
//! have not said HELLO yet, a self-pipe for SIGCHLD (and a launchd SIGTERM)
//! and every PTY master. While no daemon is attached to a terminal its
//! output is read as soon as it is ready and its ring keeps the newest
//! bytes. While a daemon is attached nothing is lost: the holder reads a
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
}

struct Terminal {
    id: [u8; 16],
    master: OwnedFd,
    pid: libc::pid_t,
    /// This holder started the child, so it reaps it and reads its status.
    own_child: bool,
    ring: Ring,
    status: Option<ExitStatus>,
    /// The master read end of file or EIO: every slave closed.
    eof: bool,
    exit_sent: bool,
    /// Next offset to send the attached daemon; `None` while not attached.
    sent: Option<u64>,
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

/// One frame waiting for the link, with the descriptor it passes.
struct OutFrame {
    chan: u32,
    bytes: Vec<u8>,
    fd: Option<OwnedFd>,
    /// Bytes of it the socket already took.
    written: usize,
}

/// The authenticated daemon link.
struct Link {
    stream: UnixStream,
    reader: wire::Reader,
    /// The daemon acknowledges what it parsed (wire version 2).
    credit: bool,
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
    fn push(&mut self, chan: u32, bytes: Vec<u8>, fd: Option<OwnedFd>) {
        self.out_bytes += bytes.len();
        let urgent = bytes.len() <= URGENT_FRAME_BYTES && !self.bulk_per_chan.contains_key(&chan);
        let frame = OutFrame { chan, bytes, fd, written: 0 };
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

/// A connection that has not authenticated yet. It never touches the
/// current link: a liveness probe, a stale token or any local tool cannot
/// drop the daemon that is attached.
struct Pending {
    stream: UnixStream,
    reader: wire::Reader,
    deadline: Instant,
}

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
}

/// The holder state.
pub struct Holder {
    listener: UnixListener,
    /// The socket file, removed when the holder exits.
    socket: Option<PathBuf>,
    token: [u8; 32],
    link: Option<Link>,
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
            socket,
            token,
            link: None,
            pending: Vec::new(),
            terminals: BTreeMap::new(),
            ending: Vec::new(),
            closing: 0,
            pump_cursor: 0,
            child_open_file_limit: None,
            idle_since: Some(Instant::now()),
            idle_exit: IDLE_EXIT,
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
        let mut fds = vec![
            pollfd(self.listener.as_raw_fd(), libc::POLLIN),
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
        let first_pending = fds.len();
        for pending in &self.pending {
            fds.push(pollfd(pending.stream.as_raw_fd(), libc::POLLIN));
        }
        let pending_count = self.pending.len();
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
            && !self.read_link()
        {
            self.drop_link(LinkDrop::Lost);
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
        let idle = self.terminals.is_empty() && self.link.is_none();
        self.idle_since = if idle { Some(self.idle_since.unwrap_or(now)) } else { None };
        Ok(())
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
        kill.into_iter().chain(handshake).chain(idle).min()
    }

    /// Take new connections. They wait in `pending` until they authenticate;
    /// the attached daemon keeps its link meanwhile.
    fn accept(&mut self) {
        while let Ok((stream, _)) = self.listener.accept() {
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
        match self.check_hello(&frame.payload) {
            Ok(version) => self.promote(pending, version),
            Err(code) => {
                // Best effort: the refused peer may already be gone.
                let payload = Out::default().u16(Kind::Hello as u16).u16(code).0;
                let frame = wire::encode(Kind::Error, 0, &payload);
                let _ = wire::send_with_fds(pending.stream.as_raw_fd(), &frame, &[]);
            }
        }
    }

    /// Make an authenticated connection the daemon link. The daemon it
    /// replaces hears SUPERSEDED (when its queue lets that through) so it
    /// does not take the holder back.
    fn promote(&mut self, pending: Pending, version: u16) {
        if self.flush_link()
            && let Some(old) = self.link.as_ref()
            && !old.has_output()
        {
            let payload = Out::default()
                .u16(Kind::Hello as u16)
                .u16(error_code::SUPERSEDED)
                .bytes(b"another daemon took this holder")
                .0;
            let frame = wire::encode(Kind::Error, 0, &payload);
            let _ = wire::send_with_fds(old.stream.as_raw_fd(), &frame, &[]);
        }
        self.drop_link(LinkDrop::Superseded);
        self.link = Some(Link {
            stream: pending.stream,
            reader: pending.reader,
            credit: version >= 2,
            current: None,
            urgent: VecDeque::new(),
            bulk: VecDeque::new(),
            bulk_per_chan: HashMap::new(),
            out_bytes: 0,
        });
        self.welcome(version);
        // Frames the daemon sent right behind its HELLO.
        if !self.drain_link_frames() {
            self.drop_link(LinkDrop::Lost);
        }
    }

    /// Forget the link. A link that was lost counts a strike against each
    /// terminal it was streaming (the poison pill); a DETACH before it
    /// ended, or another daemon taking the holder, does not.
    fn drop_link(&mut self, why: LinkDrop) {
        if self.link.take().is_none() {
            return;
        }
        let now = Instant::now();
        for terminal in self.terminals.values_mut() {
            if why == LinkDrop::Lost && terminal.sent.is_some() {
                terminal.strike(now);
            }
            terminal.sent = None;
            terminal.exit_sent = false;
        }
    }

    /// Read and handle the link's frames. False when the link is lost.
    fn read_link(&mut self) -> bool {
        let Some(link) = self.link.as_mut() else { return true };
        match link.reader.fill(link.stream.as_raw_fd()) {
            Ok(true) => {}
            Ok(false) => return false,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
            Err(_) => return false,
        }
        self.drain_link_frames()
    }

    /// Handle every complete frame the link has buffered. False when the
    /// link is lost.
    fn drain_link_frames(&mut self) -> bool {
        loop {
            let Some(link) = self.link.as_mut() else { return true };
            let frame = match link.reader.next_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => return true,
                Err(_) => return false,
            };
            if !self.handle(frame) {
                return false;
            }
        }
    }

    /// Handle one frame from the authenticated daemon. False closes the
    /// link.
    fn handle(&mut self, frame: Frame) -> bool {
        let (raw_kind, chan) = (frame.kind, frame.chan);
        let result = match Kind::from_u16(raw_kind) {
            // The link authenticated once, as a pending connection.
            Some(Kind::Hello) => return false,
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
                self.queue(Kind::Pong, 0, &frame.payload, None);
                Ok(())
            }
            _ => Err((error_code::UNKNOWN_KIND, "unknown kind".to_string())),
        };
        if let Err((code, message)) = result {
            let payload = Out::default().u16(raw_kind).u16(code).bytes(message.as_bytes()).0;
            self.queue(Kind::Error, chan, &payload, None);
        }
        true
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

    /// WELCOME the new link with every terminal and a master dup of each.
    fn welcome(&mut self, version: u16) {
        let listed: Vec<(u32, Vec<u8>, Option<OwnedFd>)> = self
            .terminals
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
                };
                (*chan, listed.encode(), terminal.master.try_clone().ok())
            })
            .collect();
        let welcome = Out::default().u16(version).u32(listed.len() as u32).0;
        self.queue(Kind::Welcome, 0, &welcome, None);
        for (chan, payload, master) in listed {
            self.queue(Kind::Listed, chan, &payload, master);
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
        let custody = spawned
            .master
            .try_clone()
            .map_err(|error| (error_code::SPAWN_FAILED, error.to_string()))?;
        let terminal = Terminal::new(request.id, spawned.master, spawned.pid, true, 0);
        self.terminals.insert(chan, terminal);
        self.queue(Kind::Spawned, chan, &Out::default().i32(spawned.pid).0, Some(custody));
        Ok(())
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
        let Some(master) = frame.fds.pop() else {
            return Err((error_code::BAD_PAYLOAD, "adopt carried no descriptor".to_string()));
        };
        pty::set_nonblocking(master.as_raw_fd());
        let mut terminal = Terminal::new(id, master, pid, false, base);
        terminal.prologue = input.rest().to_vec();
        self.terminals.insert(frame.chan, terminal);
        Ok(())
    }

    /// Stream a terminal to the link from `from`. With
    /// [`wire::FLAG_WITH_PROLOGUE`] (a restarted daemon) the prologue goes
    /// first and the stream starts at its base; a terminal whose streams
    /// keep ending without DETACH skips its ring tail (the poison pill).
    fn attach(&mut self, chan: u32, flags: u16, payload: &[u8]) -> Result<(), (u16, String)> {
        let from =
            In(payload).u64().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
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
        terminal.acked = start;
        terminal.exit_sent = false;
        if let Some(link) = self.link.as_mut() {
            for frame in frames {
                link.push(chan, frame, None);
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
        pty::signal_terminal(terminal.pid, terminal.master.as_raw_fd(), libc::SIGHUP);
        pty::signal_terminal(terminal.pid, terminal.master.as_raw_fd(), libc::SIGTERM);
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
            }
        }
    }

    /// Read the master (non-blocking) into the ring: at most the
    /// terminal's room, and at most [`READ_PER_TURN`] per wakeup.
    fn read_terminal(&mut self, chan: u32) -> ReadEnd {
        let Some(terminal) = self.terminals.get_mut(&chan) else { return ReadEnd::Eof };
        let mut buf = [0u8; 64 * 1024];
        let mut read = 0;
        loop {
            let len = buf.len().min(terminal.room()).min(READ_PER_TURN - read);
            if len == 0 {
                return ReadEnd::Stopped;
            }
            // SAFETY: reads into a live buffer of at least `len` bytes.
            let n =
                unsafe { libc::read(terminal.master.as_raw_fd(), buf.as_mut_ptr().cast(), len) };
            if n > 0 {
                terminal.ring.push(&buf[..n as usize]);
                read += n as usize;
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
                    link.push(*chan, wire::encode(Kind::Gap, *chan, &gap), None);
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
                    link.push(*chan, frame, None);
                    allowed -= len;
                    budget = budget.saturating_sub(len);
                    sent = from + len as u64;
                }
                terminal.sent = Some(sent);
                if sent >= terminal.ring.end() && !terminal.exit_sent && terminal.ended() {
                    let (kind, code) = terminal.status.unwrap_or(ExitStatus::Unobserved).encode();
                    let payload = Out::default().u8(kind).i32(code).u64(terminal.ring.end()).0;
                    link.push(*chan, wire::encode(Kind::Exit, *chan, &payload), None);
                    terminal.exit_sent = true;
                }
            }
        }
        if !self.flush_link() {
            self.drop_link(LinkDrop::Lost);
        }
    }

    fn queue(&mut self, kind: Kind, chan: u32, payload: &[u8], fd: Option<OwnedFd>) {
        if let Some(link) = self.link.as_mut() {
            link.push(chan, wire::encode(kind, chan, payload), fd);
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
            // The descriptor goes with the frame's first byte.
            let fd = frame.fd.as_ref().filter(|_| frame.written == 0).map(AsRawFd::as_raw_fd);
            match wire::send_with_fds(
                link.stream.as_raw_fd(),
                &frame.bytes[frame.written..],
                fd.as_slice(),
            ) {
                Ok(n) => {
                    if n > 0 {
                        frame.fd = None;
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
        Self {
            id,
            master,
            pid,
            own_child,
            ring: Ring::new(base, RING_BYTES),
            status: None,
            eof: false,
            exit_sent: false,
            sent: None,
            acked: base,
            closing: false,
            input: VecDeque::new(),
            kill_at: None,
            prologue: Vec::new(),
            prologue_base: base,
            strikes: Vec::new(),
        }
    }

    /// The child ended (or, adopted, cannot be waited for) and no more
    /// output will be read.
    fn ended(&self) -> bool {
        self.eof && (self.status.is_some() || !self.own_child)
    }

    /// Bytes the holder may read from the master now. Attached, at most
    /// [`UNSENT_HIGH_WATER`] bytes wait unsent; unattached, the ring keeps
    /// the newest bytes and reading never stops.
    fn room(&self) -> usize {
        match self.sent {
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
    /// within its credit, or the EXIT after the last byte.
    fn sendable(&self, credit: bool) -> bool {
        self.sent.is_some_and(|sent| {
            let end = self.ring.end();
            sent < self.ring.oldest()
                || (sent < end && sent < self.send_limit(credit))
                || (sent >= end && !self.exit_sent && self.ended())
        })
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

fn pollfd(fd: RawFd, events: libc::c_short) -> libc::pollfd {
    libc::pollfd { fd, events, revents: 0 }
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
