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
//! - Services: a circuit reaches the acpmux listener unless its first record names another
//!   service ([`CircuitService`]). [`CircuitService::CmuxTui`] reaches the machine's cmux-tui
//!   remote daemon on loopback (`cmux remote exec|cp|connect --via-machine`), only while the
//!   machine's owner named that daemon and granted control ([`CmuxTuiGate`],
//!   `cmux_tui_service.rs`). The remote protocol's own Noise handshake and device enrollment run
//!   inside the circuit: the carrier proves which machine dialed, never who may run commands.
//!   [`CircuitService::CmuxTuiSession`] reaches the machine's own cmux-tui session daemon (its
//!   app's, a unix socket), so another of the person's machines opens a workspace there; only
//!   while the person on that machine granted "control for my other machines signed in to this
//!   account" ([`SessionGate`], `session_service.rs`), refused by default.
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
//! The carrier needs the node key and nothing else of WireGuard: not acpmux's WireGuard transport
//! (`transport.wireguard`), its static endpoints (`wireguardStatic`) or any Labs switch. It reads
//! the key only under this machine's key lock (`cmux_link::key_holder`): the transport's, when
//! the transport runs, else its own ([`KeyLease`]), taken only where no cmux link serves this
//! home's node key and handed to the link once one does, the rule the transport follows
//! (`mesh_node_key::link_serves_node_key`). The lock exists because a key carries one live
//! WireGuard session per peer, so the link (or the transport) stays the one holder of the key's
//! session. Where the link holds the lock the carrier takes none and reads the key through
//! `key_holder::open_for_noise_static`: it opens no WireGuard session, only the Noise XX static
//! key of condition 2, so the key still has one session holder and the machine stays reachable
//! (`cmux remote exec --via-machine`) with the app's link running. A key the link then replaces
//! stops the carrier, as any replaced key does (condition 3).
//!
//! Load: per machine one relay control socket (the registration, pinged a third of its lease);
//! per live pair one relay circuit (two sockets) and one ticket call per dial. The dialer closes
//! its allocation socket once the circuit is open.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
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

use crate::protocol::peer_state::OfflineReason;
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

/// What a circuit reaches on the machine it was dialed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitService {
    /// The acpmux daemon's loopback WebSocket listener. A circuit whose first record names no
    /// service is this one's, as every circuit was before services had names.
    Acpmux,
    /// The machine's cmux-tui remote daemon, its WebSocket listener on loopback `port`.
    CmuxTui { port: u16 },
    /// The machine's own cmux-tui session daemon, the one its app shows (`CMUX_TUI_SOCKET`): a
    /// workspace and its terminals opened from another of the person's machines. Hello
    /// `{"service":"cmux-tui","target":"session"}`. Reached only while the person granted
    /// "control for my other machines signed in to this account" on that machine
    /// ([`SessionGate`], `cmux_tui_service.rs`); refused by default.
    CmuxTuiSession,
    /// Calls this machine's acpmux daemon runs for another of the person's machines, one JSON
    /// line each way per call (`machine_call_service.rs`): Computer Use here for an agent whose
    /// loop runs on that machine. Hello `{"service":"machine-call"}`. Reached only while the
    /// person granted "control for my other machines signed in to this account" on this machine
    /// ([`MachineCallGate`]); refused by default.
    MachineCall,
}

/// The service name a hello gives [`CircuitService::MachineCall`].
pub const MACHINE_CALL_SERVICE: &str = "machine-call";

/// The `target` a hello gives [`CircuitService::CmuxTuiSession`].
pub const SESSION_TARGET: &str = "session";

/// The first bytes of a record that names a circuit's service. A WebSocket upgrade (the acpmux
/// service's first bytes) never starts with NUL.
pub const SERVICE_HELLO: &[u8] = b"\0cmux-circuit/1\n";
/// The service name a hello gives [`CircuitService::CmuxTui`].
pub const CMUX_TUI_SERVICE: &str = "cmux-tui";
/// The longest hello or answer record.
const MAX_HELLO_BYTES: usize = 1024;

/// Why a machine refused a circuit's service: a `reason` code the dialer can act on and a line
/// for the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceRefusal {
    pub reason: String,
    pub message: String,
}

impl ServiceRefusal {
    pub fn new(reason: &str, message: impl Into<String>) -> Self {
        Self { reason: reason.to_owned(), message: message.into() }
    }
}

impl std::fmt::Display for ServiceRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.message, self.reason)
    }
}

/// Whether this machine lets a circuit reach its cmux-tui remote daemon, and where it listens.
#[async_trait]
pub trait CmuxTuiGate: Send + Sync + 'static {
    /// The loopback address a circuit that asked for `port` reaches, or why it may not.
    async fn admit(&self, port: u16) -> Result<SocketAddr, ServiceRefusal>;
}

/// Whether this machine lets a circuit reach its own cmux-tui session daemon
/// ([`CircuitService::CmuxTuiSession`]), and the unix socket it listens on.
#[async_trait]
pub trait SessionGate: Send + Sync + 'static {
    /// The socket a circuit from the machine whose hub `daemonId` is `from` reaches, or why it
    /// may not. `from` is the dialer's key as the Noise handshake proved it.
    async fn admit(&self, from: &str) -> Result<std::path::PathBuf, ServiceRefusal>;
}

/// Whether this machine runs calls for another of the person's machines
/// ([`CircuitService::MachineCall`]), and the stream its handler answers on.
#[async_trait]
pub trait MachineCallGate: Send + Sync + 'static {
    /// This machine's end of the circuit, its handler already reading the other end, for a
    /// circuit from the machine whose hub `daemonId` is `from` (as the Noise handshake proved
    /// it), or why it may not.
    async fn open(&self, from: &str) -> Result<HubStream, ServiceRefusal>;
}

/// The hello record of `service`; None for the acpmux listener, whose circuits send none.
fn service_hello(service: CircuitService) -> Option<Bytes> {
    let body = match service {
        CircuitService::Acpmux => return None,
        CircuitService::CmuxTui { port } => {
            serde_json::json!({"service": CMUX_TUI_SERVICE, "port": port})
        }
        CircuitService::CmuxTuiSession => {
            serde_json::json!({"service": CMUX_TUI_SERVICE, "target": SESSION_TARGET})
        }
        CircuitService::MachineCall => serde_json::json!({"service": MACHINE_CALL_SERVICE}),
    };
    let mut record = SERVICE_HELLO.to_vec();
    record.extend_from_slice(body.to_string().as_bytes());
    Some(Bytes::from(record))
}

/// The service a circuit's first record names: None when it names none (the acpmux listener's
/// bytes), else the service or why the hello does not parse.
fn named_service(first: &[u8]) -> Option<Result<CircuitService, ServiceRefusal>> {
    let body = first.strip_prefix(SERVICE_HELLO)?;
    let unknown = || {
        ServiceRefusal::new("service.unknown", "the circuit named no service this machine serves")
    };
    if first.len() > MAX_HELLO_BYTES {
        return Some(Err(unknown()));
    }
    let Ok(hello) = serde_json::from_slice::<serde_json::Value>(body) else {
        return Some(Err(unknown()));
    };
    let port =
        hello.get("port").and_then(serde_json::Value::as_u64).and_then(|p| u16::try_from(p).ok());
    let target = hello.get("target").and_then(serde_json::Value::as_str);
    Some(match (hello.get("service").and_then(serde_json::Value::as_str), port, target) {
        (Some(CMUX_TUI_SERVICE), Some(port), None) if port != 0 => {
            Ok(CircuitService::CmuxTui { port })
        }
        (Some(CMUX_TUI_SERVICE), None, Some(SESSION_TARGET)) if hello.get("port").is_none() => {
            Ok(CircuitService::CmuxTuiSession)
        }
        (Some(MACHINE_CALL_SERVICE), None, None) if hello.get("port").is_none() => {
            Ok(CircuitService::MachineCall)
        }
        _ => Err(unknown()),
    })
}

/// The answer record to a hello: `{"ok":true}`, or the refusal.
fn service_answer(answer: &Result<(), ServiceRefusal>) -> Bytes {
    let value = match answer {
        Ok(()) => serde_json::json!({"ok": true}),
        Err(refusal) => serde_json::json!({
            "ok": false, "reason": refusal.reason, "error": refusal.message,
        }),
    };
    Bytes::from(value.to_string())
}

/// The far end's answer record, read back.
fn read_service_answer(record: &[u8]) -> Result<(), ServiceRefusal> {
    let bad = || ServiceRefusal::new("service.bad_answer", "the machine sent no service answer");
    if record.len() > MAX_HELLO_BYTES {
        return Err(bad());
    }
    let value: serde_json::Value = serde_json::from_slice(record).map_err(|_| bad())?;
    if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return Ok(());
    }
    let text = |key: &str| value.get(key).and_then(serde_json::Value::as_str).map(str::to_owned);
    Err(ServiceRefusal {
        reason: text("reason").ok_or_else(bad)?,
        message: text("error").unwrap_or_else(|| "the machine refused the service".into()),
    })
}

/// Where the relay tickets come from: the platform in a daemon, a fixed relay in tests.
#[async_trait]
pub trait Tickets: Send + Sync + 'static {
    /// A Register ticket for this machine's own slot, with the keys it lets in.
    async fn register(&self) -> Result<CarrierAnswer, String>;
    /// A Connect ticket for the slot of the machine whose hub `daemonId` is `peer`.
    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String>;
    /// What a log may say of where the tickets come from: the hub's origin, never a token.
    fn shown(&self) -> String {
        "the hub".into()
    }
}

/// The longest wait between two register asks; the wait doubles from 1 s up to it.
const REGISTER_WAIT_MAX: Duration = Duration::from_secs(60);

/// How often the register loop says at info that the hub still refuses, after its first warn.
/// By time, not by attempt count: one ask can take from milliseconds (a refusal) to the hub
/// client's 30 s call bound (a hub that does not answer), so a count would say nothing of when
/// the next line comes. At the 60 s backoff cap this is about one line per 8 to 10 asks, six an
/// hour, which keeps a day of refusals readable and the current state never older than 10 min.
const REFUSAL_SAID_EVERY: Duration = Duration::from_secs(600);

/// The carrier's timings.
#[derive(Debug, Clone, Copy)]
pub struct Timings {
    /// One relay control step: register, allocate, join.
    pub control: Duration,
    /// The Noise exchange.
    pub handshake: Duration,
    /// How often a serving carrier checks that its key is still the machine's.
    pub key_check: Duration,
    /// How long a dial waits for the far machine to join the circuit it allocated. A carrier
    /// that serves answers in well under a second; past this the machine's carrier is taken as
    /// not serving, and the dial says so rather than leave the caller on its own timeout.
    pub peer_join: Duration,
    /// How often a kept circuit (`hub_carrier_mux.rs`) pings the far machine; two periods with
    /// nothing heard close it.
    pub keepalive: Duration,
    /// How long a kept circuit with no stream stays open.
    pub kept_idle: Duration,
}

impl Default for Timings {
    fn default() -> Self {
        Self {
            control: Duration::from_secs(10),
            handshake: Duration::from_secs(10),
            key_check: Duration::from_secs(30),
            peer_join: Duration::from_secs(6),
            keepalive: Duration::from_secs(30),
            // The relay drops a circuit idle 10 min (`relays/cloudflare-do/src/abuse.rs`); the
            // keepalive keeps it busy, and this lets go of a machine nobody dialed in that long.
            kept_idle: Duration::from_secs(600),
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
    /// Dials that rode a kept circuit as a new stream (`hub_carrier_mux.rs`), not a new circuit.
    pub kept_opens: AtomicU64,
    /// Kept circuits opened.
    pub kept_circuits: AtomicU64,
}

/// Where a new circuit's time went, step by step (`RUST_LOG=acpmux::hub_carrier=debug` logs it
/// for every dial).
#[derive(Debug, Clone, Copy, Default)]
pub struct DialStages {
    /// The platform's Connect ticket (`POST /v1/mesh/carrier`).
    pub ticket: Duration,
    /// The relay's allocation socket: TCP, TLS, the WebSocket upgrade and the allocate answer.
    pub relay: Duration,
    /// The far machine joining the circuit (its registration hears of it and opens its socket).
    pub peer_join: Duration,
    /// Noise XX, the far machine's accept included.
    pub noise: Duration,
    /// The service hello and its answer (the far machine's admission included).
    pub answer: Duration,
}

impl DialStages {
    pub fn total(&self) -> Duration {
        self.ticket + self.relay + self.peer_join + self.noise + self.answer
    }

    fn log(&self, daemon: &str, kind: &str) {
        let ms = |d: Duration| d.as_secs_f64() * 1e3;
        tracing::debug!(
            machine = %daemon.get(..8).unwrap_or(daemon),
            kind,
            ticket_ms = ms(self.ticket),
            relay_ms = ms(self.relay),
            peer_join_ms = ms(self.peer_join),
            noise_ms = ms(self.noise),
            answer_ms = ms(self.answer),
            total_ms = ms(self.total()),
            "hub carrier: a circuit opened"
        );
    }
}

/// How a dial on the kept circuit went.
enum KeptOpen {
    Stream(HubStream),
    /// The far machine refused the service: the dial's answer.
    Refused(ServiceRefusal),
    /// The circuit could not open at all (no ticket, not serving): a plain dial fares no better.
    Failed(String),
    /// No kept circuit for this one: take a plain circuit.
    Plain(String),
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
    /// Whether a circuit may reach this machine's cmux-tui remote daemon; none refuses it.
    cmux_tui: RwLock<Option<Arc<dyn CmuxTuiGate>>>,
    /// Whether a circuit may reach this machine's own cmux-tui session daemon; none refuses it.
    session: RwLock<Option<Arc<dyn SessionGate>>>,
    /// Who may have this machine run calls for them; None refuses every such circuit.
    machine_call: RwLock<Option<Arc<dyn MachineCallGate>>>,
    /// Why this machine's own registration cannot heal by retrying alone, while it cannot
    /// (`credential-unavailable`: no Register ticket comes). [`Self::serve_reason`].
    serve_reason: RwLock<Option<OfflineReason>>,
    /// One kept, multiplexed circuit per machine this carrier dialed a named service on.
    kept: mux::KeptCircuits,
    /// Held while the carrier lives: a kept circuit's keepalive closes it once this is gone.
    alive: Arc<()>,
    /// Whether this machine serves kept circuits; off only to stand in for an acpmux that
    /// predates them ([`Self::serve_kept_circuits`]).
    serves_kept: std::sync::atomic::AtomicBool,
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
            cmux_tui: RwLock::new(None),
            session: RwLock::new(None),
            machine_call: RwLock::new(None),
            serve_reason: RwLock::new(None),
            kept: mux::KeptCircuits::default(),
            alive: Arc::new(()),
            serves_kept: std::sync::atomic::AtomicBool::new(true),
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
            cmux_tui: RwLock::new(None),
            session: RwLock::new(None),
            machine_call: RwLock::new(None),
            serve_reason: RwLock::new(None),
            kept: mux::KeptCircuits::default(),
            alive: Arc::new(()),
            serves_kept: std::sync::atomic::AtomicBool::new(true),
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
        // The far machines pinned the old key: its kept circuits go with it.
        self.kept.clear();
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

    /// Let circuits reach this machine's cmux-tui remote daemon as `gate` decides.
    pub fn set_cmux_tui_gate(&self, gate: Arc<dyn CmuxTuiGate>) {
        *self.cmux_tui.write().unwrap_or_else(|e| e.into_inner()) = Some(gate);
    }

    fn cmux_tui_gate(&self) -> Option<Arc<dyn CmuxTuiGate>> {
        self.cmux_tui.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Let circuits reach this machine's own cmux-tui session daemon as `gate` decides.
    pub fn set_session_gate(&self, gate: Arc<dyn SessionGate>) {
        *self.session.write().unwrap_or_else(|e| e.into_inner()) = Some(gate);
    }

    fn session_gate(&self) -> Option<Arc<dyn SessionGate>> {
        self.session.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Let this machine run calls for the person's other machines as `gate` decides.
    pub fn set_machine_call_gate(&self, gate: Arc<dyn MachineCallGate>) {
        *self.machine_call.write().unwrap_or_else(|e| e.into_inner()) = Some(gate);
    }

    fn machine_call_gate(&self) -> Option<Arc<dyn MachineCallGate>> {
        self.machine_call.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// One live path to `daemon`: a relay circuit with the Noise handshake done, its key pinned
    /// to the platform's `peer_key`, as a byte stream. The caller speaks WebSocket over it.
    pub async fn dial(&self, daemon: &str) -> Result<HubStream, String> {
        self.dial_service(daemon, CircuitService::Acpmux).await
    }

    /// [`Self::dial`] to `service` on that machine. A service other than the acpmux listener is
    /// named in the circuit's first record, and the dial returns once the machine answered that
    /// it reached it (or fails with its refusal). A named service rides the machine's kept
    /// circuit as a new stream when the machine serves one (`hub_carrier_mux.rs`): one relay
    /// round trip once the circuit is open, else a plain circuit of its own.
    pub async fn dial_service(
        &self,
        daemon: &str,
        service: CircuitService,
    ) -> Result<HubStream, String> {
        if !self.key_current() {
            return Err("the node key was replaced; this carrier is stopped".into());
        }
        let Some(hello) = service_hello(service) else {
            let (secure, stages) = self.open_circuit(daemon).await?;
            stages.log(daemon, "plain");
            return Ok(self.carry_plain(secure));
        };
        match self.kept_open(daemon, hello.clone()).await {
            KeptOpen::Stream(stream) => return Ok(stream),
            KeptOpen::Refused(refusal) => return Err(refusal.to_string()),
            KeptOpen::Failed(e) => return Err(e),
            KeptOpen::Plain(why) => {
                tracing::debug!("hub carrier: a plain circuit for this dial: {why}");
            }
        }
        match self.plain_service(daemon, hello).await? {
            Ok(secure) => Ok(self.carry_plain(secure)),
            Err(refusal) => Err(refusal.to_string()),
        }
    }

    /// A plain circuit to `daemon` whose `hello` was answered: the circuit, else the refusal
    /// (its circuit closed).
    async fn plain_service(
        &self,
        daemon: &str,
        hello: Bytes,
    ) -> Result<Result<cmux_remote::crypto::SecureLink, ServiceRefusal>, String> {
        let (secure, mut stages) = self.open_circuit(daemon).await?;
        let answered = Instant::now();
        let answer = Self::ask_service(&secure, hello, self.timings.handshake).await;
        stages.answer = answered.elapsed();
        stages.log(daemon, "plain");
        match answer {
            Ok(Ok(())) => Ok(Ok(secure)),
            Ok(Err(refusal)) => {
                let _ = secure.close().await;
                Ok(Err(refusal))
            }
            Err(e) => {
                let _ = secure.close().await;
                Err(e)
            }
        }
    }

    /// Send `hello` as a circuit's first record and read the answer.
    async fn ask_service(
        secure: &cmux_remote::crypto::SecureLink,
        hello: Bytes,
        wait: Duration,
    ) -> Result<Result<(), ServiceRefusal>, String> {
        secure.send(hello).await.map_err(|e| e.to_string())?;
        let answer = tokio::time::timeout(wait, secure.receive())
            .await
            .map_err(|_| "the machine did not answer the service hello in time".to_owned())?
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "the machine closed the circuit before answering".to_owned())?;
        Ok(read_service_answer(&answer))
    }

    fn carry_plain(&self, secure: cmux_remote::crypto::SecureLink) -> HubStream {
        self.stats.dials.fetch_add(1, Ordering::Relaxed);
        let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
        let stats = self.stats.clone();
        tokio::spawn(async move { pump(Box::new(secure), theirs, &stats).await });
        ours
    }

    /// A stream on the kept circuit to `daemon`, opening that circuit first if there is none.
    /// A circuit that fails under the open is dropped and opened again, once.
    async fn kept_open(&self, daemon: &str, hello: Bytes) -> KeptOpen {
        let slot = self.kept.slot(daemon);
        let mut why = String::new();
        for _ in 0..2 {
            let mux = {
                let mut kept = slot.lock().await;
                match kept.live.clone().filter(|mux| !mux.is_closed()) {
                    Some(mux) => mux,
                    None => {
                        if kept.no_mux_until.is_some_and(|until| Instant::now() < until) {
                            return KeptOpen::Plain("the machine keeps no circuits".into());
                        }
                        // Parallel dials wait here on this one open, not on one each. Never a
                        // plain dial beside it: a service hello can ask the far machine's owner
                        // for consent, and one dial asks once.
                        let (mux, said, mut stages) = match self.open_kept(daemon).await {
                            Ok(opened) => opened,
                            Err(e) => return KeptOpen::Failed(e),
                        };
                        // This dial's OPEN goes right behind the `mux` hello, not after its
                        // answer: a new kept circuit costs no more round trips than a plain one.
                        let asked = Instant::now();
                        let wait = self.timings.handshake;
                        let (first, said) = tokio::join!(
                            mux.open(hello.clone(), wait),
                            tokio::time::timeout(wait, said)
                        );
                        stages.answer = asked.elapsed();
                        stages.log(daemon, "kept");
                        match said {
                            Ok(Ok(Ok(()))) => {
                                self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
                                kept.live = Some(mux.clone());
                            }
                            Ok(Ok(Err(refusal))) => {
                                mux.close().await;
                                tracing::debug!(
                                    "hub carrier: the machine keeps no circuits: {refusal}"
                                );
                                kept.no_mux_until = Some(Instant::now() + mux::NO_MUX_ASK_AGAIN);
                                return KeptOpen::Plain("the machine keeps no circuits".into());
                            }
                            Ok(Err(_)) | Err(_) => {
                                mux.close().await;
                                return KeptOpen::Failed(
                                    "the machine did not answer the kept circuit's hello".into(),
                                );
                            }
                        }
                        match first {
                            Ok(Ok(stream)) => return KeptOpen::Stream(stream),
                            Ok(Err(refusal)) => return KeptOpen::Refused(refusal),
                            Err(e) => {
                                mux.close().await;
                                why = e;
                                continue;
                            }
                        }
                    }
                }
            };
            match mux.open(hello.clone(), self.timings.handshake).await {
                Ok(Ok(stream)) => return KeptOpen::Stream(stream),
                Ok(Err(refusal)) => return KeptOpen::Refused(refusal),
                Err(e) => {
                    tracing::info!(
                        "hub carrier: a kept circuit failed under a dial ({e}); opening it again"
                    );
                    mux.close().await;
                    why = e;
                }
            }
        }
        KeptOpen::Plain(format!("the kept circuit failed twice: {why}"))
    }

    /// Open a kept circuit to `daemon`: a circuit whose first record is the `mux` hello, its
    /// dialer's end running. The answer comes on `said` (a machine whose acpmux predates kept
    /// circuits refuses it, `service.unknown`, and closes the circuit).
    async fn open_kept(
        &self,
        daemon: &str,
    ) -> Result<(Arc<mux::Mux>, mux::HelloAnswer, DialStages), String> {
        let (secure, stages) = self.open_circuit(daemon).await?;
        secure.send(mux::mux_hello()).await.map_err(|e| e.to_string())?;
        let (mux, said) = mux::start_dialer(
            Box::new(secure),
            self.stats.clone(),
            Arc::downgrade(&self.alive),
            self.timings.keepalive,
            self.timings.kept_idle,
        );
        Ok((mux, said, stages))
    }

    /// `false` answers a kept circuit's hello as an acpmux that predates kept circuits does
    /// (`service.unknown`), so a test can check that a dialer falls back to plain circuits.
    #[doc(hidden)]
    pub fn serve_kept_circuits(&self, on: bool) {
        self.serves_kept.store(on, Ordering::SeqCst);
    }

    /// Whether a kept circuit to `daemon` is open now, and how many streams ride it.
    pub fn kept_streams(&self, daemon: &str) -> Option<usize> {
        self.kept.live(daemon).map(|mux| mux.streams())
    }

    /// Cut the kept circuit to `daemon` under its streams, as a relay drop would (tests, and a
    /// caller that knows the path changed).
    pub async fn cut_kept(&self, daemon: &str) -> bool {
        match self.kept.live(daemon) {
            Some(mux) => {
                mux.close().await;
                true
            }
            None => false,
        }
    }

    /// One relay circuit to `daemon` with the Noise handshake done, its key pinned to the
    /// platform's `peer_key`, and how long each step took.
    pub(crate) async fn open_circuit(
        &self,
        daemon: &str,
    ) -> Result<(cmux_remote::crypto::SecureLink, DialStages), String> {
        let mut stages = DialStages::default();
        let step = Instant::now();
        // No ticket is `credential-unavailable` on the peer's link (`peer_carrier::reason`), unless
        // the hub has no carrier for it at all ([`ticket_refusal`]).
        let answer = self.tickets.connect(daemon).await.map_err(|e| {
            if e.contains("machine.not_found") {
                ticket_refusal(e)
            } else {
                format!(
                    "{} no relay ticket: {e}",
                    crate::protocol::peer_state::CREDENTIAL_UNAVAILABLE
                )
            }
        })?;
        stages.ticket = step.elapsed();
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
        let step = Instant::now();
        let group = provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .map_err(|e| relay_refusal(e.to_string(), self.timings.peer_join))?;
        stages.relay = step.elapsed();
        let step = Instant::now();
        let opened = tokio::time::timeout(
            self.timings.peer_join,
            group.open(LinkRequest { lane: Lane::Control, generation: 0 }),
        )
        .await;
        // The circuit is its own socket: the allocation socket is not needed past this.
        let _ = group.close().await;
        let link = opened
            .map_err(|_| carrier_not_serving(self.timings.peer_join))?
            .map_err(|e| relay_refusal(e.to_string(), self.timings.peer_join))?;
        stages.peer_join = step.elapsed();
        let step = Instant::now();
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
        stages.noise = step.elapsed();
        Ok((secure, stages))
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
        HubServe { task, lease: None }
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
        let mut attempts: u64 = 0;
        let mut last_said: Option<tokio::time::Instant> = None;
        // Said before the first ask: one ask may take up to the hub client's call bound
        // (`mesh_http.rs` `CALL_WAIT`, 30 s), and a start's log must show the carrier is asking.
        tracing::info!("hub carrier: asking {} for a register ticket", self.tickets.shown());
        // The first answer names the relay and the slot; each later authentication asks again,
        // which also refreshes the keys let in (a revoked machine is out by the next one).
        let answer = loop {
            if !self.key_current() {
                tracing::warn!(
                    "hub carrier off: the node key is no longer this machine's; not registering"
                );
                return;
            }
            attempts += 1;
            match self.tickets.register().await {
                Ok(answer) => break answer,
                Err(e) => {
                    self.set_serve_reason(Some(OfflineReason::CredentialUnavailable));
                    // The first refusal is the start's answer, a warn. The later ones say at info
                    // where the asking stands, at most once per `REFUSAL_SAID_EVERY`.
                    let now = tokio::time::Instant::now();
                    if attempts == 1 {
                        tracing::warn!(
                            "hub carrier: no register ticket yet, retrying in {}s: {e}",
                            wait.as_secs()
                        );
                        last_said = Some(now);
                    } else if last_said
                        .is_none_or(|said| now.duration_since(said) >= REFUSAL_SAID_EVERY)
                    {
                        tracing::info!(
                            "hub carrier: still no register ticket after {attempts} attempts, next try in {}s: {e}",
                            wait.as_secs()
                        );
                        last_said = Some(now);
                    } else {
                        tracing::debug!("hub carrier: no register ticket yet: {e}");
                    }
                    tokio::time::sleep(wait).await;
                    wait = (wait * 2).min(REGISTER_WAIT_MAX);
                }
            }
        };
        if attempts > 1 {
            tracing::info!("hub carrier: a register ticket came after {attempts} attempts");
        }
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
        let mut state = registration.state();
        let _registration = registration;
        let mut every = tokio::time::interval(self.timings.key_check);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        // False once the registration's task ended (only at shutdown, which the drop does).
        let mut reporting = true;
        loop {
            let reason =
                state.borrow_and_update().reason().map(|_| OfflineReason::CredentialUnavailable);
            self.set_serve_reason(reason);
            tokio::select! {
                _ = every.tick() => {}
                () = self.rekeyed.notified() => {}
                changed = state.changed(), if reporting => {
                    reporting = changed.is_ok();
                    continue;
                }
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

/// The running registration of [`HubCarrier::serve`]. Dropping it unregisters, and frees the key
/// lock the carrier took itself ([`KeyLease`]), if it took one.
pub struct HubServe {
    task: tokio::task::JoinHandle<()>,
    lease: Option<KeyLease>,
}

impl HubServe {
    /// A registration that is `task` (a test's stand-in), dropped as a real one is.
    #[cfg(test)]
    pub(crate) fn of_task(task: tokio::task::JoinHandle<()>) -> Self {
        Self { task, lease: None }
    }

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
pub struct HubCarrierSlot(Arc<std::sync::RwLock<Option<Arc<HubCarrier>>>>, bool);

impl HubCarrierSlot {
    /// A slot for a daemon whose startup may run the carrier: one with the joined machine
    /// credential (`meshRelay.credential: "join"`). Whichever holds the node key lock (the
    /// WireGuard transport, the carrier's own lease, or the cmux link, whose key the carrier
    /// reads as a Noise static key only), [`start_configured`] runs it.
    pub fn for_daemon(
        config: &crate::config::Config,
        _wireguard: Option<&Arc<crate::wireguard::Transport>>,
    ) -> Self {
        let joined = config
            .mesh_relay
            .as_ref()
            .is_some_and(|relay| relay.credential.as_deref() == Some("join"));
        Self(Arc::default(), joined)
    }

    /// Whether the carrier runs or this daemon's startup may start it.
    pub fn expected(&self) -> bool {
        self.1 || self.get().is_some()
    }

    /// Makes `carrier` the daemon's, in place of one a stop left or a join replaced.
    pub fn set(&self, carrier: Arc<HubCarrier>) {
        use crate::no_panic::RwLockExt;
        *self.0.write_or_recover() = Some(carrier);
    }

    /// The carrier that runs, if one does.
    pub fn get(&self) -> Option<Arc<HubCarrier>> {
        use crate::no_panic::RwLockExt;
        self.0.read_or_recover().clone()
    }

    /// No carrier: it stopped ([`stop_kept`]). A peer's dial finds none rather than the stopped
    /// one, whose tickets come from the left join's hub and credential.
    pub fn clear(&self) -> Option<Arc<HubCarrier>> {
        use crate::no_panic::RwLockExt;
        self.0.write_or_recover().take()
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

impl Incoming {
    /// The connection to this machine's cmux-tui remote daemon on `port`, as its gate admits.
    async fn cmux_tui(&self, port: u16) -> Result<tokio::net::TcpStream, ServiceRefusal> {
        let gate = self.carrier.cmux_tui_gate().ok_or_else(|| {
            ServiceRefusal::new(
                "service.off",
                "this machine does not serve its cmux-tui remote daemon to its other machines",
            )
        })?;
        let target = gate.admit(port).await?;
        let daemon = tokio::net::TcpStream::connect(target).await.map_err(|e| {
            ServiceRefusal::new(
                "service.unreachable",
                format!("the cmux-tui remote daemon at {target} is not listening: {e}"),
            )
        })?;
        let _ = daemon.set_nodelay(true);
        Ok(daemon)
    }

    /// This machine's end of a machine-call circuit from `from`, or why it may not have one.
    async fn machine_call(&self, from: Option<String>) -> Result<HubStream, ServiceRefusal> {
        match (self.carrier.machine_call_gate(), from) {
            (Some(gate), Some(from)) => gate.open(&from).await,
            (None, _) => Err(ServiceRefusal::new(
                "service.off",
                "this machine runs no calls for its other machines",
            )),
            (Some(_), None) => Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            )),
        }
    }

    /// The session socket a circuit from `from` (its proven key) may reach, as the session gate
    /// admits.
    async fn admit_session(
        &self,
        from: Option<String>,
    ) -> Result<std::path::PathBuf, ServiceRefusal> {
        match (self.carrier.session_gate(), from) {
            (Some(gate), Some(from)) => gate.admit(&from).await,
            (None, _) => Err(ServiceRefusal::new(
                "service.off",
                "this machine does not open workspaces for its other machines",
            )),
            (Some(_), None) => Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            )),
        }
    }
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
        // The dialer's key as the handshake proved it (its grant names the key's fingerprint).
        let from = keys
            .0
            .iter()
            .find(|key| public_key_fingerprint(key) == accepted.grant.device_id)
            .map(|key| base64::engine::general_purpose::STANDARD.encode(key));
        let link = accepted.link;
        // The acpmux listener is reached at once, as before services were named: a circuit with
        // no hello may send nothing for a while, and its listener counts it from the start. A
        // session circuit never uses it, so one that fails to connect refuses only the others.
        let listener = tokio::net::TcpStream::connect(self.websocket).await.ok();
        if let Some(listener) = &listener {
            let _ = listener.set_nodelay(true);
        }
        // The first record says which service the circuit is for: a hello names one, anything
        // else is the acpmux listener's own first bytes (a WebSocket upgrade).
        let first = match link.receive().await {
            Ok(Some(first)) => first,
            _ => {
                let _ = link.close().await;
                return;
            }
        };
        if mux::is_mux_hello(&first) && self.carrier.serves_kept.load(Ordering::SeqCst) {
            // A kept circuit: each stream names its own service and is admitted on its own.
            drop(listener);
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            let stats = self.carrier.stats.clone();
            mux::serve(Box::new(link), self, from, stats).await;
            return;
        }
        if named_service(&first) == Some(Ok(CircuitService::MachineCall)) {
            // A machine-call circuit is answered in this process; the acpmux listener's
            // connection closes unused.
            drop(listener);
            let local = match self.machine_call(from).await {
                Ok(local) => local,
                Err(refusal) => {
                    tracing::info!("hub carrier: a machine-call circuit was refused: {refusal}");
                    let _ = link.send(service_answer(&Err(refusal))).await;
                    let _ = link.close().await;
                    return;
                }
            };
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
            pump(Box::new(link), local, &self.carrier.stats).await;
            return;
        }
        if named_service(&first) == Some(Ok(CircuitService::CmuxTuiSession)) {
            // A session circuit reaches the cmux-tui session socket; the acpmux listener's
            // connection closes unused.
            drop(listener);
            let admitted = self.admit_session(from).await;
            let local = match admitted {
                Ok(socket) => connect_session(&socket).await.map_err(|e| {
                    ServiceRefusal::new(
                        "service.unreachable",
                        format!("this machine's cmux-tui session is not running: {e}"),
                    )
                }),
                Err(refusal) => Err(refusal),
            };
            let local = match local {
                Ok(local) => local,
                Err(refusal) => {
                    tracing::info!("hub carrier: a session circuit was refused: {refusal}");
                    let _ = link.send(service_answer(&Err(refusal))).await;
                    let _ = link.close().await;
                    return;
                }
            };
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
            pump(Box::new(link), local, &self.carrier.stats).await;
            return;
        }
        let Some(mut local) = listener else {
            let _ = link.close().await;
            return;
        };
        let started = match named_service(&first) {
            None => local.write_all(&first).await.map_err(|e| e.to_string()),
            Some(named) => {
                let reached = match named {
                    Ok(CircuitService::Acpmux) => Ok(local),
                    Ok(CircuitService::CmuxTui { port }) => self.cmux_tui(port).await,
                    // Served above; never reaches a TCP target.
                    Ok(CircuitService::CmuxTuiSession | CircuitService::MachineCall) => {
                        Err(ServiceRefusal::new("service.unknown", "no such service"))
                    }
                    Err(refusal) => Err(refusal),
                };
                match reached {
                    // For cmux-tui, the acpmux listener's connection closes unused.
                    Ok(reached) => {
                        local = reached;
                        link.send(service_answer(&Ok(()))).await.map_err(|e| e.to_string())
                    }
                    Err(refusal) => {
                        tracing::info!("hub carrier: a circuit's service was refused: {refusal}");
                        let _ = link.send(service_answer(&Err(refusal))).await;
                        let _ = link.close().await;
                        return;
                    }
                }
            }
        };
        if started.is_err() {
            let _ = link.close().await;
            return;
        }
        self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
        pump(Box::new(link), local, &self.carrier.stats).await;
    }
}

/// A connection to this machine's own cmux-tui session socket (unix only; elsewhere none).
#[cfg(unix)]
async fn connect_session(path: &std::path::Path) -> std::io::Result<tokio::net::UnixStream> {
    tokio::net::UnixStream::connect(path).await
}
#[cfg(not(unix))]
async fn connect_session(_path: &std::path::Path) -> std::io::Result<tokio::io::DuplexStream> {
    Err(std::io::Error::from(std::io::ErrorKind::Unsupported))
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
            // `read` never returns more than `buf` holds; `get` keeps that a checked fact.
            let read_bytes = buf.get(..n).ok_or("the read overran its buffer")?;
            link.send(Bytes::copy_from_slice(read_bytes)).await.map_err(|e| e.to_string())?;
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

/// What a dial says when the far machine's hub carrier is not serving, whatever told it so (the
/// hub's 404 `machine.not_found` on the connect ticket, the relay's `slot-offline`, or a far
/// machine that never joined the circuit): the machine's own fix, with a reason the CLI ends on
/// ([`cmux_remote::provider::TERMINAL_REFUSALS`]), where a redial only waits out its timeout.
pub(crate) fn carrier_off(how: &str) -> String {
    format!(
        "that machine's hub carrier is off ({how}): its acpmux is stopped or not joined to this \
         account, or it runs a build from before the carrier served beside the cmux link (its \
         app's link holds the node key and the older carrier stays off there). Update cmux on \
         that machine and restart its acpmux; `acpmux machine status --json` there shows the \
         carrier. (carrier.not_serving)"
    )
}

/// The far machine never joined the circuit within `waited`.
pub(crate) fn carrier_not_serving(waited: Duration) -> String {
    carrier_off(&format!("it did not answer on the relay within {}s", waited.as_secs().max(1)))
}

/// A refused connect ticket, as the dialer words it: the hub's `machine.not_found` is
/// [`not_a_teammate_machine`]; any other refusal keeps its text.
pub(crate) fn ticket_refusal(text: String) -> String {
    if text.contains("machine.not_found") { not_a_teammate_machine() } else { text }
}

/// The hub's connect ticket answers `machine.not_found` for any key that is not one of the
/// caller's person's live machines joined in the caller's own team (cmux-platform
/// `server/mesh/MeshCarrier.ts`: rows of `caller.team` minted by `caller.user`). Whether the far
/// carrier serves does not enter into it: a machine joined in another team of the same person
/// registers and serves on its own slot and still answers this, so the words name the team.
pub(crate) fn not_a_teammate_machine() -> String {
    "the hub knows no live machine of yours with that key in this machine's team: it is not \
     joined, its join was revoked or expired, or it is joined in another of your teams (the hub \
     carrier only connects machines joined in the same team). Compare teamId in `acpmux machine \
     join --status --json` on both machines; `acpmux machine doctor --here` names the team and \
     how to move a join. (carrier.not_serving)"
        .to_owned()
}

/// A relay's refusal of a dial, as the dialer words it: the relay's `slot-offline` (no daemon
/// registered for the machine's slot, or its registration lease ran out) is the far carrier not
/// serving ([`carrier_not_serving`]); any other refusal keeps its own text.
pub(crate) fn relay_refusal(text: String, waited: Duration) -> String {
    let offline = text.contains("slot-offline")
        || text.contains("no daemon is registered")
        || text.contains("registration lease has expired");
    if offline { carrier_not_serving(waited) } else { text }
}

/// The platform's tickets, by this machine's `cmm_` credential, through the mesh hub's client.
pub(crate) struct PlatformTickets {
    hub: crate::mesh_http::HttpHub,
    /// The hub's scheme, host and port (`MeshRelayConfig::shown`), for the log.
    shown: String,
}

#[async_trait]
impl Tickets for PlatformTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        self.hub.carrier(None).await
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.hub.carrier(Some(peer)).await
    }

    fn shown(&self) -> String {
        self.shown.clone()
    }
}

/// How often a carrier on its own key lock asks whether a cmux link now serves this home's node
/// key (the transport's handoff asks as often, `daemon.rs` `LINK_HANDOFF_EVERY`).
const LINK_HANDOFF_EVERY: Duration = Duration::from_secs(2);

/// Whether a cmux link serves the node key in `home` (or will at its next start): the link
/// recorded for it, else the one by this process's environment. The transport's rule
/// (`wireguard.rs`): there the link is the one key holder and acpmux takes no key lock.
fn link_serves(home: &std::path::Path) -> bool {
    let link_dir = crate::cli::mesh_node_key::recorded_link_dir(home)
        .or_else(crate::wireguard::env_link_state_dir);
    crate::cli::mesh_node_key::link_serves_node_key(link_dir.as_deref(), home)
}

/// The key lock the carrier took itself, with no WireGuard transport running: held while the
/// carrier serves, and handed to the cmux link as soon as one serves this home's node key (as
/// `Transport::yield_to_link` hands the transport's), so `cmux link ensure` never waits on the
/// daemon. The carrier keeps only a weak share ([`KeyCheck`]): once the lock goes, its key check
/// fails, and it unregisters and refuses its dials. Dropping the lease frees the lock at once.
pub(crate) struct KeyLease {
    held: Arc<Mutex<Option<Arc<cmux_link::key_holder::KeyHolder>>>>,
    handoff: tokio::task::JoinHandle<()>,
}

impl KeyLease {
    /// Takes this machine's key lock in `home` (the caller checked that no cmux link serves its
    /// node key there, [`link_serves`]), unless another process holds the lock (a link, another
    /// daemon): then the carrier stays off.
    fn take(home: &std::path::Path) -> Option<(Self, Arc<cmux_link::key_holder::KeyHolder>)> {
        use cmux_link::key_holder::{KeyHolder, KeyHolderError};
        let holder = match KeyHolder::acquire(home) {
            Ok(holder) => Arc::new(holder),
            Err(KeyHolderError::KeyHeld { pid }) => {
                tracing::warn!(
                    holder_pid = ?pid,
                    "hub carrier off for this run: another process holds this machine's node key"
                );
                return None;
            }
            Err(KeyHolderError::Io(e)) => {
                tracing::warn!("hub carrier off: take the node key lock: {e}");
                return None;
            }
        };
        let held = Arc::new(Mutex::new(Some(holder.clone())));
        let handoff = Self::scope().spawn_named(
            "hub carrier key handoff",
            Self::hand_to_link(held.clone(), home.to_path_buf()),
        );
        Some((Self { held, handoff }, holder))
    }

    /// The owner of every lease's handoff task; a lease's drop aborts its own.
    fn scope() -> &'static cmux_scope::Scope {
        static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
        SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier key lease"))
    }

    /// Frees the lock once a cmux link serves the node key in `home`.
    async fn hand_to_link(
        held: Arc<Mutex<Option<Arc<cmux_link::key_holder::KeyHolder>>>>,
        home: std::path::PathBuf,
    ) {
        loop {
            tokio::time::sleep(LINK_HANDOFF_EVERY).await;
            let at = home.clone();
            if tokio::task::spawn_blocking(move || link_serves(&at)).await.unwrap_or(false) {
                break;
            }
        }
        tracing::info!(
            "hub carrier: the cmux link now serves this machine's node key; the carrier gives \
             it the key lock and goes on serving on the Noise key alone"
        );
        drop(held.lock().unwrap_or_else(|e| e.into_inner()).take());
    }
}

impl Drop for KeyLease {
    fn drop(&mut self) {
        self.handoff.abort();
        drop(self.held.lock().unwrap_or_else(|e| e.into_inner()).take());
    }
}

/// The node key, read only under this machine's key lock (`cmux_link::key_holder`): the one this
/// daemon's WireGuard transport holds, or the carrier's own ([`KeyLease`]). Where the cmux link
/// is the key holder the carrier takes no lock (it would refuse the link's `cmux link ensure`,
/// `key_held`) and reads the key as a Noise static key instead ([`linked_node_key`]).
fn node_key(
    state_dir: &std::path::Path,
    held: Arc<cmux_link::key_holder::KeyHolder>,
) -> Result<(Arc<cmux_link::key_holder::KeyHolder>, zeroize::Zeroizing<[u8; 32]>), String> {
    let (_, private) = crate::cli::mesh_node_key::load_or_create_held(state_dir, &held)
        .map_err(|e| format!("no node key: {e:#}"))?;
    Ok((held, private))
}

/// The node key where a cmux link serves it, read with no lock as a Noise static key (never
/// created: the link adopted the key, so it exists; none means the carrier stays off).
fn linked_node_key(state_dir: &std::path::Path) -> Result<zeroize::Zeroizing<[u8; 32]>, String> {
    crate::cli::mesh_node_key::read_noise_static(state_dir)
        .map_err(|e| format!("no node key to read beside the cmux link: {e:#}"))
}

/// The daemon's hub carrier: on when config.json names a mesh hub with the joined machine
/// credential (`meshRelay.credential: "join"`), this home is not a copy, and it holds the node
/// key: under the key lock the daemon's WireGuard transport hands it (`held`), else under its own
/// ([`KeyLease`]), which it takes only where no cmux link serves this home's node key. No
/// `transport.wireguard`, `wireguardStatic` or Labs switch is needed. Where the link holds the
/// key the carrier serves too, on a lockless read of the key as a Noise static key
/// ([`linked_node_key`]): a customer's Mac with the app's link running stays reachable over the
/// relay. It serves at once; peers find it through `hub.hub_carrier`.
pub async fn start_configured(
    hub: &Arc<crate::hub::Hub>,
    state_dir: &std::path::Path,
    websocket: Option<SocketAddr>,
    held: Option<Arc<cmux_link::key_holder::KeyHolder>>,
) -> Option<HubServe> {
    // Every way out says why, so a start's log always holds the carrier's state.
    let Some(config) = hub.config.read().await.mesh_relay.clone() else {
        tracing::info!(
            "hub carrier off: this machine is not joined (config.json has no meshRelay)"
        );
        return None;
    };
    if config.credential.as_deref() != Some("join") {
        tracing::info!("hub carrier off: meshRelay's credential is not the machine join");
        return None;
    }
    let Some(websocket) = websocket else {
        tracing::warn!("hub carrier off: the daemon has no loopback WebSocket listener");
        return None;
    };
    // Only this daemon's loopback listener, whose tokens stay mandatory, as WireGuard's bridge.
    let websocket = match crate::wireguard::local_websocket(websocket) {
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
    // The transport's lock when it runs; else the carrier's own, unless the link holds the key
    // (then none: the carrier reads the key as a Noise static key).
    let linked = held.is_none() && link_serves(state_dir);
    let (lease, held) = match held {
        Some(held) => (None, Some(held)),
        None if linked => {
            tracing::info!(
                "hub carrier: the cmux link holds this machine's node key; serving on the Noise \
                 key alone, with no key lock"
            );
            (None, None)
        }
        None => {
            let (lease, held) = KeyLease::take(state_dir)?;
            (Some(lease), Some(held))
        }
    };
    let (holder, private) = match held {
        Some(held) => match node_key(state_dir, held) {
            Ok((holder, private)) => (Some(holder), private),
            Err(why) => {
                tracing::warn!("hub carrier off: {why}");
                return None;
            }
        },
        None => match linked_node_key(state_dir) {
            Ok(private) => (None, private),
            Err(why) => {
                tracing::warn!("hub carrier off: {why}");
                return None;
            }
        },
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
    // The carrier runs only while the transport or its lease holds the lock: it keeps no share of
    // it, so a transport or lease that yields to the cmux link (`Transport::yield_to_link`,
    // [`KeyLease`]) frees the key at once, and from then the check fails: the carrier unregisters
    // and refuses its dials.
    // A lock handed to the cmux link is no end of the carrier: it serves on the Noise key, so
    // while a link serves this home's key the check holds on the key alone.
    let holder = holder.as_ref().map(Arc::downgrade);
    let check: KeyCheck = Arc::new(move |public: &[u8; 32]| {
        let held =
            holder.as_ref().is_none_or(|holder| holder.upgrade().is_some()) || link_serves(&home);
        held && crate::cli::mesh_node_key::public_key_at(&home).is_some_and(|now| now == *public)
    });
    let carrier = HubCarrier::with_key_check(
        Arc::new(PlatformTickets { hub: client, shown: config.shown() }),
        *private,
        Timings::default(),
        check,
    );
    // Off unless the owner names the daemon (`remoteDaemon`) and grants control.
    carrier.set_cmux_tui_gate(Arc::new(crate::cmux_tui_service::ConfiguredGate::new(hub)));
    // Off unless the person on this machine allowed its other signed-in machines in.
    carrier.set_session_gate(Arc::new(crate::session_service::ConfiguredSessionGate::new(hub)));
    // Off under the same grant: this machine runs Computer Use calls for those machines.
    carrier.set_machine_call_gate(Arc::new(crate::machine_call_service::ConfiguredGate::new(hub)));
    hub.hub_carrier.set(carrier.clone());
    // The start's answer, whether or not the relay takes the registration yet (it retries).
    tracing::info!(
        "hub carrier: on, bridging admitted circuits to this daemon's listener {websocket}"
    );
    let mut serving = carrier.serve(websocket);
    serving.lease = lease;
    Some(serving)
}

/// [`start_configured`] on the daemon's key lock (its WireGuard transport's, else the carrier's
/// own) and node key, kept on the hub (`Hub::hub_carrier_serve`) so a sign-out's leave can stop it
/// ([`stop_kept`]). A rekey (`machine_tunnel.rs`, which runs on the transport's lock) rotates the
/// node key under the carrier: it takes the new key with the key file and registers again, rather
/// than reading it as replaced.
pub async fn start_kept(hub: &Arc<crate::hub::Hub>, websocket: Option<SocketAddr>) {
    use crate::no_panic::LockExt;
    // The lock the WireGuard transport holds, when it runs; else the carrier takes its own.
    let held = hub.wireguard.as_ref().and_then(|transport| transport.key_holder());
    let Some(serving) = start_configured(hub, &crate::config::home(), websocket, held).await else {
        return;
    };
    if let (Some(transport), Some(carrier)) = (hub.wireguard.as_ref(), hub.hub_carrier.get()) {
        transport.add_key_user(Arc::new(move |private, write| carrier.rekey(*private, write)));
    }
    *hub.hub_carrier_serve.lock_or_recover() = Some(serving);
}

/// Stops the carrier [`start_kept`] started, if it runs: dropping its registration unregisters
/// this machine's slot on the relay. True when one was running.
pub fn stop_kept(hub: &crate::hub::Hub) -> bool {
    use crate::no_panic::LockExt;
    let carrier = hub.hub_carrier.clear();
    let serving = hub.hub_carrier_serve.lock_or_recover().take();
    // The workspace routes to the person's other machines go with the carrier they dial.
    hub.machine_routes.clear();
    carrier.is_some() || serving.is_some()
}

#[path = "hub_carrier_serve_reason.rs"]
mod serve_reason;

#[path = "hub_carrier_mux.rs"]
mod mux;

#[cfg(test)]
#[path = "hub_carrier_register_log_tests.rs"]
mod register_log_tests;

#[cfg(test)]
#[path = "hub_carrier_key_lock_tests.rs"]
mod key_lock_tests;
