//! The task that runs a [`crate::WgMesh`].
//!
//! One Tokio task owns everything mutable: the peer table (one boringtun
//! session per peer), the TCP stack, the pacer and the UDP socket. Callers
//! talk to it through commands. Nothing here sleeps to synchronize: the loop
//! wakes on a datagram, a command, a stream write, the earliest WireGuard
//! timer of any session, the pacer's next departure, the next path probe,
//! or the deadline smoltcp asks for.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::task::Poll;

use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Tunn, TunnResult};
use cmux_transport::{
    CANDIDATE_PORT, DatagramClass, LocalNetwork, MAX_CANDIDATES, Probe, ProbeKind, classify,
    encode_candidates, local_networks, medium_of,
};
use ip_network::IpNetwork;
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::config::InterfaceAddress;
use crate::error::WgError;
use crate::mesh::{MeshCommand, WgMeshConfig, WgPeer};
use crate::mesh_peers::PeerTable;
use crate::mesh_route::{Outbound, PeerRoute};
use crate::pacing::Pacer;
use crate::probing;
use crate::stream::WgStream;
use crate::tcp_stack::TcpStack;
use crate::underlay::{SocketPath, Underlay, is_transient};

/// Largest datagram or packet buffer: the UDP payload maximum.
const BUFFER_BYTES: usize = 65_535;
/// Datagrams decrypted per wake before the stack runs. Running the stack
/// once per batch instead of once per datagram keeps the receive loop
/// ahead of the socket buffer; a socket buffer that overflows drops
/// segments, and smoltcp then waits a full retransmission timeout.
const RECEIVE_BATCH: usize = 64;
/// Handshake initiations the mesh examines per second before it asks
/// initiators for a cookie (WireGuard's under-load rule). Each costs a
/// Diffie-Hellman to learn the initiator's key.
pub(crate) const HANDSHAKES_PER_SECOND: u64 = 100;
/// How long this machine's interface table is trusted before it is read
/// again for the next advertisement.
const LOCAL_REFRESH: std::time::Duration = std::time::Duration::from_secs(30);

/// This machine's interfaces: the medium of each peer address, and the
/// addresses this side advertises to its peers.
pub(crate) struct LocalView {
    socket: SocketAddr,
    pub(crate) networks: Vec<LocalNetwork>,
    pub(crate) candidates: Vec<SocketAddr>,
    read_at: Instant,
}

impl LocalView {
    fn read(socket: SocketAddr, now: Instant) -> Self {
        let networks = local_networks();
        let candidates = local_candidates(socket, &networks);
        Self { socket, networks, candidates, read_at: now }
    }

    fn refresh(&mut self, now: Instant) {
        if now >= self.read_at + LOCAL_REFRESH {
            *self = Self::read(self.socket, now);
        }
    }
}

/// Whether an address can be another machine's path to this one: never
/// loopback, link-local, multicast or unspecified.
pub(crate) fn advertisable(ip: IpAddr) -> bool {
    let link_local = match ip {
        IpAddr::V4(v4) => v4.is_link_local(),
        IpAddr::V6(v6) => v6.is_unicast_link_local(),
    };
    !(ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() || link_local)
}

/// The addresses a peer may reach this socket at: every advertisable
/// interface address of a family the socket speaks, best medium first, on
/// the socket's port. A socket bound to one address advertises nothing: its
/// peers were told where it is.
fn local_candidates(socket: SocketAddr, networks: &[LocalNetwork]) -> Vec<SocketAddr> {
    if !socket.ip().is_unspecified() || socket.port() == 0 {
        return Vec::new();
    }
    let mut addresses: Vec<IpAddr> = networks
        .iter()
        .map(|network| network.address)
        .filter(|ip| advertisable(*ip) && (socket.is_ipv6() || ip.is_ipv4()))
        .collect();
    addresses.sort_by_key(|ip| medium_of(*ip, networks));
    addresses.dedup();
    addresses
        .into_iter()
        .take(MAX_CANDIDATES)
        .map(|ip| SocketAddr::new(ip, socket.port()))
        .collect()
}

/// The overlay addresses probes and candidate lists travel between: this
/// side's address and, in the same family, the base address of the peer's
/// first allowed network. The receiver intercepts both by port before
/// routing.
fn probe_route(
    addresses: &[InterfaceAddress],
    allowed: &[IpNetwork],
) -> Option<(IpAddr, IpAddr)> {
    allowed.iter().find_map(|network| {
        let remote = network.network_address();
        let local = addresses.iter().find(|entry| entry.address.is_ipv4() == remote.is_ipv4())?;
        Some((local.address, remote))
    })
}

fn earliest(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

pub(crate) fn spawn(
    config: WgMeshConfig,
    socket: UdpSocket,
    commands: mpsc::Receiver<MeshCommand>,
) -> Result<JoinHandle<()>, WgError> {
    let driver = MeshDriver::new(config, socket, commands)?;
    Ok(tokio::spawn(driver.run()))
}

pub(crate) struct MeshDriver {
    pub(crate) table: PeerTable,
    pub(crate) stack: TcpStack,
    /// The UDP socket.
    pub(crate) out: Outbound,
    addresses: Vec<InterfaceAddress>,
    /// Checks the MAC of every handshake initiation before the
    /// Diffie-Hellman that identifies its key, and rate-limits them.
    pub(crate) gate: RateLimiter,
    /// Per-connection pacing of the stack's output (shared with
    /// [`crate::WgNet`]): smoltcp releases a whole window at once, and a
    /// burst into a socket buffer loses segments.
    pub(crate) pacer: Pacer,
    pace_deadline: Option<Instant>,
    /// When some peer's paths next need a probe or an advertisement.
    probe_deadline: Option<Instant>,
    pub(crate) local: LocalView,
    /// Set by [`MeshCommand::Close`]: the driver stops once every connection delivered what
    /// its owner wrote, or at this deadline.
    closing: Option<Instant>,
    commands: mpsc::Receiver<MeshCommand>,
    wake: Arc<Notify>,
    pub(crate) scratch: Vec<u8>,
}

enum Event {
    Datagram(usize, Option<SocketAddr>),
    Drained,
    Fatal,
    Command(Option<MeshCommand>),
    Wake,
}

impl MeshDriver {
    pub(crate) fn new(
        config: WgMeshConfig,
        socket: UdpSocket,
        commands: mpsc::Receiver<MeshCommand>,
    ) -> Result<Self, WgError> {
        let local = socket.local_addr()?;
        let wake = Arc::new(Notify::new());
        let stack = TcpStack::new(&config.addresses, config.mtu, Arc::clone(&wake), true)?;
        let table = PeerTable::new(&config.private_key);
        let gate = RateLimiter::new(table.public(), HANDSHAKES_PER_SECOND);
        Ok(Self {
            table,
            stack,
            out: Outbound::new(SocketPath::new(socket, None), local),
            addresses: config.addresses,
            gate,
            pacer: Pacer::default(),
            pace_deadline: None,
            probe_deadline: None,
            local: LocalView::read(local, Instant::now()),
            closing: None,
            commands,
            wake,
            scratch: vec![0u8; BUFFER_BYTES + 32],
        })
    }

    async fn run(mut self) {
        let wake = Arc::clone(&self.wake);
        let mut datagram = vec![0u8; BUFFER_BYTES];
        loop {
            let stack_deadline = self.stack.poll_delay();
            let next_tick = self
                .table
                .next_tick()
                .into_iter()
                .chain(self.pace_deadline)
                .chain(self.probe_deadline)
                .min();
            let backlogged = self.out.udp.backlogged();
            let udp = &mut self.out.udp;
            let io = std::future::poll_fn(|cx| {
                if backlogged && udp.poll_flush(cx).is_ready() {
                    return Poll::Ready(Ok(None));
                }
                udp.poll_recv(cx, &mut datagram).map_ok(Some)
            });
            let event = tokio::select! {
                io = io => match io {
                    Ok(Some(received)) => Event::Datagram(received.len, received.origin.addr),
                    Ok(None) => Event::Drained,
                    Err(error) if is_transient(&error) => Event::Wake,
                    Err(_) => Event::Fatal,
                },
                command = self.commands.recv() => Event::Command(command),
                () = wake.notified() => Event::Wake,
                () = sleep_until(next_tick) => Event::Wake,
                () = sleep_until(stack_deadline.map(|delay| Instant::now() + delay)) => Event::Wake,
                () = sleep_until(self.closing) => Event::Wake,
            };
            self.run_timers();
            match event {
                Event::Datagram(count, source) => {
                    // A count past the buffer is not a datagram: drop it.
                    if let Some(received) = datagram.get(..count) {
                        self.handle_datagram(received, source.map(PeerRoute::Udp));
                    }
                    self.receive_ready(&mut datagram);
                }
                Event::Fatal | Event::Command(Some(MeshCommand::Shutdown) | None) => {
                    self.shutdown();
                    return;
                }
                Event::Command(Some(MeshCommand::Close { deadline })) => {
                    self.stack.close_all();
                    self.closing = Some(self.closing.map_or(deadline, |d| d.min(deadline)));
                }
                Event::Command(Some(command)) => self.handle_command(command),
                Event::Drained | Event::Wake => {}
            }
            self.out.udp.flush();
            self.service();
            self.probe_deadline = self.run_probes();
            self.out.udp.flush();
            if let Some(deadline) = self.closing
                && (self.stack.delivered() || Instant::now() >= deadline)
            {
                self.shutdown();
                return;
            }
        }
    }

    /// Decrypt the datagrams already waiting on the socket, up to a batch.
    fn receive_ready(&mut self, buffer: &mut [u8]) {
        for _ in 1..RECEIVE_BATCH {
            match self.out.udp.socket().try_recv_from(buffer) {
                Ok((count, source)) => {
                    if let Some(received) = buffer.get(..count) {
                        self.handle_datagram(received, Some(PeerRoute::Udp(source)));
                    }
                }
                // WouldBlock, or an error the next wait reports.
                Err(_) => break,
            }
        }
    }

    /// Let the stack run, then send what it emitted, until it settles.
    fn service(&mut self) {
        loop {
            let progressed = self.stack.step();
            self.flush_tx();
            if !progressed && !self.stack.has_rx() {
                break;
            }
        }
    }

    /// Move what the stack emitted into the pacer, then encrypt what the
    /// pacer lets leave for the peer that routes each destination, until the
    /// socket backs up. Nothing waits in the stack's way: a full pacer
    /// leaves packets in the device, which then refuses smoltcp more.
    fn flush_tx(&mut self) {
        let now = Instant::now();
        while self.pacer.has_room()
            && let Some(packet) = self.stack.pop_tx()
        {
            self.pacer.push(packet, now);
        }
        self.pace_deadline = None;
        while !self.out.udp.backlogged() {
            let packet = match self.pacer.pop(now) {
                Ok(Some(packet)) => packet,
                Ok(None) => break,
                Err(at) => {
                    self.pace_deadline = Some(at);
                    break;
                }
            };
            self.send_packet(&packet, now);
        }
    }

    /// Encrypt one packet for the peer that routes its destination and send
    /// it. A packet no peer routes, or for a peer with no known route, is
    /// dropped (TCP retransmits). A peer without a session queues it in
    /// boringtun and starts a handshake.
    fn send_packet(&mut self, packet: &[u8], now: Instant) {
        let Some(key) = Tunn::dst_address(packet).and_then(|dst| self.table.route(dst)) else {
            return;
        };
        let Some(peer) = self.table.get_mut(&key) else { return };
        if !peer.paths.has_target() {
            return;
        }
        if peer.tunn.time_since_last_handshake().is_none() {
            peer.waiting = Some(now);
        }
        if let TunnResult::WriteToNetwork(datagram) =
            peer.tunn.encapsulate(packet, &mut self.scratch)
        {
            if classify(datagram) == DatagramClass::WireGuardInitiation {
                peer.initiated = Some(now);
            }
            let out = &mut self.out;
            peer.paths.send(now, |target| out.send_to(target, datagram));
            peer.schedule.on_activity(now);
        }
    }

    /// Probe the paths of every peer whose session carries traffic and has
    /// more than one path, and advertise this side's addresses on each such
    /// session. Returns when this is next due. An idle session probes and
    /// advertises nothing.
    fn run_probes(&mut self) -> Option<Instant> {
        let now = Instant::now();
        let mut next = None;
        for peer in self.table.peers_mut() {
            if !peer.schedule.is_active(now) || peer.tunn.time_since_last_handshake().is_none() {
                continue;
            }
            let Some((local, remote)) = probe_route(&self.addresses, &peer.allowed_ips) else {
                continue;
            };
            let (advertise, again) = peer.advertise_due(now);
            if advertise {
                self.local.refresh(now);
            }
            if advertise && !self.local.candidates.is_empty() {
                let list = encode_candidates(&self.local.candidates);
                let packet = crate::udp::packet(
                    SocketAddr::new(local, CANDIDATE_PORT),
                    SocketAddr::new(remote, CANDIDATE_PORT),
                    &list,
                );
                if let TunnResult::WriteToNetwork(datagram) =
                    peer.tunn.encapsulate(&packet, &mut self.scratch)
                {
                    let out = &mut self.out;
                    peer.paths.send(now, |target| out.send_to(target, datagram));
                }
            }
            next = earliest(next, Some(again));
            // One path has nothing to choose between, and a peer that is
            // not a cmux endpoint (a relay shim) never sees a probe.
            if peer.paths.path_count() < 2 {
                continue;
            }
            let due = peer.paths.poll(now);
            for (path, id) in due.pings {
                let Some(target) = peer.paths.address_of(path) else { continue };
                let probe = Probe { kind: ProbeKind::Ping, id, path };
                let packet = probing::encode(local, remote, &probe);
                if let TunnResult::WriteToNetwork(datagram) =
                    peer.tunn.encapsulate(&packet, &mut self.scratch)
                {
                    self.out.send_to(target, datagram);
                }
            }
            next = earliest(next, due.next);
        }
        next
    }

    /// Run each session's boringtun timers that are due.
    fn run_timers(&mut self) {
        let now = Instant::now();
        for peer in self.table.peers_mut() {
            if !peer.schedule.due(now) {
                continue;
            }
            peer.schedule.on_tick(now);
            if let TunnResult::WriteToNetwork(packet) = peer.tunn.update_timers(&mut self.scratch) {
                // A handshake retry keeps the timers running until boringtun
                // gives up; a keepalive alone does not.
                let retry = classify(packet) == DatagramClass::WireGuardInitiation;
                let out = &mut self.out;
                peer.paths.send(now, |target| out.send_to(target, packet));
                if retry {
                    peer.initiated = Some(now);
                    peer.schedule.on_activity(now);
                }
            }
            // A dial waiting on the handshake gets an initiation every
            // HANDSHAKE_RESEND, not only boringtun's every 5 s or more.
            if peer.paths.has_target()
                && peer.resend_due(now)
                && let TunnResult::WriteToNetwork(packet) =
                    peer.tunn.format_handshake_initiation(&mut self.scratch, true)
            {
                let out = &mut self.out;
                peer.paths.send(now, |target| out.send_to(target, packet));
                peer.initiated = Some(now);
                peer.schedule.on_activity(now);
            }
        }
    }

    fn handle_command(&mut self, command: MeshCommand) {
        match command {
            MeshCommand::AddPeer { peer, reply } => {
                let _ = reply.send(self.add_peer(peer));
            }
            MeshCommand::RemovePeer { public_key, reply } => {
                let removed = self.table.remove(&public_key).is_some();
                if removed {
                    self.stack.abort_peer(public_key);
                }
                let _ = reply.send(removed);
            }
            MeshCommand::PeerPaths { public_key, reply } => {
                let _ = reply.send(self.table.get_mut(&public_key).map(|peer| peer.paths.views()));
            }
            MeshCommand::Connect { remote, reply } => self.begin_connect(remote, reply),
            MeshCommand::Listen { port, reply } => {
                let _ = reply.send(self.stack.begin_listen(port));
            }
            MeshCommand::Close { .. } | MeshCommand::Shutdown => {}
        }
    }

    fn add_peer(&mut self, peer: WgPeer) -> Result<(), WgError> {
        self.table.check(&peer)?;
        let key = peer.public_key;
        let now = Instant::now();
        let entry = self.table.insert(peer, &self.local.networks, now);
        // A replaced peer's connections stay only where it still routes.
        let allowed = entry.allowed_ips.clone();
        // Start the session now when the peer's address is known, so a peer
        // that only answers learns this side's route without waiting for
        // traffic.
        if entry.paths.has_target()
            && let TunnResult::WriteToNetwork(packet) =
                entry.tunn.format_handshake_initiation(&mut self.scratch, false)
        {
            let out = &mut self.out;
            entry.paths.send(now, |target| out.send_to(target, packet));
            entry.initiated = Some(now);
            entry.schedule.on_activity(now);
        }
        self.stack.abort_conns(|conn| {
            conn.peer == Some(key)
                && !allowed.iter().any(|network| network.contains(conn.remote.ip()))
        });
        Ok(())
    }

    fn begin_connect(
        &mut self,
        remote: SocketAddr,
        reply: oneshot::Sender<Result<WgStream, WgError>>,
    ) {
        if reply.is_closed() {
            return;
        }
        let Some(key) = self.table.route(remote.ip()) else {
            let _ = reply.send(Err(WgError::NoRoute(remote.ip())));
            return;
        };
        let Some(local) = self.local_address_for(remote.ip()) else {
            let _ = reply.send(Err(WgError::NoTunnelAddress(remote.ip())));
            return;
        };
        self.stack.begin_connect(local, remote, Some(key), reply);
    }

    fn local_address_for(&self, remote: IpAddr) -> Option<IpAddr> {
        self.addresses
            .iter()
            .map(|entry| entry.address)
            .find(|address| address.is_ipv4() == remote.is_ipv4())
    }

    /// Reset every connection and send what is queued, resets included,
    /// once and unpaced, on sessions that are up (none starts a handshake).
    fn shutdown(&mut self) {
        self.stack.abort_all();
        let now = Instant::now();
        while let Some(packet) = self.stack.pop_tx() {
            self.pacer.push(packet, now);
        }
        for packet in self.pacer.drain() {
            let live = Tunn::dst_address(&packet)
                .and_then(|dst| self.table.route(dst))
                .and_then(|key| self.table.get_mut(&key))
                .is_some_and(|peer| peer.tunn.time_since_last_handshake().is_some());
            if live {
                self.send_packet(&packet, now);
            }
        }
        self.out.udp.flush();
        self.stack.clear();
    }
}

async fn sleep_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending::<()>().await,
    }
}

#[path = "mesh_receive.rs"]
mod receive;
