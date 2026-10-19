//! WireGuard transport: a per-session userspace tunnel (cmux-wg: boringtun
//! plus smoltcp). Keys, endpoints and overlay addresses travel in
//! `wg-init` / `wg-resp`. Endpoints are the host address and the
//! STUN-discovered reflexive address of the tunnel's UDP socket; the dialer
//! adds the relayed address of a TURN allocation when `/v1/ice` offers a
//! TURN server. Until the peer confirms a UDP or TURN route, every datagram
//! goes through the backend relay and is also sprayed at the peer's
//! endpoints (the hole punch). The link is one TCP stream to
//! `overlayIP:7420`.
//!
//! Roaming (`roam.rs`): after a network change a side moves the session onto
//! a fresh UDP socket and TURN allocation, re-learns its reflexive address,
//! and tells the peer its new endpoints inside the tunnel. The session, its
//! keys and its TCP streams stay.

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
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use uuid::Uuid;
use webrtc::util::Conn;
use zeroize::Zeroizing;

use super::{DialError, DialFuture, DialOptions, Dialed, Dialer, LinkPath, SessionEvents, TransportKind};
use crate::api::stun_servers;
use crate::signaling::{
    RelayClass, RelayFrame, SessionEvent, SignalEnvelope, SignalPayload, SignalingClient, relay_class,
};
use crate::timing::Timeline;

#[path = "wireguard_roam.rs"]
mod roam;
use roam::{Control, Session};
pub use roam::{network_changed, rehome, roam_timeline};
#[doc(hidden)]
pub use roam::{roam_session, simulate_network_loss};

/// The link's TCP port inside the tunnel (PROTOCOL.md).
pub const LINK_PORT: u16 = 7420;
/// How long the input lane's second connection may take before input stays
/// on the main stream.
const LANE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
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
pub fn primary_local_ip() -> Option<IpAddr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect("192.0.2.1:9").ok()?;
    probe.local_addr().ok().map(|addr| addr.ip()).filter(|ip| !ip.is_unspecified())
}

/// Host endpoints of a socket on `port` (no STUN).
fn host_endpoints(port: u16, options: &DialOptions) -> Vec<SocketAddr> {
    if options.relay_only {
        return Vec::new();
    }
    let mut endpoints = Vec::new();
    if options.include_loopback {
        endpoints.push(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port));
    }
    if let Some(ip) = primary_local_ip() {
        endpoints.push(SocketAddr::new(ip, port));
    }
    endpoints
}

/// The IPv4 addresses of the STUN servers in `options`.
async fn resolve_stun(options: &DialOptions) -> Vec<SocketAddr> {
    let mut addresses = Vec::new();
    for server in stun_servers(&options.ice_servers) {
        let Ok(mut found) = tokio::net::lookup_host(server.as_str()).await else { continue };
        if let Some(address) = found.find(SocketAddr::is_ipv4) {
            addresses.push(address);
        }
    }
    addresses
}

/// The endpoints offered to the peer: `endpoints` as text, without CGNAT
/// addresses when the options exclude them.
fn offered(endpoints: impl IntoIterator<Item = SocketAddr>, options: &DialOptions) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for endpoint in endpoints {
        if options.exclude_cgnat && super::is_cgnat(endpoint.ip()) {
            continue;
        }
        let text = endpoint.to_string();
        if !out.contains(&text) {
            out.push(text);
        }
    }
    out
}

/// Host and server-reflexive endpoints of `socket`, and the STUN servers
/// used (kept for roaming).
async fn gather_endpoints(socket: &UdpSocket, options: &DialOptions) -> (Vec<String>, Vec<SocketAddr>) {
    if options.relay_only {
        return (Vec::new(), Vec::new());
    }
    let port = match socket.local_addr() {
        Ok(addr) => addr.port(),
        Err(_) => return (Vec::new(), Vec::new()),
    };
    let mut endpoints = host_endpoints(port, options);
    let servers = resolve_stun(options).await;
    let mut transactions = Vec::new();
    for address in &servers {
        let mut transaction = [0u8; 12];
        getrandom::fill(&mut transaction).expect("operating system randomness");
        if socket.send_to(&cmux_transport::stun::binding_request(transaction), address).await.is_ok() {
            transactions.push(transaction);
        }
    }
    let deadline = Instant::now() + STUN_WAIT;
    let mut buffer = [0u8; 1500];
    while !transactions.is_empty() {
        let Ok(Ok((len, _))) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await else {
            break;
        };
        let found = transactions.iter().position(|transaction| {
            cmux_transport::stun::parse_binding_success(&buffer[..len], transaction).is_ok_and(|reflexive| {
                if !endpoints.contains(&reflexive) {
                    endpoints.push(reflexive);
                }
                true
            })
        });
        if let Some(index) = found {
            transactions.swap_remove(index);
        }
    }
    (offered(endpoints, options), servers)
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

/// Sends one datagram through the backend relay, queued in its class.
type RelaySend = Box<dyn Fn(&[u8], RelayClass) + Send + Sync>;

/// The relay class of a datagram the tunnel's pacer sent in `priority`.
/// Handshake messages, keepalives and anything not WireGuard data keep the
/// class their shape gives (control).
fn relay_class_of(datagram: &[u8], priority: cmux_wg::Priority) -> RelayClass {
    match relay_class(datagram) {
        RelayClass::Control => RelayClass::Control,
        _ => match priority {
            cmux_wg::Priority::Interactive => RelayClass::Input,
            cmux_wg::Priority::Bulk => RelayClass::Bulk,
            cmux_wg::Priority::Media => RelayClass::Media,
        },
    }
}

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

/// The path label of a confirmed route (`None`: the backend relay). Plain
/// UDP to one of the peer's TURN relayed addresses rides the peer's TURN
/// server: the answering Mac reaches a relay-only phone that way, so it is
/// [`LinkPath::Turn`] even though this side sends plain UDP.
fn path_of(route: Option<Route>, peer_relayed: &HashSet<SocketAddr>) -> LinkPath {
    match route {
        Some(Route { carrier: Carrier::Udp, addr }) if peer_relayed.contains(&addr) => LinkPath::Turn,
        Some(Route { carrier: Carrier::Udp, .. }) => LinkPath::Direct,
        Some(Route { carrier: Carrier::Turn, .. }) => LinkPath::Turn,
        None => LinkPath::Relay,
    }
}

/// How long after a roam (this side's or the peer's) every datagram also
/// goes to the peer's plain UDP candidates, so a new NAT mapping opens on
/// both sides while the route settles.
const ROAM_SPRAY: Duration = Duration::from_secs(3);
/// Spacing of those extra datagrams inside the window.
const ROAM_SPRAY_GAP: Duration = Duration::from_millis(100);
/// Data messages sent in this long before a roam, a route change or a new
/// signaling socket are sent again on the new route: those that went into
/// the dead route would otherwise cost TCP inside the tunnel its 1 s
/// minimum retransmission timeout, or after a long outage (airplane mode)
/// its backed-off one. WireGuard's replay window drops the copies that did
/// arrive. As long as the link's own keepalive timeout.
const REPLAY_AGE: Duration = Duration::from_secs(20);
/// At most this many datagrams are kept for that (about 100 ms of a
/// 15 Mbit/s stream; a whole outage of retransmissions and keepalives).
const REPLAY_MAX: usize = 128;
/// A route that flips between two addresses of the same peer (a LAN and a
/// hairpinned public address while candidates are sprayed) replays at most
/// this often; a roam of this side always replays.
const REPLAY_GAP: Duration = Duration::from_secs(1);
/// While the confirmed route is TURN, plain UDP candidates are tried this
/// often, so the session goes back to a direct path once one works again.
const UPGRADE_SPRAY_GAP: Duration = Duration::from_secs(5);

/// The carriers: one UDP socket for direct paths, an optional TURN
/// allocation, and the backend relay.
///
/// Reachability can be one-way (one side's OS or firewall drops its
/// outbound UDP), so receiving the peer's UDP proves only the peer→us
/// direction. Until the peer confirms it receives what we send, every
/// datagram goes through the backend relay as well. The confirmation is a
/// relay frame whose datagram is the single byte `0xff` (PROTOCOL.md), sent
/// by a side whenever an authenticated UDP or TURN datagram from its peer
/// arrives (at most every 3 s, and at once when the route changed).
///
/// An address the OS refuses to send to (macOS Local Network privacy
/// returns `EHOSTUNREACH` for LAN peers) is never chosen as the route again,
/// so a peer reachable on the LAN one way and through TURN the other way
/// settles on TURN instead of flapping. A roam forgets those refusals: the
/// new network may route them.
///
/// The roaming side of the tunnel (`roam.rs`) changes the carriers through
/// [`Control`] messages, which the underlay applies before its next send or
/// receive.
struct HybridUnderlay {
    socket: UdpSocket,
    options: DialOptions,
    /// The peer's endpoints as it last announced them.
    peer_endpoints: Vec<String>,
    /// Peer endpoints for plain UDP.
    candidates: Vec<SocketAddr>,
    turn: Option<TurnCarrier>,
    /// Peer endpoints this side reaches through its TURN allocation.
    turn_targets: Vec<SocketAddr>,
    /// Peer endpoints that are the peer's own TURN relayed addresses: a
    /// plain UDP route to one of them is labeled [`LinkPath::Turn`].
    peer_relayed: HashSet<SocketAddr>,
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
    control: mpsc::UnboundedReceiver<Control>,
    /// STUN transactions of the current socket still unanswered, and where
    /// the reflexive addresses go.
    stun: Vec<([u8; 12], SocketAddr)>,
    reflexive: Option<mpsc::UnboundedSender<SocketAddr>>,
    /// Until when candidates are sprayed after a roam, and when next.
    spray_until: Option<Instant>,
    next_spray: Option<Instant>,
    /// The current roam's marks, until the new route is confirmed.
    roam: Option<Timeline>,
    /// The socket's network is gone (debug and tests): nothing it sends
    /// leaves and nothing arrives.
    blackhole: bool,
    /// Test support: addresses plain UDP was sent to; with
    /// `DialOptions::restrict_inbound_udp`, UDP from anywhere else is dropped.
    sent_to: HashSet<SocketAddr>,
    /// What was sent lately, for the replay after a route change.
    recent: std::collections::VecDeque<(Instant, Bytes, RelayClass)>,
    /// When a route change last replayed.
    last_replay: Option<Instant>,
}

const UDP_PATH: PathId = PathId(0);
const RELAY_PATH: PathId = PathId(1);
const TURN_PATH: PathId = PathId(2);

impl HybridUnderlay {
    #[allow(clippy::too_many_arguments)]
    fn new(
        socket: UdpSocket,
        options: &DialOptions,
        peer_endpoints: &[String],
        peer_relayed: &[String],
        turn: Option<TurnCarrier>,
        relay_out: RelaySend,
        relay_in: mpsc::UnboundedReceiver<Bytes>,
        path: watch::Sender<LinkPath>,
        control: mpsc::UnboundedReceiver<Control>,
    ) -> Self {
        let mut underlay = Self {
            socket,
            options: options.clone(),
            peer_endpoints: Vec::new(),
            candidates: Vec::new(),
            turn,
            turn_targets: Vec::new(),
            peer_relayed: peer_relayed.iter().filter_map(|text| text.parse().ok()).collect(),
            direct: None,
            last_direct: None,
            last_udp: None,
            refused: HashSet::new(),
            confirmed: false,
            last_marker: None,
            relay_out,
            relay_in,
            path,
            control,
            stun: Vec::new(),
            reflexive: None,
            spray_until: None,
            next_spray: None,
            roam: None,
            blackhole: false,
            sent_to: HashSet::new(),
            recent: std::collections::VecDeque::new(),
            last_replay: None,
        };
        underlay.set_peer_endpoints(peer_endpoints.to_vec());
        underlay
    }

    fn set_peer_endpoints(&mut self, endpoints: Vec<String>) {
        self.candidates =
            usable_endpoints(&endpoints, &self.options).iter().filter_map(|text| text.parse().ok()).collect();
        self.peer_endpoints = endpoints;
        self.retarget_turn();
    }

    fn retarget_turn(&mut self) {
        self.turn_targets =
            if self.turn.is_some() { turn_targets(&self.peer_endpoints, &self.options) } else { Vec::new() };
    }

    /// Apply the roaming side's changes.
    fn apply(&mut self, control: Control) {
        let now = Instant::now();
        match control {
            Control::Rebind { socket, stun, reflexive, timeline } => {
                tracing::debug!(local = ?socket.local_addr().ok(), "WireGuard roams onto a new socket");
                // The old route's address stays a candidate (a peer-reflexive
                // one may be in no announcement).
                if let Some(route) = self.direct.take()
                    && route.carrier == Carrier::Udp
                    && !self.options.relay_only
                    && !self.candidates.contains(&route.addr)
                {
                    self.candidates.push(route.addr);
                }
                self.socket = socket;
                self.blackhole = false;
                // The old allocation belongs to the old network's 5-tuple.
                self.turn = None;
                self.turn_targets.clear();
                self.last_direct = None;
                self.last_udp = None;
                self.refused.clear();
                self.sent_to.clear();
                self.confirmed = false;
                self.last_marker = None;
                self.spray_until = Some(now + ROAM_SPRAY);
                self.next_spray = None;
                self.stun.clear();
                for server in stun {
                    let mut transaction = [0u8; 12];
                    getrandom::fill(&mut transaction).expect("operating system randomness");
                    let request = cmux_transport::stun::binding_request(transaction);
                    if self.socket.try_send_to(&request, server).is_ok() {
                        self.stun.push((transaction, server));
                    }
                }
                self.reflexive = Some(reflexive);
                self.roam = Some(timeline);
                self.publish_path();
                self.replay_recent(true);
            }
            Control::Turn(turn) => {
                self.turn = Some(turn);
                self.retarget_turn();
            }
            Control::PeerEndpoints { endpoints, relayed } => {
                tracing::debug!(?endpoints, ?relayed, "WireGuard peer announced new endpoints");
                // An empty list says only that the peer's network changed.
                if !endpoints.is_empty() {
                    self.set_peer_endpoints(endpoints);
                    // A roaming relay-only phone announces its new TURN
                    // address; an older peer lists none, and the old ones stay
                    // (a stale entry only matters for a datagram from it).
                    if !relayed.is_empty() {
                        self.peer_relayed = relayed.iter().filter_map(|text| text.parse().ok()).collect();
                    }
                    self.publish_path();
                }
                self.spray_until = Some(now + ROAM_SPRAY);
                self.next_spray = None;
                self.last_marker = None;
                // What we sent toward its old network may be lost.
                self.replay_recent(true);
            }
            Control::Rehomed => {
                self.last_marker = None;
                // Relay frames sent on the dead socket are lost.
                if !self.direct_only() {
                    self.replay_recent(true);
                }
            }
            Control::Blackhole => {
                self.blackhole = true;
                self.turn = None;
                self.turn_targets.clear();
            }
        }
    }

    /// Keep `datagram` for a replay, with the relay class it went out in.
    fn record(&mut self, datagram: &[u8], class: RelayClass) {
        // Handshake messages are never worth repeating.
        if cmux_transport::classify(datagram) != cmux_transport::DatagramClass::WireGuardData {
            return;
        }
        let now = Instant::now();
        while self.recent.len() >= REPLAY_MAX
            || self.recent.front().is_some_and(|(at, _, _)| now.duration_since(*at) > REPLAY_AGE)
        {
            self.recent.pop_front();
        }
        self.recent.push_back((now, Bytes::copy_from_slice(datagram), class));
    }

    /// Send what went out lately again, on the current route. Replays for
    /// a route change (not `forced`) happen at most every [`REPLAY_GAP`].
    fn replay_recent(&mut self, forced: bool) {
        let now = Instant::now();
        if !forced {
            if self.last_replay.is_some_and(|last| now.duration_since(last) < REPLAY_GAP) {
                return;
            }
            self.last_replay = Some(now);
        }
        let recent: Vec<(Bytes, RelayClass)> = self
            .recent
            .iter()
            .filter(|(at, _, _)| now.duration_since(*at) <= REPLAY_AGE)
            .map(|(_, datagram, class)| (datagram.clone(), *class))
            .collect();
        if !recent.is_empty() {
            tracing::debug!(count = recent.len(), "WireGuard resends recent datagrams on the new route");
        }
        for (datagram, class) in recent {
            self.transmit(&datagram, class);
        }
    }

    fn drain_control(&mut self) {
        while let Ok(control) = self.control.try_recv() {
            self.apply(control);
        }
    }

    /// Send one UDP datagram; `false` when the OS refused it.
    fn send_udp(&mut self, datagram: &[u8], target: SocketAddr) -> bool {
        if self.options.refuse_udp_to.is_some_and(|refuse| refuse(&target)) {
            return false;
        }
        if self.options.drop_outbound_udp || self.blackhole {
            return true;
        }
        if self.options.restrict_inbound_udp {
            self.sent_to.insert(target);
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

    /// Plain UDP to every usable candidate but `except`.
    fn spray(&mut self, datagram: &[u8], except: Option<SocketAddr>) {
        let mut refused = Vec::new();
        for candidate in self.candidates.clone() {
            if Some(candidate) != except
                && !self.refused.contains(&candidate)
                && !self.send_udp(datagram, candidate)
            {
                refused.push(candidate);
            }
        }
        self.refused.extend(refused);
    }

    /// With a route: also try the other candidates, often right after a
    /// roam, now and then while the route is not plain UDP (so a direct
    /// path is found again).
    fn maybe_spray(&mut self, datagram: &[u8], route: Route) {
        let now = Instant::now();
        let roaming = self.spray_until.is_some_and(|until| now < until);
        let gap = if roaming {
            ROAM_SPRAY_GAP
        } else if route.carrier != Carrier::Udp {
            UPGRADE_SPRAY_GAP
        } else {
            return;
        };
        if self.next_spray.is_some_and(|next| now < next) {
            return;
        }
        self.next_spray = Some(now + gap);
        self.spray(datagram, Some(route.addr));
    }

    fn direct_only(&self) -> bool {
        self.confirmed && self.direct.is_some()
    }

    fn publish_path(&mut self) {
        let path = path_of(self.direct.filter(|_| self.confirmed), &self.peer_relayed);
        if path != LinkPath::Relay
            && let Some(roam) = self.roam.take()
        {
            roam.mark(if path == LinkPath::Direct { "roam_direct" } else { "roam_turn" });
        }
        self.path.send_if_modified(|current| std::mem::replace(current, path) != path);
    }

    fn demote(&mut self, why: &str) {
        if self.confirmed {
            tracing::debug!(why, "WireGuard direct path lost; using the relay again");
        }
        self.confirmed = false;
        self.publish_path();
    }

    /// A STUN answer to this socket's own binding request: consumed.
    fn stun_answer(&mut self, datagram: &[u8], source: SocketAddr) -> bool {
        if self.stun.is_empty() {
            return false;
        }
        let Some(index) = self.stun.iter().position(|(_, server)| *server == source) else { return false };
        let Ok(reflexive) = cmux_transport::stun::parse_binding_success(datagram, &self.stun[index].0) else {
            return false;
        };
        self.stun.swap_remove(index);
        if let Some(tx) = &self.reflexive {
            let _ = tx.send(reflexive);
        }
        true
    }
}

impl HybridUnderlay {
    fn transmit(&mut self, datagram: &[u8], class: RelayClass) {
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
                (self.relay_out)(datagram, class);
                return;
            }
            self.maybe_spray(datagram, route);
            return;
        }
        (self.relay_out)(datagram, class);
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
                self.maybe_spray(datagram, route);
            }
            None => {
                self.spray(datagram, None);
                if let Some(turn) = &self.turn {
                    for target in &self.turn_targets {
                        turn.send(datagram, *target);
                    }
                }
            }
        }
    }
}

impl Underlay for HybridUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        self.drain_control();
        let class = relay_class(datagram);
        self.record(datagram, class);
        self.transmit(datagram, class);
    }

    fn send_classified(&mut self, datagram: &[u8], priority: cmux_wg::Priority) {
        self.drain_control();
        let class = relay_class_of(datagram, priority);
        self.record(datagram, class);
        self.transmit(datagram, class);
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        while let Poll::Ready(Some(control)) = self.control.poll_recv(cx) {
            self.apply(control);
        }
        loop {
            let mut read = ReadBuf::new(buffer);
            match self.socket.poll_recv_from(cx, &mut read) {
                Poll::Ready(Ok(source)) => {
                    let len = read.filled().len();
                    if self.blackhole
                        || (self.options.restrict_inbound_udp && !self.sent_to.contains(&source))
                        || self.stun_answer(&buffer[..len], source)
                    {
                        continue;
                    }
                    return Poll::Ready(Ok(Received {
                        len,
                        origin: Origin { path: UDP_PATH, addr: Some(source) },
                    }));
                }
                // ICMP unreachable and friends: keep going on the relay.
                Poll::Ready(Err(error)) => {
                    tracing::trace!(%error, "UDP receive error");
                    if self.blackhole {
                        // A socket whose network went away can fail every
                        // receive at once; wait for the roam instead of spinning.
                        break;
                    }
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
            if let Some(roam) = &self.roam {
                roam.mark("roam_first_packet");
            }
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
                    // peer confirms what arrives on the new route, and tell
                    // the peer at once that its datagrams reach us here.
                    tracing::debug!(?route, "WireGuard direct route changed");
                    self.confirmed = false;
                    self.last_marker = None;
                    self.direct = Some(route);
                    self.replay_recent(false);
                } else {
                    self.direct = Some(route);
                }
            }
            self.last_direct = Some(now);
            if self.last_marker.is_none_or(|last| now.duration_since(last) >= MARKER_INTERVAL) {
                self.last_marker = Some(now);
                (self.relay_out)(&REACHABLE_MARKER, RelayClass::Control);
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

/// Holds the tunnel; dropping it ends the session.
struct Guard {
    session: Arc<Session>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.session.close();
    }
}

struct Tunnel {
    session: Arc<Session>,
    path: watch::Receiver<LinkPath>,
}

/// What a side knows when it starts its tunnel.
struct TunnelSpec<'a> {
    session_id: &'a str,
    peer_device: &'a str,
    socket: UdpSocket,
    private_key: Zeroizing<[u8; 32]>,
    peer_key: [u8; 32],
    own_ip: Ipv4Addr,
    peer_ip: Ipv4Addr,
    peer_endpoints: &'a [String],
    /// Which peer endpoints are its TURN relayed addresses (the dialer's,
    /// told in `wg-init`): plain UDP to them is a TURN path.
    peer_relayed: &'a [String],
    /// What this side offered the peer.
    own_endpoints: Vec<String>,
    turn: Option<TurnCarrier>,
    /// The phone allocates TURN (again after a roam) when offered one.
    dialer: bool,
    stun: Vec<SocketAddr>,
}

fn start_tunnel(
    signaling: &SignalingClient,
    spec: TunnelSpec<'_>,
    options: &DialOptions,
) -> Result<Tunnel, DialError> {
    let session_uuid = Uuid::parse_str(spec.session_id)
        .map_err(|_| DialError::Unexpected("sessionId is not a UUID".into()))?;
    let peer_uuid = Uuid::parse_str(spec.peer_device)
        .map_err(|_| DialError::Unexpected("peer deviceId is not a UUID (relay frames need one)".into()))?;
    // The relay goes through whichever signaling socket the session is on
    // now: a roam can move it to a new one.
    let current = Arc::new(Mutex::new(signaling.clone()));
    let relay_signaling = Arc::clone(&current);
    let relay_out = Box::new(move |datagram: &[u8], class: RelayClass| {
        let frame = RelayFrame {
            session_id: session_uuid,
            peer: peer_uuid,
            datagram: Bytes::copy_from_slice(datagram),
        };
        let client = relay_signaling.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let _ = client.send_relay_as(&frame, class);
    });
    let (relay_tx, relay_rx) = mpsc::unbounded_channel();
    let (path_tx, path_rx) = watch::channel(LinkPath::Relay);
    let (control_tx, control_rx) = mpsc::unbounded_channel();
    let underlay = HybridUnderlay::new(
        spec.socket,
        options,
        spec.peer_endpoints,
        spec.peer_relayed,
        spec.turn,
        relay_out,
        relay_rx,
        path_tx,
        control_rx,
    );
    let host = |ip: Ipv4Addr| IpNetwork::new(IpAddr::V4(ip), 32).expect("host prefix");
    let config = WgConfig {
        private_key: spec.private_key,
        addresses: vec![InterfaceAddress { address: IpAddr::V4(spec.own_ip), prefix: 32 }],
        mtu: MTU,
        peer_public_key: spec.peer_key,
        preshared_key: None,
        allowed_ips: vec![host(spec.peer_ip)],
        endpoint: None,
        persistent_keepalive: Some(KEEPALIVE_SECONDS),
        peer_addresses: vec![IpAddr::V4(spec.peer_ip)],
    };
    let net = WgNet::start_with_underlay(config, underlay).map_err(transport_error)?;
    let session = Session::register(roam::SessionParts {
        session_id: spec.session_id.to_owned(),
        peer: spec.peer_device.to_owned(),
        dialer: spec.dialer,
        peer_ip: spec.peer_ip,
        signaling: current,
        net: Arc::new(Mutex::new(Some(Arc::new(net)))),
        control: control_tx,
        relay_in: relay_tx,
        options: options.clone(),
        stun: spec.stun,
        endpoints: spec.own_endpoints,
    });
    Ok(Tunnel { session, path: path_rx })
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
            let ((mut endpoints, stun), turn) =
                tokio::join!(gather_endpoints(&socket, options), TurnCarrier::allocate(&options.ice_servers));
            let relayed: Vec<String> = turn.iter().map(|turn| turn.relayed.to_string()).collect();
            endpoints.extend(relayed.iter().cloned());
            options.timeline.mark("endpoints_gathered");
            let (private_key, public_key) = keypair();
            let own_endpoints = endpoints.clone();
            signaling
                .send_signal(
                    mac,
                    session_id,
                    SignalPayload::WgInit {
                        public_key: b64(&public_key),
                        endpoints,
                        overlay_ip: DIALER_OVERLAY.to_string(),
                        lanes: super::offered_lanes(options, options.video_lane),
                        relayed,
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            options.timeline.mark("wg_init_sent");
            let mut early_relay = Vec::new();
            let agreed;
            let video_agreed;
            let (peer_key, peer_endpoints, peer_ip) = loop {
                match events.next().await? {
                    SessionEvent::Signal(envelope) => match envelope.payload {
                        SignalPayload::WgResp { public_key, endpoints, overlay_ip, lanes } => {
                            options.timeline.mark("wg_resp_received");
                            let ip: Ipv4Addr = overlay_ip
                                .parse()
                                .map_err(|_| DialError::Unexpected("wg-resp overlayIP is not IPv4".into()))?;
                            agreed = super::input_lane_agreed(options, &lanes);
                            video_agreed = options.video_lane && super::video_lane_listed(&lanes);
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
            let spec = TunnelSpec {
                session_id,
                peer_device: mac,
                socket,
                private_key,
                peer_key,
                own_ip: DIALER_OVERLAY,
                peer_ip,
                peer_endpoints: &peer_endpoints,
                peer_relayed: &[],
                own_endpoints,
                turn,
                dialer: true,
                stun,
            };
            let tunnel = start_tunnel(signaling, spec, options)?;
            for datagram in early_relay {
                tunnel.session.relay(datagram);
            }
            tunnel.session.follow(events.session);
            let guard = Guard { session: Arc::clone(&tunnel.session) };
            let net = tunnel.session.net()?;
            tunnel.session.start_control(&net).await;
            // The media lane's port is bound before the link stream opens, so
            // the Mac's first frames (sent once a browser tab claims the lane)
            // find it.
            let media = if video_agreed {
                match crate::media::wireguard::WgCarrier::open(
                    &net,
                    IpAddr::V4(peer_ip),
                    crate::media::wireguard::Direction::Receive,
                    crate::media::wireguard::StreamSpec::h264_video(),
                    tunnel.session.path_changes(),
                    crate::media::wireguard::Impairment::default(),
                )
                .await
                {
                    Ok(carrier) => {
                        options.timeline.mark("video_lane");
                        Some(super::PendingMedia::Receive(carrier))
                    }
                    Err(error) => {
                        tracing::info!(%error, "no media lane on this tunnel; video stays on the channel");
                        None
                    }
                }
            } else {
                None
            };
            let link_addr = SocketAddr::new(IpAddr::V4(peer_ip), LINK_PORT);
            let stream = net.connect(link_addr).await.map_err(transport_error)?;
            // The input lane: a second TCP stream to the same port, opened
            // after the main one so the Mac tells them apart by order. Its
            // own socket buffers keep keystrokes out of the main stream's
            // 256 KiB send buffer.
            let lane = agreed.then(|| {
                let (tx, rx) = oneshot::channel();
                tokio::spawn(async move {
                    match tokio::time::timeout(LANE_TIMEOUT, net.connect(link_addr)).await {
                        Ok(Ok(stream)) => {
                            let _ = tx.send(Box::new(stream) as Box<dyn super::LinkStream>);
                        }
                        Ok(Err(error)) => tracing::info!(%error, "input lane did not connect"),
                        Err(_) => tracing::info!("input lane did not connect in time"),
                    }
                });
                rx
            });
            Ok(Dialed { stream: Box::new(stream), path: tunnel.path, guard: Box::new(guard), lane, media })
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
            let SignalPayload::WgInit { public_key, endpoints: peer_endpoints, overlay_ip, lanes, relayed } =
                first.payload
            else {
                return Err(DialError::Unexpected("expected wg-init".into()));
            };
            let agreed = super::input_lane_agreed(options, &lanes);
            let video_wanted = options.video_lane && super::video_lane_listed(&lanes);
            let peer_key = parse_key(&public_key)?;
            let peer_ip: Ipv4Addr = overlay_ip
                .parse()
                .map_err(|_| DialError::Unexpected("wg-init overlayIP is not IPv4".into()))?;
            let own_ip = if peer_ip == ANSWER_OVERLAY { DIALER_OVERLAY } else { ANSWER_OVERLAY };
            let socket = UdpSocket::bind("0.0.0.0:0").await.map_err(transport_error)?;
            let (endpoints, stun) = gather_endpoints(&socket, options).await;
            let (private_key, own_public) = keypair();
            let spec = TunnelSpec {
                session_id: &first.session_id,
                peer_device: &first.from,
                socket,
                private_key,
                peer_key,
                own_ip,
                peer_ip,
                peer_endpoints: &peer_endpoints,
                peer_relayed: &relayed,
                own_endpoints: endpoints.clone(),
                turn: None,
                dialer: false,
                stun,
            };
            let tunnel = start_tunnel(signaling, spec, options)?;
            tunnel.session.follow(events.session);
            let guard = Guard { session: Arc::clone(&tunnel.session) };
            let net = tunnel.session.net()?;
            tunnel.session.start_control(&net).await;
            let mut listener = net.listen(LINK_PORT).await.map_err(transport_error)?;
            // The media lane: listed back only once its port is bound, so a
            // phone never expects a lane this side cannot serve.
            let media = if video_wanted {
                let impairment = crate::media::wireguard::Impairment {
                    drop_permille: options.video_drop_permille,
                    cap_bps: options.video_cap_bps,
                    blackout: options.video_blackout,
                };
                match crate::media::wireguard::WgCarrier::open(
                    &net,
                    IpAddr::V4(peer_ip),
                    crate::media::wireguard::Direction::Send,
                    crate::media::wireguard::StreamSpec::h264_video(),
                    tunnel.session.path_changes(),
                    impairment,
                )
                .await
                {
                    Ok(carrier) => Some(carrier),
                    Err(error) => {
                        tracing::info!(%error, "no media lane on this tunnel; video stays on the channel");
                        None
                    }
                }
            } else {
                None
            };
            drop(net);
            signaling
                .send_signal(
                    &first.from,
                    &first.session_id,
                    SignalPayload::WgResp {
                        public_key: b64(&own_public),
                        endpoints,
                        overlay_ip: own_ip.to_string(),
                        lanes: super::offered_lanes(options, media.is_some()),
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let stream =
                listener.accept().await.ok_or_else(|| DialError::Transport("tunnel closed".into()))?;
            // The phone's second connection is the input lane.
            let lane = agreed.then(|| {
                let (tx, rx) = oneshot::channel();
                tokio::spawn(async move {
                    if let Ok(Some(stream)) = tokio::time::timeout(LANE_TIMEOUT, listener.accept()).await {
                        let _ = tx.send(Box::new(stream) as Box<dyn super::LinkStream>);
                    } else {
                        tracing::info!("input lane was not opened in time");
                    }
                });
                rx
            });
            Ok(Dialed {
                stream: Box::new(stream),
                path: tunnel.path,
                guard: Box::new(guard),
                lane,
                media: media.map(|carrier| {
                    options.timeline.mark("video_lane");
                    super::PendingMedia::Send(carrier)
                }),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Mac reaches a relay-only phone by plain UDP to the phone's TURN
    /// relayed address: that path is TURN, not direct (hostd logged a
    /// relay-only WireGuard link as `path=Direct`).
    #[test]
    fn udp_to_the_peers_relayed_address_is_a_turn_path() {
        let relayed: SocketAddr = "203.0.113.7:50000".parse().unwrap();
        let lan: SocketAddr = "192.168.1.20:41000".parse().unwrap();
        let peer_relayed: HashSet<SocketAddr> = [relayed].into_iter().collect();
        let udp = |addr| Some(Route { carrier: Carrier::Udp, addr });
        assert_eq!(path_of(udp(relayed), &peer_relayed), LinkPath::Turn);
        assert_eq!(path_of(udp(lan), &peer_relayed), LinkPath::Direct);
        assert_eq!(path_of(Some(Route { carrier: Carrier::Turn, addr: lan }), &peer_relayed), LinkPath::Turn);
        assert_eq!(path_of(None, &peer_relayed), LinkPath::Relay);
        // An older phone lists no relayed addresses: the label stays as before.
        assert_eq!(path_of(udp(relayed), &HashSet::new()), LinkPath::Direct);
    }

    /// What the tunnel's pacer knows decides the relay class, not the size:
    /// a full-size segment of an interactive connection (terminal output)
    /// is input, media is media, and handshakes and keepalives stay control.
    #[test]
    fn relay_classes_follow_the_pacer() {
        use cmux_wg::Priority;
        let data = |len: usize| {
            let mut datagram = vec![0u8; len];
            datagram[0] = 4;
            datagram
        };
        assert_eq!(relay_class_of(&data(1312), Priority::Interactive), RelayClass::Input);
        assert_eq!(relay_class_of(&data(1312), Priority::Media), RelayClass::Media);
        assert_eq!(relay_class_of(&data(1312), Priority::Bulk), RelayClass::Bulk);
        assert_eq!(relay_class_of(&data(96), Priority::Bulk), RelayClass::Bulk);
        assert_eq!(relay_class_of(&data(32), Priority::Media), RelayClass::Control, "keepalive");
        let mut initiation = vec![0u8; 148];
        initiation[0] = 1;
        assert_eq!(relay_class_of(&initiation, Priority::Bulk), RelayClass::Control);
    }
}
