//! `session-udp-v1` (cmux-remote `session_udp`): the UDP route a carrier
//! session moves its links onto, and the daemon half that serves it.
//!
//! The route is three layers, each reused as it ships:
//! - cmux-rd-link's `Net` (the Cloud desktop's datagram link): one ephemeral
//!   UDP socket per side, host and STUN candidates, path probes on every
//!   candidate pair, and Noise_XX with the key each side named in the
//!   session's offer and answer. No listening port: both ends dial out.
//! - cmux-wg over that link: smoltcp TCP, so the session's links are ordered
//!   byte streams, with ultra repair (`dup`, `fec:K:M`) under them, so a lost
//!   datagram is rebuilt instead of waiting out a retransmission.
//! - cmux-remote links on those streams, exactly as on a relay: each runs
//!   the session's own Noise and is admitted by grant or resume, so the route
//!   grants nothing the carrier did not.
//!
//! The session reaches the route with `ClientConnection::reconnect`, a resume
//! that keeps the carrier if the route fails to come up, and falls back to
//! the carrier through its reconnect source when the route dies.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::fd::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use async_trait::async_trait;
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    CarrierEvidence, LengthDelimitedLink, LinkGroup, LinkRequest, ProviderCapabilities,
    ProviderError,
};
use cmux_remote_protocol::{RpcError, SessionUdpAnswer, SessionUdpOffer};
use cmux_wg::{
    InterfaceAddress, IpNetwork, Origin, PathId, Received, UltraMode, Underlay, WgConfig, WgNet,
};
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;
use zeroize::Zeroizing;

/// The repair both ends send in when the offer names none. Keystrokes and
/// echoes are a few packets a second, so a second copy of each costs
/// little and makes a lost one free.
pub(crate) const DEFAULT_REPAIR: &str = "dup";
/// Largest IP packet inside the tunnel: with WireGuard's 32 bytes and the
/// link's seal, a datagram stays under 1200 bytes on the wire.
const TUNNEL_MTU: u16 = 1120;
const TUNNEL_PORT: u16 = 7443;
const DAEMON_ADDR: Ipv4Addr = Ipv4Addr::new(10, 211, 0, 1);
const CLIENT_ADDR: Ipv4Addr = Ipv4Addr::new(10, 211, 0, 2);
/// Datagrams held while the link's handshake runs (WireGuard's first
/// initiation among them); more are dropped oldest first.
const MAX_QUEUED: usize = 64;
const MAX_STUN: usize = 4;
const MAX_CANDIDATES: usize = 16;
/// How long a side gathers its candidates before it sends what it has.
const GATHER: Duration = Duration::from_millis(1500);
/// How long the client waits for the link to answer before it gives up.
pub(crate) const LINK_UP: Duration = Duration::from_secs(6);
/// A link open inside the tunnel that takes longer fails the open.
const OPEN_TIMEOUT: Duration = Duration::from_secs(3);
/// A client route that heard nothing for this long counts as down: the
/// session's heartbeat crosses it every 2 s, and the tunnel's keepalive
/// every [`KEEPALIVE`] s.
const SILENT: Duration = Duration::from_secs(4);
const KEEPALIVE: u16 = 4;
/// Routes one daemon holds at once; a new offer past it closes the oldest.
const MAX_ROUTES: usize = 8;
/// A daemon route with no bytes either way for this long closes (a session
/// on it sends heartbeats, so only an abandoned route goes quiet).
const ROUTE_IDLE: Duration = Duration::from_secs(90);
/// Frames on a route's links: the carrier's own bound (a relay link's), so a
/// session sends the same frames on either.
const MAX_FRAME: usize = 65_535;

/// `CMUX_SESSION_UDP=0` turns the route off on either end; anything else
/// leaves it to the platform's flag (client) or on (daemon).
pub(crate) fn enabled() -> bool {
    std::env::var("CMUX_SESSION_UDP").map_or(true, |value| value != "0")
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(crate) fn unhex32(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 || !text.is_ascii() {
        return None;
    }
    let mut out = [0u8; 32];
    for (index, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|error| io::Error::other(error.to_string()))?;
    Ok(bytes)
}

/// A fresh WireGuard key pair (private, public).
fn wg_keypair() -> io::Result<(Zeroizing<[u8; 32]>, [u8; 32])> {
    let secret = x25519_dalek::StaticSecret::from(random_bytes::<32>()?);
    let public = x25519_dalek::PublicKey::from(&secret).to_bytes();
    Ok((Zeroizing::new(secret.to_bytes()), public))
}

/// The repair mode an offer names, or the default; `None` for a text that
/// is not a mode.
pub(crate) fn repair_mode(text: Option<&str>) -> Option<UltraMode> {
    UltraMode::parse(text.unwrap_or(DEFAULT_REPAIR))
}

/// One side's tunnel: its own address, the peer's, one /32 route each way.
fn tunnel_config(
    private_key: Zeroizing<[u8; 32]>,
    peer_public_key: [u8; 32],
    own: Ipv4Addr,
    peer: Ipv4Addr,
) -> WgConfig {
    WgConfig {
        private_key,
        addresses: vec![InterfaceAddress { address: IpAddr::V4(own), prefix: 32 }],
        mtu: TUNNEL_MTU,
        peer_public_key,
        preshared_key: None,
        allowed_ips: IpNetwork::new_truncate(IpAddr::V4(peer), 32).into_iter().collect(),
        endpoint: None,
        persistent_keepalive: Some(KEEPALIVE),
        peer_addresses: vec![IpAddr::V4(peer)],
        ultra: None,
    }
}

/// STUN servers named `host:port`, resolved to IPv4 (the link binds
/// IPv4). A name that does not resolve in time is left out.
pub(crate) async fn resolve_stun(names: &[String]) -> Vec<SocketAddr> {
    let mut out = Vec::new();
    for name in names.iter().take(MAX_STUN) {
        let lookup = tokio::net::lookup_host(name.as_str());
        if let Ok(Ok(found)) = tokio::time::timeout(Duration::from_secs(2), lookup).await {
            out.extend(found.filter(SocketAddr::is_ipv4).take(1));
        }
    }
    out
}

fn millis_since(epoch: tokio::time::Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The link's driver, shared by the tunnel and its owner. [`Net`] holds a
/// receiver, so it is `Send` but not `Sync`; each call is a channel send.
struct SharedNet(Mutex<Net>);

impl SharedNet {
    fn lock(&self) -> std::sync::MutexGuard<'_, Net> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn event_fd(&self) -> RawFd {
        self.lock().event_fd()
    }

    fn events(&self) -> Vec<NetEvent> {
        self.lock().events()
    }

    fn send_datagram(&self, datagram: Vec<u8>) {
        self.lock().send_datagram(datagram);
    }

    fn add_remote_candidate(&self, candidate: Candidate) {
        self.lock().add_remote_candidate(candidate);
    }

    fn network_changed(&self) {
        self.lock().network_changed();
    }
}

/// What the link tells the side that owns it.
#[derive(Debug)]
enum LinkNews {
    Candidate(Candidate),
    CandidatesDone,
    Up,
    Down(String),
}

/// The link's event pipe, borrowed for readiness; [`Net`] owns it.
struct EventFd(RawFd);

impl AsRawFd for EventFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

/// cmux-wg's carrier over a cmux-rd-link [`Net`]: each WireGuard datagram is
/// one sealed link datagram. Datagrams sent before the link's handshake ends
/// wait (WireGuard's first initiation among them), so the tunnel starts the
/// moment the link does.
struct NetUnderlay {
    // Declared before `net`, so readiness is dropped before the pipe closes.
    events: AsyncFd<EventFd>,
    net: Arc<SharedNet>,
    received: VecDeque<Vec<u8>>,
    queued: VecDeque<Vec<u8>>,
    up: bool,
    failed: Option<String>,
    news: mpsc::UnboundedSender<LinkNews>,
    /// When a datagram last arrived (ms since `epoch`).
    received_at: Arc<AtomicU64>,
    epoch: tokio::time::Instant,
    /// Drops every datagram both ways (tests: a path that went dark).
    dark: Arc<std::sync::atomic::AtomicBool>,
}

impl NetUnderlay {
    fn new(
        net: Arc<SharedNet>,
        news: mpsc::UnboundedSender<LinkNews>,
        received_at: Arc<AtomicU64>,
        epoch: tokio::time::Instant,
        dark: Arc<std::sync::atomic::AtomicBool>,
    ) -> io::Result<Self> {
        let events =
            AsyncFd::with_interest(EventFd(net.event_fd()), tokio::io::Interest::READABLE)?;
        Ok(Self {
            events,
            net,
            received: VecDeque::new(),
            queued: VecDeque::new(),
            up: false,
            failed: None,
            news,
            received_at,
            epoch,
            dark,
        })
    }

    fn drain(&mut self) {
        for event in self.net.events() {
            match event {
                NetEvent::Candidate(candidate) => {
                    let _ = self.news.send(LinkNews::Candidate(candidate));
                }
                NetEvent::CandidatesDone => {
                    let _ = self.news.send(LinkNews::CandidatesDone);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    self.up = true;
                    for datagram in self.queued.drain(..) {
                        self.net.send_datagram(datagram);
                    }
                    let _ = self.news.send(LinkNews::Up);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(_)))
                    if self.dark.load(Ordering::Relaxed) => {}
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram))) => {
                    self.received_at.store(millis_since(self.epoch), Ordering::Relaxed);
                    self.received.push_back(datagram);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    self.fail("the peer closed the link".into());
                }
                NetEvent::Failed(reason) => self.fail(reason),
                NetEvent::Endpoint(_) | NetEvent::RelayFailed { .. } => {}
            }
        }
    }

    fn fail(&mut self, reason: String) {
        if self.failed.is_none() {
            let _ = self.news.send(LinkNews::Down(reason.clone()));
            self.failed = Some(reason);
        }
    }
}

impl Underlay for NetUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        if self.dark.load(Ordering::Relaxed) {
            return;
        }
        if self.up {
            self.net.send_datagram(datagram.to_vec());
        } else {
            if self.queued.len() >= MAX_QUEUED {
                self.queued.pop_front();
            }
            self.queued.push_back(datagram.to_vec());
        }
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        loop {
            if let Some(datagram) = self.received.pop_front() {
                let len = datagram.len().min(buffer.len());
                buffer[..len].copy_from_slice(&datagram[..len]);
                let origin = Origin { path: PathId(0), addr: None };
                return Poll::Ready(Ok(Received { len, origin }));
            }
            if let Some(reason) = &self.failed {
                return Poll::Ready(Err(io::Error::other(reason.clone())));
            }
            let mut ready = match self.events.poll_read_ready(cx) {
                Poll::Ready(Ok(ready)) => ready,
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => return Poll::Pending,
            };
            // Clear first: an event that lands after the drain wakes us again.
            ready.clear_ready();
            self.drain();
        }
    }

    fn has_peer(&self) -> bool {
        true
    }
}

/// A running route: the link, the tunnel on it, and its news.
struct Tunnel {
    net: Arc<SharedNet>,
    wg: Arc<WgNet>,
    news: mpsc::UnboundedReceiver<LinkNews>,
    received_at: Arc<AtomicU64>,
    epoch: tokio::time::Instant,
    dark: Arc<std::sync::atomic::AtomicBool>,
}

#[allow(clippy::too_many_arguments)]
fn start_tunnel(
    role: Role,
    route: &str,
    link: &KeyPair,
    peer_link_key: [u8; 32],
    stun: Vec<SocketAddr>,
    wg_private: Zeroizing<[u8; 32]>,
    peer_wg_key: [u8; 32],
    repair: UltraMode,
) -> io::Result<Tunnel> {
    let net = Net::start(NetConfig {
        role,
        session: route.as_bytes().to_vec(),
        local: link.clone(),
        expected_remote: peer_link_key,
        stun,
        bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        turn: Vec::new(),
        relay_only: false,
    })
    .map_err(|error| io::Error::other(error.to_string()))?;
    let net = Arc::new(SharedNet(Mutex::new(net)));
    let (news_tx, news) = mpsc::unbounded_channel();
    let received_at = Arc::new(AtomicU64::new(0));
    let epoch = tokio::time::Instant::now();
    let dark = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let underlay =
        NetUnderlay::new(net.clone(), news_tx, received_at.clone(), epoch, dark.clone())?;
    let (own, peer) = match role {
        Role::Initiator => (CLIENT_ADDR, DAEMON_ADDR),
        Role::Responder => (DAEMON_ADDR, CLIENT_ADDR),
    };
    let config = tunnel_config(wg_private, peer_wg_key, own, peer);
    let wg = WgNet::start_with_ultra(config, underlay, repair)
        .map_err(|error| io::Error::other(error.to_string()))?;
    Ok(Tunnel { net, wg: Arc::new(wg), news, received_at, epoch, dark })
}

/// The candidates `news` reports within [`GATHER`] (or until it says done).
async fn gather(news: &mut mpsc::UnboundedReceiver<LinkNews>, up: &mut bool) -> Vec<String> {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + GATHER;
    while let Ok(Some(item)) = tokio::time::timeout_at(deadline, news.recv()).await {
        match item {
            LinkNews::Candidate(candidate) if out.len() < MAX_CANDIDATES => {
                out.push(candidate.to_wire());
            }
            LinkNews::CandidatesDone => break,
            LinkNews::Up => *up = true,
            LinkNews::Candidate(_) | LinkNews::Down(_) => {}
        }
    }
    out
}

fn add_candidates(net: &SharedNet, candidates: &[String]) {
    for text in candidates.iter().take(MAX_CANDIDATES) {
        if let Some(candidate) = Candidate::from_wire(text) {
            net.add_remote_candidate(candidate);
        }
    }
}

// ---------------------------------------------------------------------------
// Daemon
// ---------------------------------------------------------------------------

/// Where a daemon route hands each link that arrives on it: the session
/// daemon's accept, as a relay link is.
pub(crate) type Accept = Arc<dyn Fn(Box<dyn FrameLink>) + Send + Sync>;

struct DaemonRoute {
    net: Arc<SharedNet>,
    stop: tokio::sync::watch::Sender<bool>,
    created: u64,
}

/// The daemon's `session-udp-v1` handler: one route per offer, at most
/// [`MAX_ROUTES`], each closed once idle for [`ROUTE_IDLE`].
pub(crate) struct DaemonRoutes {
    accept: Accept,
    routes: Arc<Mutex<HashMap<String, DaemonRoute>>>,
    created: AtomicU64,
}

impl DaemonRoutes {
    pub(crate) fn new(accept: Accept) -> Arc<Self> {
        Arc::new(Self { accept, routes: Arc::default(), created: AtomicU64::new(0) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, DaemonRoute>> {
        self.routes.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    #[cfg(test)]
    pub(crate) fn route_count(&self) -> usize {
        self.lock().len()
    }
}

fn refused(message: impl Into<String>) -> RpcError {
    RpcError::new("invalid-request", message)
}

#[async_trait]
impl cmux_remote::session_udp::SessionUdpHandler for DaemonRoutes {
    async fn offer(&self, offer: SessionUdpOffer) -> Result<SessionUdpAnswer, RpcError> {
        let client_link = unhex32(&offer.link_key).ok_or_else(|| refused("bad link_key"))?;
        let client_wg = unhex32(&offer.wg_key).ok_or_else(|| refused("bad wg_key"))?;
        let repair = repair_mode(offer.repair.as_deref()).ok_or_else(|| refused("bad repair"))?;
        let stun = resolve_stun(&offer.stun).await;
        let route =
            hex(&random_bytes::<16>().map_err(|e| RpcError::new("internal", e.to_string()))?);
        let link = KeyPair::generate().map_err(|e| RpcError::new("internal", e.to_string()))?;
        let (wg_private, wg_public) =
            wg_keypair().map_err(|e| RpcError::new("internal", e.to_string()))?;
        let mut tunnel = start_tunnel(
            Role::Responder,
            &route,
            &link,
            client_link,
            stun,
            wg_private,
            client_wg,
            repair,
        )
        .map_err(|e| RpcError::new("unavailable", format!("udp route: {e}")))?;
        let mut listener = tunnel
            .wg
            .listen(TUNNEL_PORT)
            .await
            .map_err(|e| RpcError::new("unavailable", format!("udp route: {e}")))?;
        let mut up = false;
        let candidates = gather(&mut tunnel.news, &mut up).await;
        let (stop, mut stopped) = tokio::sync::watch::channel(false);
        let created = self.created.fetch_add(1, Ordering::Relaxed);
        {
            let mut routes = self.lock();
            if routes.len() >= MAX_ROUTES
                && let Some(oldest) =
                    routes.iter().min_by_key(|(_, r)| r.created).map(|(id, _)| id.clone())
                && let Some(old) = routes.remove(&oldest)
            {
                let _ = old.stop.send(true);
            }
            routes.insert(route.clone(), DaemonRoute { net: tunnel.net.clone(), stop, created });
        }
        let accept = self.accept.clone();
        let routes = self.routes.clone();
        let id = route.clone();
        let Tunnel { wg, mut news, received_at, epoch, .. } = tunnel;
        tokio::spawn(async move {
            loop {
                // Only what arrives counts: this side's own keepalives go out
                // whether or not anyone is there.
                let idle_ms =
                    millis_since(epoch).saturating_sub(received_at.load(Ordering::Relaxed));
                let idle_left = ROUTE_IDLE.saturating_sub(Duration::from_millis(idle_ms));
                if idle_left.is_zero() {
                    break;
                }
                tokio::select! {
                    accepted = listener.accept() => {
                        let Some(stream) = accepted else { break };
                        let (reader, writer) = tokio::io::split(stream);
                        let link = LengthDelimitedLink::new("session-udp", MAX_FRAME, reader, writer);
                        accept(Box::new(link));
                    }
                    item = news.recv() => match item {
                        Some(LinkNews::Down(_)) | None => break,
                        Some(_) => {}
                    },
                    changed = stopped.changed() => if changed.is_err() || *stopped.borrow() { break },
                    () = tokio::time::sleep(idle_left) => {}
                }
            }
            routes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
            drop(listener);
            if let Ok(wg) = Arc::try_unwrap(wg) {
                wg.shutdown().await;
            }
        });
        Ok(SessionUdpAnswer {
            route,
            link_key: hex(&link.public),
            wg_key: hex(&wg_public),
            candidates,
            tunnel_addr: SocketAddr::new(IpAddr::V4(DAEMON_ADDR), TUNNEL_PORT).to_string(),
        })
    }

    async fn candidates(&self, route: &str, candidates: Vec<String>) -> Result<(), RpcError> {
        let net = self.lock().get(route).map(|r| r.net.clone());
        let net = net.ok_or_else(|| RpcError::new("not-found", "no such udp route"))?;
        add_candidates(&net, &candidates);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// The client's half of an offer, kept until the answer comes.
pub(crate) struct ClientOffer {
    pub(crate) offer: SessionUdpOffer,
    link: KeyPair,
    wg_private: Zeroizing<[u8; 32]>,
    stun: Vec<SocketAddr>,
    repair: UltraMode,
}

impl ClientOffer {
    /// Fresh keys for one route, and the offer that carries their public
    /// halves. `stun` names the STUN servers both ends use.
    pub(crate) async fn new(stun: &[String], repair: Option<&str>) -> io::Result<Self> {
        let repair_text = repair.unwrap_or(DEFAULT_REPAIR).to_owned();
        let repair = repair_mode(Some(&repair_text))
            .ok_or_else(|| io::Error::other(format!("bad repair mode {repair_text}")))?;
        let link = KeyPair::generate().map_err(|e| io::Error::other(e.to_string()))?;
        let (wg_private, wg_public) = wg_keypair()?;
        let names: Vec<String> = stun.iter().take(MAX_STUN).cloned().collect();
        let offer = SessionUdpOffer {
            link_key: hex(&link.public),
            wg_key: hex(&wg_public),
            stun: names.clone(),
            repair: Some(repair_text),
        };
        Ok(Self { offer, link, wg_private, stun: resolve_stun(&names).await, repair })
    }
}

/// A client route started from an answer, not yet known to work.
pub(crate) struct ClientStart {
    tunnel: Tunnel,
    target: SocketAddr,
    route: String,
    up: bool,
}

impl ClientStart {
    /// Start the link and tunnel toward the daemon's half.
    pub(crate) fn new(offer: ClientOffer, answer: &SessionUdpAnswer) -> io::Result<Self> {
        let daemon_link =
            unhex32(&answer.link_key).ok_or_else(|| io::Error::other("bad link_key"))?;
        let daemon_wg = unhex32(&answer.wg_key).ok_or_else(|| io::Error::other("bad wg_key"))?;
        let target: SocketAddr =
            answer.tunnel_addr.parse().map_err(|_| io::Error::other("bad tunnel_addr"))?;
        if target.ip() != IpAddr::V4(DAEMON_ADDR) {
            return Err(io::Error::other("tunnel_addr outside the route"));
        }
        let tunnel = start_tunnel(
            Role::Initiator,
            &answer.route,
            &offer.link,
            daemon_link,
            offer.stun,
            offer.wg_private,
            daemon_wg,
            offer.repair,
        )?;
        add_candidates(&tunnel.net, &answer.candidates);
        Ok(Self { tunnel, target, route: answer.route.clone(), up: false })
    }

    pub(crate) fn route(&self) -> &str {
        &self.route
    }

    /// This side's candidates, for the daemon.
    pub(crate) async fn candidates(&mut self) -> Vec<String> {
        gather(&mut self.tunnel.news, &mut self.up).await
    }

    /// Wait until the link answers (by `deadline`), then hand back the group
    /// the session moves onto.
    pub(crate) async fn established(
        mut self,
        deadline: tokio::time::Instant,
    ) -> io::Result<Arc<UdpLinkGroup>> {
        while !self.up {
            match tokio::time::timeout_at(deadline, self.tunnel.news.recv()).await {
                Ok(Some(LinkNews::Up)) => self.up = true,
                Ok(Some(LinkNews::Down(reason))) => return Err(io::Error::other(reason)),
                Ok(Some(_)) => {}
                Ok(None) => return Err(io::Error::other("the link stopped")),
                Err(_) => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "no udp path answered"));
                }
            }
        }
        let (down_tx, down) = tokio::sync::watch::channel(false);
        let down_tx = Arc::new(down_tx);
        let mut news = self.tunnel.news;
        let watcher = {
            let down_tx = down_tx.clone();
            tokio::spawn(async move {
                while let Some(item) = news.recv().await {
                    if matches!(item, LinkNews::Down(_)) {
                        break;
                    }
                }
                down_tx.send_replace(true);
            })
        };
        Ok(Arc::new(UdpLinkGroup {
            description: format!("session-udp:{}", self.route),
            evidence: CarrierEvidence::Udp { route: self.route },
            wg: self.tunnel.wg,
            net: self.tunnel.net,
            target: self.target,
            down_tx,
            down,
            received_at: self.tunnel.received_at,
            epoch: self.tunnel.epoch,
            dark: self.tunnel.dark,
            watcher,
        }))
    }
}

/// The session's links over a UDP route: each [`LinkGroup::open`] is one TCP
/// stream inside the tunnel.
pub(crate) struct UdpLinkGroup {
    description: String,
    evidence: CarrierEvidence,
    wg: Arc<WgNet>,
    net: Arc<SharedNet>,
    target: SocketAddr,
    down_tx: Arc<tokio::sync::watch::Sender<bool>>,
    down: tokio::sync::watch::Receiver<bool>,
    received_at: Arc<AtomicU64>,
    epoch: tokio::time::Instant,
    dark: Arc<std::sync::atomic::AtomicBool>,
    watcher: tokio::task::JoinHandle<()>,
}

impl UdpLinkGroup {
    /// The link went down (the peer closed it, or it failed), or nothing
    /// came back for [`SILENT`]: a redial goes to the carrier at once
    /// instead of waiting out a tunnel open.
    pub(crate) fn is_down(&self) -> bool {
        *self.down.borrow()
            || millis_since(self.epoch).saturating_sub(self.received_at.load(Ordering::Relaxed))
                > u64::try_from(SILENT.as_millis()).unwrap_or(u64::MAX)
    }

    /// Drop everything this route sends and receives from now on.
    #[cfg(test)]
    pub(crate) fn go_dark(&self) {
        self.dark.store(true, Ordering::Relaxed);
    }

    /// Resolves once the link is down.
    pub(crate) async fn wait_down(&self) {
        let mut down = self.down.clone();
        let _ = down.wait_for(|down| *down).await;
    }

    /// The machine's network changed: probe the link's paths again.
    pub(crate) fn network_changed(&self) {
        self.net.network_changed();
    }
}

impl Drop for UdpLinkGroup {
    fn drop(&mut self) {
        self.watcher.abort();
    }
}

#[async_trait]
impl LinkGroup for UdpLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            parallel_links: true,
            independent_reconnect: true,
            path_migration: true,
            carrier_encryption: true,
        }
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.is_down() {
            return Err(ProviderError::Transport("the udp route is down".into()));
        }
        let stream = tokio::time::timeout(OPEN_TIMEOUT, self.wg.connect(self.target))
            .await
            .map_err(|_| ProviderError::Transport("udp route open timed out".into()))?
            .map_err(|error| ProviderError::Transport(format!("udp route open: {error}")))?;
        let (reader, writer) = tokio::io::split(stream);
        Ok(Box::new(LengthDelimitedLink::new(self.description.clone(), MAX_FRAME, reader, writer)))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.down_tx.send_replace(true);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// The client's upgrade
// ---------------------------------------------------------------------------

/// The carrier answer's `session_udp` field: the platform turned the route
/// on for this machine, with the STUN servers both ends use and, at most,
/// the repair to run. Absent, the session stays on the carrier.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct SessionUdpFlag {
    pub(crate) stun: Vec<String>,
    pub(crate) repair: Option<String>,
}

impl SessionUdpFlag {
    /// `{"stun": ["host:port", …], "repair"?: "dup"}`; `None` for anything
    /// else (an answer without the field among them).
    pub(crate) fn parse(value: Option<&serde_json::Value>) -> Option<Self> {
        let value = value?.as_object()?;
        let stun = match value.get("stun") {
            None | Some(serde_json::Value::Null) => Vec::new(),
            Some(list) => list
                .as_array()?
                .iter()
                .filter_map(|item| item.as_str())
                .filter(|item| !item.is_empty() && item.len() <= 255)
                .take(MAX_STUN)
                .map(str::to_owned)
                .collect(),
        };
        let repair = match value.get("repair") {
            None | Some(serde_json::Value::Null) => None,
            Some(text) => Some(text.as_str().filter(|t| UltraMode::parse(t).is_some())?.to_owned()),
        };
        Some(Self { stun, repair })
    }
}

/// Upgrade attempts one session makes, and the least time between two.
const MAX_ATTEMPTS: u32 = 4;
const RETRY_AFTER: Duration = Duration::from_secs(30);
/// An offer, the candidate exchange and the move, at most.
const ATTEMPT_DEADLINE: Duration = Duration::from_secs(20);

/// Moves `connection` onto a UDP route when the daemon serves one, and back
/// to the carrier (its reconnect source) when the route dies; tries again
/// later, [`MAX_ATTEMPTS`] times in all. Ends with the session. Each step
/// goes to `log` as one `carrier.udp` line.
pub(crate) fn spawn_upgrade(
    connection: Arc<cmux_remote::connection::ClientConnection>,
    multiplexer: Arc<cmux_remote::service::ServiceMultiplexer>,
    flag: SessionUdpFlag,
    log: Arc<dyn Fn(String) + Send + Sync>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut state = connection.subscribe_state();
        let closed = async move {
            let _ =
                state.wait_for(|s| *s == cmux_remote::observability::ConnectionState::Closed).await;
        };
        tokio::select! {
            () = closed => {}
            () = upgrade_loop(&connection, &multiplexer, &flag, &log) => {}
        }
    })
}

fn line(event: &str, detail: &str) -> String {
    serde_json::json!({"event": "carrier.udp", "step": event, "detail": detail}).to_string()
}

async fn upgrade_loop(
    connection: &Arc<cmux_remote::connection::ClientConnection>,
    multiplexer: &Arc<cmux_remote::service::ServiceMultiplexer>,
    flag: &SessionUdpFlag,
    log: &Arc<dyn Fn(String) + Send + Sync>,
) {
    let Ok(workspace) = cmux_remote::client::WorkspaceClient::connect(multiplexer.clone()).await
    else {
        return;
    };
    match workspace.request(cmux_remote_protocol::WorkspaceRequest::Capabilities).await {
        Ok(cmux_remote_protocol::WorkspaceResponse::Capabilities { capabilities })
            if capabilities.contains(&cmux_remote_protocol::RemoteCapability::SessionUdpV1) => {}
        // An older daemon: the carrier is the route. Nothing to log per session.
        _ => return,
    }
    for attempt in 1..=MAX_ATTEMPTS {
        if attempt > 1 {
            tokio::time::sleep(RETRY_AFTER).await;
        }
        let deadline = tokio::time::Instant::now() + ATTEMPT_DEADLINE;
        let moved =
            tokio::time::timeout_at(deadline, attempt_once(connection, &workspace, flag, deadline))
                .await
                .unwrap_or_else(|_| Err("timed out".into()));
        match moved {
            Ok(group) => {
                log(line("up", group.description()));
                group.wait_down().await;
                log(line("down", "back on the carrier"));
            }
            Err(detail) => log(line("failed", &detail)),
        }
    }
}

pub(crate) async fn attempt_once(
    connection: &Arc<cmux_remote::connection::ClientConnection>,
    workspace: &Arc<cmux_remote::client::WorkspaceClient>,
    flag: &SessionUdpFlag,
    deadline: tokio::time::Instant,
) -> Result<Arc<UdpLinkGroup>, String> {
    use cmux_remote_protocol::{WorkspaceRequest, WorkspaceResponse};
    let offer =
        ClientOffer::new(&flag.stun, flag.repair.as_deref()).await.map_err(|e| e.to_string())?;
    let request = WorkspaceRequest::SessionUdpOffer { offer: offer.offer.clone() };
    let answer = match workspace.request(request).await {
        Ok(WorkspaceResponse::SessionUdpAnswer { answer }) => answer,
        Ok(_) => return Err("unexpected answer".into()),
        Err(error) => return Err(format!("offer refused: {}", error.code)),
    };
    let mut start = ClientStart::new(offer, &answer).map_err(|e| e.to_string())?;
    let candidates = start.candidates().await;
    let request =
        WorkspaceRequest::SessionUdpCandidates { route: start.route().to_owned(), candidates };
    match workspace.request(request).await {
        Ok(WorkspaceResponse::SessionUdpCandidatesAdded) => {}
        Ok(_) => return Err("unexpected answer".into()),
        Err(error) => return Err(format!("candidates refused: {}", error.code)),
    }
    let group = start
        .established(deadline.min(tokio::time::Instant::now() + LINK_UP))
        .await
        .map_err(|e| e.to_string())?;
    // A resume onto the route: on failure the carrier stays the route.
    connection.reconnect(group.clone()).await.map_err(|e| format!("move: {e}"))?;
    Ok(group)
}

#[cfg(test)]
#[path = "session_udp_tests.rs"]
mod tests;
