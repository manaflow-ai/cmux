//! The userspace TCP side of a tunnel: one smoltcp interface, its sockets,
//! and the bridges between those sockets and [`WgStream`]s.
//!
//! Both engines own one: [`crate::WgNet`] (one peer) and [`crate::WgMesh`]
//! (many peers). The stack knows nothing about WireGuard. Its engine feeds
//! it decrypted packets ([`TcpStack::push_rx`]), drains the packets it emits
//! ([`TcpStack::pop_tx`]), and calls [`TcpStack::step`] after either.
//!
//! In tagged mode (the mesh) every connection carries the key of its peer:
//! the key of the route a `connect` used, or, for an accepted connection,
//! the key of the session that delivered its SYN. An accepted connection
//! whose SYN came with no key is reset, never matched by address.

use std::collections::hash_map::RandomState;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{BuildHasher, Hasher};
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use bytes::Bytes;
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant as SmolInstant;
use smoltcp::wire::{HardwareAddress, IpCidr, IpEndpoint, IpListenEndpoint};
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::time::Instant;
use tokio_util::sync::PollSender;

use crate::config::InterfaceAddress;
use crate::device::VirtualDevice;
use crate::error::WgError;
use crate::send_gate::{SendGate, SendPacer};
use crate::stream::{Outbound, WgStream};
use crate::wire::{ip_address, socket_addr};

/// Per-socket receive and transmit buffers. Terminal traffic is small; the
/// bulk lane (screen replay) benefits from a full window.
pub(crate) const SOCKET_BUFFER_BYTES: usize = 256 * 1024;
/// Largest chunk moved from a smoltcp socket into a stream at once.
pub(crate) const INBOUND_CHUNK_BYTES: usize = 16 * 1024;
/// Queued chunks per direction per connection before backpressure.
const STREAM_CHANNEL_DEPTH: usize = 32;
/// Pending accepted connections a listener holds before refusing more.
const LISTENER_BACKLOG: usize = 16;
/// Spare LISTEN sockets kept per port. smoltcp has no accept queue: each
/// listening socket becomes exactly one connection. A small pool lets a burst
/// of concurrent SYNs (one per lane) each land on its own socket instead of
/// being reset, and each is refilled the moment it leaves LISTEN so a retransmit
/// of an in-progress SYN matches the existing half-open rather than a spare.
pub(crate) const LISTEN_SPARES: usize = 8;
/// Connections with no ACK for this long are aborted; link connections use
/// [`LINK_TCP_TIMEOUT`] instead.
pub(crate) const TCP_TIMEOUT: Duration = Duration::from_secs(60);
/// Probe each idle TCP connection before its receive timeout. WireGuard
/// keepalives and application heartbeats on another lane do not elicit its ACKs.
const TCP_KEEP_ALIVE: Duration = Duration::from_secs(15);
/// The floor under the retransmission timeout once an RTT is measured:
/// Linux's `TCP_RTO_MIN`. smoltcp defaults to RFC 6298's 1 s, which turns one
/// lost segment at the tail of a frame into a 1 s stall. Linux peers run
/// with the same floor against each other's delayed ACKs, and smoltcp delays
/// an ACK by 10 ms.
const TCP_MIN_RTO: Duration = Duration::from_millis(200);
/// The retransmission timeout before a connection has an RTT sample, which
/// is what a lost SYN or SYN-ACK waits. smoltcp defaults to RFC 6298's 1 s,
/// so one lost SYN held a cold dial a full second (3% of them on a lossy
/// phone link). 300 ms is above a typical cellular round trip; a slower one
/// resends a SYN early, which costs one segment, and no RTT sample is taken
/// from a resent segment (Karn), so the estimate is not skewed.
const TCP_INITIAL_RTO: Duration = Duration::from_millis(300);
/// How long a peer may hold an ACK, in the tail-loss probe timeout
/// (`2 * SRTT` plus this). smoltcp peers delay ACKs 10 ms; the margin covers
/// a kernel peer's first delayed ACK. A probe sent too early costs one
/// segment resent.
const TCP_PROBE_ACK_DELAY: Duration = Duration::from_millis(25);
/// The ephemeral port range (IANA 49152-65535); allocation starts at a random
/// port inside it and wraps, as a real stack does.
pub(crate) const FIRST_EPHEMERAL_PORT: u16 = 49_152;
const EPHEMERAL_PORT_COUNT: u16 = u16::MAX - FIRST_EPHEMERAL_PORT;
/// The overlay port of `cmux link` connections (transport.md 12a).
pub(crate) const LINK_PORT: u16 = 4100;
/// A link connection survives a silent peer this long (a phone in the
/// background, a laptop lid closed briefly); its streams then resume
/// without a reconnect.
pub(crate) const LINK_TCP_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// SYN origins remembered at once (tagged mode). Entries leave when their
/// connection is accepted; past this bound the ones without a half-open
/// socket are dropped, and a SYN that still finds no room is dropped too.
const MAX_SYN_ORIGINS: usize = 1024;

/// A peer's public key, the tag of a connection in a mesh.
pub(crate) type PeerKey = [u8; 32];
/// An accepted connection and its tag.
pub(crate) type Accepted = (WgStream, Option<PeerKey>);
/// A connection's local and remote address.
type FlowKey = (SocketAddr, SocketAddr);

/// The TCP user timeout for a connection to or on `port`.
pub(crate) fn user_timeout(port: u16) -> Duration {
    if port == LINK_PORT { LINK_TCP_TIMEOUT } else { TCP_TIMEOUT }
}

fn random_ephemeral_port() -> u16 {
    let mut seed = [0u8; 2];
    // A failure here only weakens port randomization, never correctness.
    let _ = getrandom::fill(&mut seed);
    FIRST_EPHEMERAL_PORT + (u16::from_le_bytes(seed) % EPHEMERAL_PORT_COUNT)
}

/// How a newly established socket reaches its owner.
pub(crate) enum Handoff {
    Connect(oneshot::Sender<Result<WgStream, WgError>>),
    Accept(mpsc::Sender<Accepted>),
}

pub(crate) struct Conn {
    pub(crate) handle: SocketHandle,
    pub(crate) remote: SocketAddr,
    /// The peer key in tagged mode.
    pub(crate) peer: Option<PeerKey>,
    /// The stream waiting to be handed to its owner once the socket is
    /// established. Taken on delivery.
    pub(crate) pending_stream: Option<(Handoff, WgStream)>,
    /// `None` once the remote closed and the buffer drained (EOF delivered),
    /// or once the owner dropped its reader.
    pub(crate) inbound: Option<mpsc::Sender<Bytes>>,
    pub(crate) outbound: mpsc::Receiver<Outbound>,
    /// Head of the outbound queue not yet accepted by smoltcp.
    pub(crate) pending_write: Option<Bytes>,
    pub(crate) outbound_closed: bool,
    /// The peer's FIN arrived: a socket that ends after this ended cleanly,
    /// one that ends without it was reset or timed out.
    pub(crate) remote_fin: bool,
    /// Bytes taken from the socket after it closed, before the owner read
    /// them (TIME-WAIT's timer would clear the socket's buffer).
    pub(crate) drained: VecDeque<Bytes>,
    /// Set before the connection is dropped for a reason the owner must see
    /// as an error (its peer was removed, or the socket was reset or timed
    /// out before the peer's FIN).
    pub(crate) reset: Arc<AtomicBool>,
    /// Measures the delivery rate and holds the stream's writes at the
    /// low-water mark of unsent bytes ([`crate::send_gate`]).
    pub(crate) send: SendPacer,
}

pub(crate) struct Listener {
    pub(crate) port: u16,
    /// Sockets in LISTEN or SYN-RECEIVED for this port.
    pub(crate) handles: Vec<SocketHandle>,
    pub(crate) accept: mpsc::Sender<Accepted>,
}

pub(crate) struct TcpStack {
    pub(crate) iface: Interface,
    pub(crate) device: VirtualDevice,
    pub(crate) sockets: SocketSet<'static>,
    pub(crate) conns: Vec<Conn>,
    pub(crate) listeners: Vec<Listener>,
    pub(crate) wake: Arc<Notify>,
    /// The stack's clock. Tokio's, so the stack and the driver's timers
    /// agree, including under a paused test clock.
    epoch: Instant,
    next_port: u16,
    /// Tagged mode: the key of the session that delivered each SYN, by flow.
    pub(crate) syn_origins: Option<HashMap<FlowKey, PeerKey>>,
    /// [`TcpStack::close_all`] ran: each connection closes after what its owner had queued.
    pub(crate) closing: bool,
    /// Congestion control for new connections: Cubic, or none when ultra
    /// mode holds the rate through loss (`CMUX_WG_ULTRA_CC=none`).
    pub(crate) congestion: tcp::CongestionControl,
    /// [`TcpStack::set_hold`]: how long a peer that went silent on purpose
    /// is waited for, while it is held.
    hold: Option<Duration>,
    /// After a hold is released, when the usual user timeout comes back
    /// ([`HOLD_RELEASE_GRACE`]).
    release_at: Option<Instant>,
    /// `CMUX_WG_CWND_TRACE=1`: each connection's congestion state as last
    /// printed ([`TcpStack::trace_congestion`]).
    cwnd_trace: Option<HashMap<SocketHandle, CongestionTrace>>,
}

/// One connection's congestion window, slow start threshold, timeouts and
/// tail-loss probes fired, as a trace prints them.
type CongestionTrace = (usize, usize, u32, u32);

fn cwnd_trace_enabled() -> bool {
    std::env::var_os("CMUX_WG_CWND_TRACE").is_some_and(|value| value == "1")
}

/// Wall-clock microseconds, so traces from both tunnels and a harness line up.
fn trace_clock() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_micros())
}

/// How long a released hold keeps its long timeout. A connection idle
/// through the hold (an input lane with no keystroke yet) last heard its
/// peer minutes ago, and its user timeout counts from then: restored at once,
/// it would abort at the next poll. The keepalive probe that the release
/// sends at once is answered well inside this, which makes the peer recent.
const HOLD_RELEASE_GRACE: Duration = Duration::from_secs(30);

impl TcpStack {
    /// An interface holding `addresses`. `tagged` turns on per-peer tags.
    pub(crate) fn new(
        addresses: &[InterfaceAddress],
        mtu: u16,
        wake: Arc<Notify>,
        tagged: bool,
    ) -> Result<Self, WgError> {
        let mut device = VirtualDevice::new(mtu);
        let mut iface_config = Config::new(HardwareAddress::Ip);
        iface_config.random_seed = RandomState::new().build_hasher().finish();
        let mut iface = Interface::new(iface_config, &mut device, SmolInstant::from_micros(0));
        let mut overflow = false;
        iface.update_ip_addrs(|list| {
            for entry in addresses {
                let cidr = IpCidr::new(ip_address(entry.address), entry.prefix);
                overflow |= list.push(cidr).is_err();
            }
        });
        if overflow {
            return Err(WgError::Stack("too many interface addresses".into()));
        }
        // Medium::Ip has no neighbor resolution, so the gateway address is
        // only a routing-table formality: everything not on a local subnet
        // goes to the engine, which picks the peer.
        for entry in addresses {
            let result = match entry.address {
                IpAddr::V4(address) => iface.routes_mut().add_default_ipv4_route(address),
                IpAddr::V6(address) => iface.routes_mut().add_default_ipv6_route(address),
            };
            result.map_err(|_| WgError::Stack("route table full".into()))?;
        }
        Ok(Self {
            iface,
            device,
            sockets: SocketSet::new(Vec::new()),
            conns: Vec::new(),
            listeners: Vec::new(),
            wake,
            epoch: Instant::now(),
            next_port: random_ephemeral_port(),
            syn_origins: tagged.then(HashMap::new),
            closing: false,
            congestion: tcp::CongestionControl::Cubic,
            hold: None,
            release_at: None,
            cwnd_trace: cwnd_trace_enabled().then(HashMap::new),
        })
    }

    /// Hold every connection for a peer that goes silent on purpose (a phone
    /// suspended in the background): no keepalive probe goes out, data whose
    /// ACK was lost is not retransmitted, and a connection is aborted only
    /// after `hold` without a segment from the peer instead of its usual user
    /// timeout. `None` releases it: the keepalive comes back at once (its
    /// first probe goes out now), unacknowledged data is resent at once, and
    /// the usual user timeout [`HOLD_RELEASE_GRACE`] later, once that probe's
    /// answer has made the peer recent again.
    pub(crate) fn set_hold(&mut self, hold: Option<Duration>) {
        if self.cwnd_trace.is_some() {
            eprintln!(
                "CWNDTRACE {} hold={hold:?} was={:?} conns={}",
                trace_clock(),
                self.hold,
                self.conns.len()
            );
        }
        let held = self.hold.or(hold);
        self.hold = hold;
        self.release_at = match hold {
            Some(_) => None,
            None => held.map(|_| Instant::now() + HOLD_RELEASE_GRACE),
        };
        for conn in &self.conns {
            let socket = self.sockets.get_mut::<tcp::Socket>(conn.handle);
            match (hold, held) {
                (Some(hold), _) => {
                    apply_hold(socket, Some(hold));
                    socket.set_retransmit_paused(true);
                }
                // Released: probe and resend now, keep the long timeout for
                // the grace.
                (None, Some(_)) => {
                    socket.set_keep_alive(Some(smol_duration(TCP_KEEP_ALIVE)));
                    socket.set_retransmit_paused(false);
                }
                (None, None) => {}
            }
        }
    }

    /// Start tracking a connection the stack just admitted (accepted or
    /// dialed). One admitted while held is held like the others (a late
    /// input lane's SYN can arrive after the park): no keepalive, no
    /// retransmission, and the hold's timeout instead of its user timeout.
    pub(crate) fn admit(&mut self, conn: Conn) {
        if let Some(hold) = self.hold {
            let socket = self.sockets.get_mut::<tcp::Socket>(conn.handle);
            apply_hold(socket, Some(hold));
            socket.set_retransmit_paused(true);
        }
        self.conns.push(conn);
    }

    /// The hold in force ([`TcpStack::set_hold`]).
    pub(crate) fn hold(&self) -> Option<Duration> {
        self.hold
    }

    /// When the stack must step to end a released hold's grace.
    pub(crate) fn release_deadline(&self) -> Option<Instant> {
        self.release_at
    }

    pub(crate) fn now(&self) -> SmolInstant {
        SmolInstant::from_micros(
            i64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(i64::MAX),
        )
    }

    /// Let smoltcp consume received packets and emit its own.
    pub(crate) fn poll(&mut self) {
        let now = self.now();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
    }

    /// The tunnel moved to another route: every connection with data in
    /// flight resends it at once, with its RTO back at the RTT estimate.
    pub(crate) fn path_changed(&mut self) {
        for conn in &self.conns {
            self.sockets.get_mut::<tcp::Socket>(conn.handle).path_changed();
        }
    }

    /// Ultra mode began repairing this tunnel's losses (Auto turned it on at
    /// the first loss): the losses that turned it on, and any other of data
    /// already in flight, cut no congestion window, and a cut one already
    /// made is undone. Repair covers the link from here on, as it covers a
    /// tunnel that started in Always, whose TCP never sees those losses.
    pub(crate) fn link_repairs_losses(&mut self) {
        for conn in &self.conns {
            self.sockets.get_mut::<tcp::Socket>(conn.handle).link_repairs_losses();
        }
    }

    /// When smoltcp next wants a poll, or `None` to wait for an event.
    pub(crate) fn poll_delay(&mut self) -> Option<Duration> {
        let now = self.now();
        self.iface
            .poll_delay(now, &self.sockets)
            .map(|delay| Duration::from_micros(delay.total_micros()))
    }

    /// One pass: poll, accept, move bytes between sockets and streams, then
    /// poll again so anything the streams produced is emitted in the same
    /// pass. Returns whether a byte moved, so the engine can pass again.
    pub(crate) fn step(&mut self) -> bool {
        if self.release_at.is_some_and(|at| Instant::now() >= at) {
            self.release_at = None;
            for conn in &self.conns {
                apply_hold(self.sockets.get_mut::<tcp::Socket>(conn.handle), None);
            }
        }
        self.poll();
        self.process_listeners();
        let progressed = self.process_conns();
        self.poll();
        self.update_send_gates();
        self.trace_congestion();
        progressed
    }

    /// `CMUX_WG_CWND_TRACE=1`: print each connection's congestion state
    /// whenever it changed since the last step.
    fn trace_congestion(&mut self) {
        let Some(last) = self.cwnd_trace.as_mut() else {
            return;
        };
        for conn in &self.conns {
            let socket = self.sockets.get::<tcp::Socket>(conn.handle);
            let (rto, tlp) = socket.retransmit_firings();
            let now = (socket.congestion_window(), socket.slow_start_threshold(), rto, tlp);
            if last.insert(conn.handle, now) != Some(now) {
                let ssthresh =
                    if now.1 == usize::MAX { "max".to_owned() } else { now.1.to_string() };
                eprintln!(
                    "CWNDTRACE {} flow={:?} cwnd={} ssthresh={ssthresh} rto_fired={rto} tlp_fired={tlp} queued={} held={}",
                    trace_clock(),
                    socket_flow(socket),
                    now.0,
                    socket.send_queue(),
                    self.hold.is_some(),
                );
            }
        }
    }

    /// Tell each stream how many of its bytes TCP has not sent yet and its
    /// low-water mark, after the poll that sent what the window allowed;
    /// a writer held at the mark is woken once there is room.
    fn update_send_gates(&mut self) {
        let now = Instant::now();
        for conn in &mut self.conns {
            let socket = self.sockets.get::<tcp::Socket>(conn.handle);
            let srtt = socket.smoothed_rtt().map(|srtt| Duration::from_micros(srtt.total_micros()));
            conn.send.update(now, socket.send_queue(), socket.unsent_queue(), srtt);
        }
    }

    /// Queue a decrypted packet for the next poll. In tagged mode `origin` is
    /// the key of the session that delivered it, recorded for a SYN.
    pub(crate) fn push_rx(&mut self, packet: Vec<u8>, origin: Option<PeerKey>) {
        if let Some(origins) = self.syn_origins.as_mut()
            && let Some(flow) = syn_flow(&packet)
        {
            let Some(origin) = origin else { return };
            if origins.len() >= MAX_SYN_ORIGINS && !origins.contains_key(&flow) {
                let half_open = half_open_flows(&self.sockets, &self.listeners);
                origins.retain(|flow, _| half_open.contains(flow));
                if origins.len() >= MAX_SYN_ORIGINS {
                    return;
                }
            }
            origins.insert(flow, origin);
        }
        self.device.push_rx(packet);
    }

    /// Take the next packet smoltcp wants sent.
    pub(crate) fn pop_tx(&mut self) -> Option<Vec<u8>> {
        self.device.pop_tx()
    }

    pub(crate) fn has_rx(&self) -> bool {
        self.device.has_rx()
    }

    pub(crate) fn allocate_port(&mut self) -> u16 {
        for _ in 0..EPHEMERAL_PORT_COUNT {
            let port = self.next_port;
            self.next_port = if self.next_port >= u16::MAX - 1 {
                FIRST_EPHEMERAL_PORT
            } else {
                self.next_port + 1
            };
            let in_use = self.conns.iter().any(|conn| {
                self.sockets
                    .get::<tcp::Socket>(conn.handle)
                    .local_endpoint()
                    .is_some_and(|endpoint| endpoint.port == port)
            });
            if !in_use {
                return port;
            }
        }
        self.next_port
    }

    /// A socket that gives up after `timeout` without an ACK from the peer.
    pub(crate) fn new_socket(
        timeout: Duration,
        congestion: tcp::CongestionControl,
    ) -> tcp::Socket<'static> {
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
        );
        // Keystrokes are latency-bound; the OS dial path disables Nagle too.
        socket.set_nagle_enabled(false);
        socket.set_congestion_control(congestion);
        socket.set_min_rto(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_MIN_RTO.as_micros()).unwrap_or(u64::MAX),
        ));
        socket.set_initial_rto(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_INITIAL_RTO.as_micros()).unwrap_or(u64::MAX),
        ));
        // A lone lost segment is resent after about two round trips, not the RTO.
        socket.set_tail_loss_probe(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_PROBE_ACK_DELAY.as_micros()).unwrap_or(u64::MAX),
        )));
        // Under repeated loss, resend only the holes the peer's SACK blocks
        // show, several per round trip, with one window cut per episode.
        socket.set_sack_recovery(true);
        // An underlay path smaller than the tunnel MTU that silently drops
        // full segments: after two timeouts in a row, send 1280 byte packets.
        socket.set_black_hole_fallback(true);
        socket.set_timeout(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(timeout.as_micros()).unwrap_or(u64::MAX),
        )));
        socket.set_keep_alive(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_KEEP_ALIVE.as_micros()).unwrap_or(u64::MAX),
        )));
        socket
    }

    /// Start a connection from `local_ip` to `remote`; `reply` gets the
    /// stream once the handshake completes.
    pub(crate) fn begin_connect(
        &mut self,
        local_ip: IpAddr,
        remote: SocketAddr,
        peer: Option<PeerKey>,
        reply: oneshot::Sender<Result<WgStream, WgError>>,
    ) {
        if reply.is_closed() {
            return;
        }
        let port = self.allocate_port();
        let local = SocketAddr::new(local_ip, port);
        let mut socket = Self::new_socket(user_timeout(remote.port()), self.congestion);
        let result = socket.connect(
            self.iface.context(),
            IpEndpoint::new(ip_address(remote.ip()), remote.port()),
            IpListenEndpoint::from(IpEndpoint::new(ip_address(local.ip()), local.port())),
        );
        if let Err(error) = result {
            let _ = reply.send(Err(WgError::Stack(format!("{error}"))));
            return;
        }
        let handle = self.sockets.add(socket);
        let (conn, stream) = self.bridge(handle, local, remote, peer);
        self.admit(Conn { pending_stream: Some((Handoff::Connect(reply), stream)), ..conn });
    }

    pub(crate) fn begin_listen(&mut self, port: u16) -> Result<mpsc::Receiver<Accepted>, WgError> {
        if self.listeners.iter().any(|listener| listener.port == port) {
            return Err(WgError::ListenerBusy(port));
        }
        let mut handles = Vec::with_capacity(LISTEN_SPARES);
        for _ in 0..LISTEN_SPARES {
            handles.push(self.listening_socket(port)?);
        }
        let (accept_tx, accept_rx) = mpsc::channel(LISTENER_BACKLOG);
        self.listeners.push(Listener { port, handles, accept: accept_tx });
        Ok(accept_rx)
    }

    pub(crate) fn listening_socket(&mut self, port: u16) -> Result<SocketHandle, WgError> {
        let mut socket = Self::new_socket(user_timeout(port), self.congestion);
        socket
            .listen(IpListenEndpoint::from(port))
            .map_err(|error| WgError::Stack(format!("{error}")))?;
        Ok(self.sockets.add(socket))
    }

    /// Build the channel pair for a socket: the stack-side [`Conn`] and the
    /// owner-side [`WgStream`].
    pub(crate) fn bridge(
        &self,
        handle: SocketHandle,
        local: SocketAddr,
        remote: SocketAddr,
        peer: Option<PeerKey>,
    ) -> (Conn, WgStream) {
        let (inbound_tx, inbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let (outbound_tx, outbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let reset = Arc::new(AtomicBool::new(false));
        let gate = Arc::new(SendGate::default());
        let stream = WgStream {
            local,
            remote,
            inbound: inbound_rx,
            leftover: Bytes::new(),
            outbound: PollSender::new(outbound_tx),
            wake: Arc::clone(&self.wake),
            shutdown_sent: false,
            reset: Arc::clone(&reset),
            gate: Arc::clone(&gate),
        };
        let conn = Conn {
            handle,
            remote,
            peer,
            pending_stream: None,
            inbound: Some(inbound_tx),
            outbound: outbound_rx,
            pending_write: None,
            outbound_closed: false,
            remote_fin: false,
            drained: VecDeque::new(),
            reset,
            send: SendPacer::new(gate),
        };
        (conn, stream)
    }
}

/// The flow of a TCP SYN (without ACK) as (local, remote): the packet's
/// destination and source.
fn syn_flow(packet: &[u8]) -> Option<FlowKey> {
    let segment = crate::pacing::segment(packet)?;
    if !segment.syn || segment.ack.is_some() {
        return None;
    }
    let local = SocketAddr::new(segment.destination.0, segment.destination.1);
    let remote = SocketAddr::new(segment.source.0, segment.source.1);
    Some((local, remote))
}

/// A held socket sends no keepalive probe and waits `hold` for its peer; an
/// unheld one has the keepalive and user timeout it was created with.
fn apply_hold(socket: &mut tcp::Socket<'static>, hold: Option<Duration>) {
    let (timeout, keep_alive) = match hold {
        Some(hold) => (hold, None),
        None => {
            let timeout = socket_flow(socket).map_or(TCP_TIMEOUT, |(local, remote)| {
                user_timeout(local.port()).max(user_timeout(remote.port()))
            });
            (timeout, Some(TCP_KEEP_ALIVE))
        }
    };
    socket.set_timeout(Some(smol_duration(timeout)));
    socket.set_keep_alive(keep_alive.map(smol_duration));
}

fn smol_duration(duration: Duration) -> smoltcp::time::Duration {
    smoltcp::time::Duration::from_micros(u64::try_from(duration.as_micros()).unwrap_or(u64::MAX))
}

/// A socket's flow, once it has both endpoints.
pub(crate) fn socket_flow(socket: &tcp::Socket<'_>) -> Option<FlowKey> {
    Some((socket_addr(socket.local_endpoint()?), socket_addr(socket.remote_endpoint()?)))
}

/// Flows of the listeners' sockets past LISTEN (half-open or just opened).
fn half_open_flows(sockets: &SocketSet<'_>, listeners: &[Listener]) -> HashSet<FlowKey> {
    listeners
        .iter()
        .flat_map(|listener| listener.handles.iter())
        .filter_map(|handle| socket_flow(sockets.get::<tcp::Socket>(*handle)))
        .collect()
}

#[path = "tcp_bridge.rs"]
mod bridge;
