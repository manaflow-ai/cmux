//! WireGuard transport: a per-session userspace tunnel (cmux-wg: boringtun
//! plus smoltcp). Keys, endpoints and overlay addresses travel in
//! `wg-init` / `wg-resp`. Endpoints are the host address and the
//! STUN-discovered reflexive address of the tunnel's UDP socket. Until a UDP
//! datagram from the peer authenticates, every datagram goes through the
//! backend relay and is also sprayed at the peer's endpoints (the hole
//! punch); the first authenticated UDP datagram switches the path to direct.
//! The link is one TCP stream to `overlayIP:7420`.

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
use tokio::time::Instant;
use uuid::Uuid;
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
/// A direct path silent this long while relay datagrams still arrive falls
/// back to the relay.
const DIRECT_STALE: Duration = Duration::from_secs(25);
const STUN_WAIT: Duration = Duration::from_millis(1500);

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
    if options.force_relay {
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

/// Sends one datagram through the backend relay.
type RelaySend = Box<dyn Fn(&[u8]) + Send>;

/// The peer's endpoints this side may use.
fn usable_endpoints(endpoints: &[String], options: &DialOptions) -> Vec<String> {
    if options.force_relay {
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

/// The carrier: one UDP socket for direct paths plus the backend relay.
struct HybridUnderlay {
    socket: UdpSocket,
    candidates: Vec<SocketAddr>,
    direct: Option<SocketAddr>,
    last_direct: Option<Instant>,
    relay_out: RelaySend,
    relay_in: mpsc::UnboundedReceiver<Bytes>,
    path: watch::Sender<LinkPath>,
}

const UDP_PATH: PathId = PathId(0);
const RELAY_PATH: PathId = PathId(1);

impl HybridUnderlay {
    fn send_udp(&self, datagram: &[u8], target: SocketAddr) {
        // A full socket drops the datagram; WireGuard and TCP retransmit.
        if let Err(error) = self.socket.try_send_to(datagram, target)
            && error.kind() != io::ErrorKind::WouldBlock
        {
            tracing::trace!(%error, %target, "UDP send failed");
        }
    }
}

impl Underlay for HybridUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        if let Some(direct) = self.direct {
            self.send_udp(datagram, direct);
            return;
        }
        (self.relay_out)(datagram);
        for candidate in &self.candidates {
            self.send_udp(datagram, *candidate);
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
        match self.relay_in.poll_recv(cx) {
            Poll::Ready(Some(datagram)) => {
                let len = datagram.len().min(buffer.len());
                buffer[..len].copy_from_slice(&datagram[..len]);
                Poll::Ready(Ok(Received { len, origin: Origin { path: RELAY_PATH, addr: None } }))
            }
            Poll::Ready(None) | Poll::Pending => Poll::Pending,
        }
    }

    fn authenticated(&mut self, origin: Origin) {
        let now = Instant::now();
        if origin.path == UDP_PATH
            && let Some(addr) = origin.addr
        {
            self.direct = Some(addr);
            self.last_direct = Some(now);
            self.path.send_if_modified(|path| std::mem::replace(path, LinkPath::Direct) != LinkPath::Direct);
        } else if origin.path == RELAY_PATH {
            if self.last_direct.is_some_and(|last| now.duration_since(last) > DIRECT_STALE) {
                self.direct = None;
                self.last_direct = None;
            }
            if self.direct.is_none() {
                self.path
                    .send_if_modified(|path| std::mem::replace(path, LinkPath::Relay) != LinkPath::Relay);
            }
        }
    }

    fn has_peer(&self) -> bool {
        true
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.direct
    }
}

/// Holds the tunnel and the task that feeds it relay frames.
struct Guard {
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    task: tokio::task::JoinHandle<()>,
    signaling: SignalingClient,
    session_id: String,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.task.abort();
        self.signaling.unsubscribe(&self.session_id);
        self.net.lock().unwrap_or_else(PoisonError::into_inner).take();
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
        candidates: peer_endpoints.iter().filter_map(|text| text.parse().ok()).collect(),
        direct: None,
        last_direct: None,
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
            let endpoints = gather_endpoints(&socket, options).await;
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
                &usable_endpoints(&peer_endpoints, options),
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
                &usable_endpoints(&peer_endpoints, options),
            )?;
            let task = follow(events, &tunnel);
            let guard = Guard {
                net: Arc::clone(&tunnel.net),
                task,
                signaling: signaling.clone(),
                session_id: first.session_id.clone(),
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
