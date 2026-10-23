//! The holder's single-threaded event loop.
//!
//! One `poll` set: the listening socket, the daemon link, connections that
//! have not said HELLO yet, a self-pipe for SIGCHLD and every PTY master.
//! While no daemon is attached to a terminal its output is read as soon as
//! it is ready and its ring keeps the newest bytes. While a daemon is
//! attached nothing is lost: the holder reads a master only while fewer than
//! [`UNSENT_HIGH_WATER`] bytes wait unsent, sends at most
//! [`wire::CREDIT_WINDOW`] past what the daemon acknowledged it parsed, and
//! a shell that prints faster than that blocks in its PTY, as on a direct
//! PTY. No timers: `poll` waits forever unless a CLOSE grace or a handshake
//! deadline is pending.

use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicI32, Ordering};
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
    /// SIGKILL the group at this time (a CLOSE's grace).
    kill_at: Option<Instant>,
    /// A VT replay of the screen at `prologue_base` (an adopted terminal:
    /// the daemon's parsed screen when this holder took it over), sent
    /// before the ring to a daemon that asks, so a restart after a holder
    /// crash still restores the screen.
    prologue: Vec<u8>,
    prologue_base: u64,
}

/// The authenticated daemon link.
struct Link {
    stream: UnixStream,
    reader: wire::Reader,
    /// The daemon acknowledges what it parsed (wire version 2).
    credit: bool,
    /// Frames to write, each with the descriptor it passes.
    out: VecDeque<(Vec<u8>, Option<OwnedFd>)>,
    out_bytes: usize,
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

/// The holder state.
pub struct Holder {
    listener: UnixListener,
    token: [u8; 32],
    link: Option<Link>,
    pending: Vec<Pending>,
    terminals: BTreeMap<u32, Terminal>,
    /// Terminals whose child ended but whose master is not at end of file
    /// yet: read what the child printed, then stop reading.
    ending: Vec<u32>,
    /// Terminals with `closing` set.
    closing: usize,
    sigchld: OwnedFd,
}

static SIGCHLD_WRITE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_sigchld(_: libc::c_int) {
    let fd = SIGCHLD_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write is async-signal-safe; a full pipe already wakes the loop.
        unsafe { libc::write(fd, [1u8].as_ptr().cast(), 1) };
    }
}

impl Holder {
    /// A holder serving `listener`, accepting daemons that present `token`.
    pub fn new(listener: UnixListener, token: [u8; 32]) -> io::Result<Self> {
        listener.set_nonblocking(true)?;
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            pty::set_cloexec(fd);
            pty::set_nonblocking(fd);
        }
        SIGCHLD_WRITE.store(fds[1], Ordering::Relaxed);
        // SAFETY: installs an async-signal-safe handler.
        unsafe {
            libc::signal(
                libc::SIGCHLD,
                on_sigchld as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )
        };
        // SAFETY: pipe returned fds[0]; fds[1] stays open for the handler.
        let sigchld = unsafe { std::os::fd::FromRawFd::from_raw_fd(fds[0]) };
        Ok(Self {
            listener,
            token,
            link: None,
            pending: Vec::new(),
            terminals: BTreeMap::new(),
            ending: Vec::new(),
            closing: 0,
            sigchld,
        })
    }

    /// Serve until the process ends. The holder outlives every daemon.
    pub fn run(&mut self) -> io::Result<()> {
        loop {
            self.turn()?;
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
            if !link.out.is_empty() || self.unsent_output(link.credit) {
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
            self.drop_link();
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
        Ok(())
    }

    /// Whether some attached terminal has output (or its EXIT) the link may
    /// take now. Output past a terminal's credit does not count: it waits
    /// for an ACK, not for the socket.
    fn unsent_output(&self, credit: bool) -> bool {
        self.terminals.values().any(|terminal| {
            terminal.sent.is_some_and(|sent| {
                let end = terminal.ring.end();
                (sent < end && sent < terminal.send_limit(credit))
                    || (sent >= end && Self::exit_due(terminal))
            })
        })
    }

    fn next_deadline(&self) -> Option<Instant> {
        let kill = self.terminals.values().filter_map(|terminal| terminal.kill_at).min();
        let handshake = self.pending.iter().map(|pending| pending.deadline).min();
        kill.into_iter().chain(handshake).min()
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
            && old.out.is_empty()
        {
            let payload = Out::default()
                .u16(Kind::Hello as u16)
                .u16(error_code::SUPERSEDED)
                .bytes(b"another daemon took this holder")
                .0;
            let frame = wire::encode(Kind::Error, 0, &payload);
            let _ = wire::send_with_fds(old.stream.as_raw_fd(), &frame, &[]);
        }
        self.drop_link();
        self.link = Some(Link {
            stream: pending.stream,
            reader: pending.reader,
            credit: version >= 2,
            out: VecDeque::new(),
            out_bytes: 0,
        });
        self.welcome(version);
        // Frames the daemon sent right behind its HELLO.
        if !self.drain_link_frames() {
            self.drop_link();
        }
    }

    fn drop_link(&mut self) {
        self.link = None;
        for terminal in self.terminals.values_mut() {
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
        let spawned =
            pty::spawn(&request).map_err(|error| (error_code::SPAWN_FAILED, error.to_string()))?;
        let custody = spawned
            .master
            .try_clone()
            .map_err(|error| (error_code::SPAWN_FAILED, error.to_string()))?;
        self.terminals
            .insert(chan, Terminal::new(request.id, spawned.master, spawned.pid, true, 0));
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

    fn attach(&mut self, chan: u32, flags: u16, payload: &[u8]) -> Result<(), (u16, String)> {
        let from =
            In(payload).u64().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let terminal = self.terminal(chan)?;
        let oldest = terminal.ring.oldest();
        let start = from.clamp(oldest, terminal.ring.end());
        terminal.sent = Some(start);
        terminal.acked = start;
        terminal.exit_sent = false;
        // The prologue holds while the ring still starts at its base.
        if oldest > terminal.prologue_base {
            terminal.prologue = Vec::new();
        }
        if flags & wire::FLAG_WITH_PROLOGUE != 0 && !terminal.prologue.is_empty() {
            let payload = Out::default().u64(terminal.prologue_base).bytes(&terminal.prologue).0;
            let frame = wire::encode_flagged(Kind::Data, wire::FLAG_PROLOGUE, chan, &payload);
            if let Some(link) = self.link.as_mut() {
                link.out_bytes += frame.len();
                link.out.push_back((frame, None));
            }
        }
        if from < oldest {
            self.queue(Kind::Gap, chan, &Out::default().u64(from).u64(oldest).0, None);
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
        if terminal.ended() {
            let was_closing = terminal.closing;
            self.terminals.remove(&chan);
            if was_closing {
                self.closing -= 1;
            }
            return Ok(());
        }
        let newly_closing = !terminal.closing;
        terminal.closing = true;
        // SAFETY: signals this terminal's own process group.
        unsafe {
            libc::killpg(terminal.pid, libc::SIGHUP);
            libc::killpg(terminal.pid, libc::SIGTERM);
        }
        terminal.kill_at = Some(Instant::now() + Duration::from_millis(u64::from(grace)));
        if newly_closing {
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
                // SAFETY: signals this terminal's own process group.
                unsafe { libc::killpg(terminal.pid, libc::SIGKILL) };
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

    fn exit_due(terminal: &Terminal) -> bool {
        !terminal.exit_sent && terminal.ended()
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
    /// then write what the link takes.
    fn pump(&mut self) {
        let Some(link) = self.link.as_mut() else { return };
        let mut frames = Vec::new();
        let mut budget = LINK_QUEUE_BYTES.saturating_sub(link.out_bytes);
        for (chan, terminal) in &mut self.terminals {
            let Some(mut sent) = terminal.sent else { continue };
            // Never splice output silently: bytes the ring dropped before
            // they were sent are a GAP the daemon hears about.
            let oldest = terminal.ring.oldest();
            if sent < oldest {
                frames.push(wire::encode(
                    Kind::Gap,
                    *chan,
                    &Out::default().u64(sent).u64(oldest).0,
                ));
                sent = oldest;
            }
            let limit = terminal.send_limit(link.credit).min(terminal.ring.end());
            while budget > 0 && sent < limit {
                let max = DATA_CHUNK.min(budget).min((limit - sent) as usize);
                let (from, bytes) = terminal.ring.read(sent, max);
                if bytes.is_empty() {
                    break;
                }
                budget = budget.saturating_sub(bytes.len());
                sent = from + bytes.len() as u64;
                frames.push(wire::encode(
                    Kind::Data,
                    *chan,
                    &Out::default().u64(from).bytes(&bytes).0,
                ));
            }
            terminal.sent = Some(sent);
            if sent >= terminal.ring.end() && Self::exit_due(terminal) {
                let (kind, code) = terminal.status.unwrap_or(ExitStatus::Unobserved).encode();
                let payload = Out::default().u8(kind).i32(code).u64(terminal.ring.end()).0;
                frames.push(wire::encode(Kind::Exit, *chan, &payload));
                terminal.exit_sent = true;
            }
        }
        for frame in frames {
            link.out_bytes += frame.len();
            link.out.push_back((frame, None));
        }
        if !self.flush_link() {
            self.drop_link();
        }
    }

    fn queue(&mut self, kind: Kind, chan: u32, payload: &[u8], fd: Option<OwnedFd>) {
        if let Some(link) = self.link.as_mut() {
            let frame = wire::encode(kind, chan, payload);
            link.out_bytes += frame.len();
            link.out.push_back((frame, fd));
        }
    }

    /// Write queued frames until the socket would block. False when lost.
    fn flush_link(&mut self) -> bool {
        let Some(link) = self.link.as_mut() else { return true };
        while let Some((bytes, fd)) = link.out.front_mut() {
            let fds: Vec<RawFd> = fd.iter().map(AsRawFd::as_raw_fd).collect();
            match wire::send_with_fds(link.stream.as_raw_fd(), bytes, &fds) {
                Ok(n) if n == bytes.len() => {
                    link.out_bytes -= n;
                    link.out.pop_front();
                }
                Ok(n) => {
                    // The descriptor went with the first byte.
                    *fd = None;
                    link.out_bytes -= n;
                    bytes.drain(..n);
                    return true;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(_) => return false,
            }
        }
        true
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
