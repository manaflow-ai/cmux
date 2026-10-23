//! The holder's single-threaded event loop.
//!
//! One `poll` set: the listening socket, the daemon link, a self-pipe for
//! SIGCHLD and every PTY master. Output is read as soon as it is ready and
//! appended to the terminal's ring, never blocked on the daemon: the ring is
//! the only buffer, and a slow or absent daemon only loses the oldest bytes.
//! No timers: `poll` waits forever unless a CLOSE grace is pending.

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

/// Error codes of [`Kind::Error`].
pub mod error_code {
    pub const UNKNOWN_KIND: u16 = 1;
    pub const BAD_TOKEN: u16 = 2;
    pub const NO_COMMON_VERSION: u16 = 3;
    pub const UNKNOWN_CHAN: u16 = 4;
    pub const BAD_PAYLOAD: u16 = 6;
    pub const SPAWN_FAILED: u16 = 8;
    pub const CHAN_IN_USE: u16 = 9;
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
    /// Input waiting for the PTY to accept it.
    input: VecDeque<u8>,
    /// SIGKILL the group at this time (a CLOSE's grace).
    kill_at: Option<Instant>,
}

struct Link {
    stream: UnixStream,
    reader: wire::Reader,
    authed: bool,
    /// Frames to write, each with the descriptor it passes.
    out: VecDeque<(Vec<u8>, Option<OwnedFd>)>,
    out_bytes: usize,
}

/// The holder state.
pub struct Holder {
    listener: UnixListener,
    token: [u8; 32],
    link: Option<Link>,
    terminals: BTreeMap<u32, Terminal>,
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
        Ok(Self { listener, token, link: None, terminals: BTreeMap::new(), sigchld })
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
            if !link.out.is_empty() || (link.authed && self.unsent_output()) {
                events |= libc::POLLOUT;
            }
            fds.push(pollfd(link.stream.as_raw_fd(), events));
            fds.len() - 1
        });
        let first_terminal = fds.len();
        // A terminal at end of file stays out of the set: its master would
        // report POLLHUP forever.
        let mut chans = Vec::new();
        for (chan, terminal) in &self.terminals {
            if terminal.eof {
                continue;
            }
            let mut events = libc::POLLIN;
            if !terminal.input.is_empty() {
                events |= libc::POLLOUT;
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
            if revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                self.read_terminal(*chan);
            }
            if revents & libc::POLLOUT != 0 {
                self.write_terminal(*chan);
            }
        }
        if let Some(index) = link_at
            && fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
            && !self.read_link()
        {
            self.drop_link();
        }
        if fds[0].revents & libc::POLLIN != 0 {
            self.accept();
        }
        self.kill_overdue();
        self.pump();
        Ok(())
    }

    fn unsent_output(&self) -> bool {
        self.terminals.values().any(|terminal| {
            terminal.sent.is_some_and(|sent| sent < terminal.ring.end())
                || (terminal.sent.is_some() && Self::exit_due(terminal))
        })
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.terminals.values().filter_map(|terminal| terminal.kill_at).min()
    }

    fn accept(&mut self) {
        while let Ok((stream, _)) = self.listener.accept() {
            if !same_user(&stream) {
                continue;
            }
            if stream.set_nonblocking(true).is_err() {
                continue;
            }
            // A new daemon always wins: the old link's daemon is gone or stale.
            self.drop_link();
            self.link = Some(Link {
                stream,
                reader: wire::Reader::default(),
                authed: false,
                out: VecDeque::new(),
                out_bytes: 0,
            });
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

    /// Handle one frame from the daemon. False closes the link.
    fn handle(&mut self, frame: Frame) -> bool {
        let authed = self.link.as_ref().is_some_and(|link| link.authed);
        let (raw_kind, chan) = (frame.kind, frame.chan);
        let kind = Kind::from_u16(raw_kind);
        if kind != Some(Kind::Hello) && !authed {
            return false;
        }
        let result = match kind {
            Some(Kind::Hello) => return self.hello(&frame.payload),
            Some(Kind::Spawn) => self.spawn(frame.chan, &frame.payload),
            Some(Kind::Adopt) => self.adopt(frame),
            Some(Kind::Attach) => self.attach(frame.chan, &frame.payload),
            Some(Kind::Write) => self.terminal(frame.chan).map(|terminal| {
                terminal.input.extend(&frame.payload);
            }),
            Some(Kind::Resize) => self.resize(frame.chan, &frame.payload),
            Some(Kind::Signal) => self.signal(frame.chan, &frame.payload),
            Some(Kind::Close) => self.close(frame.chan, &frame.payload),
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

    fn hello(&mut self, payload: &[u8]) -> bool {
        let mut input = In(payload);
        let (Ok(version), Ok(token)) = (input.u16(), input.array::<32>()) else { return false };
        if !constant_time_eq(&token, &self.token) {
            let payload = Out::default().u16(Kind::Hello as u16).u16(error_code::BAD_TOKEN).0;
            self.queue(Kind::Error, 0, &payload, None);
            self.flush_link();
            return false;
        }
        if version < wire::VERSION {
            let payload =
                Out::default().u16(Kind::Hello as u16).u16(error_code::NO_COMMON_VERSION).0;
            self.queue(Kind::Error, 0, &payload, None);
            self.flush_link();
            return false;
        }
        if let Some(link) = self.link.as_mut() {
            link.authed = true;
        }
        let listed: Vec<(u32, Vec<u8>)> = self
            .terminals
            .iter()
            .map(|(chan, terminal)| {
                let listed = Listed {
                    chan: *chan,
                    id: terminal.id,
                    pid: terminal.pid,
                    oldest: terminal.ring.oldest(),
                    end: terminal.ring.end(),
                    exited: terminal.eof && (terminal.status.is_some() || !terminal.own_child),
                };
                (*chan, listed.encode())
            })
            .collect();
        let welcome = Out::default().u16(wire::VERSION).u32(listed.len() as u32).0;
        self.queue(Kind::Welcome, 0, &welcome, None);
        for (chan, payload) in listed {
            self.queue(Kind::Listed, chan, &payload, None);
        }
        true
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
        self.terminals.insert(frame.chan, Terminal::new(id, master, pid, false, base));
        Ok(())
    }

    fn attach(&mut self, chan: u32, payload: &[u8]) -> Result<(), (u16, String)> {
        let from =
            In(payload).u64().map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let terminal = self.terminal(chan)?;
        let oldest = terminal.ring.oldest();
        terminal.sent = Some(from.max(oldest));
        terminal.exit_sent = false;
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
        if terminal.eof && (terminal.status.is_some() || !terminal.own_child) {
            self.terminals.remove(&chan);
            return Ok(());
        }
        // SAFETY: signals this terminal's own process group.
        unsafe {
            libc::killpg(terminal.pid, libc::SIGHUP);
            libc::killpg(terminal.pid, libc::SIGTERM);
        }
        terminal.kill_at = Some(Instant::now() + Duration::from_millis(u64::from(grace)));
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

    fn read_terminal(&mut self, chan: u32) {
        let Some(terminal) = self.terminals.get_mut(&chan) else { return };
        let mut buf = [0u8; 64 * 1024];
        loop {
            // SAFETY: reads into a live buffer.
            let n = unsafe {
                libc::read(terminal.master.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len())
            };
            if n > 0 {
                terminal.ring.push(&buf[..n as usize]);
                continue;
            }
            if n == 0 {
                terminal.eof = true;
                return;
            }
            match io::Error::last_os_error().kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => return,
                // EIO: every slave closed (the child and its group ended).
                _ => {
                    terminal.eof = true;
                    return;
                }
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
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return;
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
            if let Some(terminal) =
                self.terminals.values_mut().find(|t| t.pid == pid && t.own_child)
            {
                terminal.status = Some(exit);
            }
        }
    }

    fn exit_due(terminal: &Terminal) -> bool {
        !terminal.exit_sent && terminal.eof && (terminal.status.is_some() || !terminal.own_child)
    }

    /// Make DATA (and EXIT after the last byte) for the attached daemon,
    /// then write what the link takes.
    fn pump(&mut self) {
        let Some(link) = self.link.as_mut() else { return };
        if !link.authed {
            return;
        }
        let mut frames = Vec::new();
        let mut budget = LINK_QUEUE_BYTES.saturating_sub(link.out_bytes);
        for (chan, terminal) in &mut self.terminals {
            let Some(mut sent) = terminal.sent else { continue };
            while budget > 0 && sent < terminal.ring.end() {
                let (from, bytes) = terminal.ring.read(sent, DATA_CHUNK.min(budget));
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
            input: VecDeque::new(),
            kill_at: None,
        }
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
