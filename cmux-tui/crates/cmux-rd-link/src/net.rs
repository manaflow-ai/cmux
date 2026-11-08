//! The I/O driver of an [`Endpoint`] (feature `net`): one thread owns one UDP
//! socket and the endpoint; the caller talks to it through commands and reads
//! its events, and may wait on [`Net::event_fd`] in its own `poll(2)` loop.
//!
//! Candidates (the routes this side offers the peer through signaling):
//! - host: every non-loopback address of this machine's interfaces with the
//!   socket's port, which includes the tailnet's addresses;
//! - server-reflexive: the address a STUN server (from the hub ticket) sees,
//!   the public mapping the peer can punch through to;
//! - relay: the relayed address of an allocation on each TURN server of the
//!   hub ticket (RFC 8656 over UDP, [`crate::turn`]).
//!
//! For every remote candidate the driver also adds a path through each of
//! its own allocations (`Route::Relay`), so a session works when no direct
//! path does; the selector still prefers any live direct path. A remote
//! `relay` candidate is a plain UDP destination: their allocation forwards it.
//! Relays only see sealed packets.
//!
//! STUN and TURN messages, ChannelData and link packets share the socket; the
//! RFC 7983 ranges and the sender's address tell them apart.

use crate::endpoint::{Endpoint, EndpointEvent, MAX_PATHS, Route};
use crate::turn::{TurnClient, TurnEvent, TurnReceive};
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
/// How long `CandidatesDone` waits for TURN allocations.
const RELAY_GATHER_US: u64 = 3_000_000;
/// Most TURN servers used.
pub const MAX_TURN_SERVERS: usize = 8;

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
    /// A TURN allocation's relayed address (wire form `relay`).
    Relay,
}

impl Candidate {
    pub fn to_wire(&self) -> String {
        let kind = match self.kind {
            CandidateKind::Host => "host",
            CandidateKind::ServerReflexive => "srflx",
            CandidateKind::Relay => "relay",
        };
        format!("{kind} {}", self.addr)
    }

    pub fn from_wire(text: &str) -> Option<Self> {
        let (kind, addr) = text.split_once(' ')?;
        let kind = match kind {
            "host" => CandidateKind::Host,
            "srflx" => CandidateKind::ServerReflexive,
            "relay" => CandidateKind::Relay,
            _ => return None,
        };
        Some(Self { kind, addr: addr.parse().ok()? })
    }

    fn path_kind(&self) -> PathKind {
        if self.kind == CandidateKind::Relay {
            return PathKind::TurnRelay;
        }
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
    /// TURN servers (from the hub ticket's relay list), for the relay
    /// candidate and the relayed paths. At most [`MAX_TURN_SERVERS`] are used.
    pub turn: Vec<TurnServer>,
    /// Reach the peer only through this side's TURN allocations: no host or
    /// reflexive candidate is gathered or sent, no direct path is opened, and a
    /// packet from anywhere but a TURN server is dropped, so the peer never
    /// learns this side's addresses. Without a TURN server nothing connects.
    pub relay_only: bool,
}

/// A TURN server with long-term credentials (RFC 8656 over UDP).
#[derive(Clone, PartialEq, Eq)]
pub struct TurnServer {
    pub addr: SocketAddr,
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for TurnServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnServer")
            .field("addr", &self.addr)
            .field("username", &self.username)
            .finish_non_exhaustive()
    }
}

/// What the driver reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetEvent {
    /// A local candidate to send to the peer through signaling.
    Candidate(Candidate),
    /// Every candidate this side will find was reported.
    CandidatesDone,
    Endpoint(EndpointEvent),
    /// A TURN server gave no allocation, or the allocation ended; the session
    /// goes on over the other paths.
    RelayFailed {
        server: SocketAddr,
        reason: String,
    },
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
            stun: (if config.relay_only { &[][..] } else { &config.stun[..] })
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
            relays: config
                .turn
                .iter()
                .take(MAX_TURN_SERVERS)
                .map(|server| Relay {
                    server: server.addr,
                    client: TurnClient::new(&server.username, &server.password, seed()),
                    settled: false,
                })
                .collect(),
            remote: Vec::new(),
            relay_only: config.relay_only,
            candidates_done: false,
            start: Instant::now(),
        };
        // Host candidates are known at once.
        for ip in interface_addresses().into_iter().filter(|_| !config.relay_only) {
            driver.emit(NetEvent::Candidate(Candidate {
                kind: CandidateKind::Host,
                addr: SocketAddr::new(ip, local_addr.port()),
            }));
        }
        if driver.stun.is_empty() && driver.relays.is_empty() {
            driver.candidates_done = true;
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

/// 32 random bytes (a fresh 25519 public key), for TURN transaction ids.
fn seed() -> [u8; 32] {
    KeyPair::generate().map(|k| k.public).unwrap_or_else(|_| {
        let mut fallback = [0u8; 32];
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        fallback[..16].copy_from_slice(&nanos.to_be_bytes());
        fallback
    })
}

/// One TURN server's allocation.
struct Relay {
    server: SocketAddr,
    client: TurnClient,
    /// Allocated or failed: `CandidatesDone` no longer waits for it.
    settled: bool,
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
    relays: Vec<Relay>,
    /// The peer's candidates, for the relayed paths of allocations that finish later.
    remote: Vec<Candidate>,
    /// `NetConfig::relay_only`.
    relay_only: bool,
    candidates_done: bool,
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

    fn send(&mut self, route: Route, packet: &[u8], now: u64) {
        match route {
            Route::Udp(addr) => {
                let _ = self.socket.send_to(packet, addr);
            }
            Route::Relay { relay, peer } => {
                let Some(r) = self.relays.get_mut(usize::from(relay)) else { return };
                if let Some(wrapped) = r.client.send(peer, packet, now) {
                    let _ = self.socket.send_to(&wrapped, r.server);
                }
            }
        }
    }

    fn flush(&mut self, now: u64) -> Result<(), LinkError> {
        for t in self.endpoint.poll_transmit(now)? {
            self.send(t.route, &t.packet, now);
        }
        for event in self.endpoint.take_events() {
            self.emit(NetEvent::Endpoint(event));
        }
        Ok(())
    }

    fn stun_tick(&mut self, now: u64) {
        for q in self.stun.iter_mut().filter(|q| !q.done && q.next_us <= now) {
            if q.attempts >= STUN_ATTEMPTS {
                q.done = true;
                continue;
            }
            q.attempts += 1;
            q.next_us = now + STUN_RETRY_US;
            let _ = self.socket.send_to(&binding_request(q.transaction), q.server);
        }
        self.maybe_done(now);
    }

    /// `CandidatesDone` once every STUN query ended and every TURN allocation
    /// settled, or the relay gathering time ran out.
    fn maybe_done(&mut self, now: u64) {
        if !self.candidates_done
            && self.stun.iter().all(|q| q.done)
            && (self.relays.iter().all(|r| r.settled) || now >= RELAY_GATHER_US)
        {
            self.candidates_done = true;
            self.emit(NetEvent::CandidatesDone);
        }
    }

    fn turn_tick(&mut self, now: u64) {
        for r in &mut self.relays {
            for packet in r.client.poll_transmit(now) {
                let _ = self.socket.send_to(&packet, r.server);
            }
        }
        self.turn_events(now);
    }

    fn turn_events(&mut self, now: u64) {
        for index in 0..self.relays.len() {
            for event in self.relays[index].client.take_events() {
                self.relays[index].settled = true;
                match event {
                    TurnEvent::Allocated { relayed, .. } => {
                        self.emit(NetEvent::Candidate(Candidate {
                            kind: CandidateKind::Relay,
                            addr: relayed,
                        }));
                        let peers: Vec<SocketAddr> = self.remote.iter().map(|c| c.addr).collect();
                        for peer in peers {
                            self.relay_path(index, peer, now);
                        }
                    }
                    TurnEvent::Failed(error) => {
                        let server = self.relays[index].server;
                        self.emit(NetEvent::RelayFailed { server, reason: error.to_string() });
                    }
                }
            }
        }
        self.maybe_done(now);
    }

    /// A path to `peer` through allocation `index` (permission and channel included).
    fn relay_path(&mut self, index: usize, peer: SocketAddr, now: u64) {
        let (Ok(relay), Some(r)) = (u16::try_from(index), self.relays.get_mut(index)) else {
            return;
        };
        if r.client.relayed().is_some() && r.client.add_peer(peer, now) {
            self.endpoint.add_path(Route::Relay { relay, peer }, PathKind::TurnRelay, now);
        }
    }

    fn on_remote_candidate(&mut self, c: Candidate, now: u64) {
        if !self.relay_only {
            self.endpoint.add_path(Route::Udp(c.addr), c.path_kind(), now);
        }
        if self.remote.contains(&c) || self.remote.len() >= MAX_PATHS {
            return;
        }
        self.remote.push(c);
        for index in 0..self.relays.len() {
            self.relay_path(index, c.addr, now);
        }
    }

    /// Feeds one link packet to the endpoint. True when the peer closed the session.
    fn deliver(&mut self, route: Route, packet: &[u8], now: u64) -> Result<bool, LinkError> {
        for event in self.endpoint.on_packet(route, packet, now)? {
            let closed = matches!(event, EndpointEvent::Link(crate::Event::Closed));
            self.emit(NetEvent::Endpoint(event));
            if closed {
                return Ok(true);
            }
        }
        Ok(false)
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
        }
        self.maybe_done(now_us(self.start));
    }

    fn deadline_ms(&self, now: u64) -> i32 {
        let stun = self.stun.iter().filter(|q| !q.done).map(|q| q.next_us).min();
        let turn = self.relays.iter().filter_map(|r| r.client.next_deadline_us()).min();
        let gather = (!self.candidates_done && now < RELAY_GATHER_US).then_some(RELAY_GATHER_US);
        match [self.endpoint.next_deadline_us(), stun, turn, gather].into_iter().flatten().min() {
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
            self.turn_tick(now);
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
                    Command::RemoteCandidate(c) => self.on_remote_candidate(c, now),
                    Command::Datagram(d) => {
                        if self.endpoint.link().is_established() {
                            for t in self.endpoint.send_datagram(&d)? {
                                self.send(t.route, &t.packet, now);
                            }
                        }
                    }
                    Command::Control(r) => self.endpoint.send_control(r, now)?,
                    Command::NetworkChange => self.endpoint.on_network_change(),
                    Command::Close => {
                        if self.endpoint.link().is_established() {
                            for t in self.endpoint.close()? {
                                self.send(t.route, &t.packet, now);
                            }
                        }
                        for r in &mut self.relays {
                            for packet in r.client.close() {
                                let _ = self.socket.send_to(&packet, r.server);
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
                        if let Some(index) = self.relays.iter().position(|r| r.server == from) {
                            match self.relays[index].client.on_packet(packet, now) {
                                TurnReceive::Data { peer, payload } => {
                                    let relay = u16::try_from(index).unwrap_or(u16::MAX);
                                    if self.deliver(Route::Relay { relay, peer }, payload, now)? {
                                        return Ok(());
                                    }
                                    continue;
                                }
                                TurnReceive::Handled => {
                                    self.turn_events(now);
                                    continue;
                                }
                                // A STUN binding answer from the same server, say.
                                TurnReceive::Ignored => {}
                            }
                        }
                        // Relay only: nothing but the TURN servers may reach this side.
                        if self.relay_only {
                            continue;
                        }
                        if packet.first().is_some_and(|b| *b < 4) {
                            self.on_stun(packet);
                            continue;
                        }
                        if self.deliver(Route::Udp(from), packet, now)? {
                            return Ok(());
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
