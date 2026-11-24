use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use bytes::Bytes;
use cmux_braid_session::{Capabilities, LinkFacts, NOISE_XX, Pattern};
use cmux_link::carrier_grant::CarrierGrant;
use cmux_remote_protocol::{Lane, REMOTE_PROTOCOL_VERSION, Service, SessionId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use snow::params::NoiseParams;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::link::{FrameLink, LinkError};

const HANDSHAKE_NAME: &str = "cmux-remote-noise";
/// The Noise protocol of a link without an invitation. acpmux's hub carrier pins its hash to
/// WireGuard's, since it reuses the machine's WireGuard key as this static key.
pub const NOISE_XX_PROTOCOL: &str = NOISE_XX;
const NOISE_MAX_MESSAGE: usize = 65_535;
const NOISE_TAG_BYTES: usize = 16;
const NOISE_NONCE_BYTES: usize = 8;
pub(crate) const SECURE_FRAME_OVERHEAD_BYTES: usize = NOISE_TAG_BYTES + NOISE_NONCE_BYTES;
const HANDSHAKE_PAYLOAD_MAX: usize = 16 * 1024;
/// Bounds closing a link whose handshake deadline expired; the peer already
/// proved unresponsive, so a graceful close may never be acknowledged.
const HANDSHAKE_TEARDOWN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct StaticIdentity {
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl StaticIdentity {
    pub fn generate() -> Result<Self, CryptoError> {
        let mut private = Zeroizing::new([0_u8; 32]);
        getrandom::fill(private.as_mut())
            .map_err(|error| CryptoError::Random(error.to_string()))?;
        Ok(Self::from_private(*private))
    }

    pub fn from_private(private: [u8; 32]) -> Self {
        let secret = StaticSecret::from(private);
        let public = PublicKey::from(&secret).to_bytes();
        Self { private: Zeroizing::new(private), public }
    }

    pub fn private_key(&self) -> &[u8; 32] {
        &self.private
    }

    pub fn public_key(&self) -> [u8; 32] {
        self.public
    }

    pub fn fingerprint(&self) -> String {
        public_key_fingerprint(&self.public)
    }
}

impl fmt::Debug for StaticIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StaticIdentity")
            .field("fingerprint", &self.fingerprint())
            .finish_non_exhaustive()
    }
}

pub fn public_key_fingerprint(public: &[u8; 32]) -> String {
    let digest = Sha256::digest(public);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&digest[..16])
}

#[derive(Clone)]
pub enum ClientAuthMode {
    Enrolled,
    Invitation {
        id: String,
        secret: Zeroizing<[u8; 32]>,
    },
    Carrier,
    /// A carrier grant: a short-lived token the platform signed for this
    /// client's Noise key. It rides inside the encrypted handshake, and a
    /// daemon with no grant verifier refuses it.
    Grant {
        token: Zeroizing<String>,
    },
}

impl fmt::Debug for ClientAuthMode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Enrolled => formatter.write_str("Enrolled"),
            Self::Invitation { id, .. } => {
                formatter.debug_struct("Invitation").field("id", id).finish_non_exhaustive()
            }
            Self::Carrier => formatter.write_str("Carrier"),
            Self::Grant { .. } => formatter.debug_struct("Grant").finish_non_exhaustive(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClientHandshake {
    pub identity: StaticIdentity,
    pub expected_daemon: Option<[u8; 32]>,
    pub auth: ClientAuthMode,
    pub device_name: String,
    pub session: SessionId,
    pub lane: Lane,
    pub lanes: Vec<Lane>,
    pub generation: u64,
    pub connection_attempt: ConnectionAttemptId,
    pub resume: BTreeMap<Lane, u64>,
    /// The daemon said, in an earlier welcome, that it takes Noise IK: with `expected_daemon`
    /// set and no bearer secret in the hello, the link runs IK and its welcome is back one round
    /// trip sooner (`cmux_braid_session::choose`).
    pub daemon_takes_ik: bool,
    /// Bounds the prelude and Noise exchange of one link, the phase a live
    /// daemon answers immediately with no human involved. An endpoint that
    /// accepts the transport and then never speaks (a preview-gateway edge
    /// whose machine was deleted) fails here instead of holding the
    /// connection open forever. The post-Noise welcome wait is exempt so an
    /// invitation may still spend its enrollment-approval window.
    pub handshake_timeout: Duration,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConnectionAttemptId(pub [u8; 16]);

impl fmt::Debug for ConnectionAttemptId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

/// The non-authoritative network path that delivered an inbound link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkPeer {
    Tcp,
    Tls,
    Relay,
    Iroh,
}

/// Kernel credentials verified to belong to the daemon's effective user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VerifiedKernelPeer {
    uid: u32,
}

impl VerifiedKernelPeer {
    pub fn uid(&self) -> u32 {
        self.uid
    }
}

/// An SSH principal verified by a future SSH server boundary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VerifiedSshPrincipal {
    principal: String,
}

impl VerifiedSshPrincipal {
    pub fn principal(&self) -> &str {
        &self.principal
    }
}

/// Server-side evidence established by the transport boundary.
///
/// Network evidence identifies provenance for diagnostics but never
/// authorizes carrier authentication. `TrustedNetwork` is the one exception:
/// a listener the operator marked trusted, because the network it is bound to
/// already admits only authorized peers (a cmux Cloud machine's private VPC,
/// where every member is the owner's Mac or another of the owner's machines).
/// The listener, not the daemon, carries that policy, so ssh, relay, and iroh
/// links on the same daemon still enroll.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InboundAuthEvidence {
    Kernel(VerifiedKernelPeer),
    Ssh(VerifiedSshPrincipal),
    Network(NetworkPeer),
    TrustedNetwork(NetworkPeer),
}

impl InboundAuthEvidence {
    pub(crate) fn verified_same_owner_kernel_peer(
        peer_uid: u32,
        effective_uid: u32,
    ) -> Option<Self> {
        (peer_uid == effective_uid).then_some(Self::Kernel(VerifiedKernelPeer { uid: peer_uid }))
    }
}

/// A carrier grant as the client presented it. Its `Debug` never shows it.
#[derive(Clone, PartialEq, Eq)]
pub struct GrantToken(Zeroizing<String>);

impl GrantToken {
    pub fn new(token: impl Into<String>) -> Self {
        Self(Zeroizing::new(token.into()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for GrantToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GrantToken(..)")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthRequest {
    pub mode: AuthKind,
    pub invitation_id: Option<String>,
    /// The carrier grant, present only when `mode` is [`AuthKind::Grant`].
    pub grant: Option<GrantToken>,
    /// The client's connection attempt: every physical link of one attempt
    /// may present the same grant.
    pub connection_attempt: ConnectionAttemptId,
    pub device_public_key: [u8; 32],
    pub device_name: String,
    pub session: SessionId,
    pub lane: Lane,
    pub lanes: Vec<Lane>,
    pub generation: u64,
    pub inbound: InboundAuthEvidence,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceAuthority {
    services: Box<[Service]>,
    /// The carrier grant that admitted the session, if one did: the only
    /// source of who the person is ([`Service::Acpmux`] names them to acpmux
    /// from it).
    grant: Option<Arc<CarrierGrant>>,
}

impl ServiceAuthority {
    /// Refuse every service. Callers add authority deliberately rather than
    /// inheriting access when the protocol gains a new service.
    pub fn none() -> Self {
        Self { services: Box::new([]), grant: None }
    }

    /// Preserve the service access held by devices before service-scoped
    /// authorization existed. This list is intentionally explicit: a future
    /// service is denied until an authority constructor includes it.
    pub fn legacy_full() -> Self {
        Self {
            services: Box::new([
                Service::MuxControl,
                Service::WorkspaceRpc,
                Service::ProcessStream,
                Service::TerminalBytes,
                Service::TcpTunnel,
                Service::ComputerUse,
            ]),
            grant: None,
        }
    }

    /// Exactly `services`, each once, in the order given.
    pub fn from_services(services: impl IntoIterator<Item = Service>) -> Self {
        let mut unique = Vec::new();
        for service in services {
            if !unique.contains(&service) {
                unique.push(service);
            }
        }
        Self { services: unique.into_boxed_slice(), grant: None }
    }

    /// This authority, held by the session `grant` admitted.
    pub fn with_grant(mut self, grant: CarrierGrant) -> Self {
        self.grant = Some(Arc::new(grant));
        self
    }

    /// Whether this grant may open the service.
    pub fn allows(&self, service: Service) -> bool {
        self.services.contains(&service)
    }

    /// The carrier grant that admitted the session, if one did.
    pub fn grant(&self) -> Option<&Arc<CarrierGrant>> {
        self.grant.as_ref()
    }
}

impl Default for ServiceAuthority {
    fn default() -> Self {
        Self::none()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthGrant {
    pub device_id: String,
    pub daemon_name: String,
    pub revocation_generation: u64,
    pub authority: ServiceAuthority,
}

pub struct AcceptedSecureLink {
    pub link: SecureLink,
    pub grant: AuthGrant,
    pub resume: BTreeMap<Lane, u64>,
    pub session: SessionId,
    pub lane: Lane,
    pub lanes: Vec<Lane>,
    pub generation: u64,
    pub connection_attempt: ConnectionAttemptId,
}

pub(crate) struct VerifiedSecureLink {
    link: SecureLink,
    request: AuthRequest,
    connection_attempt: ConnectionAttemptId,
    resume: BTreeMap<Lane, u64>,
}

impl VerifiedSecureLink {
    pub(crate) fn auth_kind(&self) -> AuthKind {
        self.request.mode
    }
}

impl fmt::Debug for AcceptedSecureLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AcceptedSecureLink")
            .field("link", &self.link)
            .field("grant", &self.grant)
            .field("resume", &self.resume)
            .field("session", &self.session)
            .field("lane", &self.lane)
            .field("lanes", &self.lanes)
            .field("generation", &self.generation)
            .field("connection_attempt", &self.connection_attempt)
            .finish()
    }
}

#[async_trait]
pub trait ServerAuthenticator: Send + Sync {
    async fn invitation_secret(&self, id: &str) -> Result<Option<[u8; 32]>, CryptoError>;
    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthKind {
    Enrolled,
    Invitation,
    Carrier,
    Grant,
}

#[derive(Debug, Serialize, Deserialize)]
struct ClientPrelude {
    name: String,
    protocol: u8,
    auth: AuthKind,
    invitation_id: Option<String>,
    session: SessionId,
    lane: Lane,
    lanes: Vec<Lane>,
    generation: u64,
    connection_attempt: ConnectionAttemptId,
    /// The Noise pattern that follows. Absent (an older client): XX, or XXpsk3 with an
    /// invitation. Part of the prologue, so a relay that rewrites it breaks the handshake.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pattern: Option<Pattern>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ClientHello {
    device_name: String,
    resume: BTreeMap<Lane, u64>,
    /// The carrier grant. It travels in the third Noise message, encrypted
    /// to the daemon's static key, never in the plaintext prelude.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    grant: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ServerWelcome {
    accepted: bool,
    error: Option<String>,
    daemon_name: Option<String>,
    device_id: Option<String>,
    revocation_generation: Option<u64>,
    /// What this daemon's handshake takes beyond XX. Absent from an older daemon, which an
    /// older client never reads either.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capabilities: Option<Capabilities>,
}

pub struct SecureLink {
    description: String,
    inner: Box<dyn FrameLink>,
    transport: snow::StatelessTransportState,
    maximum_plaintext: usize,
    remote_static: [u8; 32],
    /// Held from taking a nonce until the record is handed to the inner link, so records go
    /// out in nonce order even when two tasks send at once.
    send_order: tokio::sync::Mutex<()>,
    send_nonce: AtomicU64,
    /// The nonce the next record must carry. The transport is stateless, so this is the only
    /// replay guard: a record whose nonce is not exactly this one (a duplicate, a reorder or a
    /// skip, as a relay in the middle could make) fails the link for good.
    receive_nonce: AtomicU64,
    /// The daemon's welcome is still unread ([`initiate_secure_link_pipelined`]): the first
    /// receive reads and checks it before handing back any record.
    welcome_pending: std::sync::atomic::AtomicBool,
    /// The pattern this link's handshake ran.
    pattern: Pattern,
    /// The daemon's welcome said it takes IK (set once the welcome is read).
    peer_takes_ik: std::sync::atomic::AtomicBool,
}

/// `receive_nonce` once the link has failed; no record can carry it.
const RECEIVE_FAILED: u64 = u64::MAX;

impl fmt::Debug for SecureLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureLink")
            .field("description", &self.description)
            .field("maximum_plaintext", &self.maximum_plaintext)
            .field("remote_fingerprint", &public_key_fingerprint(&self.remote_static))
            .finish_non_exhaustive()
    }
}

impl SecureLink {
    pub fn remote_static(&self) -> [u8; 32] {
        self.remote_static
    }

    /// The Noise pattern this link's handshake ran.
    pub fn pattern(&self) -> Pattern {
        self.pattern
    }

    /// Whether the daemon's welcome said it takes IK, so the next link may run it. False until
    /// the welcome is read (a pipelined link reads it with its first receive).
    pub fn peer_takes_ik(&self) -> bool {
        self.peer_takes_ik.load(Ordering::Acquire)
    }

    /// Fails the link on the first bad record: no later record is accepted and the inner link
    /// is closed.
    fn note_welcome(&self, welcome: &ServerWelcome) {
        let ik = welcome.capabilities.is_some_and(|capabilities| capabilities.ik);
        self.peer_takes_ik.store(ik, Ordering::Release);
    }

    async fn fail_receive(&self, reason: String) -> LinkError {
        self.receive_nonce.store(RECEIVE_FAILED, Ordering::Release);
        let _ = self.inner.close().await;
        LinkError::Protocol(reason)
    }
}

#[async_trait]
impl FrameLink for SecureLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum_plaintext
    }

    fn terminal_control_drain_active(&self) -> bool {
        self.inner.terminal_control_drain_active()
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if frame.len() > self.maximum_plaintext {
            return Err(LinkError::FrameTooLarge {
                actual: frame.len(),
                maximum: self.maximum_plaintext,
            });
        }
        let _order = self.send_order.lock().await;
        let nonce = self
            .send_nonce
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |nonce| nonce.checked_add(1))
            .map_err(|_| LinkError::Protocol("Noise send nonce exhausted".into()))?;
        let mut ciphertext = vec![0_u8; NOISE_NONCE_BYTES + frame.len() + NOISE_TAG_BYTES];
        ciphertext[..NOISE_NONCE_BYTES].copy_from_slice(&nonce.to_be_bytes());
        let size = self
            .transport
            .write_message(nonce, &frame, &mut ciphertext[NOISE_NONCE_BYTES..])
            .map_err(|error| LinkError::Protocol(format!("Noise encrypt failed: {error}")))?;
        ciphertext.truncate(NOISE_NONCE_BYTES + size);
        self.inner.send(Bytes::from(ciphertext)).await
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        if self.welcome_pending.swap(false, Ordering::AcqRel) {
            let Some(encoded) = self.receive_record().await? else { return Ok(None) };
            let welcome: ServerWelcome = serde_json::from_slice(&encoded)
                .map_err(|error| LinkError::Protocol(format!("handshake JSON failed: {error}")))?;
            self.note_welcome(&welcome);
            if !welcome.accepted {
                let _ = self.inner.close().await;
                return Err(LinkError::Protocol(format!(
                    "daemon rejected device: {}",
                    welcome.error.unwrap_or_else(|| "no reason given".into())
                )));
            }
        }
        self.receive_record().await
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.inner.close().await
    }
}

impl SecureLink {
    async fn receive_record(&self) -> Result<Option<Bytes>, LinkError> {
        let Some(ciphertext) = self.inner.receive().await? else { return Ok(None) };
        if ciphertext.len() > NOISE_MAX_MESSAGE {
            return Err(LinkError::FrameTooLarge {
                actual: ciphertext.len(),
                maximum: NOISE_MAX_MESSAGE,
            });
        }
        if ciphertext.len() < NOISE_NONCE_BYTES + NOISE_TAG_BYTES {
            return Err(LinkError::Protocol("Noise record is truncated".into()));
        }
        let nonce = u64::from_be_bytes(ciphertext[..NOISE_NONCE_BYTES].try_into().unwrap());
        let expected = self.receive_nonce.load(Ordering::Acquire);
        if expected == RECEIVE_FAILED || nonce != expected {
            return Err(self
                .fail_receive(format!(
                    "Noise record out of order: nonce {nonce}, expected {expected}"
                ))
                .await);
        }
        let mut plaintext = vec![0_u8; ciphertext.len() - NOISE_NONCE_BYTES];
        let size = match self.transport.read_message(
            nonce,
            &ciphertext[NOISE_NONCE_BYTES..],
            &mut plaintext,
        ) {
            Ok(size) => size,
            Err(error) => {
                return Err(self.fail_receive(format!("Noise decrypt failed: {error}")).await);
            }
        };
        // Only an authentic record moves the window, and only from the nonce it was checked at.
        if self
            .receive_nonce
            .compare_exchange(expected, expected + 1, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(self.fail_receive("Noise records received concurrently".into()).await);
        }
        plaintext.truncate(size);
        Ok(Some(Bytes::from(plaintext)))
    }
}

pub async fn initiate_secure_link(
    link: Box<dyn FrameLink>,
    config: ClientHandshake,
) -> Result<SecureLink, CryptoError> {
    let secure = complete_handshake(link, config).await?;
    let welcome: ServerWelcome = receive_secure_json(&secure).await?;
    secure.note_welcome(&welcome);
    if !welcome.accepted {
        return Err(CryptoError::Unauthorized(
            welcome.error.unwrap_or_else(|| "daemon rejected device".into()),
        ));
    }
    Ok(secure)
}

/// [`initiate_secure_link`] that returns once the Noise handshake is done, without waiting for
/// the daemon's welcome: the caller's first record rides right behind the last handshake
/// message, saving a round trip. The welcome is read and checked by the first receive, so a
/// refusal still fails the link before any answer is handed back. Records sent before then go
/// only to the pinned daemon key; use it only with `expected_daemon` set and an auth that never
/// waits on a human (an invitation's welcome can).
pub async fn initiate_secure_link_pipelined(
    link: Box<dyn FrameLink>,
    config: ClientHandshake,
) -> Result<SecureLink, CryptoError> {
    if config.expected_daemon.is_none() {
        return Err(CryptoError::Link("a pipelined handshake needs a pinned daemon key".into()));
    }
    let secure = complete_handshake(link, config).await?;
    secure.welcome_pending.store(true, Ordering::Release);
    Ok(secure)
}

async fn complete_handshake(
    link: Box<dyn FrameLink>,
    config: ClientHandshake,
) -> Result<SecureLink, CryptoError> {
    let (auth, invitation_id, psk) = match &config.auth {
        ClientAuthMode::Enrolled => (AuthKind::Enrolled, None, None),
        ClientAuthMode::Invitation { id, secret } => {
            (AuthKind::Invitation, Some(id.clone()), Some(&**secret))
        }
        ClientAuthMode::Carrier => (AuthKind::Carrier, None, None),
        ClientAuthMode::Grant { .. } => (AuthKind::Grant, None, None),
    };
    // A grant opens a new session only; a resume (generation 1+) re-admits
    // the same Noise key with no grant.
    let grant = match &config.auth {
        ClientAuthMode::Grant { token } if config.generation == 0 => {
            Some(token.as_str().to_owned())
        }
        _ => None,
    };
    let pattern = cmux_braid_session::choose(LinkFacts {
        invitation: psk.is_some(),
        pinned_peer: config.expected_daemon.is_some(),
        peer_takes_ik: config.daemon_takes_ik,
        carries_bearer_secret: grant.is_some(),
    });
    let prelude = ClientPrelude {
        name: HANDSHAKE_NAME.into(),
        protocol: REMOTE_PROTOCOL_VERSION,
        auth,
        invitation_id,
        session: config.session,
        lane: config.lane,
        lanes: config.lanes,
        generation: config.generation,
        connection_attempt: config.connection_attempt,
        // An XX link keeps the prelude an older daemon reads byte for byte.
        pattern: (pattern == Pattern::Ik).then_some(Pattern::Ik),
    };
    validate_lanes(prelude.lane, &prelude.lanes)?;
    let prelude_bytes = serde_json::to_vec(&prelude).map_err(CryptoError::Json)?;

    // A live daemon answers the prelude and Noise exchange immediately; only
    // the welcome below may legitimately wait on a human (invitation
    // approval). Deadline the machine-speed phase so an endpoint that accepts
    // the transport and then never speaks fails instead of pinning the
    // connection until the caller's much larger startup budget expires.
    let handshake_phase = async {
        send_bytes(&*link, Bytes::copy_from_slice(&prelude_bytes)).await?;

        let params: NoiseParams = pattern.noise_name().parse().map_err(CryptoError::Noise)?;
        let mut builder = snow::Builder::new(params)
            .prologue(&prelude_bytes)
            .map_err(CryptoError::Noise)?
            .local_private_key(config.identity.private_key())
            .map_err(CryptoError::Noise)?;
        if let Some(psk) = psk {
            builder = builder.psk(3, psk).map_err(CryptoError::Noise)?;
        }
        let hello = serde_json::to_vec(&ClientHello {
            device_name: config.device_name,
            resume: config.resume,
            grant,
        })
        .map_err(CryptoError::Json)?;
        // IK is chosen only with a pinned key.
        if let Some(expected) = config.expected_daemon.filter(|_| pattern == Pattern::Ik) {
            // `-> e es s ss` with the hello, `<- e ee se`: the daemon's key is the pinned one
            // by construction, and its proof (msg2 decrypting) arrives with the welcome.
            builder = builder.remote_public_key(&expected).map_err(CryptoError::Noise)?;
            let mut handshake = builder.build_initiator().map_err(CryptoError::Noise)?;
            write_handshake(&*link, &mut handshake, &hello).await?;
            read_handshake(&*link, &mut handshake).await?;
            let transport =
                handshake.into_stateless_transport_mode().map_err(CryptoError::Noise)?;
            return Ok((transport, expected));
        }
        let mut handshake = builder.build_initiator().map_err(CryptoError::Noise)?;
        write_handshake(&*link, &mut handshake, &[]).await?;
        read_handshake(&*link, &mut handshake).await?;

        let remote_static = handshake_remote_static(&handshake)?;
        if config.expected_daemon.is_some_and(|expected| expected != remote_static) {
            return Err(CryptoError::DaemonKeyMismatch {
                expected: config.expected_daemon.map(|key| public_key_fingerprint(&key)).unwrap(),
                actual: public_key_fingerprint(&remote_static),
            });
        }

        write_handshake(&*link, &mut handshake, &hello).await?;
        let transport = handshake.into_stateless_transport_mode().map_err(CryptoError::Noise)?;
        Ok((transport, remote_static))
    };
    let (transport, remote_static) =
        match tokio::time::timeout(config.handshake_timeout, handshake_phase).await {
            Ok(Ok(completed)) => completed,
            Ok(Err(error)) => {
                if matches!(error, CryptoError::DaemonKeyMismatch { .. }) {
                    let _ = link.close().await;
                }
                return Err(error);
            }
            Err(_) => {
                // Tear the transport down before reporting, bounding a close
                // that itself needs the dead peer to answer.
                let _ = tokio::time::timeout(HANDSHAKE_TEARDOWN_TIMEOUT, link.close()).await;
                return Err(CryptoError::HandshakeTimeout { timeout: config.handshake_timeout });
            }
        };
    secure_link(link, transport, remote_static, pattern)
}

pub async fn accept_secure_link(
    link: Box<dyn FrameLink>,
    identity: &StaticIdentity,
    authenticator: &dyn ServerAuthenticator,
    inbound: InboundAuthEvidence,
) -> Result<AcceptedSecureLink, CryptoError> {
    let verified = verify_secure_link(link, identity, authenticator, inbound).await?;
    authorize_secure_link(verified, authenticator).await
}

pub(crate) async fn verify_secure_link(
    link: Box<dyn FrameLink>,
    identity: &StaticIdentity,
    authenticator: &dyn ServerAuthenticator,
    inbound: InboundAuthEvidence,
) -> Result<VerifiedSecureLink, CryptoError> {
    let prelude_bytes = receive_bytes(&*link).await?;
    let prelude: ClientPrelude =
        serde_json::from_slice(&prelude_bytes).map_err(CryptoError::Json)?;
    if prelude.name != HANDSHAKE_NAME {
        return Err(CryptoError::BadPrelude("unexpected handshake name".into()));
    }
    if prelude.protocol != REMOTE_PROTOCOL_VERSION {
        return Err(CryptoError::BadPrelude(format!("unsupported protocol {}", prelude.protocol)));
    }
    validate_lanes(prelude.lane, &prelude.lanes)?;

    let invitation_secret =
        match prelude.auth {
            AuthKind::Invitation => {
                let id = prelude
                    .invitation_id
                    .as_deref()
                    .ok_or_else(|| CryptoError::BadPrelude("invitation id is required".into()))?;
                Some(authenticator.invitation_secret(id).await?.ok_or_else(|| {
                    CryptoError::Unauthorized("unknown or expired invitation".into())
                })?)
            }
            AuthKind::Enrolled | AuthKind::Carrier | AuthKind::Grant => None,
        };

    let pattern = match (prelude.pattern, invitation_secret.is_some()) {
        (None, true) => Pattern::XxPsk3,
        (None, false) => Pattern::Xx,
        (Some(Pattern::Ik), false) => Pattern::Ik,
        (Some(other), _) => {
            return Err(CryptoError::BadPrelude(format!(
                "pattern {other:?} is not offered for {:?}",
                prelude.auth
            )));
        }
    };
    let params: NoiseParams = pattern.noise_name().parse().map_err(CryptoError::Noise)?;
    let mut builder = snow::Builder::new(params)
        .prologue(&prelude_bytes)
        .map_err(CryptoError::Noise)?
        .local_private_key(identity.private_key())
        .map_err(CryptoError::Noise)?;
    if let Some(secret) = &invitation_secret {
        builder = builder.psk(3, secret).map_err(CryptoError::Noise)?;
    }
    let mut handshake = builder.build_responder().map_err(CryptoError::Noise)?;
    let hello_payload = if pattern == Pattern::Ik {
        // `-> e es s ss` carries the hello; `<- e ee se` finishes it.
        let hello = read_handshake(&*link, &mut handshake).await?;
        write_handshake(&*link, &mut handshake, &[]).await?;
        hello
    } else {
        read_handshake(&*link, &mut handshake).await?;
        write_handshake(&*link, &mut handshake, &[]).await?;
        read_handshake(&*link, &mut handshake).await?
    };
    let remote_static = handshake_remote_static(&handshake)?;
    let hello: ClientHello = serde_json::from_slice(&hello_payload).map_err(CryptoError::Json)?;
    if pattern == Pattern::Ik && hello.grant.is_some() {
        // IK's first message is not forward secret; a grant never rides it.
        return Err(CryptoError::BadPrelude("a carrier grant needs an XX link".into()));
    }
    let transport = handshake.into_stateless_transport_mode().map_err(CryptoError::Noise)?;
    let secure = secure_link(link, transport, remote_static, pattern)?;

    Ok(VerifiedSecureLink {
        link: secure,
        request: AuthRequest {
            mode: prelude.auth,
            invitation_id: prelude.invitation_id,
            // A grant counts only under the grant mode; any other mode drops it.
            grant: hello.grant.filter(|_| prelude.auth == AuthKind::Grant).map(GrantToken::new),
            connection_attempt: prelude.connection_attempt,
            device_public_key: remote_static,
            device_name: hello.device_name,
            session: prelude.session,
            lane: prelude.lane,
            lanes: prelude.lanes,
            generation: prelude.generation,
            inbound,
        },
        connection_attempt: prelude.connection_attempt,
        resume: hello.resume,
    })
}

pub(crate) async fn authorize_secure_link(
    verified: VerifiedSecureLink,
    authenticator: &dyn ServerAuthenticator,
) -> Result<AcceptedSecureLink, CryptoError> {
    let authorization = authenticator.authorize(verified.request.clone()).await;
    let grant = match authorization {
        Ok(grant) => {
            send_secure_json(
                &verified.link,
                &ServerWelcome {
                    accepted: true,
                    error: None,
                    daemon_name: Some(grant.daemon_name.clone()),
                    device_id: Some(grant.device_id.clone()),
                    revocation_generation: Some(grant.revocation_generation),
                    capabilities: Some(Capabilities { ik: true, ..Capabilities::default() }),
                },
            )
            .await?;
            grant
        }
        Err(message) => {
            let _ = send_secure_json(
                &verified.link,
                &ServerWelcome {
                    accepted: false,
                    error: Some(message.clone()),
                    daemon_name: None,
                    device_id: None,
                    revocation_generation: None,
                    capabilities: None,
                },
            )
            .await;
            let _ = verified.link.close().await;
            return Err(CryptoError::Unauthorized(message));
        }
    };
    Ok(AcceptedSecureLink {
        link: verified.link,
        grant,
        resume: verified.resume,
        session: verified.request.session,
        lane: verified.request.lane,
        lanes: verified.request.lanes,
        generation: verified.request.generation,
        connection_attempt: verified.connection_attempt,
    })
}

fn validate_lanes(primary: Lane, lanes: &[Lane]) -> Result<(), CryptoError> {
    if lanes.is_empty() || !lanes.contains(&primary) {
        return Err(CryptoError::BadPrelude(
            "physical link lanes must include the primary lane".into(),
        ));
    }
    let unique = lanes.iter().copied().collect::<BTreeSet<_>>();
    if unique.len() != lanes.len() {
        return Err(CryptoError::BadPrelude("physical link lanes contain duplicates".into()));
    }
    Ok(())
}

fn secure_link(
    inner: Box<dyn FrameLink>,
    transport: snow::StatelessTransportState,
    remote_static: [u8; 32],
    pattern: Pattern,
) -> Result<SecureLink, CryptoError> {
    let link_maximum = inner.maximum_frame_bytes();
    let maximum_plaintext = link_maximum
        .min(NOISE_MAX_MESSAGE)
        .checked_sub(SECURE_FRAME_OVERHEAD_BYTES)
        .ok_or_else(|| CryptoError::Link("link frame limit is too small for Noise".into()))?;
    let description = format!("noise+{}", inner.description());
    Ok(SecureLink {
        description,
        inner,
        transport,
        maximum_plaintext,
        remote_static,
        send_order: tokio::sync::Mutex::new(()),
        send_nonce: AtomicU64::new(0),
        receive_nonce: AtomicU64::new(0),
        welcome_pending: std::sync::atomic::AtomicBool::new(false),
        pattern,
        peer_takes_ik: std::sync::atomic::AtomicBool::new(false),
    })
}

async fn write_handshake(
    link: &dyn FrameLink,
    handshake: &mut snow::HandshakeState,
    payload: &[u8],
) -> Result<(), CryptoError> {
    if payload.len() > HANDSHAKE_PAYLOAD_MAX {
        return Err(CryptoError::PayloadTooLarge(payload.len()));
    }
    let mut output = vec![0_u8; NOISE_MAX_MESSAGE];
    let size = handshake.write_message(payload, &mut output).map_err(CryptoError::Noise)?;
    output.truncate(size);
    link.send(Bytes::from(output)).await.map_err(CryptoError::LinkError)
}

async fn read_handshake(
    link: &dyn FrameLink,
    handshake: &mut snow::HandshakeState,
) -> Result<Vec<u8>, CryptoError> {
    let message =
        link.receive().await.map_err(CryptoError::LinkError)?.ok_or(CryptoError::UnexpectedEof)?;
    if message.len() > NOISE_MAX_MESSAGE {
        return Err(CryptoError::PayloadTooLarge(message.len()));
    }
    let mut payload = vec![0_u8; NOISE_MAX_MESSAGE];
    let size = handshake.read_message(&message, &mut payload).map_err(CryptoError::Noise)?;
    if size > HANDSHAKE_PAYLOAD_MAX {
        return Err(CryptoError::PayloadTooLarge(size));
    }
    payload.truncate(size);
    Ok(payload)
}

fn handshake_remote_static(handshake: &snow::HandshakeState) -> Result<[u8; 32], CryptoError> {
    handshake
        .get_remote_static()
        .and_then(|key| key.try_into().ok())
        .ok_or(CryptoError::MissingRemoteStatic)
}

async fn send_bytes(link: &dyn FrameLink, encoded: Bytes) -> Result<(), CryptoError> {
    if encoded.len() > HANDSHAKE_PAYLOAD_MAX {
        return Err(CryptoError::PayloadTooLarge(encoded.len()));
    }
    link.send(encoded).await.map_err(CryptoError::LinkError)
}

async fn receive_bytes(link: &dyn FrameLink) -> Result<Bytes, CryptoError> {
    let encoded =
        link.receive().await.map_err(CryptoError::LinkError)?.ok_or(CryptoError::UnexpectedEof)?;
    if encoded.len() > HANDSHAKE_PAYLOAD_MAX {
        return Err(CryptoError::PayloadTooLarge(encoded.len()));
    }
    Ok(encoded)
}

async fn send_secure_json<T: Serialize>(link: &SecureLink, value: &T) -> Result<(), CryptoError> {
    let encoded = serde_json::to_vec(value).map_err(CryptoError::Json)?;
    link.send(Bytes::from(encoded)).await.map_err(CryptoError::LinkError)
}

async fn receive_secure_json<T: for<'de> Deserialize<'de>>(
    link: &SecureLink,
) -> Result<T, CryptoError> {
    let encoded =
        link.receive().await.map_err(CryptoError::LinkError)?.ok_or(CryptoError::UnexpectedEof)?;
    serde_json::from_slice(&encoded).map_err(CryptoError::Json)
}

#[derive(Debug)]
pub enum CryptoError {
    Random(String),
    Json(serde_json::Error),
    Noise(snow::Error),
    LinkError(LinkError),
    Link(String),
    BadPrelude(String),
    PayloadTooLarge(usize),
    MissingRemoteStatic,
    UnexpectedEof,
    DaemonKeyMismatch {
        expected: String,
        actual: String,
    },
    Unauthorized(String),
    /// The peer accepted the transport but did not complete the prelude and
    /// Noise exchange within the handshake deadline. A retryable carrier
    /// failure, like any unavailable carrier: the link is torn down before
    /// this is reported, so nothing holds TCP between attempts, and the
    /// caller's ReconnectPolicy (attempt limits, backoff, startup budget)
    /// decides when to stop redialing and exit.
    HandshakeTimeout {
        timeout: Duration,
    },
}

impl fmt::Display for CryptoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Random(message) => write!(formatter, "secure randomness failed: {message}"),
            Self::Json(error) => write!(formatter, "handshake JSON failed: {error}"),
            Self::Noise(error) => write!(formatter, "Noise handshake failed: {error}"),
            Self::LinkError(error) => write!(formatter, "{error}"),
            Self::Link(message) => write!(formatter, "secure link failed: {message}"),
            Self::BadPrelude(message) => write!(formatter, "invalid handshake prelude: {message}"),
            Self::PayloadTooLarge(size) => {
                write!(formatter, "handshake payload is too large: {size}")
            }
            Self::MissingRemoteStatic => {
                formatter.write_str("Noise handshake omitted remote static key")
            }
            Self::UnexpectedEof => formatter.write_str("link closed during handshake"),
            Self::DaemonKeyMismatch { expected, actual } => {
                write!(formatter, "daemon key mismatch: expected {expected}, got {actual}")
            }
            Self::Unauthorized(message) => {
                write!(formatter, "authorization failed: {message}")?;
                match unauthorized_next_step(message) {
                    Some(step) => write!(formatter, "; {step}"),
                    None => Ok(()),
                }
            }
            Self::HandshakeTimeout { timeout } => write!(
                formatter,
                "secure link handshake timed out after {}ms: the endpoint accepted the \
                 connection but never completed the cmux remote handshake",
                timeout.as_millis()
            ),
        }
    }
}

/// What a person does next after the host refused this device, from the host's words.
fn unauthorized_next_step(message: &str) -> Option<&'static str> {
    if message.contains("revoked") {
        Some(
            "the host's owner removed this device; ask for a new invitation (on the host: `cmux remote enroll create`), then join with `cmux remote connect --invite-file PATH`",
        )
    } else if message.contains("expired") || message.contains("already claimed") {
        Some(
            "ask for a new invitation (on the host: `cmux remote enroll create`), then join with `cmux remote connect --invite-file PATH`",
        )
    } else {
        None
    }
}

impl std::error::Error for CryptoError {}

#[cfg(test)]
mod next_step_tests {
    use super::*;

    #[test]
    fn a_refused_device_is_told_what_to_do_next() {
        for message in [
            "device has been revoked",
            "invitation is expired",
            "invitation was already claimed by another device",
        ] {
            let text = CryptoError::Unauthorized(message.into()).to_string();
            assert!(text.starts_with(&format!("authorization failed: {message}; ")), "{text}");
            assert!(text.contains("cmux remote enroll create"), "{text}");
            assert!(text.contains("cmux remote connect --invite-file"), "{text}");
        }
        let other = CryptoError::Unauthorized("no such invitation".into()).to_string();
        assert_eq!(other, "authorization failed: no such invitation");
    }
}

/// Lockstep: the IK prelude field and welcome offer, read by builds on either side of them.
#[cfg(test)]
mod lockstep_tests {
    use super::*;

    /// `ClientPrelude` and `ServerWelcome` as they were before IK.
    #[derive(Serialize, Deserialize)]
    struct OldPrelude {
        name: String,
        protocol: u8,
        auth: AuthKind,
        invitation_id: Option<String>,
        session: SessionId,
        lane: Lane,
        lanes: Vec<Lane>,
        generation: u64,
        connection_attempt: ConnectionAttemptId,
    }

    #[derive(Serialize, Deserialize)]
    struct OldWelcome {
        accepted: bool,
        error: Option<String>,
        daemon_name: Option<String>,
        device_id: Option<String>,
        revocation_generation: Option<u64>,
    }

    fn prelude(pattern: Option<Pattern>) -> ClientPrelude {
        ClientPrelude {
            name: HANDSHAKE_NAME.into(),
            protocol: REMOTE_PROTOCOL_VERSION,
            auth: AuthKind::Carrier,
            invitation_id: None,
            session: SessionId([1; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 3,
            connection_attempt: ConnectionAttemptId([2; 16]),
            pattern,
        }
    }

    #[test]
    fn an_xx_prelude_is_the_old_prelude_byte_for_byte() {
        let new = serde_json::to_vec(&prelude(None)).unwrap();
        let old = serde_json::to_vec(&OldPrelude {
            name: HANDSHAKE_NAME.into(),
            protocol: REMOTE_PROTOCOL_VERSION,
            auth: AuthKind::Carrier,
            invitation_id: None,
            session: SessionId([1; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 3,
            connection_attempt: ConnectionAttemptId([2; 16]),
        })
        .unwrap();
        assert_eq!(new, old, "an older daemon must read a new client's XX prelude unchanged");
        // And the new daemon reads the old one as XX.
        let read: ClientPrelude = serde_json::from_slice(&old).unwrap();
        assert_eq!(read.pattern, None);
        let ik = serde_json::to_string(&prelude(Some(Pattern::Ik))).unwrap();
        assert!(ik.ends_with(r#","pattern":"ik"}"#), "{ik}");
    }

    #[test]
    fn welcomes_read_across_the_ik_offer_in_both_directions() {
        // A new daemon's welcome, read by an old client: the offer is an unknown field.
        let new = serde_json::to_vec(&ServerWelcome {
            accepted: true,
            error: None,
            daemon_name: Some("d".into()),
            device_id: Some("x".into()),
            revocation_generation: Some(0),
            capabilities: Some(Capabilities { ik: true, ..Capabilities::default() }),
        })
        .unwrap();
        let old: OldWelcome = serde_json::from_slice(&new).unwrap();
        assert!(old.accepted);
        // An old daemon's welcome, read by a new client: no offer, so the client stays on XX.
        let old = serde_json::to_vec(&OldWelcome {
            accepted: true,
            error: None,
            daemon_name: Some("d".into()),
            device_id: Some("x".into()),
            revocation_generation: Some(0),
        })
        .unwrap();
        let new: ServerWelcome = serde_json::from_slice(&old).unwrap();
        assert!(new.accepted);
        assert_eq!(new.capabilities, None);
    }
}
