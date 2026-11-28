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
use crate::wake::{AddressWatch, SleepWatch};
use crate::{KeyPair, LinkError, Role};
use cmux_rd_proto::{DatagramDeparture, DatagramHeader, MAX_DEPARTURE_RECEIPTS};
use cmux_transport::PathKind;
use cmux_transport::stun::{TransactionId, binding_request, parse_binding_success};
use std::collections::BTreeMap;
use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
#[cfg(unix)]
use std::os::fd::RawFd;
#[cfg(windows)]
use std::os::windows::io::RawSocket;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

/// Outer WireGuard media may not wait in the rd-link handoff longer than cmux-wg's media
/// scheduler budget. Control and handshake records use the command queue and are never aged
/// by this limit.
const MEDIA_MAX_AGE: Duration = Duration::from_millis(50);

struct QueuedMedia {
    queued_at: Instant,
    datagram: Vec<u8>,
}

impl QueuedMedia {
    fn take_payload_if_fresh(self, now: Instant) -> Option<Vec<u8>> {
        (!self.stale_at(now)).then_some(self.datagram)
    }
    fn stale_at(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.queued_at) > MEDIA_MAX_AGE
    }
}

#[path = "media_queue.rs"]
mod media_queue;
#[path = "no_path.rs"]
mod no_path;
#[path = "socket.rs"]
mod socket;
#[path = "stream_relay.rs"]
mod stream_relay;
#[cfg(unix)]
#[path = "net_unix.rs"]
mod sys;
#[cfg(windows)]
#[path = "net_windows.rs"]
mod sys;

use media_queue::{MediaFrame, MediaQueue};
use socket::send_to_observed;
use stream_relay::StreamRelay;
use sys::{
    Wake, grow_udp_buffers, interface_addresses, mark_interactive_video, wait_readable, wait_ready,
};

/// STUN requests are retried this often until each server answers or gives up.
const STUN_RETRY_US: u64 = 300_000;
const STUN_ATTEMPTS: u32 = 5;
/// Most STUN servers one link queries, late ones included.
const MAX_STUN_SERVERS: usize = 8;
/// How often the driver asks a [`Later`] list while it has not answered.
const LATER_POLL_US: u64 = 50_000;
/// Largest UDP payload read.
const MAX_PACKET: usize = 65_535;
/// Room for a burst of media datagrams before the driver can drain the socket.
/// Linux doubles this request when reporting the effective buffer size.
const UDP_BUFFER_SIZE: i32 = 4 << 20;
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
        if self.kind == CandidateKind::Host && crate::endpoint::is_local(self.addr.ip()) {
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

/// A TURN server with long-term credentials (RFC 8656), reached over UDP, TCP or TLS.
#[derive(Clone, PartialEq, Eq)]
pub struct TurnServer {
    pub addr: SocketAddr,
    pub username: String,
    pub password: String,
    pub transport: TurnTransport,
}

/// How this side reaches a TURN server. The allocation is UDP on the server's side in
/// every case; TCP and TLS are for a network that blocks UDP (RFC 8656 §3.1).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum TurnTransport {
    /// Datagrams from the driver's one socket.
    #[default]
    Udp,
    /// One TCP connection, STUN and padded ChannelData framed on it.
    Tcp,
    /// TCP with TLS; the server's certificate must name `server_name`.
    Tls { server_name: String },
}

impl TurnTransport {
    /// From a setup line's relay entry: `transport` is `udp` (or empty), `tcp` or `tls`, and
    /// TLS checks the certificate against the host part of `addr` (`host:port`,
    /// `[v6]:port`). `None` for a transport this side does not know.
    pub fn from_setup(transport: &str, addr: &str) -> Option<Self> {
        match transport {
            "" | "udp" => Some(Self::Udp),
            "tcp" => Some(Self::Tcp),
            "tls" => {
                let host = addr.rsplit_once(':').map_or(addr, |(host, _)| host);
                let host = host.trim_start_matches('[').trim_end_matches(']');
                (!host.is_empty()).then(|| Self::Tls { server_name: host.to_owned() })
            }
            _ => None,
        }
    }
}

impl std::fmt::Debug for TurnServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnServer")
            .field("addr", &self.addr)
            .field("username", &self.username)
            .field("transport", &self.transport)
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
    /// A connect step happened, once each per driver: where connect time goes
    /// ([`ConnectPhase`]). `at_us` counts from [`Net::start`]; `route` is the
    /// path it happened on, when there is one.
    Phase {
        phase: ConnectPhase,
        at_us: u64,
        route: Option<Route>,
    },
}

impl NetEvent {
    /// A [`NetEvent::Phase`] as the one stdout line `cmux rd serve`, `connect`
    /// and `bench --link` print for it:
    /// `{"phase":"first_check_answered","ms":0.42,"route":"172.20.21.17:61200"}`
    /// (`ms` from [`Net::start`]; `route` is `relay<N>><peer>` for a relayed
    /// path and absent when there is none). The app's line reader reads a line
    /// it does not know as empty, so the line is safe on the app's pipe too.
    pub fn phase_line(&self) -> Option<String> {
        let Self::Phase { phase, at_us, route } = self else { return None };
        let ms = *at_us as f64 / 1000.0;
        let route = match route {
            Some(Route::Udp(addr)) => format!(",\"route\":\"{addr}\""),
            Some(Route::Relay { relay, peer }) => format!(",\"route\":\"relay{relay}>{peer}\""),
            None => String::new(),
        };
        Some(format!("{{\"phase\":\"{}\",\"ms\":{ms:.3}{route}}}", phase.name()))
    }
}

/// The steps of a connect, in the order a healthy one reaches them (gathering
/// runs beside the others, and nothing on the link waits for it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectPhase {
    /// Every local candidate was reported (`CandidatesDone`).
    GatherDone,
    /// The first packet to the peer left on any path (msg1 or a punch).
    FirstCheckSent,
    /// The first packet from the peer arrived on any path.
    FirstCheckAnswered,
    /// The first handshake message was sent or received.
    HandshakeStart,
    /// The link is up (`Established`).
    HandshakeDone,
    /// The selector picked the first path (`PathChanged` with a route).
    Nominated,
}

impl ConnectPhase {
    const ALL: [Self; 6] = [
        Self::GatherDone,
        Self::FirstCheckSent,
        Self::FirstCheckAnswered,
        Self::HandshakeStart,
        Self::HandshakeDone,
        Self::Nominated,
    ];

    /// The name the binaries print (`{"phase": NAME, ...}`).
    pub fn name(self) -> &'static str {
        match self {
            Self::GatherDone => "gather_done",
            Self::FirstCheckSent => "first_check_sent",
            Self::FirstCheckAnswered => "first_check_answered",
            Self::HandshakeStart => "handshake_start",
            Self::HandshakeDone => "handshake_done",
            Self::Nominated => "nominated",
        }
    }

    fn bit(self) -> u8 {
        1 << Self::ALL.iter().position(|p| *p == self).unwrap_or(0)
    }
}

/// Servers still resolving when the link started: `None` until they are
/// here. See [`Net::add_stun_later`] and [`Net::add_turn_later`].
pub type Later<T> = Box<dyn FnMut() -> Option<Vec<T>> + Send>;

enum Command {
    RemoteCandidate(Candidate),
    StunLater(Later<SocketAddr>),
    TurnLater(Later<TurnServer>),
    Control(Vec<u8>),
    Datagram(Vec<u8>),
    ControlBarrier(mpsc::Sender<()>),
    NetworkChange,
    PeerLost(Option<u64>),
    Close,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NetStats {
    pub departure_overflows: u64,
    pub queue_frames: usize,
    pub queue_datagrams: usize,
    pub dropped_frames: u64,
    pub dropped_datagrams: u64,
    pub dropped_replaced_frames: u64,
    pub dropped_replaced_datagrams: u64,
    pub dropped_evicted_for_protected_frames: u64,
    pub dropped_evicted_for_protected_datagrams: u64,
    pub dropped_rejected_protected_frames: u64,
    pub dropped_rejected_protected_datagrams: u64,
}

/// A running driver. Dropping it closes the link and stops the thread.
pub struct Net {
    departures: mpsc::Receiver<DatagramDeparture>,
    departure_overflows: Arc<AtomicU64>,
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<NetEvent>,
    command_wake: Arc<Wake>,
    event_wake: Arc<Wake>,
    thread: Option<thread::JoinHandle<()>>,
    local_addr: SocketAddr,
    media_queue: Arc<Mutex<MediaQueue>>,
    media: mpsc::SyncSender<QueuedMedia>,
}

/// A send-only handle for a running link. The owner remains the sole reader of
/// `Net::events`; the owner must outlive every handle.
#[derive(Clone)]
pub struct NetSender {
    commands: mpsc::Sender<Command>,
    command_wake: Arc<Wake>,
    media: mpsc::SyncSender<QueuedMedia>,
}

impl NetSender {
    pub fn send_datagram(&self, datagram: Vec<u8>) {
        // Handshake/control traffic is not media: preserve it on the reliable
        // command queue, where the media age budget cannot discard it.
        self.command(Command::Datagram(datagram));
    }
    pub fn send_media(&self, datagram: Vec<u8>) {
        // Best-effort media: keep the overlay from building an unbounded outer
        // queue, and timestamp before the bounded handoff so a stalled driver
        // cannot deliver stale frames after cmux-wg's 50 ms budget.
        let queued = QueuedMedia { queued_at: Instant::now(), datagram };
        if self.media.try_send(queued).is_ok() {
            self.command_wake.wake();
        }
    }
    pub fn send_control(&self, record: Vec<u8>) {
        self.command(Command::Control(record));
    }
    fn command(&self, command: Command) {
        if self.commands.send(command).is_ok() {
            self.command_wake.wake();
        }
    }
}

/// A candidate kind's slot in the driver's counts: host, srflx, relay.
fn kind_index(kind: CandidateKind) -> usize {
    match kind {
        CandidateKind::Host => 0,
        CandidateKind::ServerReflexive => 1,
        CandidateKind::Relay => 2,
    }
}

fn now_us(start: Instant) -> u64 {
    u64::try_from(start.elapsed().as_micros()).unwrap_or(u64::MAX)
}

/// A clock that keeps counting while the machine sleeps, unlike `Instant`
/// (macOS: `CLOCK_MONOTONIC` counts sleep, `Instant` reads uptime; Linux:
/// `CLOCK_BOOTTIME`). Only its differences matter ([`SleepWatch`]).
#[cfg(unix)]
fn with_sleep_us() -> u64 {
    #[cfg(target_vendor = "apple")]
    const CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;
    #[cfg(not(target_vendor = "apple"))]
    const CLOCK: libc::clockid_t = libc::CLOCK_BOOTTIME;
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes one timespec into a live local.
    if unsafe { libc::clock_gettime(CLOCK, &mut ts) } != 0 {
        return 0;
    }
    u64::try_from(ts.tv_sec).unwrap_or_default().saturating_mul(1_000_000)
        + u64::try_from(ts.tv_nsec).unwrap_or_default() / 1_000
}

/// Windows: `GetTickCount64` keeps counting through sleep and hibernation; its
/// 10-16 ms tick is far finer than the gaps [`SleepWatch`] looks for.
#[cfg(windows)]
fn with_sleep_us() -> u64 {
    // SAFETY: GetTickCount64 takes no arguments and cannot fail.
    unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() }.saturating_mul(1000)
}

/// The keep-awake interval ([`crate::endpoint::KEEP_AWAKE_US`]);
/// `CMUX_RD_KEEP_AWAKE_MS` overrides it for measurements, 0 turns it off.
/// `CMUX_RD_BRAID_PATHS=0`: the path code before RFD 0164 B10
/// ([`Endpoint::set_braid_paths`]), for one release.
fn braid_paths() -> bool {
    std::env::var("CMUX_RD_BRAID_PATHS").map_or(true, |v| v.trim() != "0")
}

fn keep_awake_us() -> Option<u64> {
    match std::env::var("CMUX_RD_KEEP_AWAKE_MS").ok().and_then(|v| v.trim().parse::<u64>().ok()) {
        Some(ms) => Some(ms.saturating_mul(1000)).filter(|us| *us > 0),
        None => Some(crate::endpoint::KEEP_AWAKE_US),
    }
}

impl Net {
    /// Binds the socket, starts the driver thread and begins gathering candidates.
    pub fn start(config: NetConfig) -> Result<Self, LinkError> {
        let socket = UdpSocket::bind(config.bind).map_err(|e| LinkError::Io(e.to_string()))?;
        grow_udp_buffers(&socket);
        mark_interactive_video(&socket);
        socket.set_nonblocking(true).map_err(|e| LinkError::Io(e.to_string()))?;
        let local_addr = socket.local_addr().map_err(|e| LinkError::Io(e.to_string()))?;
        let mut endpoint =
            Endpoint::new(config.role, &config.session, &config.local, config.expected_remote, 0)?;
        endpoint.set_local_networks(cmux_transport::local_networks());
        endpoint.set_keep_awake(keep_awake_us());
        endpoint.set_braid_paths(braid_paths());
        let (command_tx, command_rx) = mpsc::channel();
        let (event_tx, event_rx) = mpsc::channel();
        let (departure_tx, departure_rx) = mpsc::sync_channel(MAX_DEPARTURE_RECEIPTS);
        let departure_overflows = Arc::new(AtomicU64::new(0));
        let media_queue = Arc::new(Mutex::new(MediaQueue::default()));
        let (media_tx, media_rx) = mpsc::sync_channel(256);
        let command_wake = Arc::new(Wake::new().map_err(|e| LinkError::Io(e.to_string()))?);
        let event_wake = Arc::new(Wake::new().map_err(|e| LinkError::Io(e.to_string()))?);
        let mut driver = Driver {
            media: media_rx,
            barriers: Vec::new(),
            departures: departure_tx,
            departure_overflows: Arc::clone(&departure_overflows),
            departure_wake: false,
            socket,
            endpoint,
            commands: command_rx,
            media_queue: Arc::clone(&media_queue),
            pending_datagrams: VecDeque::new(),
            command_wake: Arc::clone(&command_wake),
            events: event_tx,
            event_wake: Arc::clone(&event_wake),
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
            relays: Vec::new(),
            stun_later: None,
            turn_later: None,
            remote: Vec::new(),
            relay_only: config.relay_only,
            candidates_done: false,
            start: Instant::now(),
            gathered: std::cell::Cell::new([0; 3]),
            heard: 0,
            sleep_watch: SleepWatch::default(),
            address_watch: AddressWatch::default(),
            phases: std::cell::Cell::new(0),
            refused: BTreeMap::new(),
        };
        // Host candidates are known at once.
        for ip in interface_addresses().into_iter().filter(|_| !config.relay_only) {
            driver.emit(NetEvent::Candidate(Candidate {
                kind: CandidateKind::Host,
                addr: SocketAddr::new(ip, local_addr.port()),
            }));
        }
        // UDP relays first, then TCP and TLS ones, in the order given.
        for server in config.turn.iter().take(MAX_TURN_SERVERS) {
            driver.add_turn(server.clone());
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
            departures: departure_rx,
            departure_overflows,
            commands: command_tx,
            events: event_rx,
            command_wake,
            event_wake,
            thread: Some(thread),
            local_addr,
            media_queue,
            media: media_tx,
        })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Readable when events are waiting ([`Net::events`]).
    #[cfg(unix)]
    pub fn event_fd(&self) -> RawFd {
        self.event_wake.raw()
    }

    /// Readable when events are waiting ([`Net::events`]).
    #[cfg(windows)]
    pub fn event_socket(&self) -> RawSocket {
        self.event_wake.raw()
    }

    /// Blocks until events are waiting or `timeout` passes (`None`: until events).
    /// Portable form of polling [`Net::event_fd`] for callers without a loop of their own.
    pub fn wait(&self, timeout: Option<Duration>) {
        let ms =
            timeout.map_or(-1, |t| i32::try_from(t.as_micros().div_ceil(1000)).unwrap_or(i32::MAX));
        wait_readable(&[self.event_wake.raw()], ms);
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

    /// STUN servers whose names were still resolving at [`Net::start`]. The
    /// driver asks `later` until it answers, then queries what it found, so a
    /// slow resolver still yields the reflexive candidate, trickled after the
    /// others (cmuxterm-hq#7976). Ignored when relay only.
    pub fn add_stun_later(&self, later: Later<SocketAddr>) {
        self.command(Command::StunLater(later));
    }

    /// TURN servers whose names were still resolving at [`Net::start`], as
    /// [`Net::add_stun_later`]: each allocates once here, and its relayed
    /// paths go to every peer candidate known by then.
    pub fn add_turn_later(&self, later: Later<TurnServer>) {
        self.command(Command::TurnLater(later));
    }

    /// One rd datagram, sealed and sent on the current path (best effort).
    pub fn send_datagram(&self, datagram: Vec<u8>) {
        self.command(Command::Datagram(datagram));
    }

    /// Queues one complete encoded frame. If a frame is already pending, it
    /// is evicted as a whole so no stale fragments survive into the next one.
    pub fn send_datagram_frame(&self, datagrams: Vec<Vec<u8>>, droppable: bool) {
        if let Ok(mut queue) = self.media_queue.lock() {
            queue.push(MediaFrame { datagrams, droppable });
        }
        self.command_wake.wake();
    }

    /// Drain at most one bounded batch, without waiting for the driver.
    pub fn drain_departures(&self, out: &mut Vec<DatagramDeparture>) {
        out.extend(self.departures.try_iter().take(MAX_DEPARTURE_RECEIPTS));
    }

    pub fn departure_overflows(&self) -> u64 {
        self.departure_overflows.load(Ordering::Relaxed)
    }

    /// A snapshot of the bounded media queue and its drop counters.
    pub fn stats(&self) -> NetStats {
        let mut stats =
            self.media_queue.lock().map_or_else(|_| NetStats::default(), |queue| queue.stats());
        stats.departure_overflows = self.departure_overflows();
        stats
    }

    /// One control record (ordered, reliable).
    pub fn send_control(&self, record: Vec<u8>) {
        self.command(Command::Control(record));
    }

    pub fn sender(&self) -> NetSender {
        NetSender {
            commands: self.commands.clone(),
            command_wake: Arc::clone(&self.command_wake),
            media: self.media.clone(),
        }
    }

    /// Completes once the peer has acknowledged all reliable controls queued
    /// before this call. Closing/failure drops the receiver without success.
    pub fn control_barrier(&self) -> mpsc::Receiver<()> {
        let (tx, rx) = mpsc::channel();
        self.command(Command::ControlBarrier(tx));
        rx
    }

    /// The machine's network changed (interface, address, wake from sleep).
    pub fn network_changed(&self) {
        self.command(Command::NetworkChange);
    }

    /// Fails the link ([`NetEvent::Failed`]) once the established peer sent
    /// nothing for `after` ([`crate::PEER_LOST_US`] for a viewer): a host that
    /// died without a close. `None` (the default) waits forever.
    pub fn set_peer_lost(&self, after: Option<Duration>) {
        let us = after.map(|d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX));
        self.command(Command::PeerLost(us));
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
    /// TCP or TLS to the server; `None`: datagrams from the driver's socket.
    stream: Option<StreamRelay>,
    /// The stream failed or ended: nothing goes through this relay again.
    dead: bool,
}

impl Relay {
    /// The TURN client may send: UDP always, a stream once connected (and TLS shaken hands).
    fn live(&self) -> bool {
        !self.dead && self.stream.as_ref().is_none_or(StreamRelay::is_ready)
    }

    /// One TURN message to the server, on the stream or as a datagram.
    fn transmit(
        &mut self,
        socket: &UdpSocket,
        refused: &mut BTreeMap<i32, u64>,
        packet: &[u8],
    ) -> Option<(u64, usize)> {
        if self.dead {
            return None;
        }
        match self.stream.as_mut() {
            None => send_counted(socket, refused, packet, self.server),
            Some(stream) => {
                let wire = stream.send(packet)?;
                Some((socket::monotonic_us()?, wire))
            }
        }
    }
}

struct StunQuery {
    server: SocketAddr,
    transaction: TransactionId,
    attempts: u32,
    next_us: u64,
    done: bool,
}

struct Driver {
    media: mpsc::Receiver<QueuedMedia>,
    barriers: Vec<mpsc::Sender<()>>,
    departures: mpsc::SyncSender<DatagramDeparture>,
    departure_overflows: Arc<AtomicU64>,
    departure_wake: bool,
    socket: UdpSocket,
    endpoint: Endpoint,
    commands: mpsc::Receiver<Command>,
    media_queue: Arc<Mutex<MediaQueue>>,
    /// Protected one-datagram sends received before the Noise link is ready.
    pending_datagrams: VecDeque<Vec<u8>>,
    command_wake: Arc<Wake>,
    events: mpsc::Sender<NetEvent>,
    event_wake: Arc<Wake>,
    stun: Vec<StunQuery>,
    /// `Net::add_stun_later`'s servers, until they resolve.
    stun_later: Option<Later<SocketAddr>>,
    /// `Net::add_turn_later`'s servers, until they resolve.
    turn_later: Option<Later<TurnServer>>,
    relays: Vec<Relay>,
    /// The peer's candidates, for the relayed paths of allocations that finish later.
    remote: Vec<Candidate>,
    /// `NetConfig::relay_only`.
    relay_only: bool,
    candidates_done: bool,
    start: Instant,
    /// Local candidates reported, by kind (host, srflx, relay), for a failure's reason.
    gathered: std::cell::Cell<[u32; 3]>,
    /// Packets from anywhere but a STUN or TURN server, handed to the link.
    heard: u64,
    /// A sleep or an address change re-checks every path ([`crate::wake`]).
    sleep_watch: SleepWatch,
    address_watch: AddressWatch<IpAddr>,
    /// The [`ConnectPhase`]s already reported, one bit each.
    phases: std::cell::Cell<u8>,
    /// Sends the system refused, by OS error (`-1`: none given), for a failure's reason.
    refused: BTreeMap<i32, u64>,
}

/// Sends `packet` to `to`, counting a refusal in `refused`. A refused send is not an error
/// of the session (another path may work), but one that is never named reads as a silent
/// network: a Mac app without Local Network access sees every LAN send fail with
/// `EHOSTUNREACH` while the peer hears nothing (cmuxterm-hq CMUX-572).
fn send_counted(
    socket: &UdpSocket,
    refused: &mut BTreeMap<i32, u64>,
    packet: &[u8],
    to: SocketAddr,
) -> Option<(u64, usize)> {
    send_to_observed(socket, refused, packet, to)
}

/// `; sends refused: <error> xN, ..`, or nothing when every send went out.
fn refused_text(refused: &BTreeMap<i32, u64>) -> String {
    if refused.is_empty() {
        return String::new();
    }
    let each: Vec<String> = refused
        .iter()
        .map(|(code, n)| {
            let error = if *code < 0 {
                "unknown error".to_owned()
            } else {
                io::Error::from_raw_os_error(*code).to_string()
            };
            format!("{error} x{n}")
        })
        .collect();
    format!("; sends refused: {}", each.join(", "))
}

impl Driver {
    /// The machine slept, or its addresses changed, since the last turn: the
    /// path chosen before may be gone, so the next sends go on every path
    /// while every path is probed at once ([`crate::wake`]). Runs before any
    /// queued frame goes out.
    fn watch_wake(&mut self, now: u64) {
        let slept = self.sleep_watch.observe(now, with_sleep_us());
        let moved =
            self.address_watch.due(now) && self.address_watch.observe(interface_addresses(), now);
        if slept || moved {
            self.endpoint.set_local_networks(cmux_transport::local_networks());
            self.endpoint.on_network_change();
        }
    }

    fn drain_media(&mut self, now: u64) -> Result<(), LinkError> {
        if !self.endpoint.link().is_established() {
            return Ok(());
        }
        let frame = self.media_queue.lock().ok().and_then(|mut queue| queue.pop());
        let Some(frame) = frame else { return Ok(()) };
        for datagram in frame.datagrams {
            self.send_media_datagram(&datagram, now)?;
        }
        Ok(())
    }

    fn drain_pending_datagrams(&mut self, now: u64) -> Result<(), LinkError> {
        if !self.endpoint.link().is_established() {
            return Ok(());
        }
        while let Some(datagram) = self.pending_datagrams.pop_front() {
            self.send_media_datagram(&datagram, now)?;
        }
        Ok(())
    }

    fn emit(&self, event: NetEvent) {
        if let NetEvent::Candidate(c) = &event {
            let mut gathered = self.gathered.get();
            if let Some(n) = gathered.get_mut(kind_index(c.kind)) {
                *n += 1;
            }
            self.gathered.set(gathered);
        }
        let phase = match &event {
            NetEvent::CandidatesDone => Some((ConnectPhase::GatherDone, None)),
            NetEvent::Endpoint(EndpointEvent::Link(crate::Event::Established)) => {
                Some((ConnectPhase::HandshakeDone, None))
            }
            NetEvent::Endpoint(EndpointEvent::PathChanged { route: Some(route), .. }) => {
                Some((ConnectPhase::Nominated, Some(*route)))
            }
            _ => None,
        };
        self.send_event(event);
        if let Some((phase, route)) = phase {
            self.phase(phase, route);
        }
    }

    /// Reports `phase` the first time it happens.
    fn phase(&self, phase: ConnectPhase, route: Option<Route>) {
        let seen = self.phases.get();
        if seen & phase.bit() != 0 {
            return;
        }
        self.phases.set(seen | phase.bit());
        self.send_event(NetEvent::Phase { phase, at_us: now_us(self.start), route });
    }

    fn send_event(&self, event: NetEvent) {
        if self.events.send(event).is_ok() {
            self.event_wake.wake();
        }
    }

    fn send_media_datagram(&mut self, datagram: &[u8], now: u64) -> Result<(), LinkError> {
        // Preserve identity before sealing; never infer departure from enqueue.
        let header = DatagramHeader::decode(datagram).ok().map(|(header, _)| header);
        for transmit in self.endpoint.send_datagram(datagram)? {
            if let Some((departed_us, wire_bytes)) =
                self.send(transmit.route, &transmit.packet, now)
                && let Some(header) = header.filter(|header| {
                    matches!(
                        header.kind,
                        cmux_rd_proto::DatagramKind::Video
                            | cmux_rd_proto::DatagramKind::Fec
                            | cmux_rd_proto::DatagramKind::UpMedia
                    )
                })
            {
                let receipt = DatagramDeparture { header, departed_us, wire_bytes };
                if self.departures.try_send(receipt).is_ok() {
                    self.departure_wake = true;
                } else {
                    self.departure_overflows.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        Ok(())
    }

    fn send(&mut self, route: Route, packet: &[u8], now: u64) -> Option<(u64, usize)> {
        match route {
            Route::Udp(addr) => send_counted(&self.socket, &mut self.refused, packet, addr),
            Route::Relay { relay, peer } => {
                let r = self.relays.get_mut(usize::from(relay))?;
                if !r.live() {
                    return None;
                }
                let wrapped = r.client.send(peer, packet, now)?;
                r.transmit(&self.socket, &mut self.refused, &wrapped)
            }
        }
    }

    fn flush(&mut self, now: u64) -> Result<(), LinkError> {
        for t in self.endpoint.poll_transmit(now)? {
            if self.send(t.route, &t.packet, now).is_some() {
                self.phase(ConnectPhase::FirstCheckSent, Some(t.route));
                if is_handshake(&t.packet) {
                    self.phase(ConnectPhase::HandshakeStart, Some(t.route));
                }
            }
        }
        for event in self.endpoint.take_events() {
            self.emit(NetEvent::Endpoint(event));
        }
        Ok(())
    }

    /// Takes the late servers once they resolved; their queries and allocations start now.
    fn later_tick(&mut self) {
        if let Some(found) = self.stun_later.as_mut().and_then(|later| later()) {
            self.stun_later = None;
            for server in found {
                self.add_stun(server);
            }
        }
        if let Some(found) = self.turn_later.as_mut().and_then(|later| later()) {
            self.turn_later = None;
            for server in found {
                self.add_turn(server);
            }
        }
    }

    fn add_turn(&mut self, server: TurnServer) {
        let stream = server.transport != TurnTransport::Udp;
        // One server may take UDP and TCP on one port: a UDP and a stream relay to it are two.
        if self.relays.len() >= MAX_TURN_SERVERS
            || self.relays.iter().any(|r| r.server == server.addr && r.stream.is_some() == stream)
        {
            return;
        }
        let now = now_us(self.start);
        let connected = match &server.transport {
            TurnTransport::Udp => Ok(None),
            TurnTransport::Tcp => StreamRelay::connect(server.addr, None, now).map(Some),
            TurnTransport::Tls { server_name } => {
                StreamRelay::connect(server.addr, Some(server_name), now).map(Some)
            }
        };
        let (stream, failed) = match connected {
            Ok(stream) => (stream, None),
            Err(e) => (None, Some(format!("connect: {e}"))),
        };
        self.relays.push(Relay {
            server: server.addr,
            client: TurnClient::new(&server.username, &server.password, seed()),
            settled: false,
            stream,
            dead: false,
        });
        if let Some(reason) = failed {
            self.relay_failed(self.relays.len() - 1, reason, now);
        }
    }

    /// A stream relay's connection failed or ended: it is settled and stays out of every path.
    fn relay_failed(&mut self, index: usize, reason: String, now: u64) {
        let Some(r) = self.relays.get_mut(index) else { return };
        if r.dead {
            return;
        }
        r.dead = true;
        r.settled = true;
        r.stream = None;
        let server = r.server;
        self.emit(NetEvent::RelayFailed { server, reason });
        self.maybe_done(now);
    }

    /// Reads every stream relay and feeds its messages to the relay's TURN client, as the
    /// UDP loop does for datagrams from a server. True when the peer closed the session.
    fn read_streams(&mut self, now: u64) -> Result<bool, LinkError> {
        for index in 0..self.relays.len() {
            let Some(stream) = self.relays.get_mut(index).and_then(|r| r.stream.as_mut()) else {
                continue;
            };
            let mut messages = Vec::new();
            let ended = stream.read(|m| messages.push(m.to_vec())).err();
            for message in messages {
                let Some(r) = self.relays.get_mut(index) else { break };
                match r.client.on_packet(&message, now) {
                    TurnReceive::Data { peer, payload } => {
                        self.heard += 1;
                        let relay = u16::try_from(index).unwrap_or(u16::MAX);
                        if self.deliver(Route::Relay { relay, peer }, payload, now)? {
                            return Ok(true);
                        }
                    }
                    TurnReceive::Handled => self.turn_events(now),
                    TurnReceive::Ignored => {}
                }
            }
            if let Some(reason) = ended {
                self.relay_failed(index, reason, now);
            }
        }
        Ok(false)
    }

    fn add_stun(&mut self, server: SocketAddr) {
        if self.relay_only
            || self.stun.len() >= MAX_STUN_SERVERS
            || self.stun.iter().any(|q| q.server == server)
        {
            return;
        }
        self.stun.push(StunQuery {
            server,
            transaction: transaction(self.stun.len()),
            attempts: 0,
            next_us: 0,
            done: false,
        });
    }

    fn stun_tick(&mut self, now: u64) {
        for q in self.stun.iter_mut().filter(|q| !q.done && q.next_us <= now) {
            if q.attempts >= STUN_ATTEMPTS {
                q.done = true;
                continue;
            }
            q.attempts += 1;
            q.next_us = now + STUN_RETRY_US;
            send_counted(
                &self.socket,
                &mut self.refused,
                &binding_request(q.transaction),
                q.server,
            );
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
        for index in 0..self.relays.len() {
            let Some(r) = self.relays.get_mut(index) else { continue };
            if let Some(Err(reason)) = r.stream.as_mut().map(|stream| stream.poll(now)) {
                self.relay_failed(index, reason, now);
                continue;
            }
            if !r.live() {
                continue;
            }
            for packet in r.client.poll_transmit(now) {
                r.transmit(&self.socket, &mut self.refused, &packet);
            }
        }
        self.turn_events(now);
    }

    fn turn_events(&mut self, now: u64) {
        for index in 0..self.relays.len() {
            let Some(relay) = self.relays.get_mut(index) else { continue };
            if relay.dead {
                continue;
            }
            let events = relay.client.take_events();
            if !events.is_empty() {
                relay.settled = true;
            }
            for event in events {
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
                        if let Some(server) = self.relays.get(index).map(|r| r.server) {
                            self.emit(NetEvent::RelayFailed { server, reason: error.to_string() });
                        }
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
        if r.live() && r.client.relayed().is_some() && r.client.add_peer(peer, now) {
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
        if self.phases.get() & ConnectPhase::HandshakeDone.bit() == 0 {
            self.phase(ConnectPhase::FirstCheckAnswered, Some(route));
            if is_handshake(packet) {
                self.phase(ConnectPhase::HandshakeStart, Some(route));
            }
        }
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
        if self.endpoint.link().is_established()
            && (self.media_queue.lock().is_ok_and(|queue| !queue.frames.is_empty())
                || !self.pending_datagrams.is_empty())
        {
            return 0;
        }
        let stun = self.stun.iter().filter(|q| !q.done).map(|q| q.next_us).min();
        let later =
            (self.stun_later.is_some() || self.turn_later.is_some()).then_some(now + LATER_POLL_US);
        // A stream still connecting: its give-up time, not the client's (it has not started).
        let turn = self
            .relays
            .iter()
            .filter(|r| !r.dead)
            .filter_map(|r| match &r.stream {
                Some(stream) if !stream.is_ready() => stream.deadline_us(),
                _ => r.client.next_deadline_us(),
            })
            .min();
        let gather = (!self.candidates_done && now < RELAY_GATHER_US).then_some(RELAY_GATHER_US);
        match [self.endpoint.next_deadline_us(), stun, later, turn, gather]
            .into_iter()
            .flatten()
            .min()
        {
            Some(at) => i32::try_from(at.saturating_sub(now).div_ceil(1000)).unwrap_or(i32::MAX),
            None => 1000,
        }
    }

    /// What this side gathered and what the peer sent, by kind, for a failure's reason
    /// ([`no_path`]): whether the handshake ever reached this side and which routes each
    /// side had (the sends the system refused follow it, [`refused_text`]). Counts only, never an address.
    fn candidate_counts(&self) -> (no_path::Counts, no_path::Counts) {
        let mut peer = [0u32; 3];
        for c in &self.remote {
            if let Some(n) = peer.get_mut(kind_index(c.kind)) {
                *n += 1;
            }
        }
        (self.gathered.get(), peer)
    }

    fn run(&mut self) {
        let Err(error) = self.serve() else { return };
        // Counted after the run: what was gathered and heard by the time it failed.
        let (local, peer) = self.candidate_counts();
        let why = match error {
            // No path at all: say so in words the viewer's failed card can show.
            LinkError::HandshakeTimeout => no_path::handshake_timeout(local, peer, self.heard),
            e => format!("{e} ({})", no_path::counts(local, peer, self.heard)),
        };
        let why = format!("{why}{}", refused_text(&self.refused));
        self.emit(NetEvent::Failed(why));
    }

    fn serve(&mut self) -> Result<(), LinkError> {
        let mut buf = vec![0u8; MAX_PACKET];
        loop {
            let now = now_us(self.start);
            self.watch_wake(now);
            self.later_tick();
            self.stun_tick(now);
            self.turn_tick(now);
            self.flush(now)?;
            if self.endpoint.link().controls_acknowledged() {
                for barrier in self.barriers.drain(..) {
                    let _ = barrier.send(());
                }
            }
            let timeout = self.deadline_ms(now);
            let mut wait = vec![(sys::raw(&self.socket), false), (self.command_wake.raw(), false)];
            for stream in self.relays.iter().filter_map(|r| r.stream.as_ref()) {
                wait.push((stream.raw(), stream.wants_write()));
            }
            wait_ready(&wait, timeout);
            self.command_wake.drain();
            let now = now_us(self.start);
            self.watch_wake(now);
            while let Ok(command) = self.commands.try_recv() {
                match command {
                    Command::RemoteCandidate(c) => self.on_remote_candidate(c, now),
                    Command::StunLater(later) => {
                        self.stun_later = (!self.relay_only).then_some(later);
                    }
                    Command::TurnLater(later) => self.turn_later = Some(later),
                    Command::Control(r) => self.endpoint.send_control(r, now)?,
                    Command::ControlBarrier(reply) => self.barriers.push(reply),
                    Command::Datagram(datagram) => {
                        // Input, cursor and repair traffic never replaces queued video.
                        if self.endpoint.link().is_established() {
                            self.send_media_datagram(&datagram, now)?;
                        } else {
                            self.pending_datagrams.push_back(datagram);
                        }
                    }
                    Command::NetworkChange => {
                        self.endpoint.set_local_networks(cmux_transport::local_networks());
                        self.endpoint.on_network_change();
                    }
                    Command::PeerLost(us) => self.endpoint.set_peer_lost(us),
                    Command::Close => {
                        // What was queued before the close goes out first: a host's `ended`
                        // reason sent just before it drops the link (`failed: <why>`) must reach
                        // the viewer, not vanish behind the close packet.
                        self.flush(now)?;
                        if self.endpoint.link().is_established() {
                            for t in self.endpoint.close()? {
                                let _ = self.send(t.route, &t.packet, now);
                            }
                        }
                        for r in &mut self.relays {
                            if !r.live() {
                                continue;
                            }
                            let packets = r.client.close();
                            match r.stream.as_mut() {
                                Some(stream) => stream.close(packets),
                                None => {
                                    for packet in packets {
                                        send_counted(
                                            &self.socket,
                                            &mut self.refused,
                                            &packet,
                                            r.server,
                                        );
                                    }
                                }
                            }
                        }
                        return Ok(());
                    }
                }
            }
            loop {
                match self.socket.recv_from(&mut buf) {
                    Ok((n, from)) => {
                        let packet = buf.get(..n).unwrap_or_default();
                        if let Some((index, server)) = self
                            .relays
                            .iter_mut()
                            .enumerate()
                            .find(|(_, r)| r.server == from && r.stream.is_none())
                        {
                            match server.client.on_packet(packet, now) {
                                TurnReceive::Data { peer, payload } => {
                                    self.heard += 1;
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
                        self.heard += 1;
                        if self.deliver(Route::Udp(from), packet, now)? {
                            return Ok(());
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    // ICMP errors (port unreachable on a dead candidate) surface here; keep going.
                    Err(_) => break,
                }
            }
            if self.read_streams(now)? {
                return Ok(());
            }
            for _ in 0..256 {
                let Ok(queued) = self.media.try_recv() else { break };
                if self.endpoint.link().is_established()
                    && let Some(datagram) = queued.take_payload_if_fresh(Instant::now())
                {
                    self.send_media_datagram(&datagram, now)?;
                }
            }
            self.flush(now)?;
            self.drain_pending_datagrams(now)?;
            self.drain_media(now)?;
            if std::mem::take(&mut self.departure_wake) {
                // One wake per driver turn, not a syscall per media datagram.
                self.event_wake.wake();
            }
        }
    }
}

/// A Noise handshake message (msg1, msg2 or msg3).
fn is_handshake(packet: &[u8]) -> bool {
    matches!(packet.first(), Some(&(crate::TAG_HANDSHAKE_1..=crate::TAG_HANDSHAKE_3)))
}

#[cfg(test)]
#[path = "net_media_handoff_tests.rs"]
mod media_handoff_tests;
