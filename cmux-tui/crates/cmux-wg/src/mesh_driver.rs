//! The task that runs a [`crate::WgMesh`].
//!
//! One Tokio task owns everything mutable: the peer table (one boringtun
//! session per peer), the TCP stack, the pacer, and the UDP socket. Callers
//! talk to it through commands. Nothing here sleeps to synchronize: the loop
//! wakes on a datagram, a command, a stream write, the earliest WireGuard
//! timer of any session, the pacer's next departure, or the deadline smoltcp
//! asks for.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::task::Poll;

use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Tunn, TunnResult};
use cmux_transport::{DatagramClass, classify};
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::config::InterfaceAddress;
use crate::error::WgError;
use crate::mesh::{MeshCommand, WgMeshConfig, WgPeer};
use crate::mesh_peers::PeerTable;
use crate::pacing::Pacer;
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
    pub(crate) udp: SocketPath<UdpSocket>,
    /// The socket's own address, to map endpoints to its family.
    local: SocketAddr,
    addresses: Vec<InterfaceAddress>,
    /// Checks the MAC of every handshake initiation before the
    /// Diffie-Hellman that identifies its key, and rate-limits them.
    pub(crate) gate: RateLimiter,
    /// Per-connection pacing of the stack's output (shared with
    /// [`crate::WgNet`]): smoltcp releases a whole window at once, and a
    /// burst into a socket buffer loses segments.
    pub(crate) pacer: Pacer,
    pace_deadline: Option<Instant>,
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
            udp: SocketPath::new(socket, None),
            local,
            addresses: config.addresses,
            gate,
            pacer: Pacer::default(),
            pace_deadline: None,
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
            let next_tick = self.table.next_tick().into_iter().chain(self.pace_deadline).min();
            let backlogged = self.udp.backlogged();
            let udp = &mut self.udp;
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
            };
            self.run_timers();
            match event {
                Event::Datagram(count, source) => {
                    self.handle_datagram(&datagram[..count], source);
                    self.receive_ready(&mut datagram);
                }
                Event::Fatal | Event::Command(Some(MeshCommand::Shutdown) | None) => {
                    self.shutdown();
                    return;
                }
                Event::Command(Some(command)) => self.handle_command(command),
                Event::Drained | Event::Wake => {}
            }
            self.udp.flush();
            self.service();
            self.udp.flush();
        }
    }

    /// Decrypt the datagrams already waiting on the socket, up to a batch.
    fn receive_ready(&mut self, buffer: &mut [u8]) {
        for _ in 1..RECEIVE_BATCH {
            match self.udp.socket().try_recv_from(buffer) {
                Ok((count, source)) => self.handle_datagram(&buffer[..count], Some(source)),
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
        while !self.udp.backlogged() {
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
    /// it. A packet no peer routes, or for a peer with no known endpoint, is
    /// dropped (TCP retransmits). A peer without a session queues it in
    /// boringtun and starts a handshake.
    fn send_packet(&mut self, packet: &[u8], now: Instant) {
        let Some(key) = Tunn::dst_address(packet).and_then(|dst| self.table.route(dst)) else {
            return;
        };
        let Some(peer) = self.table.get_mut(&key) else { return };
        if peer.endpoint.is_none() {
            return;
        }
        if let TunnResult::WriteToNetwork(datagram) =
            peer.tunn.encapsulate(packet, &mut self.scratch)
        {
            transmit(&mut self.udp, self.local, peer.endpoint, datagram);
            peer.schedule.on_activity(now);
        }
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
                transmit(&mut self.udp, self.local, peer.endpoint, packet);
                if retry {
                    peer.schedule.on_activity(now);
                }
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
            MeshCommand::Connect { remote, reply } => self.begin_connect(remote, reply),
            MeshCommand::Listen { port, reply } => {
                let _ = reply.send(self.stack.begin_listen(port));
            }
            MeshCommand::Shutdown => {}
        }
    }

    fn add_peer(&mut self, peer: WgPeer) -> Result<(), WgError> {
        self.table.check(&peer)?;
        let key = peer.public_key;
        let now = Instant::now();
        let entry = self.table.insert(peer, now);
        // A replaced peer's connections stay only where it still routes.
        let allowed = entry.allowed_ips.clone();
        // Start the session now when the peer's address is known, so a peer
        // that only answers learns this side's endpoint without waiting for
        // traffic.
        if entry.endpoint.is_some()
            && let TunnResult::WriteToNetwork(packet) =
                entry.tunn.format_handshake_initiation(&mut self.scratch, false)
        {
            transmit(&mut self.udp, self.local, entry.endpoint, packet);
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
        self.udp.flush();
        self.stack.clear();
    }
}

async fn sleep_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending::<()>().await,
    }
}

/// Send `datagram` to `target` on the shared socket, mapped to the socket's
/// address family (a dual-stack IPv6 socket reaches IPv4 peers through
/// mapped addresses).
pub(crate) fn transmit(
    udp: &mut SocketPath<UdpSocket>,
    local: SocketAddr,
    target: Option<SocketAddr>,
    datagram: &[u8],
) {
    let Some(target) = target else { return };
    let target = match (local, target) {
        (SocketAddr::V6(_), SocketAddr::V4(v4)) => {
            SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port())
        }
        (SocketAddr::V4(_), SocketAddr::V6(v6)) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
            None => return,
        },
        _ => target,
    };
    udp.send_to(datagram, target);
}

#[path = "mesh_receive.rs"]
mod receive;

#[cfg(test)]
#[path = "mesh_tests.rs"]
mod tests;
