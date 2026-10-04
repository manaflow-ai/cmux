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
use std::fmt;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::Poll;
use std::time::Duration;

use boringtun::noise::{Tunn, TunnResult};
use cmux_transport::{DatagramClass, classify};
use ip_network::IpNetwork;
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::config::{InterfaceAddress, WgConfig};
pub use crate::error::WgError;
use crate::pacing::{DropCounters, Pacer, Priority};
use crate::probing;
use crate::stream::WgStream;
use crate::tcp_stack::{Accepted, TcpStack};
use crate::timers::TimerSchedule;
use crate::underlay::{Origin, SocketPath, Underlay, is_transient};
use crate::watchdog::Watchdog;
use crate::wire::packet_source;

/// Commands in flight before `connect`/`listen` callers wait.
const COMMAND_DEPTH: usize = 64;
/// Largest datagram or packet buffer: the UDP payload maximum.
const BUFFER_BYTES: usize = 65_535;

/// A running tunnel. Dropping it stops the driver; every stream then reads
/// EOF and fails writes.
pub struct WgNet {
    commands: mpsc::Sender<Command>,
    wake: Arc<Notify>,
    wakeups: Arc<AtomicU64>,
    routes: Arc<[IpNetwork]>,
    addresses: Arc<[InterfaceAddress]>,
    max_datagram: usize,
    drops: Arc<DropCounters>,
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
        let path = crate::single_path::new_socket_path(&config, None).await?;
        Self::start_with_underlay(config, path)
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
        let drops = Arc::clone(&driver.pacer.drops);
        let handle = tokio::spawn(driver.run());
        let commands = commands_tx;
        let driver = Some(handle);
        Ok(Self { commands, wake, wakeups, routes, addresses, max_datagram, drops, driver })
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
    /// timeout; the stack aborts an unanswered SYN after
    /// [`crate::tcp_stack::TCP_TIMEOUT`].
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
    incoming: mpsc::Receiver<Accepted>,
}

impl WgListener {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The next established connection, or `None` once the tunnel is gone.
    pub async fn accept(&mut self) -> Option<WgStream> {
        self.incoming.recv().await.map(|(stream, _)| stream)
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

struct Driver {
    config: WgConfig,
    tunn: Tunn,
    underlay: Box<dyn Underlay>,
    stack: TcpStack,
    commands: mpsc::Receiver<Command>,
    wake: Arc<Notify>,
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

        let keepalive = config.persistent_keepalive.is_some_and(|seconds| seconds > 0);
        let schedule = TimerSchedule::new(Instant::now(), keepalive);
        let probe_route = probing::probe_route(&config);
        let stack = TcpStack::new(&config.addresses, config.mtu, Arc::clone(&wake), false)?;

        Ok(Self {
            config,
            tunn,
            underlay,
            stack,
            commands,
            wake,
            schedule,
            probe_route,
            probe_deadline: None,
            pacer: Pacer::default(),
            pace_deadline: None,
            datagram_ports: HashMap::new(),
            watchdog: Watchdog::default(),
            wakeups: Arc::new(AtomicU64::new(0)),
            scratch: vec![0u8; BUFFER_BYTES + 32],
        })
    }

    async fn run(mut self) {
        let wake = Arc::clone(&self.wake);
        let mut datagram = vec![0u8; BUFFER_BYTES];

        self.initiate_handshake();
        self.underlay.flush();
        self.service();

        loop {
            let deadline = self.stack.poll_delay();
            let stack_deadline = async {
                match deadline {
                    Some(delay) => tokio::time::sleep(delay).await,
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
                        self.stack.push_rx(packet.to_vec(), None);
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
            && let Some(packet) = self.stack.pop_tx()
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
            let progressed = self.stack.step();
            self.flush_tx();
            if !progressed && !self.stack.has_rx() {
                break;
            }
        }
    }

    /// Reset every connection and send what is left, unpaced. Returns the
    /// resets, which [`Driver::farewell`] repeats.
    fn shutdown(&mut self) -> Vec<Vec<u8>> {
        self.stack.abort_all();
        // Last words leave unpaced: the resets must not wait behind data.
        while let Some(packet) = self.stack.pop_tx() {
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
        self.stack.clear();
        resets
    }

    fn handle_command(&mut self, command: Command) {
        match command {
            Command::Connect { remote, reply } => self.begin_connect(remote, reply),
            Command::Listen { port, reply } => {
                let listener = self
                    .stack
                    .begin_listen(port)
                    .map(|incoming| WgListener { port, incoming });
                let _ = reply.send(listener);
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

    /// Start a connection from this side's address in `remote`'s family.
    fn begin_connect(
        &mut self,
        remote: SocketAddr,
        reply: oneshot::Sender<Result<WgStream, WgError>>,
    ) {
        if reply.is_closed() {
            return;
        }
        match self.config.local_address_for(remote.ip()) {
            Some(local) => self.stack.begin_connect(local, remote, None, reply),
            None => {
                let _ = reply.send(Err(WgError::NoTunnelAddress(remote.ip())));
            }
        }
    }
}

#[path = "net_timers.rs"]
mod timer_ops;

#[path = "net_datagrams.rs"]
mod datagram_ops;
pub use datagram_ops::{Datagram, DatagramDrops, WgDatagramSocket};

#[cfg(test)]
#[path = "net_tests.rs"]
mod tests;
