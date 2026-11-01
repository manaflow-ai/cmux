//! The I/O driver of an [`Endpoint`] (feature `net`): one thread owns one UDP
//! socket and the endpoint; the caller talks to it through commands and reads
//! its events, and may wait on [`Net::event_fd`] in its own `poll(2)` loop.
//!
//! Candidates (the routes this side offers the peer through signaling):
//! - host: every non-loopback address of this machine's interfaces with the
//!   socket's port, which includes the tailnet's addresses;
//! - server-reflexive: the address a STUN server (from the hub ticket) sees,
//!   the public mapping the peer can punch through to.
//!
//! STUN answers and link packets share the socket; the RFC 7983 ranges tell
//! them apart. Relays (TURN) are a later carrier behind the same endpoint.

use crate::endpoint::{Endpoint, EndpointEvent, Route};
use crate::{KeyPair, LinkError, Role};
use cmux_transport::PathKind;
use cmux_transport::stun::{TransactionId, binding_request, parse_binding_success};
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};
use std::sync::mpsc;
use std::thread;
use std::time::Instant;

/// STUN requests are retried this often until each server answers or gives up.
const STUN_RETRY_US: u64 = 300_000;
const STUN_ATTEMPTS: u32 = 5;
/// Largest UDP payload read.
const MAX_PACKET: usize = 65_535;

/// A route this side offers, in the signaling form `"<kind> <addr>"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Candidate {
    pub kind: CandidateKind,
    pub addr: SocketAddr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateKind {
    Host,
    ServerReflexive,
}

impl Candidate {
    pub fn to_wire(&self) -> String {
        let kind = match self.kind {
            CandidateKind::Host => "host",
            CandidateKind::ServerReflexive => "srflx",
        };
        format!("{kind} {}", self.addr)
    }

    pub fn from_wire(text: &str) -> Option<Self> {
        let (kind, addr) = text.split_once(' ')?;
        let kind = match kind {
            "host" => CandidateKind::Host,
            "srflx" => CandidateKind::ServerReflexive,
            _ => return None,
        };
        Some(Self { kind, addr: addr.parse().ok()? })
    }

    fn path_kind(&self) -> PathKind {
        let local = match self.addr.ip() {
            IpAddr::V4(v4) => v4.is_private() || v4.is_link_local() || v4.is_loopback(),
            IpAddr::V6(v6) => (v6.segments()[0] & 0xfe00) == 0xfc00 || v6.is_loopback(),
        };
        if self.kind == CandidateKind::Host && local {
            PathKind::DirectLan
        } else {
            PathKind::DirectWan
        }
    }
}

pub struct NetConfig {
    pub role: Role,
    /// The hub's session id (the Noise prologue).
    pub session: Vec<u8>,
    pub local: KeyPair,
    /// The peer's session key, checked against its device key by the caller.
    pub expected_remote: [u8; 32],
    /// STUN servers (from the hub ticket's relay list), for the reflexive candidate.
    pub stun: Vec<SocketAddr>,
    /// Where to bind; port 0 picks one.
    pub bind: SocketAddr,
}

/// What the driver reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetEvent {
    /// A local candidate to send to the peer through signaling.
    Candidate(Candidate),
    /// Every candidate this side will find was reported.
    CandidatesDone,
    Endpoint(EndpointEvent),
    /// The link failed (handshake timeout, wrong peer, socket error); the driver stopped.
    Failed(String),
}

enum Command {
    RemoteCandidate(Candidate),
    Datagram(Vec<u8>),
    Control(Vec<u8>),
    NetworkChange,
    Close,
}

/// A running driver. Dropping it closes the link and stops the thread.
pub struct Net {
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<NetEvent>,
    command_wake: Pipe,
    event_wake: Pipe,
    thread: Option<thread::JoinHandle<()>>,
    local_addr: SocketAddr,
}

/// A non-blocking pipe used as a wake-up: a byte means "look at the queue".
struct Pipe {
    read: RawFd,
    write: RawFd,
}

impl Pipe {
    fn new() -> io::Result<Self> {
        let mut fds = [0; 2];
        // SAFETY: pipe(2) fills the two-element array we own.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            // SAFETY: fcntl on descriptors we just created.
            unsafe {
                libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        Ok(Self { read: fds[0], write: fds[1] })
    }

    fn wake(&self) {
        // SAFETY: one byte from a local to our write end; a full pipe already holds a wake-up.
        unsafe { libc::write(self.write, [1u8].as_ptr().cast(), 1) };
    }

    fn drain(&self) {
        let mut scratch = [0u8; 64];
        // SAFETY: reads into a local buffer from our non-blocking read end.
        while unsafe { libc::read(self.read, scratch.as_mut_ptr().cast(), scratch.len()) } > 0 {}
    }
}

impl Drop for Pipe {
    fn drop(&mut self) {
        // SAFETY: closing the two descriptors this value owns, once.
        unsafe {
            libc::close(self.read);
            libc::close(self.write);
        }
    }
}

/// Every non-loopback address of this machine's up interfaces.
fn interface_addresses() -> Vec<IpAddr> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs allocates a list we walk read-only and free once.
    unsafe {
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null() || entry.ifa_flags & (libc::IFF_UP as u32) == 0 {
                continue;
            }
            let ip = match i32::from((*entry.ifa_addr).sa_family) {
                libc::AF_INET => {
                    let sin = &*(entry.ifa_addr as *const libc::sockaddr_in);
                    IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)))
                }
                _ => continue,
            };
            if !ip.is_loopback() && !ip.is_unspecified() {
                out.push(ip);
            }
        }
        libc::freeifaddrs(head);
    }
    out.sort();
    out.dedup();
    out
}

fn now_us(start: Instant) -> u64 {
    u64::try_from(start.elapsed().as_micros()).unwrap_or(u64::MAX)
}

impl Net {
    /// Binds the socket, starts the driver thread and begins gathering candidates.
    pub fn start(config: NetConfig) -> Result<Self, LinkError> {
        let socket = UdpSocket::bind(config.bind).map_err(|e| LinkError::Io(e.to_string()))?;
        socket.set_nonblocking(true).map_err(|e| LinkError::Io(e.to_string()))?;
        let local_addr = socket.local_addr().map_err(|e| LinkError::Io(e.to_string()))?;
        let endpoint =
            Endpoint::new(config.role, &config.session, &config.local, config.expected_remote, 0)?;
        let (command_tx, command_rx) = mpsc::channel();
        let (event_tx, event_rx) = mpsc::channel();
        let command_wake = Pipe::new().map_err(|e| LinkError::Io(e.to_string()))?;
        let event_wake = Pipe::new().map_err(|e| LinkError::Io(e.to_string()))?;
        let mut driver = Driver {
            socket,
            endpoint,
            commands: command_rx,
            command_fd: command_wake.read,
            events: event_tx,
            event_fd: event_wake.write,
            stun: config
                .stun
                .iter()
                .enumerate()
                .map(|(i, server)| StunQuery {
                    server: *server,
                    transaction: transaction(i),
                    attempts: 0,
                    next_us: 0,
                    done: false,
                })
                .collect(),
            start: Instant::now(),
        };
        // Host candidates are known at once.
        for ip in interface_addresses() {
            driver.emit(NetEvent::Candidate(Candidate {
                kind: CandidateKind::Host,
                addr: SocketAddr::new(ip, local_addr.port()),
            }));
        }
        if driver.stun.is_empty() {
            driver.emit(NetEvent::CandidatesDone);
        }
        let thread = thread::Builder::new()
            .name("cmux-rd-net".into())
            .spawn(move || driver.run())
            .map_err(|e| LinkError::Io(e.to_string()))?;
        Ok(Self {
            commands: command_tx,
            events: event_rx,
            command_wake,
            event_wake,
            thread: Some(thread),
            local_addr,
        })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Readable when events are waiting ([`Net::events`]).
    pub fn event_fd(&self) -> RawFd {
        self.event_wake.read
    }

    /// Every event waiting now (clears the wake-up).
    pub fn events(&self) -> Vec<NetEvent> {
        self.event_wake.drain();
        self.events.try_iter().collect()
    }

    fn command(&self, command: Command) {
        if self.commands.send(command).is_ok() {
            self.command_wake.wake();
        }
    }

    /// A candidate the peer offered through signaling.
    pub fn add_remote_candidate(&self, candidate: Candidate) {
        self.command(Command::RemoteCandidate(candidate));
    }

    /// One rd datagram, sealed and sent on the current path (best effort).
    pub fn send_datagram(&self, datagram: Vec<u8>) {
        self.command(Command::Datagram(datagram));
    }

    /// One control record (ordered, reliable).
    pub fn send_control(&self, record: Vec<u8>) {
        self.command(Command::Control(record));
    }

    /// The machine's network changed (interface, address, wake from sleep).
    pub fn network_changed(&self) {
        self.command(Command::NetworkChange);
    }
}

impl Drop for Net {
    fn drop(&mut self) {
        self.command(Command::Close);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn transaction(index: usize) -> TransactionId {
    let mut id = [0u8; 12];
    let seed = KeyPair::generate().map(|k| k.public).unwrap_or([index as u8; 32]);
    id.copy_from_slice(&seed[..12]);
    id
}

struct StunQuery {
    server: SocketAddr,
    transaction: TransactionId,
    attempts: u32,
    next_us: u64,
    done: bool,
}

struct Driver {
    socket: UdpSocket,
    endpoint: Endpoint,
    commands: mpsc::Receiver<Command>,
    command_fd: RawFd,
    events: mpsc::Sender<NetEvent>,
    event_fd: RawFd,
    stun: Vec<StunQuery>,
    start: Instant,
}

impl Driver {
    fn emit(&self, event: NetEvent) {
        if self.events.send(event).is_ok() {
            // SAFETY: one byte from a local to the event pipe's write end (owned by `Net`,
            // which joins this thread before closing it).
            unsafe { libc::write(self.event_fd, [1u8].as_ptr().cast(), 1) };
        }
    }

    fn send(&self, route: Route, packet: &[u8]) {
        if let Route::Udp(addr) = route {
            let _ = self.socket.send_to(packet, addr);
        }
    }

    fn flush(&mut self, now: u64) -> Result<(), LinkError> {
        for t in self.endpoint.poll_transmit(now)? {
            self.send(t.route, &t.packet);
        }
        for event in self.endpoint.take_events() {
            self.emit(NetEvent::Endpoint(event));
        }
        Ok(())
    }

    fn stun_tick(&mut self, now: u64) {
        let mut finished = false;
        for q in self.stun.iter_mut().filter(|q| !q.done && q.next_us <= now) {
            if q.attempts >= STUN_ATTEMPTS {
                q.done = true;
                finished = true;
                continue;
            }
            q.attempts += 1;
            q.next_us = now + STUN_RETRY_US;
            let _ = self.socket.send_to(&binding_request(q.transaction), q.server);
        }
        if finished && self.stun.iter().all(|q| q.done) {
            self.emit(NetEvent::CandidatesDone);
        }
    }

    fn on_stun(&mut self, packet: &[u8]) {
        let mut found = None;
        for q in self.stun.iter_mut().filter(|q| !q.done) {
            if let Ok(addr) = parse_binding_success(packet, &q.transaction) {
                q.done = true;
                found = Some(addr);
            }
        }
        if let Some(addr) = found {
            self.emit(NetEvent::Candidate(Candidate {
                kind: CandidateKind::ServerReflexive,
                addr,
            }));
            if self.stun.iter().all(|q| q.done) {
                self.emit(NetEvent::CandidatesDone);
            }
        }
    }

    fn deadline_ms(&self, now: u64) -> i32 {
        let stun = self.stun.iter().filter(|q| !q.done).map(|q| q.next_us).min();
        match [self.endpoint.next_deadline_us(), stun].into_iter().flatten().min() {
            Some(at) => i32::try_from(at.saturating_sub(now).div_ceil(1000)).unwrap_or(i32::MAX),
            None => 1000,
        }
    }

    fn run(&mut self) {
        if let Err(e) = self.serve() {
            self.emit(NetEvent::Failed(e.to_string()));
        }
    }

    fn serve(&mut self) -> Result<(), LinkError> {
        let mut buf = vec![0u8; MAX_PACKET];
        loop {
            let now = now_us(self.start);
            self.stun_tick(now);
            self.flush(now)?;
            let mut fds = [
                libc::pollfd { fd: self.socket.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.command_fd, events: libc::POLLIN, revents: 0 },
            ];
            let timeout = self.deadline_ms(now);
            // SAFETY: fds is a valid array of pollfd for its length.
            unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
            let mut scratch = [0u8; 64];
            // SAFETY: drains our own non-blocking command pipe into a local buffer.
            while unsafe { libc::read(self.command_fd, scratch.as_mut_ptr().cast(), scratch.len()) }
                > 0
            {}
            let now = now_us(self.start);
            while let Ok(command) = self.commands.try_recv() {
                match command {
                    Command::RemoteCandidate(c) => {
                        self.endpoint.add_path(Route::Udp(c.addr), c.path_kind(), now);
                    }
                    Command::Datagram(d) => {
                        if self.endpoint.link().is_established() {
                            for t in self.endpoint.send_datagram(&d)? {
                                self.send(t.route, &t.packet);
                            }
                        }
                    }
                    Command::Control(r) => self.endpoint.send_control(r, now)?,
                    Command::NetworkChange => self.endpoint.on_network_change(),
                    Command::Close => {
                        if self.endpoint.link().is_established() {
                            for t in self.endpoint.close()? {
                                self.send(t.route, &t.packet);
                            }
                        }
                        return Ok(());
                    }
                }
            }
            loop {
                match self.socket.recv_from(&mut buf) {
                    Ok((n, from)) => {
                        let packet = &buf[..n];
                        if packet.first().is_some_and(|b| *b < 4) {
                            self.on_stun(packet);
                            continue;
                        }
                        for event in self.endpoint.on_packet(Route::Udp(from), packet, now)? {
                            let closed = matches!(event, EndpointEvent::Link(crate::Event::Closed));
                            self.emit(NetEvent::Endpoint(event));
                            if closed {
                                return Ok(());
                            }
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    // ICMP errors (port unreachable on a dead candidate) surface here; keep going.
                    Err(_) => break,
                }
            }
        }
    }
}
