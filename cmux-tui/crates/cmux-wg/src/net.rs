//! The driver that joins WireGuard, the TCP stack, and the underlay.
//!
//! One Tokio task owns everything mutable: the [`Tunn`] session, the smoltcp
//! interface and socket set, the virtual device, the [`Underlay`] that carries
//! encrypted datagrams, and the per-connection bridges. Callers talk to it
//! through [`WgNet`], which sends commands over a channel and hands back
//! [`WgStream`]s. Nothing here sleeps to synchronize: the loop wakes on a
//! datagram, a command, a stream write, the WireGuard timer tick, or the
//! deadline smoltcp asks for.

use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::fmt;
use std::hash::{BuildHasher, Hasher};
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::Poll;
use std::time::Duration;

use boringtun::noise::{Tunn, TunnResult};
use bytes::{Buf, Bytes};
use cmux_transport::{DatagramClass, classify};
use ip_network::IpNetwork;
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant as SmolInstant;
use smoltcp::wire::{HardwareAddress, IpCidr, IpEndpoint, IpListenEndpoint};
use tokio::net::UdpSocket;
use tokio::sync::mpsc::error::{TryRecvError, TrySendError};
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_util::sync::PollSender;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::{InterfaceAddress, WgConfig};
use crate::device::VirtualDevice;
pub use crate::error::WgError;
use crate::pacing::{Pacer, Priority};
use crate::probing;
use crate::stream::{Outbound, WgStream};
use crate::timers::TimerSchedule;
use crate::underlay::{Origin, SocketPath, Underlay, is_transient};
use crate::watchdog::Watchdog;
use crate::wire::{ip_address, packet_source, socket_addr};

/// Per-socket receive and transmit buffers. Terminal traffic is small; the
/// bulk lane (screen replay) benefits from a full window.
const SOCKET_BUFFER_BYTES: usize = 256 * 1024;
/// Largest chunk moved from a smoltcp socket into a stream at once.
const INBOUND_CHUNK_BYTES: usize = 16 * 1024;
/// Queued chunks per direction per connection before backpressure.
const STREAM_CHANNEL_DEPTH: usize = 32;
/// Pending accepted connections a listener holds before refusing more.
const LISTENER_BACKLOG: usize = 16;
/// Spare LISTEN sockets kept per port. smoltcp has no accept queue: each
/// listening socket becomes exactly one connection. A small pool lets a burst
/// of concurrent SYNs (one per lane) each land on its own socket instead of
/// being reset, and each is refilled the moment it leaves LISTEN so a retransmit
/// of an in-progress SYN matches the existing half-open rather than a spare.
const LISTEN_SPARES: usize = 8;
/// Commands in flight before `connect`/`listen` callers wait.
const COMMAND_DEPTH: usize = 64;
/// Connections with no ACK for this long are aborted; link connections use
/// `net_sockets::LINK_TCP_TIMEOUT` instead.
const TCP_TIMEOUT: Duration = Duration::from_secs(60);
/// Probe each idle TCP connection before its receive timeout. WireGuard
/// keepalives and application heartbeats on another lane do not elicit its ACKs.
const TCP_KEEP_ALIVE: Duration = Duration::from_secs(15);
/// Largest datagram or packet buffer: the UDP payload maximum.
const BUFFER_BYTES: usize = 65_535;
/// The ephemeral port range (IANA 49152-65535); allocation starts at a random
/// port inside it and wraps, as a real stack does.
const FIRST_EPHEMERAL_PORT: u16 = 49_152;
const EPHEMERAL_PORT_COUNT: u16 = u16::MAX - FIRST_EPHEMERAL_PORT;

fn random_ephemeral_port() -> u16 {
    let mut seed = [0u8; 2];
    // A failure here only weakens port randomization, never correctness.
    let _ = getrandom::fill(&mut seed);
    FIRST_EPHEMERAL_PORT + (u16::from_le_bytes(seed) % EPHEMERAL_PORT_COUNT)
}

/// A running tunnel. Dropping it stops the driver; every stream then reads
/// EOF and fails writes.
pub struct WgNet {
    commands: mpsc::Sender<Command>,
    wake: Arc<Notify>,
    wakeups: Arc<AtomicU64>,
    routes: Arc<[IpNetwork]>,
    addresses: Arc<[InterfaceAddress]>,
    max_datagram: usize,
    driver: Option<JoinHandle<()>>,
}

impl fmt::Debug for WgNet {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WgNet")
            .field("routes", &self.routes)
            .field("addresses", &self.addresses)
            .finish_non_exhaustive()
    }
}

impl WgNet {
    /// Start the tunnel on a UDP socket the caller bound. The configured
    /// endpoint is resolved here and must share the socket's address family.
    pub async fn start(config: WgConfig, socket: UdpSocket) -> Result<Self, WgError> {
        let local = socket.local_addr()?;
        let peer = match &config.endpoint {
            Some(endpoint) => {
                let candidates = endpoint
                    .resolve()
                    .await
                    .map_err(|_| WgError::EndpointUnresolved(endpoint.host.clone()))?;
                Some(
                    candidates
                        .into_iter()
                        .find(|candidate| candidate.is_ipv4() == local.is_ipv4())
                        .ok_or(WgError::EndpointFamilyMismatch)?,
                )
            }
            None => None,
        };
        Self::start_with_underlay(config, SocketPath::new(socket, peer))
    }

    /// Start the tunnel on a fresh unbound-port UDP socket whose family matches
    /// the resolved endpoint. Requires a configured endpoint.
    pub async fn start_with_new_socket(config: WgConfig) -> Result<Self, WgError> {
        let endpoint = config
            .endpoint
            .as_ref()
            .ok_or_else(|| WgError::EndpointUnresolved("<none configured>".into()))?;
        let candidates = endpoint
            .resolve()
            .await
            .map_err(|_| WgError::EndpointUnresolved(endpoint.host.clone()))?;
        let peer = *candidates
            .first()
            .ok_or_else(|| WgError::EndpointUnresolved(endpoint.host.clone()))?;
        let bind: SocketAddr = if peer.is_ipv4() { "0.0.0.0:0".parse() } else { "[::]:0".parse() }
            .expect("literal bind address");
        let socket = UdpSocket::bind(bind).await?;
        Self::start_with_underlay(config, SocketPath::new(socket, Some(peer)))
    }

    /// Start the tunnel on a caller-built underlay, for example a
    /// [`crate::Multipath`]. The configured endpoint is ignored: the underlay
    /// owns addressing.
    pub fn start_with_underlay(config: WgConfig, underlay: impl Underlay) -> Result<Self, WgError> {
        let routes: Arc<[IpNetwork]> = config.allowed_ips.clone().into();
        let addresses: Arc<[InterfaceAddress]> = config.addresses.clone().into();
        let (commands_tx, commands_rx) = mpsc::channel(COMMAND_DEPTH);
        let wake = Arc::new(Notify::new());
        let max_datagram = usize::from(config.mtu).saturating_sub(datagram_ops::DATAGRAM_OVERHEAD);
        let mut underlay: Box<dyn Underlay> = Box::new(underlay);
        underlay.set_max_datagram(max_datagram);
        let driver = Driver::new(config, underlay, commands_rx, Arc::clone(&wake))?;
        let wakeups = Arc::clone(&driver.wakeups);
        let handle = tokio::spawn(driver.run());
        let commands = commands_tx;
        Ok(Self { commands, wake, wakeups, routes, addresses, max_datagram, driver: Some(handle) })
    }

    /// How many times the driver task has woken since it started: datagrams,
    /// commands, stream writes, timers. An idle tunnel stops counting.
    pub fn wakeups(&self) -> u64 {
        self.wakeups.load(Ordering::Relaxed)
    }

    /// Networks reachable through the tunnel (the peer's `AllowedIPs`).
    pub fn routes(&self) -> &[IpNetwork] {
        &self.routes
    }

    /// Whether `address` is reachable through the tunnel.
    pub fn routes_contain(&self, address: IpAddr) -> bool {
        self.routes.iter().any(|network| network.contains(address))
    }

    /// This side's addresses inside the network.
    pub fn addresses(&self) -> &[InterfaceAddress] {
        &self.addresses
    }

    /// Open a TCP connection to `remote` through the tunnel. Resolves once the
    /// three-way handshake completes. Callers bound the wait with their own
    /// timeout; the stack aborts an unanswered SYN after [`TCP_TIMEOUT`].
    pub async fn connect(&self, remote: SocketAddr) -> Result<WgStream, WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::Connect { remote, reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        reply_rx.await.map_err(|_| WgError::Shutdown)?
    }

    /// Accept TCP connections on `port` at every tunnel address.
    pub async fn listen(&self, port: u16) -> Result<WgListener, WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::Listen { port, reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        reply_rx.await.map_err(|_| WgError::Shutdown)?
    }

    /// Move the session onto a new underlay after a network change. The
    /// session, its keys and its TCP streams stay; the old underlay is
    /// dropped. One authenticated datagram goes out at once on the new
    /// underlay so the peer roams to it without waiting for traffic.
    pub async fn rebind(&self, underlay: impl Underlay) -> Result<(), WgError> {
        self.send_rebind(Rebind::Underlay(Box::new(underlay))).await
    }

    /// Move the session onto a new UDP socket, still aimed at the current
    /// peer address (for example the old socket's interface went away).
    pub async fn rebind_socket(&self, socket: UdpSocket) -> Result<(), WgError> {
        self.send_rebind(Rebind::Socket(socket)).await
    }

    /// The device woke from sleep or the network may have changed without a
    /// new socket: make the session usable again at once.
    pub async fn refresh(&self) -> Result<(), WgError> {
        self.send_rebind(Rebind::Keep).await
    }

    async fn send_rebind(&self, rebind: Rebind) -> Result<(), WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::Rebind { rebind, reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        reply_rx.await.map_err(|_| WgError::Shutdown)
    }

    /// Time since the last completed WireGuard handshake, if any.
    pub async fn time_since_last_handshake(&self) -> Result<Option<Duration>, WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::LastHandshake { reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        reply_rx.await.map_err(|_| WgError::Shutdown)
    }

    /// Wait until the peer completes a WireGuard handshake.
    ///
    /// Starting the driver only proves that the local UDP socket and the
    /// userspace stack are alive. A hub must also prove that its peer can be
    /// reached before it advertises a ready SOCKS socket. The driver sends an
    /// initial handshake during startup, so polling this value is a bounded
    /// end-to-end readiness check.
    pub async fn wait_for_handshake(&self, timeout: Duration) -> Result<Duration, WgError> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(age) = self.time_since_last_handshake().await? {
                return Ok(age);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(WgError::HandshakeTimeout(timeout));
            }
            tokio::time::sleep_until(deadline.min(now + Duration::from_millis(100))).await;
        }
    }

    /// Stop the driver and wait for it to exit. Open connections are reset.
    pub async fn shutdown(mut self) {
        let _ = self.commands.send(Command::Shutdown).await;
        if let Some(driver) = self.driver.take() {
            let _ = driver.await;
        }
    }
}

impl Drop for WgNet {
    fn drop(&mut self) {
        // A full command queue means the driver is alive and busy; it will see
        // the closed channel on its next receive. Only a stuck driver needs
        // the abort.
        if self.commands.try_send(Command::Shutdown).is_err()
            && let Some(driver) = self.driver.take()
        {
            driver.abort();
        }
        self.wake.notify_one();
    }
}

/// Connections accepted by [`WgNet::listen`].
pub struct WgListener {
    port: u16,
    incoming: mpsc::Receiver<WgStream>,
}

impl WgListener {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The next established connection, or `None` once the tunnel is gone.
    pub async fn accept(&mut self) -> Option<WgStream> {
        self.incoming.recv().await
    }
}

enum Command {
    Connect { remote: SocketAddr, reply: oneshot::Sender<Result<WgStream, WgError>> },
    Listen { port: u16, reply: oneshot::Sender<Result<WgListener, WgError>> },
    LastHandshake { reply: oneshot::Sender<Option<Duration>> },
    BindDatagram { port: u16, reply: oneshot::Sender<Result<mpsc::Receiver<Datagram>, WgError>> },
    UnbindDatagram { port: u16 },
    SendDatagram { from_port: u16, to: SocketAddr, payload: Vec<u8>, priority: Priority },
    Rebind { rebind: Rebind, reply: oneshot::Sender<()> },
    Shutdown,
}

enum Rebind {
    Underlay(Box<dyn Underlay>),
    Socket(UdpSocket),
    Keep,
}

/// How a newly established socket reaches its owner.
enum Handoff {
    Connect(oneshot::Sender<Result<WgStream, WgError>>),
    Accept(mpsc::Sender<WgStream>),
}

struct Conn {
    handle: SocketHandle,
    remote: SocketAddr,
    /// The stream waiting to be handed to its owner once the socket is
    /// established. Taken on delivery.
    pending_stream: Option<(Handoff, WgStream)>,
    /// `None` once the remote closed and the buffer drained (EOF delivered),
    /// or once the owner dropped its reader.
    inbound: Option<mpsc::Sender<Bytes>>,
    outbound: mpsc::Receiver<Outbound>,
    /// Head of the outbound queue not yet accepted by smoltcp.
    pending_write: Option<Bytes>,
    outbound_closed: bool,
}

struct Listener {
    port: u16,
    /// Sockets in LISTEN or SYN-RECEIVED for this port.
    handles: Vec<SocketHandle>,
    accept: mpsc::Sender<WgStream>,
}

struct Driver {
    config: WgConfig,
    tunn: Tunn,
    underlay: Box<dyn Underlay>,
    iface: Interface,
    device: VirtualDevice,
    sockets: SocketSet<'static>,
    conns: Vec<Conn>,
    listeners: Vec<Listener>,
    commands: mpsc::Receiver<Command>,
    wake: Arc<Notify>,
    /// The stack's clock. Tokio's, so the stack and the driver's timers
    /// agree, including under a paused test clock.
    epoch: Instant,
    schedule: TimerSchedule,
    /// Overlay addresses for path probes, and when the underlay next wants
    /// a probe sent or judged.
    probe_route: Option<(IpAddr, IpAddr)>,
    probe_deadline: Option<Instant>,
    /// Per-connection pacing of the stack's output, and when it next lets
    /// a queued packet leave.
    pacer: Pacer,
    pace_deadline: Option<Instant>,
    /// Bound datagram-service ports.
    datagram_ports: HashMap<u16, mpsc::Sender<Datagram>>,
    watchdog: Watchdog,
    wakeups: Arc<AtomicU64>,
    next_port: u16,
    scratch: Vec<u8>,
}

enum Event {
    Datagram(usize, Origin),
    /// The underlay drained its backlog: data may flow again.
    Drained,
    DatagramError(io::Error),
    Command(Option<Command>),
    Wake,
    Tick,
    StackDeadline,
}

impl Driver {
    fn new(
        config: WgConfig,
        underlay: Box<dyn Underlay>,
        commands: mpsc::Receiver<Command>,
        wake: Arc<Notify>,
    ) -> Result<Self, WgError> {
        let private = StaticSecret::from(*config.private_key);
        let public = PublicKey::from(config.peer_public_key);
        let tunn = Tunn::new(
            private,
            public,
            config.preshared_key.as_deref().copied(),
            config.persistent_keepalive,
            0,
            None,
        );

        let epoch = Instant::now();
        let keepalive = config.persistent_keepalive.is_some_and(|seconds| seconds > 0);
        let schedule = TimerSchedule::new(epoch, keepalive);
        let probe_route = probing::probe_route(&config);
        let mut device = VirtualDevice::new(config.mtu);
        let mut iface_config = Config::new(HardwareAddress::Ip);
        iface_config.random_seed = RandomState::new().build_hasher().finish();
        let mut iface = Interface::new(iface_config, &mut device, SmolInstant::from_micros(0));
        let mut overflow = false;
        iface.update_ip_addrs(|addresses| {
            for entry in &config.addresses {
                let cidr = IpCidr::new(ip_address(entry.address), entry.prefix);
                overflow |= addresses.push(cidr).is_err();
            }
        });
        if overflow {
            return Err(WgError::Stack("too many interface addresses".into()));
        }
        // Medium::Ip has no neighbor resolution, so the gateway address is
        // only a routing-table formality: everything not on a local subnet
        // goes into the tunnel.
        for entry in &config.addresses {
            let result = match entry.address {
                IpAddr::V4(address) => iface.routes_mut().add_default_ipv4_route(address),
                IpAddr::V6(address) => iface.routes_mut().add_default_ipv6_route(address),
            };
            result.map_err(|_| WgError::Stack("route table full".into()))?;
        }

        Ok(Self {
            config,
            tunn,
            underlay,
            iface,
            device,
            sockets: SocketSet::new(Vec::new()),
            conns: Vec::new(),
            listeners: Vec::new(),
            commands,
            wake,
            epoch,
            schedule,
            probe_route,
            probe_deadline: None,
            pacer: Pacer::default(),
            pace_deadline: None,
            datagram_ports: HashMap::new(),
            watchdog: Watchdog::default(),
            wakeups: Arc::new(AtomicU64::new(0)),
            next_port: random_ephemeral_port(),
            scratch: vec![0u8; BUFFER_BYTES + 32],
        })
    }

    fn now(&self) -> SmolInstant {
        SmolInstant::from_micros(
            i64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(i64::MAX),
        )
    }

    async fn run(mut self) {
        let wake = Arc::clone(&self.wake);
        let mut datagram = vec![0u8; BUFFER_BYTES];

        self.initiate_handshake();
        self.underlay.flush();
        self.service();

        loop {
            let now = self.now();
            let deadline = self.iface.poll_delay(now, &self.sockets);
            let stack_deadline = async {
                match deadline {
                    Some(delay) => {
                        tokio::time::sleep(Duration::from_micros(delay.total_micros())).await;
                    }
                    None => std::future::pending::<()>().await,
                }
            };
            let watchdog = self.watchdog.deadline(self.pacer.srtt());
            let next_tick =
                [self.schedule.next_tick(), self.probe_deadline, self.pace_deadline, watchdog]
                    .into_iter()
                    .flatten()
                    .min();
            let timers = async {
                match next_tick {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending::<()>().await,
                }
            };
            let backlogged = self.underlay.backlogged();
            let underlay = &mut self.underlay;
            let io = std::future::poll_fn(|cx| {
                if backlogged && underlay.poll_flush(cx).is_ready() {
                    return Poll::Ready(Ok(None));
                }
                underlay.poll_recv(cx, &mut datagram).map_ok(Some)
            });
            let event = tokio::select! {
                io = io => match io {
                    Ok(Some(received)) => Event::Datagram(received.len, received.origin),
                    Ok(None) => Event::Drained,
                    Err(error) => Event::DatagramError(error),
                },
                command = self.commands.recv() => Event::Command(command),
                () = wake.notified() => Event::Wake,
                () = timers => Event::Tick,
                () = stack_deadline => Event::StackDeadline,
            };
            self.wakeups.fetch_add(1, Ordering::Relaxed);
            self.catch_up_timers();
            self.run_watchdog();
            match event {
                Event::Datagram(count, origin) => self.handle_datagram(&datagram[..count], origin),
                Event::DatagramError(error) => {
                    if is_transient(&error) {
                        continue;
                    }
                    self.shutdown();
                    return;
                }
                Event::Command(Some(Command::Shutdown)) | Event::Command(None) => {
                    let resets = self.shutdown();
                    self.farewell(resets);
                    return;
                }
                Event::Command(Some(command)) => self.handle_command(command),
                Event::Wake | Event::StackDeadline | Event::Drained | Event::Tick => {}
            }
            self.underlay.flush();
            self.service();
            self.run_probes();
            self.underlay.flush();
        }
    }

    fn handle_datagram(&mut self, datagram: &[u8], origin: Origin) {
        let mut input = datagram;
        let source = origin.addr.map(|addr| addr.ip());
        let handshake = matches!(
            classify(datagram),
            DatagramClass::WireGuardInitiation | DatagramClass::WireGuardResponse
        );
        let mut replay = Vec::new();
        loop {
            match self.tunn.decapsulate(source, input, &mut self.scratch) {
                TunnResult::Done => {
                    // A data message that decrypts to nothing is a keepalive:
                    // authenticated, so it moves the peer like any packet.
                    // (Done for other messages, a cookie reply, proves less.)
                    if !input.is_empty() && classify(input) == DatagramClass::WireGuardData {
                        self.underlay.authenticated(origin);
                        self.watchdog.on_inbound_data();
                    }
                    break;
                }
                TunnResult::Err(_) => break,
                TunnResult::WriteToNetwork(packet) => {
                    // Authenticated traffic from a new address moves the peer
                    // (WireGuard roaming); this is also how the answering side
                    // learns its peer in the first place. A cookie reply (the
                    // rate limiter's answer) proves only the public key.
                    if classify(packet) != DatagramClass::WireGuardCookieReply {
                        self.underlay.authenticated(origin);
                        self.schedule.on_activity(Instant::now());
                    }
                    self.underlay.send(packet);
                    // An answered handshake message begins a new session.
                    if handshake && !input.is_empty() {
                        replay = self.watchdog.on_new_session();
                    }
                    input = &[];
                }
                TunnResult::WriteToTunnelV4(packet, _) | TunnResult::WriteToTunnelV6(packet, _) => {
                    self.underlay.authenticated(origin);
                    self.watchdog.on_inbound_data();
                    let allowed = packet_source(packet)
                        .is_some_and(|source| self.config.routes_contain(source));
                    // A probe is answered here and is not activity.
                    if let Some(probe) = probing::decode(packet).filter(|_| allowed) {
                        let (tunn, scratch) = (&mut self.tunn, &mut self.scratch);
                        probing::receive(tunn, &mut *self.underlay, scratch, probe, origin.path);
                    } else if allowed
                        && let Some((source, destination, payload)) = crate::udp::parse(packet)
                    {
                        let datagram = (source, destination, payload.to_vec());
                        self.deliver_datagram(datagram);
                    } else if allowed {
                        // TCP keepalives and their ACKs are not activity.
                        if self.pacer.received(packet, Instant::now()) {
                            self.schedule.on_activity(Instant::now());
                        }
                        self.device.push_rx(packet.to_vec());
                    }
                    break;
                }
            }
        }
        self.replay(replay);
    }

    /// Move what smoltcp emitted into the pacer, then encrypt and send what
    /// the pacer lets leave, until the underlay backs up. Nothing is
    /// dropped: a full pacer leaves packets in the device queue, which then
    /// refuses smoltcp more, so TCP waits instead of losing segments.
    fn flush_tx(&mut self) {
        let now = Instant::now();
        let mut fresh = false;
        while self.pacer.has_room()
            && let Some(packet) = self.device.pop_tx()
        {
            fresh |= self.pacer.push(packet, now);
        }
        self.pace_deadline = None;
        // Without a session boringtun would hold the segment through the
        // handshake, and the pacer would time that wait as a round trip.
        if self.tunn.time_since_last_handshake().is_none() && self.pacer.has_queued() {
            self.initiate_handshake();
        }
        while !self.underlay.backlogged() && self.tunn.time_since_last_handshake().is_some() {
            let packet = match self.pacer.pop(now) {
                Ok(Some(packet)) => packet,
                Ok(None) => break,
                Err(at) => {
                    self.pace_deadline = Some(at);
                    break;
                }
            };
            if let TunnResult::WriteToNetwork(encrypted) =
                self.tunn.encapsulate(&packet, &mut self.scratch)
            {
                self.underlay.send(encrypted);
            }
            // Datagrams are unreliable: the watchdog neither waits on them
            // nor replays them.
            if crate::udp::parse(&packet).is_none() {
                self.watchdog.on_data_sent(now, &packet);
            }
        }
        if fresh {
            self.schedule.on_activity(now);
        }
    }

    /// One pass: let smoltcp consume received packets and emit its own, move
    /// bytes between sockets and streams, then poll again so anything the
    /// streams produced leaves in the same pass.
    fn service(&mut self) {
        loop {
            let now = self.now();
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            self.process_listeners();
            let progressed = self.process_conns();
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            self.flush_tx();
            if !progressed && !self.device.has_rx() {
                break;
            }
        }
    }

    /// Reset every connection and send what is left, unpaced. Returns the
    /// resets, which [`Driver::farewell`] repeats.
    fn shutdown(&mut self) -> Vec<Vec<u8>> {
        for conn in &self.conns {
            self.sockets.get_mut::<tcp::Socket>(conn.handle).abort();
        }
        for listener in &self.listeners {
            for handle in &listener.handles {
                self.sockets.get_mut::<tcp::Socket>(*handle).abort();
            }
        }
        let now = self.now();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        // Last words leave unpaced: the resets must not wait behind data.
        while let Some(packet) = self.device.pop_tx() {
            self.pacer.push(packet, Instant::now());
        }
        let mut resets = Vec::new();
        for packet in self.pacer.drain() {
            if let TunnResult::WriteToNetwork(encrypted) =
                self.tunn.encapsulate(&packet, &mut self.scratch)
            {
                self.underlay.send(encrypted);
            }
            if crate::pacing::segment(&packet).is_some_and(|segment| segment.reset) {
                resets.push(packet);
            }
        }
        self.underlay.flush();
        self.conns.clear();
        self.listeners.clear();
        resets
    }

    fn handle_command(&mut self, command: Command) {
        match command {
            Command::Connect { remote, reply } => self.begin_connect(remote, reply),
            Command::Listen { port, reply } => {
                let _ = reply.send(self.begin_listen(port));
            }
            Command::LastHandshake { reply } => {
                let _ = reply.send(self.tunn.time_since_last_handshake());
            }
            Command::BindDatagram { port, reply } => {
                let _ = reply.send(self.bind_datagram(port));
            }
            Command::UnbindDatagram { port } => {
                if self.datagram_ports.get(&port).is_some_and(|sender| sender.is_closed()) {
                    self.datagram_ports.remove(&port);
                }
            }
            Command::SendDatagram { from_port, to, payload, priority } => {
                self.send_datagram(from_port, to, &payload, priority);
            }
            Command::Rebind { rebind, reply } => {
                match rebind {
                    Rebind::Underlay(underlay) => {
                        self.underlay = underlay;
                        let max = usize::from(self.config.mtu)
                            .saturating_sub(datagram_ops::DATAGRAM_OVERHEAD);
                        self.underlay.set_max_datagram(max);
                    }
                    Rebind::Socket(socket) => {
                        let peer = self.underlay.peer_hint();
                        self.underlay = Box::new(SocketPath::new(socket, peer));
                    }
                    Rebind::Keep => {}
                }
                self.reassert();
                let _ = reply.send(());
            }
            Command::Shutdown => {}
        }
    }

    fn process_listeners(&mut self) {
        let mut index = 0;
        while index < self.listeners.len() {
            if self.listeners[index].accept.is_closed() {
                for handle in std::mem::take(&mut self.listeners[index].handles) {
                    self.sockets.get_mut::<tcp::Socket>(handle).abort();
                    self.sockets.remove(handle);
                }
                self.listeners.swap_remove(index);
                continue;
            }
            let port = self.listeners[index].port;
            let handles = std::mem::take(&mut self.listeners[index].handles);
            let mut still_listening = Vec::with_capacity(handles.len());
            let mut listen_count = 0;
            let mut half_open = 0;
            for handle in handles {
                let (state, endpoints) = {
                    let socket = self.sockets.get::<tcp::Socket>(handle);
                    (socket.state(), (socket.local_endpoint(), socket.remote_endpoint()))
                };
                match state {
                    tcp::State::Established => {
                        let (Some(local), Some(remote)) = endpoints else {
                            self.sockets.remove(handle);
                            continue;
                        };
                        let accept = self.listeners[index].accept.clone();
                        let (conn, stream) =
                            self.bridge(handle, socket_addr(local), socket_addr(remote));
                        self.conns.push(Conn {
                            pending_stream: Some((Handoff::Accept(accept), stream)),
                            ..conn
                        });
                    }
                    tcp::State::Listen => {
                        listen_count += 1;
                        still_listening.push(handle);
                    }
                    tcp::State::SynReceived => {
                        half_open += 1;
                        still_listening.push(handle);
                    }
                    // The handshake fell apart (peer reset, timeout): drop it.
                    _ => {
                        self.sockets.remove(handle);
                    }
                }
            }
            // Refill only while no handshake is in flight. A new Listen socket
            // added beside a live half-open can be assigned a lower socket slot
            // (freed by a closed connection), and smoltcp would then route a
            // retransmitted SYN to that Listen socket instead of the existing
            // half-open, spawning a duplicate that never completes.
            if half_open == 0 {
                while listen_count < LISTEN_SPARES {
                    match self.listening_socket(port) {
                        Ok(handle) => {
                            still_listening.push(handle);
                            listen_count += 1;
                        }
                        Err(_) => break,
                    }
                }
            }
            self.listeners[index].handles = still_listening;
            index += 1;
        }
    }

    /// Returns whether any byte moved, so the caller can poll again.
    fn process_conns(&mut self) -> bool {
        let mut progressed = false;
        let mut index = 0;
        while index < self.conns.len() {
            let conn = &mut self.conns[index];
            let socket = self.sockets.get_mut::<tcp::Socket>(conn.handle);

            if let Some((handoff, stream)) = conn.pending_stream.take() {
                if matches!(&handoff, Handoff::Connect(reply) if reply.is_closed()) {
                    // The connect future was cancelled before the handshake
                    // completed. No stream owner remains to close this socket.
                    socket.abort();
                    let handle = conn.handle;
                    self.sockets.remove(handle);
                    self.conns.swap_remove(index);
                    continue;
                }
                if socket.state() == tcp::State::Established {
                    match handoff {
                        Handoff::Connect(reply) => {
                            let _ = reply.send(Ok(stream));
                        }
                        Handoff::Accept(accept) => {
                            if accept.try_send(stream).is_err() {
                                socket.abort();
                            }
                        }
                    }
                } else if !socket.is_open() {
                    if let Handoff::Connect(reply) = handoff {
                        let _ = reply.send(Err(WgError::ConnectionRefused(conn.remote)));
                    }
                    let handle = conn.handle;
                    self.sockets.remove(handle);
                    self.conns.swap_remove(index);
                    continue;
                } else {
                    // Still in the handshake: no owner yet, so nothing to move
                    // and no EOF to detect (`may_recv` is false before
                    // Established).
                    conn.pending_stream = Some((handoff, stream));
                    index += 1;
                    continue;
                }
            }

            // Owner -> socket.
            if !conn.outbound_closed {
                loop {
                    if conn.pending_write.is_none() {
                        match conn.outbound.try_recv() {
                            Ok(Outbound::Data(bytes)) => conn.pending_write = Some(bytes),
                            Ok(Outbound::Shutdown) | Err(TryRecvError::Disconnected) => {
                                conn.outbound_closed = true;
                                socket.close();
                                break;
                            }
                            Err(TryRecvError::Empty) => break,
                        }
                    }
                    let Some(pending) = conn.pending_write.as_mut() else { break };
                    if !socket.can_send() {
                        break;
                    }
                    match socket.send_slice(pending) {
                        Ok(written) => {
                            pending.advance(written);
                            progressed |= written > 0;
                            if pending.is_empty() {
                                conn.pending_write = None;
                            } else {
                                break;
                            }
                        }
                        Err(_) => {
                            conn.outbound_closed = true;
                            break;
                        }
                    }
                }
            }

            // Socket -> owner.
            if let Some(sender) = conn.inbound.as_ref() {
                let mut reader_gone = false;
                while socket.can_recv() {
                    match sender.try_reserve() {
                        Ok(permit) => {
                            let mut chunk = vec![0u8; socket.recv_queue().min(INBOUND_CHUNK_BYTES)];
                            match socket.recv_slice(&mut chunk) {
                                Ok(count) => {
                                    chunk.truncate(count);
                                    progressed |= count > 0;
                                    permit.send(Bytes::from(chunk));
                                }
                                Err(_) => break,
                            }
                        }
                        Err(TrySendError::Full(())) => break,
                        Err(TrySendError::Closed(())) => {
                            reader_gone = true;
                            break;
                        }
                    }
                }
                if reader_gone {
                    conn.inbound = None;
                } else if !socket.may_recv() && !socket.can_recv() {
                    // Remote FIN and every byte delivered: EOF to the owner.
                    conn.inbound = None;
                }
            } else if socket.can_recv() {
                // Nobody will read it; keep the window moving so the peer can
                // finish closing.
                let _ = socket.recv(|buffer| (buffer.len(), ()));
            }

            if !socket.is_open() && conn.pending_stream.is_none() {
                let handle = conn.handle;
                self.sockets.remove(handle);
                self.conns.swap_remove(index);
                continue;
            }
            index += 1;
        }
        progressed
    }
}

#[path = "net_timers.rs"]
mod timer_ops;

#[path = "net_datagrams.rs"]
mod datagram_ops;
pub use datagram_ops::{Datagram, WgDatagramSocket};

#[path = "net_sockets.rs"]
mod socket_ops;

#[cfg(test)]
#[path = "net_tests.rs"]
mod tests;
