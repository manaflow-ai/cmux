//! The hub carrier: a live, binary, two-way stream between two of one person's own machines
//! through the platform, carrying the acpmux WebSocket so `serve_heard` and its `afterSeq` replay
//! run over it unchanged (carrier audit fix 3). The hub was only a mailbox before (`mesh.rs`):
//! long-polled inbox, text sends, 64 KB reads, no live attach.
//!
//! Nothing here is a second relay or a second handshake. The relay is the Cloud carrier's
//! (cmux `relays/cloudflare-do`, Worker `cmux-remote-relay-<env>`), reached with cmux-remote's
//! relay client ([`RelayProvider`] to dial, [`spawn_relay_daemon_registration`] to serve), and
//! the stream runs cmux-remote's Noise XX handshake ([`initiate_secure_link`],
//! [`accept_secure_link`]) with each machine's node key (`node.wg.key`, whose public half the hub
//! already holds as the machine's `daemonId`). The relay and the platform see ciphertext only.
//!
//! Tickets come from the platform (`POST /v1/mesh/carrier`, cmux-platform `MeshCarrier.ts`) by
//! the machine's `cmm_` credential: a Register ticket for this machine's own slot with the keys
//! of its person's other live machines (`peers`, the only keys the handshake lets in), or a
//! Connect ticket for a peer's slot with the key to pin (`peer_key`). Another person's machine,
//! another team's or a revoked one gets no ticket.
//!
//! - Dial: [`HubCarrier::dial`] returns a [`HubStream`], a duplex byte stream to the peer's
//!   WebSocket listener (its tokens and peer proofs are still checked there, as over WireGuard).
//!   [`HubCarrier::probe`] is the same dial, measured and closed: the probe hook a set of live
//!   paths uses to rank this one.
//! - Serve: [`HubCarrier::serve`] registers this machine's slot and bridges each admitted circuit
//!   to the daemon's loopback WebSocket listener, as `wireguard.rs` bridges WireGuard streams.
//! - Peers: a peer whose config names a WireGuard key reaches it through the carrier too
//!   ([`HubCarrierSlot`]); [`HubCarrier::set_route`] names another.
//!
//! The node key in two protocols. `node.wg.key` is WireGuard's static key and this carrier's
//! Noise XX static key. The acpmux owner allows that reuse on these conditions, and they bind
//! every change here:
//! 1. Both protocols stay BLAKE2s ([`NOISE_PROTOCOL`] and [`WIREGUARD_NOISE_PROTOCOL`] name the
//!    same hash, and the two names keep their transcripts apart). If either suite changes, the
//!    keys split. `tests/hub_carrier.rs` pins it.
//! 2. The key is used only as a Noise static key: no signing, no raw DH and no KDF input
//!    anywhere else.
//! 3. A copied home stays off: `daemon.rs` starts no carrier while the clone check is unsettled
//!    or the home is a copy, and a copy's join credential gets no ticket. A key replaced
//!    (`mesh_node_key::replace_at`) while the carrier runs stops it: its key check
//!    ([`HubCarrier::with_key_check`]) unregisters it and refuses its dials.
//!
//! Load: per machine one relay control socket (the registration, pinged a third of its lease);
//! per live pair one relay circuit (two sockets) and one ticket call per dial. The dialer closes
//! its allocation socket once the circuit is open.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine;
use bytes::Bytes;
use cmux_remote::crypto::{
    AuthGrant, AuthKind, AuthRequest, ClientAuthMode, ClientHandshake, ConnectionAttemptId,
    CryptoError, InboundAuthEvidence, NetworkPeer, ServerAuthenticator, ServiceAuthority,
    StaticIdentity, accept_secure_link, initiate_secure_link, public_key_fingerprint,
};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkRequest, RelayClientConfig, RelayCredentialSource, RelayDaemonConfig,
    RelayDaemonRegistration, RelayIncoming, RelayProvider, TransportProvider,
    spawn_relay_daemon_registration,
};
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use url::Url;
use zeroize::Zeroizing;

/// The carrier's Noise protocol (cmux-remote's handshake).
pub const NOISE_PROTOCOL: &str = cmux_remote::crypto::NOISE_XX_PROTOCOL;
/// WireGuard's Noise protocol (its CONSTRUCTION), whose static key the carrier reuses.
pub const WIREGUARD_NOISE_PROTOCOL: &str = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";

/// The largest relay frame: the Noise record limit, as the Cloud carrier uses.
const MAX_FRAME_BYTES: usize = 65_535;
/// Bytes read from either side before they go out as one record.
const CHUNK_BYTES: usize = 16 * 1024;
/// The duplex buffer between the WebSocket and the carrier pump.
const DUPLEX_BYTES: usize = 64 * 1024;
const DEVICE_NAME: &str = "acpmux";

/// A relay answer from the platform (`POST /v1/mesh/carrier`).
#[derive(Clone, Deserialize)]
pub struct CarrierAnswer {
    /// `relay+do://host` (the Durable Object relay) or `relay+ws://host` (the native one).
    pub relay: String,
    pub slot: String,
    pub ticket: String,
    #[serde(default)]
    pub expires_at: u64,
    /// Connect: the peer's key to pin (standard base64 of 32 bytes).
    #[serde(default)]
    pub peer_key: Option<String>,
    /// Register: the keys this machine lets in.
    #[serde(default)]
    pub peers: Vec<String>,
}

impl std::fmt::Debug for CarrierAnswer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CarrierAnswer")
            .field("relay", &cmux_remote::provider::sanitized_route_text(&self.relay))
            .field("peers", &self.peers.len())
            .finish_non_exhaustive()
    }
}

/// Where the relay tickets come from: the platform in a daemon, a fixed relay in tests.
#[async_trait]
pub trait Tickets: Send + Sync + 'static {
    /// A Register ticket for this machine's own slot, with the keys it lets in.
    async fn register(&self) -> Result<CarrierAnswer, String>;
    /// A Connect ticket for the slot of the machine whose hub `daemonId` is `peer`.
    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String>;
}

/// The carrier's timings.
#[derive(Debug, Clone, Copy)]
pub struct Timings {
    /// One relay control step: register, allocate, join.
    pub control: Duration,
    /// The Noise exchange.
    pub handshake: Duration,
    /// How often a serving carrier checks that its key is still the machine's.
    pub key_check: Duration,
}

impl Default for Timings {
    fn default() -> Self {
        Self {
            control: Duration::from_secs(10),
            handshake: Duration::from_secs(10),
            key_check: Duration::from_secs(30),
        }
    }
}

/// Whether the carrier's key is still the machine's node key (false once it was replaced).
pub type KeyCheck = Arc<dyn Fn(&[u8; 32]) -> bool + Send + Sync>;

/// Counters for the load a carrier puts on the relay (`acpmux peers --json` may show them).
#[derive(Debug, Default)]
pub struct Stats {
    pub dials: AtomicU64,
    pub accepted: AtomicU64,
    /// Plaintext bytes this machine sent and received over the carrier.
    pub sent: AtomicU64,
    pub received: AtomicU64,
    /// Relay records (one Noise record each) both ways.
    pub records: AtomicU64,
}

/// One machine's hub carrier: its key, its ticket source and its peer routes.
pub struct HubCarrier {
    tickets: Arc<dyn Tickets>,
    /// The node key as a Noise static key; [`Self::rekey`] puts the next one in.
    identity: RwLock<StaticIdentity>,
    /// How many times [`Self::rekey`] ran; the serve loop registers again when it moves.
    generation: AtomicU64,
    rekeyed: tokio::sync::Notify,
    routes: Mutex<HashMap<String, String>>,
    /// The keys the last Register ticket let in (`peers`): the machines that reach this one
    /// under its current key.
    allowed: Arc<RwLock<HashSet<[u8; 32]>>>,
    timings: Timings,
    stats: Arc<Stats>,
    key_check: Option<KeyCheck>,
}

impl std::fmt::Debug for HubCarrier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HubCarrier").field("key", &self.identity().fingerprint()).finish()
    }
}

/// The stream a dial returns: bytes to and from the peer's WebSocket listener.
pub type HubStream = tokio::io::DuplexStream;

impl HubCarrier {
    /// A carrier with `private_key` (the node key) as its Noise static key.
    pub fn new(tickets: Arc<dyn Tickets>, private_key: [u8; 32], timings: Timings) -> Arc<Self> {
        Arc::new(Self {
            tickets,
            identity: RwLock::new(StaticIdentity::from_private(private_key)),
            generation: AtomicU64::new(0),
            rekeyed: tokio::sync::Notify::new(),
            routes: Mutex::new(HashMap::new()),
            allowed: Arc::default(),
            timings,
            stats: Arc::default(),
            key_check: None,
        })
    }

    /// The carrier with `check`, asked before every dial and every `timings.key_check` while it
    /// serves: once it says the key is no longer the machine's, dials are refused and the slot
    /// is unregistered (condition 3 in the module doc).
    pub fn with_key_check(
        tickets: Arc<dyn Tickets>,
        private_key: [u8; 32],
        timings: Timings,
        check: KeyCheck,
    ) -> Arc<Self> {
        Arc::new(Self {
            tickets,
            identity: RwLock::new(StaticIdentity::from_private(private_key)),
            generation: AtomicU64::new(0),
            rekeyed: tokio::sync::Notify::new(),
            routes: Mutex::new(HashMap::new()),
            allowed: Arc::default(),
            timings,
            stats: Arc::default(),
            key_check: Some(check),
        })
    }

    /// False once the machine's node key is no longer this carrier's. Checked under the key's
    /// lock, so it never sees a [`Self::rekey`] half done.
    pub fn key_current(&self) -> bool {
        let identity = self.identity.read().unwrap_or_else(|e| e.into_inner());
        self.key_check.as_ref().is_none_or(|check| check(&identity.public_key()))
    }

    /// This carrier's key now.
    fn identity(&self) -> StaticIdentity {
        self.identity.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The node key rotated (`machine_tunnel.rs` rekey): `promote`, which makes `private` the
    /// machine's node key on disk, runs under the lock every key check takes, then `private`
    /// becomes this carrier's key. A check sees the old key in both places or the new key in
    /// both, never one of each, so a rotation never reads as a replaced key; the serve loop
    /// registers the slot again under the new key. A failed `promote` changes nothing.
    pub fn rekey<E>(
        &self,
        private: [u8; 32],
        promote: impl FnOnce() -> Result<(), E>,
    ) -> Result<(), E> {
        let mut identity = self.identity.write().unwrap_or_else(|e| e.into_inner());
        promote()?;
        *identity = StaticIdentity::from_private(private);
        drop(identity);
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.rekeyed.notify_one();
        Ok(())
    }

    /// The keys of the machines the platform's last Register ticket let reach this one
    /// (standard base64, sorted). Empty before the first registration.
    pub fn registered_peers(&self) -> Vec<String> {
        let allowed = self.allowed.read().unwrap_or_else(|e| e.into_inner());
        let mut keys: Vec<String> =
            allowed.iter().map(|k| base64::engine::general_purpose::STANDARD.encode(k)).collect();
        keys.sort();
        keys
    }

    /// This machine's key as the hub knows it (`daemonId`): standard base64.
    pub fn public_key(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.identity().public_key())
    }

    pub fn stats(&self) -> &Stats {
        &self.stats
    }

    /// Reach peer `name` at the machine whose hub `daemonId` is `daemon`.
    pub fn set_route(&self, name: &str, daemon: &str) {
        self.routes.lock().unwrap_or_else(|e| e.into_inner()).insert(name.into(), daemon.into());
    }

    /// The daemon id peer `name` is reached at, when one was named.
    pub fn route(&self, name: &str) -> Option<String> {
        self.routes.lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned()
    }

    /// One live path to `daemon`: a relay circuit with the Noise handshake done, its key pinned
    /// to the platform's `peer_key`, as a byte stream. The caller speaks WebSocket over it.
    pub async fn dial(&self, daemon: &str) -> Result<HubStream, String> {
        if !self.key_current() {
            return Err("the node key was replaced; this carrier is stopped".into());
        }
        let answer = self.tickets.connect(daemon).await?;
        let pinned = key_bytes(answer.peer_key.as_deref().ok_or("the hub named no key to pin")?)
            .ok_or("the hub's peer key is not 32 bytes of base64")?;
        if pinned != key_bytes(daemon).unwrap_or(pinned) {
            return Err("the hub's peer key is not the one asked for".into());
        }
        let endpoint = relay_url(&answer.relay)?;
        // The ticket in hand first; a later relay authentication asks the platform again.
        let first = Arc::new(Mutex::new(Some(Zeroizing::new(answer.ticket.clone()))));
        let tickets = self.tickets.clone();
        let peer = daemon.to_owned();
        let credentials = RelayCredentialSource::callback(move || {
            let first = first.lock().unwrap_or_else(|e| e.into_inner()).take();
            let tickets = tickets.clone();
            let peer = peer.clone();
            async move {
                match first {
                    Some(ticket) => Ok(ticket.to_string()),
                    None => tickets.connect(&peer).await.map(|a| a.ticket),
                }
            }
        });
        let provider = RelayProvider::with_credentials(
            RelayClientConfig {
                slot: answer.slot.clone(),
                ticket: String::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                control_timeout: self.timings.control,
            },
            credentials,
        )
        .map_err(|e| e.to_string())?;
        let session = SessionId(random_16()?);
        let group = provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .map_err(|e| e.to_string())?;
        let opened = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await;
        // The circuit is its own socket: the allocation socket is not needed past this.
        let _ = group.close().await;
        let link = opened.map_err(|e| e.to_string())?;
        let secure = initiate_secure_link(
            link,
            ClientHandshake {
                identity: self.identity(),
                expected_daemon: Some(pinned),
                auth: ClientAuthMode::Enrolled,
                device_name: DEVICE_NAME.into(),
                session,
                lane: Lane::Control,
                lanes: vec![Lane::Control],
                generation: 0,
                connection_attempt: ConnectionAttemptId(random_16()?),
                resume: BTreeMap::new(),
                handshake_timeout: self.timings.handshake,
            },
        )
        .await
        .map_err(|e| e.to_string())?;
        self.stats.dials.fetch_add(1, Ordering::Relaxed);
        let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
        let stats = self.stats.clone();
        tokio::spawn(async move { pump(Box::new(secure), theirs, &stats).await });
        Ok(ours)
    }

    /// The probe hook: a full dial to `daemon` (ticket, relay, handshake), closed at once.
    /// Answers how long it took, the cost a set of live paths ranks this path by.
    pub async fn probe(&self, daemon: &str) -> Result<Duration, String> {
        let started = Instant::now();
        let stream = self.dial(daemon).await?;
        drop(stream);
        Ok(started.elapsed())
    }

    /// Register this machine's slot and bridge every admitted circuit to `websocket`, the
    /// daemon's loopback WebSocket listener. Registration retries on its own while the platform
    /// or the relay is down; dropping the returned handle unregisters.
    pub fn serve(self: &Arc<Self>, websocket: SocketAddr) -> HubServe {
        let me = self.clone();
        let task = tokio::spawn(async move { me.serve_until_dropped(websocket).await });
        HubServe { task }
    }

    /// Serves under the current key; a [`Self::rekey`] ends that registration and starts the
    /// next under the new key. Anything else that ends it (a key replaced outside a rekey, a
    /// relay the ticket names wrongly) ends the carrier.
    async fn serve_until_dropped(self: Arc<Self>, websocket: SocketAddr) {
        loop {
            let generation = self.generation.load(Ordering::SeqCst);
            self.clone().serve_once(websocket, generation).await;
            if self.generation.load(Ordering::SeqCst) == generation {
                return;
            }
            tracing::info!("hub carrier: the node key was rotated; registering again");
        }
    }

    async fn serve_once(self: Arc<Self>, websocket: SocketAddr, generation: u64) {
        let allowed = self.allowed.clone();
        allowed.write().unwrap_or_else(|e| e.into_inner()).clear();
        let mut wait = Duration::from_secs(1);
        // The first answer names the relay and the slot; each later authentication asks again,
        // which also refreshes the keys let in (a revoked machine is out by the next one).
        let answer = loop {
            if !self.key_current() {
                return;
            }
            match self.tickets.register().await {
                Ok(answer) => break answer,
                Err(e) => {
                    tracing::debug!("hub carrier: no register ticket yet: {e}");
                    tokio::time::sleep(wait).await;
                    wait = (wait * 2).min(Duration::from_secs(60));
                }
            }
        };
        let endpoint = match relay_url(&answer.relay) {
            Ok(endpoint) => endpoint,
            Err(e) => {
                tracing::warn!("hub carrier off: {e}");
                return;
            }
        };
        set_allowed(&allowed, &answer.peers);
        let first = Arc::new(Mutex::new(Some(Zeroizing::new(answer.ticket.clone()))));
        let credentials = {
            let tickets = self.tickets.clone();
            let allowed = allowed.clone();
            RelayCredentialSource::callback(move || {
                let first = first.lock().unwrap_or_else(|e| e.into_inner()).take();
                let tickets = tickets.clone();
                let allowed = allowed.clone();
                async move {
                    if let Some(ticket) = first {
                        return Ok(ticket.to_string());
                    }
                    let answer = tickets.register().await?;
                    set_allowed(&allowed, &answer.peers);
                    Ok::<_, String>(answer.ticket)
                }
            })
        };
        let incoming = Arc::new(Incoming { carrier: self.clone(), websocket, allowed });
        let registration = spawn_relay_daemon_registration(
            incoming,
            RelayDaemonConfig {
                endpoint,
                slot: answer.slot,
                ticket: String::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                control_timeout: self.timings.control,
            },
            credentials,
            "acpmux hub carrier",
        );
        let registration: RelayDaemonRegistration = match registration {
            Ok(registration) => registration,
            Err(e) => {
                tracing::warn!("hub carrier off: {e}");
                return;
            }
        };
        tracing::info!("hub carrier: serving on the relay as {}", self.identity().fingerprint());
        // Held until this task is aborted ([`HubServe`]'s drop) or the key is replaced, which
        // drops it and unregisters.
        let _registration = registration;
        let mut every = tokio::time::interval(self.timings.key_check);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = every.tick() => {}
                () = self.rekeyed.notified() => {}
            }
            if self.generation.load(Ordering::SeqCst) != generation {
                return;
            }
            if !self.key_current() {
                tracing::warn!("hub carrier: the node key was replaced; unregistering");
                return;
            }
        }
    }
}

/// The running registration of [`HubCarrier::serve`]. Dropping it unregisters.
pub struct HubServe {
    task: tokio::task::JoinHandle<()>,
}

impl HubServe {
    /// True once the registration stopped for good (its key was replaced).
    pub fn is_finished(&self) -> bool {
        self.task.is_finished()
    }
}

impl Drop for HubServe {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Where a peer finds its hub carrier: the daemon's one carrier, set once it starts (peers
/// start before it, `hub/mod.rs` `build`), and whether one is expected at all.
#[derive(Clone, Default)]
pub struct HubCarrierSlot(Arc<OnceLock<Arc<HubCarrier>>>, bool);

impl HubCarrierSlot {
    /// A slot for a daemon whose startup may run the carrier: one with the joined machine
    /// credential (`meshRelay.credential: "join"`) whose WireGuard transport holds the key lock
    /// ([`start_configured`] runs only on that lock).
    pub fn for_daemon(
        config: &crate::config::Config,
        wireguard: Option<&Arc<crate::wireguard::Transport>>,
    ) -> Self {
        let joined = config
            .mesh_relay
            .as_ref()
            .is_some_and(|relay| relay.credential.as_deref() == Some("join"));
        let held = wireguard.is_some_and(|transport| transport.key_holder().is_some());
        Self(Arc::default(), joined && held)
    }

    /// Whether the carrier runs or this daemon's startup may start it.
    pub fn expected(&self) -> bool {
        self.1 || self.0.get().is_some()
    }

    pub fn set(&self, carrier: Arc<HubCarrier>) -> bool {
        self.0.set(carrier).is_ok()
    }

    pub fn get(&self) -> Option<&Arc<HubCarrier>> {
        self.0.get()
    }
}

/// The keys a circuit may come from: this person's other live machines, per the platform.
struct PeerKeys(HashSet<[u8; 32]>);

#[async_trait]
impl ServerAuthenticator for PeerKeys {
    async fn invitation_secret(&self, _id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        Ok(None)
    }

    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
        if request.mode != AuthKind::Enrolled {
            return Err("the hub carrier takes a machine key only".into());
        }
        if !self.0.contains(&request.device_public_key) {
            return Err("not one of this person's machines".into());
        }
        Ok(AuthGrant {
            device_id: public_key_fingerprint(&request.device_public_key),
            daemon_name: DEVICE_NAME.into(),
            revocation_generation: 0,
            authority: ServiceAuthority::none(),
        })
    }
}

struct Incoming {
    carrier: Arc<HubCarrier>,
    websocket: SocketAddr,
    allowed: Arc<RwLock<HashSet<[u8; 32]>>>,
}

#[async_trait]
impl RelayIncoming for Incoming {
    async fn incoming(self: Arc<Self>, link: Box<dyn FrameLink>) {
        let keys = PeerKeys(self.allowed.read().unwrap_or_else(|e| e.into_inner()).clone());
        let identity = self.carrier.identity();
        let accepted = tokio::time::timeout(
            self.carrier.timings.handshake,
            accept_secure_link(
                link,
                &identity,
                &keys,
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            ),
        )
        .await;
        let accepted = match accepted {
            Ok(Ok(accepted)) => accepted,
            Ok(Err(e)) => {
                tracing::debug!("hub carrier: a circuit was refused: {e}");
                return;
            }
            Err(_) => return,
        };
        let Ok(local) = tokio::net::TcpStream::connect(self.websocket).await else {
            let _ = accepted.link.close().await;
            return;
        };
        let _ = local.set_nodelay(true);
        self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
        pump(Box::new(accepted.link), local, &self.carrier.stats).await;
    }
}

/// Carry bytes between `io` and the Noise link until either side ends, then close both.
async fn pump<S>(link: Box<dyn FrameLink>, io: S, stats: &Stats)
where
    S: AsyncRead + AsyncWrite + Send + Unpin,
{
    let link: Arc<dyn FrameLink> = Arc::from(link);
    let (mut read, mut write) = tokio::io::split(io);
    let chunk = link.maximum_frame_bytes().clamp(1, CHUNK_BYTES);
    let up = async {
        let mut buf = vec![0u8; chunk];
        loop {
            let n = read.read(&mut buf).await.map_err(|e| e.to_string())?;
            if n == 0 {
                return Ok::<_, String>(());
            }
            link.send(Bytes::copy_from_slice(&buf[..n])).await.map_err(|e| e.to_string())?;
            stats.sent.fetch_add(n as u64, Ordering::Relaxed);
            stats.records.fetch_add(1, Ordering::Relaxed);
        }
    };
    let down = async {
        while let Some(frame) = link.receive().await.map_err(|e| e.to_string())? {
            write.write_all(&frame).await.map_err(|e| e.to_string())?;
            stats.received.fetch_add(frame.len() as u64, Ordering::Relaxed);
            stats.records.fetch_add(1, Ordering::Relaxed);
        }
        Ok::<_, String>(())
    };
    tokio::select! {
        _ = up => {}
        _ = down => {}
    }
    let _ = write.shutdown().await;
    let _ = link.close().await;
}

fn set_allowed(allowed: &RwLock<HashSet<[u8; 32]>>, peers: &[String]) {
    let keys = peers.iter().filter_map(|k| key_bytes(k)).collect();
    *allowed.write().unwrap_or_else(|e| e.into_inner()) = keys;
}

/// A 32-byte key in standard or URL-safe base64.
fn key_bytes(text: &str) -> Option<[u8; 32]> {
    use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
    let bytes = STANDARD.decode(text).or_else(|_| URL_SAFE_NO_PAD.decode(text)).ok()?;
    bytes.try_into().ok()
}

fn relay_url(relay: &str) -> Result<Url, String> {
    let url = Url::parse(relay).map_err(|_| "the hub named no relay".to_owned())?;
    match url.scheme() {
        "relay+do" | "relay+wss" | "relay+https" => Ok(url),
        // A plain relay only on this machine (tests, a local relay).
        "relay+ws"
            if url.host_str().is_some_and(|h| {
                h == "localhost" || h.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
            }) =>
        {
            Ok(url)
        }
        _ => Err("the hub named a relay this carrier does not dial".into()),
    }
}

fn random_16() -> Result<[u8; 16], String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
    Ok(bytes)
}

/// The platform's tickets, by this machine's `cmm_` credential, through the mesh hub's client.
pub(crate) struct PlatformTickets {
    hub: crate::mesh_http::HttpHub,
}

#[async_trait]
impl Tickets for PlatformTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        self.hub.carrier(None).await
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.hub.carrier(Some(peer)).await
    }
}

/// The node key, read only under the WireGuard key lock (`cmux_link::key_holder`) that this daemon's
/// WireGuard transport already holds. The carrier never takes the lock itself: on a Mac the cmux
/// link is the one key holder, and a carrier holding the lock would refuse the link's
/// `cmux link ensure` (`key_held`) for as long as the daemon runs.
fn node_key(
    state_dir: &std::path::Path,
    held: Arc<cmux_link::key_holder::KeyHolder>,
) -> Result<(Arc<cmux_link::key_holder::KeyHolder>, zeroize::Zeroizing<[u8; 32]>), String> {
    let (_, private) = crate::cli::mesh_node_key::load_or_create_held(state_dir, &held)
        .map_err(|e| format!("no node key: {e:#}"))?;
    Ok((held, private))
}

/// The daemon's hub carrier: on when config.json names a mesh hub with the joined machine
/// credential (`meshRelay.credential: "join"`), this home is not a copy, and the daemon's WireGuard
/// transport hands it the key lock it holds (`held`). Without that lock it stays off and peers go on
/// over ssh and the relay. It serves at once; peers find it through `hub.hub_carrier`.
pub async fn start_configured(
    hub: &Arc<crate::hub::Hub>,
    state_dir: &std::path::Path,
    websocket: Option<SocketAddr>,
    held: Option<Arc<cmux_link::key_holder::KeyHolder>>,
) -> Option<HubServe> {
    let config = hub.config.read().await.mesh_relay.clone()?;
    if config.credential.as_deref() != Some("join") {
        return None;
    }
    let Some(held) = held else {
        tracing::info!(
            "hub carrier off: the WireGuard key is owned by the link/no transport (transport.wireguard is off)"
        );
        return None;
    };
    // Only this daemon's loopback listener, whose tokens stay mandatory, as WireGuard's bridge.
    let websocket = match crate::wireguard::local_websocket(websocket?) {
        Ok(websocket) => websocket,
        Err(e) => {
            tracing::warn!("hub carrier off: {e:#}");
            return None;
        }
    };
    let client = match crate::mesh_http::HttpHub::new(&config) {
        Ok(client) => client,
        Err(e) => {
            tracing::warn!("hub carrier off: {e}");
            return None;
        }
    };
    let (holder, private) = match node_key(state_dir, held) {
        Ok(key) => key,
        Err(why) => {
            tracing::warn!("hub carrier off: {why}");
            return None;
        }
    };
    // A copy of another machine's home never serves (condition 3), whatever its credential.
    let copied_home = state_dir.to_path_buf();
    if tokio::task::spawn_blocking(move || {
        crate::cli::cloud_join::copied_from_another_box_at(&copied_home)
    })
    .await
    .unwrap_or(true)
    {
        tracing::warn!("hub carrier off: this home was copied from another machine");
        return None;
    }
    let home = state_dir.to_path_buf();
    // The carrier runs only while the transport holds the lock: it keeps no share of it, so a
    // transport that yields to the cmux link (`Transport::yield_to_link`) frees the key at once,
    // and from then the check fails: the carrier unregisters and refuses its dials.
    let holder = Arc::downgrade(&holder);
    let check: KeyCheck = Arc::new(move |public: &[u8; 32]| {
        holder.upgrade().is_some()
            && crate::cli::mesh_node_key::public_key_at(&home).is_some_and(|now| now == *public)
    });
    let carrier = HubCarrier::with_key_check(
        Arc::new(PlatformTickets { hub: client }),
        *private,
        Timings::default(),
        check,
    );
    hub.hub_carrier.set(carrier.clone());
    Some(carrier.serve(websocket))
}

#[cfg(test)]
mod key_lock_tests {
    use super::*;
    use cmux_link::key_holder::KeyHolder;

    fn joined_hub(home: &std::path::Path) -> Arc<crate::hub::Hub> {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        config.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
            url: "http://127.0.0.1:9".into(),
            token_command: vec!["must-not-run".into()],
            team_messaging: true,
            credential: Some("join".into()),
            control_from: Vec::new(),
        });
        let store = crate::store::open(&config.store, home).unwrap();
        crate::hub::Hub::new(config, store)
    }

    /// With transport.wireguard off, a joined daemon's carrier takes no lock and reads no key, so
    /// the link can take the lock while the daemon runs.
    #[tokio::test]
    async fn without_the_transports_lock_the_carrier_takes_none() {
        let home = tempfile::tempdir().unwrap();
        let hub = joined_hub(home.path());
        let websocket = Some("127.0.0.1:1".parse().unwrap());
        assert!(start_configured(&hub, home.path(), websocket, None).await.is_none());
        let link = KeyHolder::acquire(home.path());
        assert!(link.is_ok(), "the carrier kept the lock: {:?}", link.err());
        assert!(
            !home.path().join(cmux_link::key_holder::KeyFile::Node.file_name()).exists(),
            "a key was read"
        );
    }

    /// Given the transport's holder, the carrier reads the key under that same lock, and the lock
    /// is free once both drop.
    #[test]
    fn with_the_transports_lock_the_carrier_reads_the_key() {
        let home = tempfile::tempdir().unwrap();
        let shared = Arc::new(KeyHolder::acquire(home.path()).unwrap());
        let (holder, private) = node_key(home.path(), shared.clone()).unwrap();
        assert!(Arc::ptr_eq(&holder, &shared));
        let public = crate::cli::mesh_node_key::public_key_at(home.path()).unwrap();
        assert_eq!(
            public,
            x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(*private)).to_bytes()
        );
        drop((holder, shared));
        assert!(KeyHolder::acquire(home.path()).is_ok(), "the lock outlived its holders");
    }
}
