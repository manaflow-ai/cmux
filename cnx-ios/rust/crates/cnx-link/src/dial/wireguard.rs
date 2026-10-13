//! WireGuard transport: a per-session userspace tunnel (cmux-wg: boringtun
//! plus smoltcp). Keys, endpoints and overlay addresses travel in
//! `wg-init` / `wg-resp`. Endpoints are the host address and the
//! STUN-discovered reflexive address of the tunnel's UDP socket; the dialer
//! adds the relayed address of a TURN allocation when `/v1/ice` offers a
//! TURN server. Until the peer confirms a UDP or TURN route, every datagram
//! goes through the backend relay and is also sprayed at the peer's
//! endpoints (the hole punch). The link is one TCP stream to
//! `overlayIP:7420`.

use std::collections::HashSet;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use base64::Engine;
use bytes::Bytes;
use cmux_transport::PathId;
use cmux_wg::{InterfaceAddress, IpNetwork, Origin, Received, Underlay, WgConfig, WgNet};
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use uuid::Uuid;
use webrtc::util::Conn;
use zeroize::Zeroizing;

use super::{DialError, DialFuture, DialOptions, Dialed, Dialer, LinkPath, SessionEvents, TransportKind};
use crate::api::stun_servers;
use crate::signaling::{RelayFrame, SessionEvent, SignalEnvelope, SignalPayload, SignalingClient};

/// The link's TCP port inside the tunnel (PROTOCOL.md).
pub const LINK_PORT: u16 = 7420;
/// Overlay addresses: each tunnel is its own userspace network, so fixed
/// addresses never collide across sessions.
const DIALER_OVERLAY: Ipv4Addr = Ipv4Addr::new(10, 77, 0, 2);
const ANSWER_OVERLAY: Ipv4Addr = Ipv4Addr::new(10, 77, 0, 1);
/// Room for the relay frame header and WebSocket framing.
const MTU: u16 = 1280;
const KEEPALIVE_SECONDS: u16 = 10;
/// A direct route silent this long falls back to the relay: when relay
/// datagrams still arrive, or when this side keeps sending into it. Longer
/// than the WireGuard keepalive (10 s), shorter than the link keepalive
/// timeout (20 s), so a route that dies in both directions recovers on the
/// relay before the link gives up.
const DIRECT_STALE: Duration = Duration::from_secs(14);
const STUN_WAIT: Duration = Duration::from_millis(1500);
/// Bound on a TURN allocation; the dial goes on without one after this.
const TURN_WAIT: Duration = Duration::from_millis(2000);
/// Datagrams queued toward the TURN server before new ones are dropped.
const TURN_QUEUE: usize = 1024;

pub struct WireGuardDialer;

fn transport_error(error: impl std::fmt::Display) -> DialError {
    DialError::Transport(error.to_string())
}

fn keypair() -> (Zeroizing<[u8; 32]>, [u8; 32]) {
    let mut private = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut private[..]).expect("operating system randomness");
    let secret = x25519_dalek::StaticSecret::from(*private);
    let public = x25519_dalek::PublicKey::from(&secret);
    (Zeroizing::new(secret.to_bytes()), public.to_bytes())
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn parse_key(text: &str) -> Result<[u8; 32], DialError> {
    base64::engine::general_purpose::STANDARD
        .decode(text)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| DialError::Unexpected("bad WireGuard public key".into()))
}

/// The machine's primary local address (no packet is sent).
fn primary_local_ip() -> Option<IpAddr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect("192.0.2.1:9").ok()?;
    probe.local_addr().ok().map(|addr| addr.ip()).filter(|ip| !ip.is_unspecified())
}

/// Host and server-reflexive endpoints of `socket`.
async fn gather_endpoints(socket: &UdpSocket, options: &DialOptions) -> Vec<String> {
    if options.relay_only {
        return Vec::new();
    }
    let port = match socket.local_addr() {
        Ok(addr) => addr.port(),
        Err(_) => return Vec::new(),
    };
    let mut endpoints = Vec::new();
    if options.include_loopback {
        endpoints.push(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port));
    }
    if let Some(ip) = primary_local_ip() {
        endpoints.push(SocketAddr::new(ip, port));
    }
    let servers = stun_servers(&options.ice_servers);
    if !servers.is_empty() {
        let mut transactions = Vec::new();
        for server in &servers {
            let Ok(mut addresses) = tokio::net::lookup_host(server.as_str()).await else { continue };
            let Some(address) = addresses.find(SocketAddr::is_ipv4) else { continue };
            let mut transaction = [0u8; 12];
            getrandom::fill(&mut transaction).expect("operating system randomness");
            if socket.send_to(&cmux_transport::stun::binding_request(transaction), address).await.is_ok() {
                transactions.push(transaction);
            }
        }
        let deadline = Instant::now() + STUN_WAIT;
        let mut buffer = [0u8; 1500];
        while !transactions.is_empty() {
            let Ok(Ok((len, _))) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await
            else {
                break;
            };
            let found = transactions.iter().position(|transaction| {
                cmux_transport::stun::parse_binding_success(&buffer[..len], transaction).is_ok_and(
                    |reflexive| {
                        if !endpoints.contains(&reflexive) {
                            endpoints.push(reflexive);
                        }
                        true
                    },
                )
            });
            if let Some(index) = found {
                transactions.swap_remove(index);
            }
        }
    }
    endpoints
        .into_iter()
        .filter(|endpoint| !(options.exclude_cgnat && super::is_cgnat(endpoint.ip())))
        .map(|endpoint| endpoint.to_string())
        .collect()
}

/// The first plain `turn:` URL over UDP and its credentials, as
/// `(host:port, username, credential)`.
fn turn_server(servers: &[crate::api::IceServer]) -> Option<(String, String, String)> {
    servers.iter().find_map(|server| {
        let username = server.username.clone()?;
        let credential = server.credential.clone()?;
        server.urls.iter().find_map(|url| {
            let rest = url.strip_prefix("turn:")?;
            let (host, query) = rest.split_once('?').unwrap_or((rest, ""));
            if !query.is_empty() && !query.split('&').any(|pair| pair == "transport=udp") {
                return None;
            }
            let address = if host.rsplit_once(':').is_some_and(|(_, port)| port.parse::<u16>().is_ok()) {
                host.to_owned()
            } else {
                format!("{host}:3478")
            };
            Some((address, username.clone(), credential.clone()))
        })
    })
}

/// A TURN allocation used as one more WireGuard carrier (PROTOCOL.md): the
/// peer sends plain UDP to `relayed`, and this side sends through the TURN
/// server to the peer's public endpoints. TURN servers sit on well-routed
/// anycast addresses, so this relay is usually much nearer than the
/// backend's.
struct TurnCarrier {
    relayed: SocketAddr,
    out: mpsc::Sender<(Bytes, SocketAddr)>,
    inbound: mpsc::Receiver<(Bytes, SocketAddr)>,
    tasks: Vec<JoinHandle<()>>,
    relay: Arc<dyn Conn + Send + Sync>,
    client: webrtc::turn::client::Client,
}

impl TurnCarrier {
    /// Allocate on the first UDP TURN server of `servers`; `None` when there
    /// is none or the allocation fails within [`TURN_WAIT`].
    async fn allocate(servers: &[crate::api::IceServer]) -> Option<Self> {
        let (address, username, password) = turn_server(servers)?;
        let attempt = async {
            let socket = UdpSocket::bind("0.0.0.0:0").await.map_err(|e| e.to_string())?;
            let config = webrtc::turn::client::ClientConfig {
                stun_serv_addr: String::new(),
                turn_serv_addr: address.clone(),
                username,
                password,
                realm: String::new(),
                software: String::new(),
                rto_in_ms: 0,
                conn: Arc::new(socket),
                vnet: None,
            };
            let client = webrtc::turn::client::Client::new(config).await.map_err(|e| e.to_string())?;
            client.listen().await.map_err(|e| e.to_string())?;
            match client.allocate().await {
                Ok(relay) => Ok::<_, String>((client, Arc::new(relay) as Arc<dyn Conn + Send + Sync>)),
                Err(error) => {
                    let _ = client.close().await;
                    Err(error.to_string())
                }
            }
        };
        let (client, relay) = match tokio::time::timeout(TURN_WAIT, attempt).await {
            Ok(Ok(allocated)) => allocated,
            Ok(Err(error)) => {
                tracing::debug!(%error, %address, "TURN allocation failed; WireGuard goes without it");
                return None;
            }
            Err(_) => {
                tracing::debug!(%address, "TURN allocation timed out; WireGuard goes without it");
                return None;
            }
        };
        let relayed = relay.local_addr().ok()?;
        let (out, mut outgoing) = mpsc::channel::<(Bytes, SocketAddr)>(TURN_QUEUE);
        let (inbound_tx, inbound) = mpsc::channel(TURN_QUEUE);
        let sender = {
            let relay = Arc::clone(&relay);
            tokio::spawn(async move {
                while let Some((datagram, to)) = outgoing.recv().await {
                    if let Err(error) = relay.send_to(&datagram, to).await {
                        tracing::trace!(%error, %to, "TURN send failed");
                    }
                }
            })
        };
        let receiver = {
            let relay = Arc::clone(&relay);
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 65_536];
                while let Ok((len, from)) = relay.recv_from(&mut buffer).await {
                    match inbound_tx.try_send((Bytes::copy_from_slice(&buffer[..len]), from)) {
                        Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                        Err(mpsc::error::TrySendError::Closed(_)) => return,
                    }
                }
            })
        };
        tracing::debug!(%relayed, %address, "TURN allocation for WireGuard");
        Some(Self { relayed, out, inbound, tasks: vec![sender, receiver], relay, client })
    }

    /// Queue one datagram to `to` through the TURN server (dropped when the
    /// queue is full; WireGuard and TCP retransmit).
    fn send(&self, datagram: &[u8], to: SocketAddr) {
        let _ = self.out.try_send((Bytes::copy_from_slice(datagram), to));
    }
}

impl Drop for TurnCarrier {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        // Release the allocation; without a runtime it simply expires.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let (relay, client) = (Arc::clone(&self.relay), self.client.clone());
            runtime.spawn(async move {
                let _ = relay.close().await;
                let _ = client.close().await;
            });
        }
    }
}

/// Whether a TURN server may relay to `addr`: public unicast only (TURN
/// servers refuse private and loopback peers), except loopback in tests.
fn turn_reachable(addr: &SocketAddr, options: &DialOptions) -> bool {
    match addr.ip() {
        IpAddr::V4(ip) => {
            (options.include_loopback && ip.is_loopback())
                || !(ip.is_private()
                    || ip.is_loopback()
                    || ip.is_link_local()
                    || ip.is_unspecified()
                    || super::is_cgnat(IpAddr::V4(ip)))
        }
        IpAddr::V6(ip) => {
            (options.include_loopback && ip.is_loopback())
                || !(ip.is_loopback() || ip.is_unspecified() || (ip.segments()[0] & 0xfe00) == 0xfc00)
        }
    }
}

/// The peer endpoints this side sends to through its TURN allocation. Relay
/// only keeps these: like WebRTC's `relay` policy, only this side's
/// candidates are restricted to relayed ones.
fn turn_targets(endpoints: &[String], options: &DialOptions) -> Vec<SocketAddr> {
    endpoints
        .iter()
        .filter_map(|text| text.parse::<SocketAddr>().ok())
        .filter(|addr| !(options.exclude_cgnat && super::is_cgnat(addr.ip())))
        .filter(|addr| turn_reachable(addr, options))
        .collect()
}

/// Sends one datagram through the backend relay.
type RelaySend = Box<dyn Fn(&[u8]) + Send>;

/// The peer's endpoints this side may use.
fn usable_endpoints(endpoints: &[String], options: &DialOptions) -> Vec<String> {
    if options.relay_only {
        return Vec::new();
    }
    endpoints
        .iter()
        .filter(|text| {
            text.parse::<SocketAddr>()
                .is_ok_and(|addr| !(options.exclude_cgnat && super::is_cgnat(addr.ip())))
        })
        .cloned()
        .collect()
}

/// The relay datagram that means "your UDP reaches me". WireGuard messages
/// start with type 1 to 4 and are at least 32 bytes, so it never collides.
const REACHABLE_MARKER: [u8; 1] = [0xff];
/// Time between "your UDP reaches me" markers while UDP keeps arriving.
const MARKER_INTERVAL: Duration = Duration::from_secs(3);

/// How a direct route reaches the peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Carrier {
    /// Plain UDP from the tunnel's socket.
    Udp,
    /// Through this side's TURN allocation.
    Turn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Route {
    carrier: Carrier,
    addr: SocketAddr,
}

/// The carriers: one UDP socket for direct paths, an optional TURN
/// allocation, and the backend relay.
///
/// Reachability can be one-way (one side's OS or firewall drops its
/// outbound UDP), so receiving the peer's UDP proves only the peer→us
/// direction. Until the peer confirms it receives what we send, every
/// datagram goes through the backend relay as well. The confirmation is a
/// relay frame whose datagram is the single byte `0xff` (PROTOCOL.md), sent
/// by a side whenever an authenticated UDP or TURN datagram from its peer
/// arrives (at most every 3 s).
///
/// An address the OS refuses to send to (macOS Local Network privacy
/// returns `EHOSTUNREACH` for LAN peers) is never chosen as the route again,
/// so a peer reachable on the LAN one way and through TURN the other way
/// settles on TURN instead of flapping.
struct HybridUnderlay {
    socket: UdpSocket,
    drop_outbound_udp: bool,
    refuse_udp_to: Option<fn(&SocketAddr) -> bool>,
    /// Peer endpoints for plain UDP.
    candidates: Vec<SocketAddr>,
    turn: Option<TurnCarrier>,
    /// Peer endpoints this side reaches through its TURN allocation.
    turn_targets: Vec<SocketAddr>,
    /// The route of the latest authenticated peer datagram (peer→us works).
    direct: Option<Route>,
    last_direct: Option<Instant>,
    /// When plain UDP from the peer last authenticated.
    last_udp: Option<Instant>,
    /// Addresses the OS refused plain UDP to.
    refused: HashSet<SocketAddr>,
    /// The peer said it receives what we send (us→peer works).
    confirmed: bool,
    last_marker: Option<Instant>,
    relay_out: RelaySend,
    relay_in: mpsc::UnboundedReceiver<Bytes>,
    path: watch::Sender<LinkPath>,
}

const UDP_PATH: PathId = PathId(0);
const RELAY_PATH: PathId = PathId(1);
const TURN_PATH: PathId = PathId(2);

impl HybridUnderlay {
    /// Send one UDP datagram; `false` when the OS refused it.
    fn send_udp(&self, datagram: &[u8], target: SocketAddr) -> bool {
        if self.refuse_udp_to.is_some_and(|refuse| refuse(&target)) {
            return false;
        }
        if self.drop_outbound_udp {
            return true;
        }
        // A full socket drops the datagram; WireGuard and TCP retransmit.
        match self.socket.try_send_to(datagram, target) {
            Ok(_) => true,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => true,
            Err(error) => {
                tracing::trace!(%error, %target, "UDP send failed");
                false
            }
        }
    }

    /// Send on `route`; `false` when the OS refused it (the address is then
    /// never used for plain UDP again).
    fn send_on(&mut self, route: Route, datagram: &[u8]) -> bool {
        match route.carrier {
            Carrier::Udp => {
                if self.send_udp(datagram, route.addr) {
                    return true;
                }
                self.refused.insert(route.addr);
                false
            }
            Carrier::Turn => match &self.turn {
                Some(turn) => {
                    turn.send(datagram, route.addr);
                    true
                }
                None => false,
            },
        }
    }

    fn direct_only(&self) -> bool {
        self.confirmed && self.direct.is_some()
    }

    fn publish_path(&self) {
        let path = match self.direct {
            Some(route) if self.confirmed => match route.carrier {
                Carrier::Udp => LinkPath::Direct,
                Carrier::Turn => LinkPath::Turn,
            },
            _ => LinkPath::Relay,
        };
        self.path.send_if_modified(|current| std::mem::replace(current, path) != path);
    }

    fn demote(&mut self, why: &str) {
        if self.confirmed {
            tracing::debug!(why, "WireGuard direct path lost; using the relay again");
        }
        self.confirmed = false;
        self.publish_path();
    }
}

impl Underlay for HybridUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        if self.direct_only() && self.last_direct.is_some_and(|last| last.elapsed() > DIRECT_STALE) {
            // Nothing came back on the route for a while: offer the relay
            // again (and the peer's marker re-confirms the route if it works).
            self.demote("direct route silent");
        }
        if self.direct_only()
            && let Some(route) = self.direct
        {
            if !self.send_on(route, datagram) {
                self.direct = None;
                self.demote("send refused");
                (self.relay_out)(datagram);
            }
            return;
        }
        (self.relay_out)(datagram);
        match self.direct {
            Some(route) => {
                if !self.send_on(route, datagram) {
                    self.direct = None;
                    self.publish_path();
                }
                // Until confirmed, keep offering TURN too: the route may be
                // a plain UDP address the peer never receives from us.
                if route.carrier == Carrier::Udp
                    && let Some(turn) = &self.turn
                {
                    for target in &self.turn_targets {
                        turn.send(datagram, *target);
                    }
                }
            }
            None => {
                let mut refused = Vec::new();
                for candidate in &self.candidates {
                    if !self.refused.contains(candidate) && !self.send_udp(datagram, *candidate) {
                        refused.push(*candidate);
                    }
                }
                self.refused.extend(refused);
                if let Some(turn) = &self.turn {
                    for target in &self.turn_targets {
                        turn.send(datagram, *target);
                    }
                }
            }
        }
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        loop {
            let mut read = ReadBuf::new(buffer);
            match self.socket.poll_recv_from(cx, &mut read) {
                Poll::Ready(Ok(source)) => {
                    let len = read.filled().len();
                    return Poll::Ready(Ok(Received {
                        len,
                        origin: Origin { path: UDP_PATH, addr: Some(source) },
                    }));
                }
                // ICMP unreachable and friends: keep going on the relay.
                Poll::Ready(Err(error)) => {
                    tracing::trace!(%error, "UDP receive error");
                    continue;
                }
                Poll::Pending => break,
            }
        }
        if let Some(turn) = &mut self.turn
            && let Poll::Ready(Some((datagram, from))) = turn.inbound.poll_recv(cx)
        {
            let len = datagram.len().min(buffer.len());
            buffer[..len].copy_from_slice(&datagram[..len]);
            return Poll::Ready(Ok(Received { len, origin: Origin { path: TURN_PATH, addr: Some(from) } }));
        }
        loop {
            match self.relay_in.poll_recv(cx) {
                // The peer receives what we send.
                Poll::Ready(Some(datagram)) if datagram[..] == REACHABLE_MARKER => {
                    if !self.confirmed {
                        tracing::debug!("peer confirmed our datagrams reach it");
                    }
                    self.confirmed = true;
                    self.publish_path();
                }
                Poll::Ready(Some(datagram)) => {
                    let len = datagram.len().min(buffer.len());
                    buffer[..len].copy_from_slice(&datagram[..len]);
                    return Poll::Ready(Ok(Received {
                        len,
                        origin: Origin { path: RELAY_PATH, addr: None },
                    }));
                }
                Poll::Ready(None) | Poll::Pending => return Poll::Pending,
            }
        }
    }

    fn authenticated(&mut self, origin: Origin) {
        let now = Instant::now();
        let carrier = match origin.path {
            UDP_PATH => Some(Carrier::Udp),
            TURN_PATH => Some(Carrier::Turn),
            _ => None,
        };
        if let (Some(carrier), Some(addr)) = (carrier, origin.addr) {
            let route = Route { carrier, addr };
            if carrier == Carrier::Udp {
                self.last_udp = Some(now);
            }
            // Plain UDP wins over TURN while it keeps arriving, and an
            // address the OS refuses to send to is never the route.
            let udp_fresh = self.last_udp.is_some_and(|last| now.duration_since(last) <= DIRECT_STALE);
            let keep_udp = carrier == Carrier::Turn
                && udp_fresh
                && self.direct.is_some_and(|current| current.carrier == Carrier::Udp);
            let refused = carrier == Carrier::Udp && self.refused.contains(&addr);
            if !keep_udp && !refused && self.direct != Some(route) {
                if self.direct.is_some() {
                    // The marker confirmed the old route, not this one (our
                    // UDP may be dropped silently): relay again until the
                    // peer confirms what arrives on the new route.
                    tracing::debug!(?route, "WireGuard direct route changed");
                    self.confirmed = false;
                }
                self.direct = Some(route);
            }
            self.last_direct = Some(now);
            if self.last_marker.is_none_or(|last| now.duration_since(last) >= MARKER_INTERVAL) {
                self.last_marker = Some(now);
                (self.relay_out)(&REACHABLE_MARKER);
            }
            self.publish_path();
        } else if origin.path == RELAY_PATH
            && self.last_direct.is_some_and(|last| now.duration_since(last) > DIRECT_STALE)
        {
            // The peer still talks, but not over UDP any more.
            self.direct = None;
            self.last_direct = None;
            self.demote("direct path silent");
        }
    }

    fn has_peer(&self) -> bool {
        true
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.direct.map(|route| route.addr)
    }
}

/// Holds the tunnel and the task that feeds it relay frames.
struct Guard {
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    task: tokio::task::JoinHandle<()>,
    signaling: SignalingClient,
    session_id: String,
    peer: String,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.task.abort();
        // Tell the peer, so its tunnel stops sending relay frames the
        // backend can only answer with `offline` or `not_owner`.
        if self.net.lock().unwrap_or_else(PoisonError::into_inner).take().is_some() {
            let _ = self.signaling.send_signal(
                &self.peer,
                &self.session_id,
                SignalPayload::Bye { reason: "closed".into() },
            );
        }
        self.signaling.unsubscribe(&self.session_id);
    }
}

struct Tunnel {
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    path: watch::Receiver<LinkPath>,
    relay_in: mpsc::UnboundedSender<Bytes>,
}

#[allow(clippy::too_many_arguments)]
fn start_tunnel(
    signaling: &SignalingClient,
    session_id: &str,
    peer_device: &str,
    socket: UdpSocket,
    private_key: Zeroizing<[u8; 32]>,
    peer_key: [u8; 32],
    own_ip: Ipv4Addr,
    peer_ip: Ipv4Addr,
    peer_endpoints: &[String],
    turn: Option<TurnCarrier>,
    options: &DialOptions,
) -> Result<Tunnel, DialError> {
    let session_uuid =
        Uuid::parse_str(session_id).map_err(|_| DialError::Unexpected("sessionId is not a UUID".into()))?;
    let peer_uuid = Uuid::parse_str(peer_device)
        .map_err(|_| DialError::Unexpected("peer deviceId is not a UUID (relay frames need one)".into()))?;
    let relay_signaling = signaling.clone();
    let relay_out = Box::new(move |datagram: &[u8]| {
        let frame = RelayFrame {
            session_id: session_uuid,
            peer: peer_uuid,
            datagram: Bytes::copy_from_slice(datagram),
        };
        let _ = relay_signaling.send_relay(&frame);
    });
    let (relay_tx, relay_rx) = mpsc::unbounded_channel();
    let (path_tx, path_rx) = watch::channel(LinkPath::Relay);
    let underlay = HybridUnderlay {
        socket,
        drop_outbound_udp: options.drop_outbound_udp,
        refuse_udp_to: options.refuse_udp_to,
        candidates: usable_endpoints(peer_endpoints, options)
            .iter()
            .filter_map(|text| text.parse().ok())
            .collect(),
        turn_targets: if turn.is_some() { turn_targets(peer_endpoints, options) } else { Vec::new() },
        turn,
        direct: None,
        last_direct: None,
        last_udp: None,
        refused: HashSet::new(),
        confirmed: false,
        last_marker: None,
        relay_out,
        relay_in: relay_rx,
        path: path_tx,
    };
    let host = |ip: Ipv4Addr| IpNetwork::new(IpAddr::V4(ip), 32).expect("host prefix");
    let config = WgConfig {
        private_key,
        addresses: vec![InterfaceAddress { address: IpAddr::V4(own_ip), prefix: 32 }],
        mtu: MTU,
        peer_public_key: peer_key,
        preshared_key: None,
        allowed_ips: vec![host(peer_ip)],
        endpoint: None,
        persistent_keepalive: Some(KEEPALIVE_SECONDS),
        peer_addresses: vec![IpAddr::V4(peer_ip)],
    };
    let net = WgNet::start_with_underlay(config, underlay).map_err(transport_error)?;
    Ok(Tunnel { net: Arc::new(Mutex::new(Some(Arc::new(net)))), path: path_rx, relay_in: relay_tx })
}

/// Feed relay frames to the tunnel; drop the tunnel on `bye`.
fn follow(mut events: SessionEvents, tunnel: &Tunnel) -> tokio::task::JoinHandle<()> {
    let relay_in = tunnel.relay_in.clone();
    let net = Arc::clone(&tunnel.net);
    tokio::spawn(async move {
        loop {
            match events.session.recv().await {
                Some(SessionEvent::Relay(datagram)) => {
                    let _ = relay_in.send(datagram);
                }
                Some(SessionEvent::Signal(envelope)) => {
                    if matches!(envelope.payload, SignalPayload::Bye { .. }) {
                        net.lock().unwrap_or_else(PoisonError::into_inner).take();
                        return;
                    }
                }
                // Direct UDP can outlive a signaling outage.
                Some(SessionEvent::Disconnected) | None => return,
            }
        }
    })
}

/// The running tunnel, unless `bye` already dropped it.
fn running(net: &Arc<Mutex<Option<Arc<WgNet>>>>) -> Result<Arc<WgNet>, DialError> {
    net.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .ok_or_else(|| DialError::Bye("tunnel closed".into()))
}

impl Dialer for WireGuardDialer {
    fn kind(&self) -> TransportKind {
        TransportKind::WireGuard
    }

    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        mut events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let socket = UdpSocket::bind("0.0.0.0:0").await.map_err(transport_error)?;
            let (mut endpoints, turn) =
                tokio::join!(gather_endpoints(&socket, options), TurnCarrier::allocate(&options.ice_servers));
            if let Some(turn) = &turn {
                endpoints.push(turn.relayed.to_string());
            }
            let (private_key, public_key) = keypair();
            signaling
                .send_signal(
                    mac,
                    session_id,
                    SignalPayload::WgInit {
                        public_key: b64(&public_key),
                        endpoints,
                        overlay_ip: DIALER_OVERLAY.to_string(),
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let mut early_relay = Vec::new();
            let (peer_key, peer_endpoints, peer_ip) = loop {
                match events.next().await? {
                    SessionEvent::Signal(envelope) => match envelope.payload {
                        SignalPayload::WgResp { public_key, endpoints, overlay_ip } => {
                            let ip: Ipv4Addr = overlay_ip
                                .parse()
                                .map_err(|_| DialError::Unexpected("wg-resp overlayIP is not IPv4".into()))?;
                            break (parse_key(&public_key)?, endpoints, ip);
                        }
                        SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                        other => return Err(DialError::Unexpected(format!("{other:?}"))),
                    },
                    SessionEvent::Relay(datagram) => early_relay.push(datagram),
                    SessionEvent::Disconnected => return Err(DialError::Signaling("disconnected".into())),
                }
            };
            if peer_ip == DIALER_OVERLAY {
                return Err(DialError::Unexpected("peer overlay address collides".into()));
            }
            let tunnel = start_tunnel(
                signaling,
                session_id,
                mac,
                socket,
                private_key,
                peer_key,
                DIALER_OVERLAY,
                peer_ip,
                &peer_endpoints,
                turn,
                options,
            )?;
            for datagram in early_relay {
                let _ = tunnel.relay_in.send(datagram);
            }
            let task = follow(events, &tunnel);
            let guard = Guard {
                net: Arc::clone(&tunnel.net),
                task,
                signaling: signaling.clone(),
                session_id: session_id.to_owned(),
                peer: mac.to_owned(),
            };
            let net = running(&tunnel.net)?;
            let stream = net
                .connect(SocketAddr::new(IpAddr::V4(peer_ip), LINK_PORT))
                .await
                .map_err(transport_error)?;
            drop(net);
            Ok(Dialed { stream: Box::new(stream), path: tunnel.path, guard: Box::new(guard) })
        })
    }

    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let SignalPayload::WgInit { public_key, endpoints: peer_endpoints, overlay_ip } = first.payload
            else {
                return Err(DialError::Unexpected("expected wg-init".into()));
            };
            let peer_key = parse_key(&public_key)?;
            let peer_ip: Ipv4Addr = overlay_ip
                .parse()
                .map_err(|_| DialError::Unexpected("wg-init overlayIP is not IPv4".into()))?;
            let own_ip = if peer_ip == ANSWER_OVERLAY { DIALER_OVERLAY } else { ANSWER_OVERLAY };
            let socket = UdpSocket::bind("0.0.0.0:0").await.map_err(transport_error)?;
            let endpoints = gather_endpoints(&socket, options).await;
            let (private_key, own_public) = keypair();
            let tunnel = start_tunnel(
                signaling,
                &first.session_id,
                &first.from,
                socket,
                private_key,
                peer_key,
                own_ip,
                peer_ip,
                &peer_endpoints,
                None,
                options,
            )?;
            let task = follow(events, &tunnel);
            let guard = Guard {
                net: Arc::clone(&tunnel.net),
                task,
                signaling: signaling.clone(),
                session_id: first.session_id.clone(),
                peer: first.from.clone(),
            };
            let net = running(&tunnel.net)?;
            let mut listener = net.listen(LINK_PORT).await.map_err(transport_error)?;
            drop(net);
            signaling
                .send_signal(
                    &first.from,
                    &first.session_id,
                    SignalPayload::WgResp {
                        public_key: b64(&own_public),
                        endpoints,
                        overlay_ip: own_ip.to_string(),
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let stream =
                listener.accept().await.ok_or_else(|| DialError::Transport("tunnel closed".into()))?;
            Ok(Dialed { stream: Box::new(stream), path: tunnel.path, guard: Box::new(guard) })
        })
    }
}
