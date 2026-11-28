//! One userspace WireGuard session: boringtun for the Noise protocol, smoltcp
//! for IP (ICMP echo and TCP), one UDP socket. No root, no utun, no route
//! change on the host.
//!
//! Everything runs on the caller's thread: [`Tunnel::poll`] receives at most
//! a bounded time on the UDP socket, runs the WireGuard timers, and lets
//! smoltcp move packets. Higher-level operations loop on `poll` until their
//! own deadline.
//!
//! The same type acts as the answering side (no endpoint: it learns the peer
//! from the first authenticated datagram), which the loopback tests use as a
//! stand-in VM.

use std::fmt;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

use boringtun::noise::{Tunn, TunnResult};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::ChecksumCapabilities;
use smoltcp::socket::{icmp, tcp};
use smoltcp::wire::{HardwareAddress, Icmpv4Packet, Icmpv4Repr, IpAddress, IpCidr, IpEndpoint};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::Cidr;
use crate::device::VirtualDevice;

/// How long the first handshake may take. A new provider tunnel's first
/// handshake has stalled 11-16 s.
pub const FIRST_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(25);
/// WireGuard's REKEY_TIMEOUT plus margin: if no initiation went out for this
/// long while no session exists, send one ourselves (boringtun's timers
/// normally already did).
const HANDSHAKE_RETRY: Duration = Duration::from_millis(5_500);
/// How often boringtun's timers run.
const TIMER_TICK: Duration = Duration::from_millis(100);
const SCRATCH_BYTES: usize = 65_536 + 256;
const TCP_BUFFER_BYTES: usize = 64 * 1024;
const ICMP_PAYLOAD: &[u8] = b"cmux-mesh-agent!";
/// WireGuard message type 1 is a handshake initiation, 148 bytes.
const INITIATION_LEN: usize = 148;

pub struct TunnelParams {
    pub private_key: StaticSecret,
    pub peer_public_key: [u8; 32],
    /// The peer's UDP address. `None` makes this the answering side.
    pub endpoint: Option<SocketAddr>,
    /// Local UDP bind address.
    pub bind: SocketAddr,
    /// This side's address inside the tunnel.
    pub address: Cidr,
    /// Inner source addresses accepted from the peer, and destinations sent.
    pub allowed_ips: Vec<Cidr>,
    pub mtu: u16,
    pub persistent_keepalive: Option<u16>,
}

impl fmt::Debug for TunnelParams {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TunnelParams")
            .field("endpoint", &self.endpoint)
            .field("address", &self.address)
            .field("allowed_ips", &self.allowed_ips)
            .field("mtu", &self.mtu)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub enum TunnelError {
    Io(io::Error),
    HandshakeTimeout(Duration),
    NotRouted(Ipv4Addr),
    Stack(String),
}

impl fmt::Display for TunnelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            Self::HandshakeTimeout(after) => {
                write!(formatter, "no WireGuard handshake after {} ms", after.as_millis())
            }
            Self::NotRouted(address) => write!(formatter, "{address} is not in allowedIps"),
            Self::Stack(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for TunnelError {}

impl From<io::Error> for TunnelError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Where a TCP connection attempt stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TcpStatus {
    Pending,
    Connected,
    /// Reset or closed before it connected.
    Failed,
}

/// Resolve `host:port` with the system resolver, IPv4 first.
pub fn resolve_endpoint(host: &str, port: u16) -> io::Result<SocketAddr> {
    let candidates: Vec<SocketAddr> = (host, port).to_socket_addrs()?.collect();
    candidates
        .iter()
        .find(|candidate| candidate.is_ipv4())
        .or_else(|| candidates.first())
        .copied()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{host} has no address")))
}

/// A bind address of the same family as `endpoint`, any port.
pub fn bind_for(endpoint: SocketAddr) -> SocketAddr {
    match endpoint {
        SocketAddr::V4(_) => SocketAddr::from(([0, 0, 0, 0], 0)),
        SocketAddr::V6(_) => SocketAddr::from(([0u16; 8], 0)),
    }
}

pub struct Tunnel {
    tunn: Tunn,
    udp: UdpSocket,
    endpoint: Option<SocketAddr>,
    peer: Option<SocketAddr>,
    iface: Interface,
    device: VirtualDevice,
    sockets: SocketSet<'static>,
    address: Ipv4Addr,
    allowed: Vec<Cidr>,
    epoch: Instant,
    scratch: Vec<u8>,
    recv_buf: Vec<u8>,
    last_timer: Instant,
    last_initiation: Option<Instant>,
    initiating: bool,
    next_port: u16,
    icmp: Option<(SocketHandle, u16)>,
    drop_inbound: usize,
}

impl Tunnel {
    pub fn new(params: TunnelParams) -> Result<Self, TunnelError> {
        let udp = UdpSocket::bind(params.bind)?;
        let tunn = Tunn::new(
            params.private_key,
            PublicKey::from(params.peer_public_key),
            None,
            params.persistent_keepalive.filter(|seconds| *seconds > 0),
            0,
            None,
        );
        let mut device = VirtualDevice::new(params.mtu);
        let mut iface_config = Config::new(HardwareAddress::Ip);
        iface_config.random_seed = random_u64();
        let epoch = Instant::now();
        let mut iface =
            Interface::new(iface_config, &mut device, smoltcp::time::Instant::from_micros(0));
        let address = params.address.address;
        let mut overflow = false;
        iface.update_ip_addrs(|list| {
            overflow =
                list.push(IpCidr::new(IpAddress::Ipv4(address), params.address.prefix)).is_err();
        });
        // Medium::Ip has no neighbors: the gateway is a routing-table formality
        // that sends every non-local destination into the tunnel.
        if overflow || iface.routes_mut().add_default_ipv4_route(address).is_err() {
            return Err(TunnelError::Stack("interface setup failed".into()));
        }
        let first_port = 49_152 + (random_u64() % 16_000) as u16;
        Ok(Self {
            tunn,
            udp,
            endpoint: params.endpoint,
            peer: params.endpoint,
            iface,
            device,
            sockets: SocketSet::new(Vec::new()),
            address,
            allowed: params.allowed_ips,
            epoch,
            scratch: vec![0u8; SCRATCH_BYTES],
            recv_buf: vec![0u8; SCRATCH_BYTES],
            last_timer: Instant::now(),
            last_initiation: None,
            initiating: false,
            next_port: first_port,
            icmp: None,
            drop_inbound: 0,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.udp.local_addr()
    }

    /// This side's address inside the tunnel.
    pub fn address(&self) -> Ipv4Addr {
        self.address
    }

    /// Drop the next `count` datagrams received, before WireGuard sees them.
    /// Tests use it to lose a handshake message.
    pub fn drop_next_datagrams(&mut self, count: usize) {
        self.drop_inbound = count;
    }

    pub fn has_session(&self) -> bool {
        self.tunn.time_since_last_handshake().is_some()
    }

    /// Start the handshake and wait for a session, retrying the initiation.
    /// Returns how long it took.
    pub fn handshake(&mut self, timeout: Duration) -> Result<Duration, TunnelError> {
        let start = Instant::now();
        self.initiating = true;
        if !self.has_session() {
            self.send_initiation();
        }
        while !self.has_session() {
            let elapsed = start.elapsed();
            if elapsed >= timeout {
                return Err(TunnelError::HandshakeTimeout(elapsed));
            }
            self.poll((timeout - elapsed).min(Duration::from_millis(50)))?;
        }
        Ok(start.elapsed())
    }

    /// One pass: let smoltcp emit, receive for at most `max_wait`, run the
    /// WireGuard timers, let smoltcp consume and emit again.
    pub fn poll(&mut self, max_wait: Duration) -> io::Result<()> {
        self.pump();
        let delay = self
            .iface
            .poll_delay(self.smol_now(), &self.sockets)
            .map_or(max_wait, |delay| Duration::from_micros(delay.total_micros()));
        let wait = delay.min(max_wait).min(TIMER_TICK).max(Duration::from_millis(1));
        self.receive(wait)?;
        self.run_timers();
        self.pump();
        Ok(())
    }

    /// Poll until `deadline`.
    pub fn poll_until(&mut self, deadline: Instant) -> io::Result<()> {
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Ok(());
            }
            self.poll(deadline - now)?;
        }
    }

    fn smol_now(&self) -> smoltcp::time::Instant {
        smoltcp::time::Instant::from_micros(
            i64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(i64::MAX),
        )
    }

    fn receive(&mut self, wait: Duration) -> io::Result<()> {
        self.udp.set_nonblocking(false)?;
        self.udp.set_read_timeout(Some(wait))?;
        if !self.receive_one()? {
            return Ok(());
        }
        // Drain what else already arrived without waiting.
        self.udp.set_nonblocking(true)?;
        let result = loop {
            match self.receive_one() {
                Ok(true) => continue,
                Ok(false) => break Ok(()),
                Err(error) => break Err(error),
            }
        };
        self.udp.set_nonblocking(false)?;
        result
    }

    /// Receive and handle one datagram; `false` when none came.
    fn receive_one(&mut self) -> io::Result<bool> {
        match self.udp.recv_from(&mut self.recv_buf) {
            Ok((len, from)) => {
                let datagram = self.recv_buf[..len].to_vec();
                self.on_datagram(&datagram, from);
                Ok(true)
            }
            // ICMP errors from earlier sends surface here on some systems.
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionRefused | io::ErrorKind::ConnectionReset
                ) =>
            {
                Ok(true)
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }

    fn on_datagram(&mut self, datagram: &[u8], from: SocketAddr) {
        if self.drop_inbound > 0 {
            self.drop_inbound -= 1;
            return;
        }
        if self.endpoint.is_some_and(|endpoint| endpoint != from) {
            return;
        }
        enum Action {
            Network(Vec<u8>),
            Inner(Vec<u8>, Ipv4Addr),
            Stop,
        }
        let mut input = datagram;
        loop {
            let action = match self.tunn.decapsulate(Some(from.ip()), input, &mut self.scratch) {
                TunnResult::WriteToNetwork(packet) => Action::Network(packet.to_vec()),
                TunnResult::WriteToTunnelV4(packet, source) => {
                    Action::Inner(packet.to_vec(), source)
                }
                _ => Action::Stop,
            };
            match action {
                Action::Network(packet) => {
                    // Authenticated: on the answering side this is how the
                    // peer is learned.
                    if self.endpoint.is_none() {
                        self.peer = Some(from);
                    }
                    self.send(&packet);
                    // boringtun may hold queued packets: drain with empty input.
                    input = &[];
                }
                Action::Inner(packet, source) => {
                    if self.endpoint.is_none() {
                        self.peer = Some(from);
                    }
                    if self.allowed.iter().any(|network| network.contains(source)) {
                        self.device.rx.push_back(packet);
                    }
                    break;
                }
                Action::Stop => break,
            }
        }
    }

    fn send(&mut self, packet: &[u8]) {
        let Some(peer) = self.peer else { return };
        if packet.len() == INITIATION_LEN && packet.first() == Some(&1) {
            self.last_initiation = Some(Instant::now());
        }
        // A lost send is like a lost packet: WireGuard and TCP retry.
        let _ = self.udp.send_to(packet, peer);
    }

    fn send_initiation(&mut self) {
        let packet = match self.tunn.format_handshake_initiation(&mut self.scratch, true) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            _ => return,
        };
        self.send(&packet);
    }

    fn run_timers(&mut self) {
        if self.last_timer.elapsed() < TIMER_TICK {
            return;
        }
        self.last_timer = Instant::now();
        let packet = match self.tunn.update_timers(&mut self.scratch) {
            TunnResult::WriteToNetwork(packet) => Some(packet.to_vec()),
            _ => None,
        };
        if let Some(packet) = packet {
            self.send(&packet);
        }
        let stale = self.last_initiation.is_none_or(|sent| sent.elapsed() >= HANDSHAKE_RETRY);
        if self.initiating && !self.has_session() && stale {
            self.send_initiation();
        }
    }

    /// Let smoltcp run and encrypt everything it emitted.
    fn pump(&mut self) {
        for _ in 0..16 {
            let now = self.smol_now();
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            if self.device.tx.is_empty() {
                return;
            }
            while let Some(packet) = self.device.tx.pop_front() {
                let encrypted = match self.tunn.encapsulate(&packet, &mut self.scratch) {
                    TunnResult::WriteToNetwork(encrypted) => Some(encrypted.to_vec()),
                    _ => None,
                };
                if let Some(encrypted) = encrypted {
                    self.send(&encrypted);
                }
            }
        }
    }

    fn check_route(&self, address: Ipv4Addr) -> Result<(), TunnelError> {
        if self.allowed.iter().any(|network| network.contains(address)) {
            Ok(())
        } else {
            Err(TunnelError::NotRouted(address))
        }
    }

    // ICMP echo.

    fn icmp_socket(&mut self) -> Result<(SocketHandle, u16), TunnelError> {
        if let Some(socket) = self.icmp {
            return Ok(socket);
        }
        let ident = (random_u64() & 0xffff) as u16;
        let buffer =
            || icmp::PacketBuffer::new(vec![icmp::PacketMetadata::EMPTY; 32], vec![0; 8192]);
        let mut socket = icmp::Socket::new(buffer(), buffer());
        socket
            .bind(icmp::Endpoint::Ident(ident))
            .map_err(|error| TunnelError::Stack(format!("icmp bind: {error}")))?;
        let handle = self.sockets.add(socket);
        self.icmp = Some((handle, ident));
        Ok((handle, ident))
    }

    /// Send one ICMP echo request.
    pub fn send_echo(&mut self, destination: Ipv4Addr, seq: u16) -> Result<(), TunnelError> {
        self.check_route(destination)?;
        let (handle, ident) = self.icmp_socket()?;
        let repr = Icmpv4Repr::EchoRequest { ident, seq_no: seq, data: ICMP_PAYLOAD };
        let socket = self.sockets.get_mut::<icmp::Socket>(handle);
        let buffer = socket
            .send(repr.buffer_len(), IpAddress::Ipv4(destination))
            .map_err(|error| TunnelError::Stack(format!("icmp send: {error}")))?;
        let mut packet = Icmpv4Packet::new_unchecked(buffer);
        repr.emit(&mut packet, &ChecksumCapabilities::default());
        self.pump();
        Ok(())
    }

    /// Take received echo replies from `source`: their sequence numbers.
    pub fn take_echo_replies(&mut self, source: Ipv4Addr) -> Vec<u16> {
        let Some((handle, ident)) = self.icmp else { return Vec::new() };
        let socket = self.sockets.get_mut::<icmp::Socket>(handle);
        let mut replies = Vec::new();
        while let Ok((data, from)) = socket.recv() {
            if from != IpAddress::Ipv4(source) {
                continue;
            }
            let Ok(packet) = Icmpv4Packet::new_checked(data) else { continue };
            if let Ok(Icmpv4Repr::EchoReply { ident: reply_ident, seq_no, .. }) =
                Icmpv4Repr::parse(&packet, &ChecksumCapabilities::default())
                && reply_ident == ident
            {
                replies.push(seq_no);
            }
        }
        replies
    }

    // TCP.

    fn allocate_port(&mut self) -> u16 {
        let port = self.next_port;
        self.next_port = self.next_port.checked_add(1).unwrap_or(49_152);
        port
    }

    fn new_tcp_socket() -> tcp::Socket<'static> {
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; TCP_BUFFER_BYTES]),
            tcp::SocketBuffer::new(vec![0u8; TCP_BUFFER_BYTES]),
        );
        socket.set_nagle_enabled(false);
        socket
    }

    /// Start a TCP connection; follow it with [`Tunnel::tcp_status`].
    pub fn tcp_open(&mut self, remote: SocketAddrV4) -> Result<SocketHandle, TunnelError> {
        self.check_route(*remote.ip())?;
        let mut socket = Self::new_tcp_socket();
        let port = self.allocate_port();
        socket
            .connect(
                self.iface.context(),
                IpEndpoint::new(IpAddress::Ipv4(*remote.ip()), remote.port()),
                port,
            )
            .map_err(|error| TunnelError::Stack(format!("tcp connect: {error}")))?;
        let handle = self.sockets.add(socket);
        self.pump();
        Ok(handle)
    }

    /// Accept one TCP connection on `port`: a listening socket.
    pub fn tcp_listen(&mut self, port: u16) -> Result<SocketHandle, TunnelError> {
        let mut socket = Self::new_tcp_socket();
        socket.listen(port).map_err(|error| TunnelError::Stack(format!("tcp listen: {error}")))?;
        Ok(self.sockets.add(socket))
    }

    pub fn tcp_status(&self, handle: SocketHandle) -> TcpStatus {
        let socket = self.sockets.get::<tcp::Socket>(handle);
        match socket.state() {
            tcp::State::Closed | tcp::State::TimeWait => {
                if socket.can_recv() {
                    TcpStatus::Connected
                } else {
                    TcpStatus::Failed
                }
            }
            tcp::State::Listen | tcp::State::SynSent | tcp::State::SynReceived => {
                TcpStatus::Pending
            }
            _ => TcpStatus::Connected,
        }
    }

    /// Whether the peer has closed its side and every byte was read.
    pub fn tcp_eof(&self, handle: SocketHandle) -> bool {
        let socket = self.sockets.get::<tcp::Socket>(handle);
        !socket.may_recv() && !socket.can_recv()
    }

    /// Queue bytes to send; returns how many fit.
    pub fn tcp_send(&mut self, handle: SocketHandle, data: &[u8]) -> Result<usize, TunnelError> {
        let socket = self.sockets.get_mut::<tcp::Socket>(handle);
        let sent = socket
            .send_slice(data)
            .map_err(|error| TunnelError::Stack(format!("tcp send: {error}")))?;
        self.pump();
        Ok(sent)
    }

    /// Append received bytes to `out`; returns how many.
    pub fn tcp_recv(&mut self, handle: SocketHandle, out: &mut Vec<u8>) -> usize {
        let socket = self.sockets.get_mut::<tcp::Socket>(handle);
        let mut buffer = [0u8; 4096];
        let mut total = 0;
        while socket.can_recv() {
            match socket.recv_slice(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(read) => {
                    out.extend_from_slice(&buffer[..read]);
                    total += read;
                }
            }
        }
        total
    }

    /// Close gracefully (FIN); the socket stays until [`Tunnel::tcp_remove`].
    pub fn tcp_close(&mut self, handle: SocketHandle) {
        self.sockets.get_mut::<tcp::Socket>(handle).close();
        self.pump();
    }

    /// Abort (RST when connected) and free the socket.
    pub fn tcp_remove(&mut self, handle: SocketHandle) {
        self.sockets.get_mut::<tcp::Socket>(handle).abort();
        self.pump();
        self.sockets.remove(handle);
    }
}

fn random_u64() -> u64 {
    let mut bytes = [0u8; 8];
    // A failure leaves zeros: ports and seeds then start at fixed values.
    let _ = getrandom::fill(&mut bytes);
    u64::from_le_bytes(bytes)
}
