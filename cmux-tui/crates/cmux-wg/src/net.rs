//! The driver that joins WireGuard, the TCP stack, and the UDP socket.
//!
//! One Tokio task owns everything mutable: the [`Tunn`] session, the smoltcp
//! interface and socket set, the virtual device, and the per-connection
//! bridges. Callers talk to it through [`WgNet`], which sends commands over a
//! channel and hands back [`WgStream`]s. A stream is two bounded channels and a
//! wake signal; the driver copies between them and the smoltcp socket on
//! every service pass. Nothing here sleeps to synchronize: the loop wakes on a
//! datagram, a command, a stream write, the WireGuard timer tick, or the
//! deadline smoltcp asks for.

use std::collections::hash_map::RandomState;
use std::fmt;
use std::hash::{BuildHasher, Hasher};
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use boringtun::noise::{Tunn, TunnResult};
use bytes::{Buf, Bytes};
use ip_network::IpNetwork;
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant as SmolInstant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, IpEndpoint, IpListenEndpoint};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::UdpSocket;
use tokio::sync::mpsc::error::{TryRecvError, TrySendError};
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_util::sync::PollSender;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::{InterfaceAddress, WgConfig};
use crate::device::VirtualDevice;

/// Per-socket receive and transmit buffers. Terminal traffic is small; the
/// bulk lane (screen replay) benefits from a full window.
const SOCKET_BUFFER_BYTES: usize = 256 * 1024;
/// Largest chunk moved from a smoltcp socket into a stream at once.
const INBOUND_CHUNK_BYTES: usize = 16 * 1024;
/// Largest single write a stream accepts before splitting it.
const MAX_WRITE_CHUNK_BYTES: usize = 64 * 1024;
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
/// WireGuard timer resolution; boringtun's own device uses the same.
const TIMER_TICK: Duration = Duration::from_millis(250);
/// Idle TCP connections with no ACK for this long are aborted.
const TCP_TIMEOUT: Duration = Duration::from_secs(60);
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

#[derive(Debug)]
pub enum WgError {
    Io(io::Error),
    /// The configured endpoint did not resolve.
    EndpointUnresolved(String),
    /// The endpoint resolved only to addresses of a family the UDP socket
    /// cannot reach.
    EndpointFamilyMismatch,
    /// This side has no tunnel address in the remote's address family.
    NoTunnelAddress(IpAddr),
    /// The remote answered the SYN with a reset, or never answered.
    ConnectionRefused(SocketAddr),
    /// A listener already owns the port.
    ListenerBusy(u16),
    /// The tunnel has been shut down.
    Shutdown,
    /// smoltcp refused the operation.
    Stack(String),
}

impl fmt::Display for WgError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "socket error: {error}"),
            Self::EndpointUnresolved(host) => write!(formatter, "endpoint {host} did not resolve"),
            Self::EndpointFamilyMismatch => {
                formatter.write_str("endpoint address family does not match the UDP socket")
            }
            Self::NoTunnelAddress(remote) => {
                write!(formatter, "no tunnel address in the same family as {remote}")
            }
            Self::ConnectionRefused(remote) => write!(formatter, "{remote} refused the connection"),
            Self::ListenerBusy(port) => write!(formatter, "port {port} already has a listener"),
            Self::Shutdown => formatter.write_str("the tunnel is shut down"),
            Self::Stack(detail) => write!(formatter, "tcp stack: {detail}"),
        }
    }
}

impl std::error::Error for WgError {}

impl From<io::Error> for WgError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// A running tunnel. Dropping it stops the driver; every stream then reads
/// EOF and fails writes.
pub struct WgNet {
    commands: mpsc::Sender<Command>,
    wake: Arc<Notify>,
    routes: Arc<[IpNetwork]>,
    addresses: Arc<[InterfaceAddress]>,
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
        Self::start_resolved(config, socket, peer)
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
        let peer = *candidates.first().ok_or_else(|| WgError::EndpointUnresolved(endpoint.host.clone()))?;
        let bind: SocketAddr = if peer.is_ipv4() { "0.0.0.0:0".parse() } else { "[::]:0".parse() }
            .expect("literal bind address");
        let socket = UdpSocket::bind(bind).await?;
        Self::start_resolved(config, socket, Some(peer))
    }

    fn start_resolved(
        config: WgConfig,
        socket: UdpSocket,
        peer: Option<SocketAddr>,
    ) -> Result<Self, WgError> {
        let routes: Arc<[IpNetwork]> = config.allowed_ips.clone().into();
        let addresses: Arc<[InterfaceAddress]> = config.addresses.clone().into();
        let (commands_tx, commands_rx) = mpsc::channel(COMMAND_DEPTH);
        let wake = Arc::new(Notify::new());
        let driver = Driver::new(config, socket, peer, commands_rx, Arc::clone(&wake))?;
        let handle = tokio::spawn(driver.run());
        Ok(Self { commands: commands_tx, wake, routes, addresses, driver: Some(handle) })
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

    /// Time since the last completed WireGuard handshake, if any.
    pub async fn time_since_last_handshake(&self) -> Result<Option<Duration>, WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::LastHandshake { reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        reply_rx.await.map_err(|_| WgError::Shutdown)
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
    Shutdown,
}

enum Outbound {
    Data(Bytes),
    Shutdown,
}

/// One TCP connection through the tunnel, usable wherever a `TcpStream` is.
pub struct WgStream {
    local: SocketAddr,
    remote: SocketAddr,
    inbound: mpsc::Receiver<Bytes>,
    leftover: Bytes,
    outbound: PollSender<Outbound>,
    wake: Arc<Notify>,
    shutdown_sent: bool,
}

impl fmt::Debug for WgStream {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WgStream")
            .field("local", &self.local)
            .field("remote", &self.remote)
            .finish_non_exhaustive()
    }
}

impl WgStream {
    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }

    pub fn peer_addr(&self) -> SocketAddr {
        self.remote
    }
}

fn broken_pipe() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "tunnel connection is closed")
}

impl AsyncRead for WgStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = &mut *self;
        if this.leftover.is_empty() {
            match this.inbound.poll_recv(cx) {
                Poll::Ready(Some(bytes)) => this.leftover = bytes,
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Pending => return Poll::Pending,
            }
        }
        let count = this.leftover.len().min(buf.remaining());
        buf.put_slice(&this.leftover.split_to(count));
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for WgStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = &mut *self;
        if this.shutdown_sent {
            return Poll::Ready(Err(broken_pipe()));
        }
        match this.outbound.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let count = data.len().min(MAX_WRITE_CHUNK_BYTES);
                this.outbound
                    .send_item(Outbound::Data(Bytes::copy_from_slice(&data[..count])))
                    .map_err(|_| broken_pipe())?;
                this.wake.notify_one();
                Poll::Ready(Ok(count))
            }
            Poll::Ready(Err(_)) => Poll::Ready(Err(broken_pipe())),
            Poll::Pending => Poll::Pending,
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Writes are handed to the driver synchronously; there is no local
        // buffer left to flush. Delivery is TCP's job.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = &mut *self;
        if this.shutdown_sent {
            return Poll::Ready(Ok(()));
        }
        match this.outbound.poll_reserve(cx) {
            Poll::Ready(Ok(())) => {
                let _ = this.outbound.send_item(Outbound::Shutdown);
                this.shutdown_sent = true;
                this.wake.notify_one();
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(_)) => {
                this.shutdown_sent = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
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
    udp: Arc<UdpSocket>,
    peer: Option<SocketAddr>,
    iface: Interface,
    device: VirtualDevice,
    sockets: SocketSet<'static>,
    conns: Vec<Conn>,
    listeners: Vec<Listener>,
    commands: mpsc::Receiver<Command>,
    wake: Arc<Notify>,
    epoch: std::time::Instant,
    next_port: u16,
    scratch: Vec<u8>,
}

enum Event {
    Datagram(usize, SocketAddr),
    DatagramError(io::Error),
    Command(Option<Command>),
    Wake,
    Tick,
    StackDeadline,
}

impl Driver {
    fn new(
        config: WgConfig,
        socket: UdpSocket,
        peer: Option<SocketAddr>,
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

        let epoch = std::time::Instant::now();
        let mut device = VirtualDevice::new(config.mtu);
        let mut iface_config = Config::new(HardwareAddress::Ip);
        iface_config.random_seed = RandomState::new().build_hasher().finish();
        let mut iface = Interface::new(iface_config, &mut device, SmolInstant::from_micros(0));
        let mut overflow = false;
        iface.update_ip_addrs(|addresses| {
            for entry in &config.addresses {
                let cidr = IpCidr::new(ip_address(entry.address), entry.prefix);
                if addresses.push(cidr).is_err() {
                    overflow = true;
                }
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
                IpAddr::V4(address) => iface.routes_mut().add_default_ipv4_route(address).map(|_| ()),
                IpAddr::V6(address) => iface.routes_mut().add_default_ipv6_route(address).map(|_| ()),
            };
            result.map_err(|_| WgError::Stack("route table full".into()))?;
        }

        Ok(Self {
            config,
            tunn,
            udp: Arc::new(socket),
            peer,
            iface,
            device,
            sockets: SocketSet::new(Vec::new()),
            conns: Vec::new(),
            listeners: Vec::new(),
            commands,
            wake,
            epoch,
            next_port: random_ephemeral_port(),
            scratch: vec![0u8; BUFFER_BYTES + 32],
        })
    }

    fn now(&self) -> SmolInstant {
        SmolInstant::from_micros(i64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(i64::MAX))
    }

    async fn run(mut self) {
        let udp = Arc::clone(&self.udp);
        let wake = Arc::clone(&self.wake);
        let mut ticks = tokio::time::interval(TIMER_TICK);
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut datagram = vec![0u8; BUFFER_BYTES];

        self.initiate_handshake();
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
            let event = tokio::select! {
                received = udp.recv_from(&mut datagram) => match received {
                    Ok((count, source)) => Event::Datagram(count, source),
                    Err(error) => Event::DatagramError(error),
                },
                command = self.commands.recv() => Event::Command(command),
                () = wake.notified() => Event::Wake,
                _ = ticks.tick() => Event::Tick,
                () = stack_deadline => Event::StackDeadline,
            };
            match event {
                Event::Datagram(count, source) => self.handle_datagram(&datagram[..count], source),
                Event::DatagramError(error) => {
                    // Transient receive errors (ICMP port unreachable surfaced as
                    // ECONNREFUSED on some platforms) are not fatal for UDP.
                    if error.kind() == io::ErrorKind::Interrupted
                        || error.kind() == io::ErrorKind::ConnectionRefused
                        || error.kind() == io::ErrorKind::ConnectionReset
                    {
                        continue;
                    }
                    self.shutdown();
                    return;
                }
                Event::Command(Some(Command::Shutdown)) | Event::Command(None) => {
                    self.shutdown();
                    return;
                }
                Event::Command(Some(command)) => self.handle_command(command),
                Event::Wake | Event::StackDeadline => {}
                Event::Tick => self.update_timers(),
            }
            self.service();
        }
    }

    fn send_to_peer(&self, packet: &[u8]) {
        if let Some(peer) = self.peer {
            // WireGuard tolerates loss; a momentarily unwritable UDP socket
            // drops the datagram rather than blocking the driver.
            let _ = self.udp.try_send_to(packet, peer);
        }
    }

    fn initiate_handshake(&mut self) {
        if self.peer.is_none() {
            return;
        }
        if let TunnResult::WriteToNetwork(packet) =
            self.tunn.format_handshake_initiation(&mut self.scratch, false)
        {
            let packet = packet.to_vec();
            self.send_to_peer(&packet);
        }
    }

    fn update_timers(&mut self) {
        if let TunnResult::WriteToNetwork(packet) = self.tunn.update_timers(&mut self.scratch) {
            let packet = packet.to_vec();
            self.send_to_peer(&packet);
        }
    }

    fn handle_datagram(&mut self, datagram: &[u8], source: SocketAddr) {
        let mut input = datagram;
        loop {
            match self.tunn.decapsulate(Some(source.ip()), input, &mut self.scratch) {
                TunnResult::Done => break,
                TunnResult::Err(_) => break,
                TunnResult::WriteToNetwork(packet) => {
                    let packet = packet.to_vec();
                    // Authenticated traffic from a new address moves the peer
                    // (WireGuard roaming); this is also how the answering side
                    // learns its peer in the first place.
                    self.peer = Some(source);
                    self.send_to_peer(&packet);
                    input = &[];
                }
                TunnResult::WriteToTunnelV4(packet, _) | TunnResult::WriteToTunnelV6(packet, _) => {
                    self.peer = Some(source);
                    if let Some(origin) = packet_source(packet)
                        && self.config.routes_contain(origin)
                    {
                        self.device.push_rx(packet.to_vec());
                    }
                    break;
                }
            }
        }
    }

    fn flush_tx(&mut self) {
        while let Some(packet) = self.device.pop_tx() {
            if let TunnResult::WriteToNetwork(encrypted) =
                self.tunn.encapsulate(&packet, &mut self.scratch)
            {
                let encrypted = encrypted.to_vec();
                self.send_to_peer(&encrypted);
            }
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

    fn shutdown(&mut self) {
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
        self.flush_tx();
        self.conns.clear();
        self.listeners.clear();
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
            Command::Shutdown => {}
        }
    }

    fn allocate_port(&mut self) -> u16 {
        for _ in 0..EPHEMERAL_PORT_COUNT {
            let port = self.next_port;
            self.next_port =
                if self.next_port >= u16::MAX - 1 { FIRST_EPHEMERAL_PORT } else { self.next_port + 1 };
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

    fn new_socket() -> tcp::Socket<'static> {
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
        );
        // Keystrokes are latency-bound; the OS dial path disables Nagle too.
        socket.set_nagle_enabled(false);
        socket.set_timeout(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_TIMEOUT.as_micros()).unwrap_or(u64::MAX),
        )));
        socket
    }

    fn begin_connect(
        &mut self,
        remote: SocketAddr,
        reply: oneshot::Sender<Result<WgStream, WgError>>,
    ) {
        let Some(local_ip) = self.config.local_address_for(remote.ip()) else {
            let _ = reply.send(Err(WgError::NoTunnelAddress(remote.ip())));
            return;
        };
        let port = self.allocate_port();
        let local = SocketAddr::new(local_ip, port);
        let mut socket = Self::new_socket();
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
        let (conn, stream) = self.bridge(handle, local, remote);
        self.conns.push(Conn { pending_stream: Some((Handoff::Connect(reply), stream)), ..conn });
    }

    fn begin_listen(&mut self, port: u16) -> Result<WgListener, WgError> {
        if self.listeners.iter().any(|listener| listener.port == port) {
            return Err(WgError::ListenerBusy(port));
        }
        let mut handles = Vec::with_capacity(LISTEN_SPARES);
        for _ in 0..LISTEN_SPARES {
            handles.push(self.listening_socket(port)?);
        }
        let (accept_tx, accept_rx) = mpsc::channel(LISTENER_BACKLOG);
        self.listeners.push(Listener { port, handles, accept: accept_tx });
        Ok(WgListener { port, incoming: accept_rx })
    }

    fn listening_socket(&mut self, port: u16) -> Result<SocketHandle, WgError> {
        let mut socket = Self::new_socket();
        socket
            .listen(IpListenEndpoint::from(port))
            .map_err(|error| WgError::Stack(format!("{error}")))?;
        Ok(self.sockets.add(socket))
    }

    /// Build the channel pair for a socket: the driver-side [`Conn`] and the
    /// owner-side [`WgStream`].
    fn bridge(&self, handle: SocketHandle, local: SocketAddr, remote: SocketAddr) -> (Conn, WgStream) {
        let (inbound_tx, inbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let (outbound_tx, outbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let stream = WgStream {
            local,
            remote,
            inbound: inbound_rx,
            leftover: Bytes::new(),
            outbound: PollSender::new(outbound_tx),
            wake: Arc::clone(&self.wake),
            shutdown_sent: false,
        };
        let conn = Conn {
            handle,
            remote,
            pending_stream: None,
            inbound: Some(inbound_tx),
            outbound: outbound_rx,
            pending_write: None,
            outbound_closed: false,
        };
        (conn, stream)
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

fn ip_address(address: IpAddr) -> IpAddress {
    match address {
        IpAddr::V4(address) => IpAddress::Ipv4(address),
        IpAddr::V6(address) => IpAddress::Ipv6(address),
    }
}

fn socket_addr(endpoint: IpEndpoint) -> SocketAddr {
    let address = match endpoint.addr {
        IpAddress::Ipv4(address) => IpAddr::V4(address),
        IpAddress::Ipv6(address) => IpAddr::V6(address),
    };
    SocketAddr::new(address, endpoint.port)
}

/// The source address of a raw IPv4 or IPv6 packet, for crypto-key routing.
fn packet_source(packet: &[u8]) -> Option<IpAddr> {
    match packet.first()? >> 4 {
        4 if packet.len() >= 20 => {
            let octets: [u8; 4] = packet[12..16].try_into().ok()?;
            Some(IpAddr::V4(octets.into()))
        }
        6 if packet.len() >= 40 => {
            let octets: [u8; 16] = packet[8..24].try_into().ok()?;
            Some(IpAddr::V6(octets.into()))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn ephemeral_port_allocator_stays_bounded_under_load() {
        let mut allocator = PortAllocator::with_next_port(FIRST_EPHEMERAL_PORT);
        let mut ports = HashSet::with_capacity(8_192);
        let mut probes = 0;
        for _ in 0..8_192 {
            let (port, examined) = allocator.allocate_with_probe_count().expect("port available");
            assert!(ports.insert(port), "allocator returned a duplicate port");
            probes += examined;
        }

        // With an uncontended cursor, each allocation examines one candidate.
        // This bound catches a regression to scanning every active connection.
        assert!(probes <= ports.len() * 2, "allocator examined {probes} candidates for {} ports", ports.len());

        let occupied = FIRST_EPHEMERAL_PORT + 8_191;
        assert!(ports.contains(&occupied));
        allocator.set_next_port(occupied);
        let (replacement, examined) = allocator.allocate_with_probe_count().expect("port available");
        assert_ne!(replacement, occupied);
        assert_eq!(examined, 2);

        let released = ports.iter().next().copied().expect("ports allocated");
        allocator.release(released);
        allocator.set_next_port(released);
        assert_eq!(allocator.allocate(), Some(released));
    }

    #[test]
    fn packet_source_reads_both_families() {
        let mut v4 = vec![0u8; 20];
        v4[0] = 0x45;
        v4[12..16].copy_from_slice(&[10, 200, 0, 2]);
        assert_eq!(packet_source(&v4), Some("10.200.0.2".parse().unwrap()));

        let mut v6 = vec![0u8; 40];
        v6[0] = 0x60;
        v6[8] = 0xfd;
        v6[9] = 0xcc;
        v6[23] = 1;
        assert_eq!(packet_source(&v6), Some("fdcc::1".parse().unwrap()));

        assert_eq!(packet_source(&[0x45; 10]), None);
        assert_eq!(packet_source(&[]), None);
    }
}
