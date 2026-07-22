use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use base64::Engine;
use bytes::Bytes;
use cmux_remote_protocol::{Lane, REMOTE_PROTOCOL_VERSION, SessionId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use snow::params::NoiseParams;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::link::{FrameLink, LinkError};

const HANDSHAKE_NAME: &str = "cmux-remote-noise";
const NOISE_XX: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
const NOISE_XX_PSK3: &str = "Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s";
const NOISE_MAX_MESSAGE: usize = 65_535;
const NOISE_TAG_BYTES: usize = 16;
const NOISE_NONCE_BYTES: usize = 8;
const HANDSHAKE_PAYLOAD_MAX: usize = 16 * 1024;

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
    Invitation { id: String, secret: Zeroizing<[u8; 32]> },
    Carrier,
}

impl fmt::Debug for ClientAuthMode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Enrolled => formatter.write_str("Enrolled"),
            Self::Invitation { id, .. } => {
                formatter.debug_struct("Invitation").field("id", id).finish_non_exhaustive()
            }
            Self::Carrier => formatter.write_str("Carrier"),
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
    pub resume: BTreeMap<Lane, u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthRequest {
    pub mode: AuthKind,
    pub invitation_id: Option<String>,
    pub device_public_key: [u8; 32],
    pub device_name: String,
    pub session: SessionId,
    pub lane: Lane,
    pub lanes: Vec<Lane>,
    pub generation: u64,
    pub carrier_trusted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthGrant {
    pub device_id: String,
    pub daemon_name: String,
    pub revocation_generation: u64,
}

pub struct AcceptedSecureLink {
    pub link: SecureLink,
    pub grant: AuthGrant,
    pub resume: BTreeMap<Lane, u64>,
    pub session: SessionId,
    pub lane: Lane,
    pub lanes: Vec<Lane>,
    pub generation: u64,
}

pub(crate) struct VerifiedSecureLink {
    link: SecureLink,
    request: AuthRequest,
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
}

#[derive(Debug, Serialize, Deserialize)]
struct ClientHello {
    device_name: String,
    resume: BTreeMap<Lane, u64>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ServerWelcome {
    accepted: bool,
    error: Option<String>,
    daemon_name: Option<String>,
    device_id: Option<String>,
    revocation_generation: Option<u64>,
}

pub struct SecureLink {
    description: String,
    inner: Box<dyn FrameLink>,
    transport: snow::StatelessTransportState,
    maximum_plaintext: usize,
    remote_static: [u8; 32],
    send_nonce: AtomicU64,
}

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
}

#[async_trait]
impl FrameLink for SecureLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum_plaintext
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if frame.len() > self.maximum_plaintext {
            return Err(LinkError::FrameTooLarge {
                actual: frame.len(),
                maximum: self.maximum_plaintext,
            });
        }
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
        let mut plaintext = vec![0_u8; ciphertext.len() - NOISE_NONCE_BYTES];
        let size = self
            .transport
            .read_message(nonce, &ciphertext[NOISE_NONCE_BYTES..], &mut plaintext)
            .map_err(|error| LinkError::Protocol(format!("Noise decrypt failed: {error}")))?;
        plaintext.truncate(size);
        Ok(Some(Bytes::from(plaintext)))
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.inner.close().await
    }
}

pub async fn initiate_secure_link(
    link: Box<dyn FrameLink>,
    config: ClientHandshake,
) -> Result<SecureLink, CryptoError> {
    let (auth, invitation_id, psk) = match &config.auth {
        ClientAuthMode::Enrolled => (AuthKind::Enrolled, None, None),
        ClientAuthMode::Invitation { id, secret } => {
            (AuthKind::Invitation, Some(id.clone()), Some(&**secret))
        }
        ClientAuthMode::Carrier => (AuthKind::Carrier, None, None),
    };
    let prelude = ClientPrelude {
        name: HANDSHAKE_NAME.into(),
        protocol: REMOTE_PROTOCOL_VERSION,
        auth,
        invitation_id,
        session: config.session,
        lane: config.lane,
        lanes: config.lanes,
        generation: config.generation,
    };
    validate_lanes(prelude.lane, &prelude.lanes)?;
    let prelude_bytes = serde_json::to_vec(&prelude).map_err(CryptoError::Json)?;
    send_bytes(&*link, Bytes::copy_from_slice(&prelude_bytes)).await?;

    let params: NoiseParams = noise_pattern(psk.is_some()).parse().map_err(CryptoError::Noise)?;
    let mut builder = snow::Builder::new(params)
        .prologue(&prelude_bytes)
        .map_err(CryptoError::Noise)?
        .local_private_key(config.identity.private_key())
        .map_err(CryptoError::Noise)?;
    if let Some(psk) = psk {
        builder = builder.psk(3, psk).map_err(CryptoError::Noise)?;
    }
    let mut handshake = builder.build_initiator().map_err(CryptoError::Noise)?;
    write_handshake(&*link, &mut handshake, &[]).await?;
    read_handshake(&*link, &mut handshake).await?;

    let remote_static = handshake_remote_static(&handshake)?;
    if config.expected_daemon.is_some_and(|expected| expected != remote_static) {
        let _ = link.close().await;
        return Err(CryptoError::DaemonKeyMismatch {
            expected: config.expected_daemon.map(|key| public_key_fingerprint(&key)).unwrap(),
            actual: public_key_fingerprint(&remote_static),
        });
    }

    let hello =
        serde_json::to_vec(&ClientHello { device_name: config.device_name, resume: config.resume })
            .map_err(CryptoError::Json)?;
    write_handshake(&*link, &mut handshake, &hello).await?;
    let transport = handshake.into_stateless_transport_mode().map_err(CryptoError::Noise)?;
    let secure = secure_link(link, transport, remote_static)?;
    let welcome: ServerWelcome = receive_secure_json(&secure).await?;
    if !welcome.accepted {
        return Err(CryptoError::Unauthorized(
            welcome.error.unwrap_or_else(|| "daemon rejected device".into()),
        ));
    }
    Ok(secure)
}

pub async fn accept_secure_link(
    link: Box<dyn FrameLink>,
    identity: &StaticIdentity,
    authenticator: &dyn ServerAuthenticator,
    carrier_trusted: bool,
) -> Result<AcceptedSecureLink, CryptoError> {
    let verified = verify_secure_link(link, identity, authenticator, carrier_trusted).await?;
    authorize_secure_link(verified, authenticator).await
}

pub(crate) async fn verify_secure_link(
    link: Box<dyn FrameLink>,
    identity: &StaticIdentity,
    authenticator: &dyn ServerAuthenticator,
    carrier_trusted: bool,
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
            AuthKind::Enrolled | AuthKind::Carrier => None,
        };

    let params: NoiseParams =
        noise_pattern(invitation_secret.is_some()).parse().map_err(CryptoError::Noise)?;
    let mut builder = snow::Builder::new(params)
        .prologue(&prelude_bytes)
        .map_err(CryptoError::Noise)?
        .local_private_key(identity.private_key())
        .map_err(CryptoError::Noise)?;
    if let Some(secret) = &invitation_secret {
        builder = builder.psk(3, secret).map_err(CryptoError::Noise)?;
    }
    let mut handshake = builder.build_responder().map_err(CryptoError::Noise)?;
    read_handshake(&*link, &mut handshake).await?;
    write_handshake(&*link, &mut handshake, &[]).await?;
    let hello_payload = read_handshake(&*link, &mut handshake).await?;
    let remote_static = handshake_remote_static(&handshake)?;
    let hello: ClientHello = serde_json::from_slice(&hello_payload).map_err(CryptoError::Json)?;
    let transport = handshake.into_stateless_transport_mode().map_err(CryptoError::Noise)?;
    let secure = secure_link(link, transport, remote_static)?;

    Ok(VerifiedSecureLink {
        link: secure,
        request: AuthRequest {
            mode: prelude.auth,
            invitation_id: prelude.invitation_id,
            device_public_key: remote_static,
            device_name: hello.device_name,
            session: prelude.session,
            lane: prelude.lane,
            lanes: prelude.lanes,
            generation: prelude.generation,
            carrier_trusted,
        },
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

fn noise_pattern(invitation: bool) -> &'static str {
    if invitation { NOISE_XX_PSK3 } else { NOISE_XX }
}

fn secure_link(
    inner: Box<dyn FrameLink>,
    transport: snow::StatelessTransportState,
    remote_static: [u8; 32],
) -> Result<SecureLink, CryptoError> {
    let link_maximum = inner.maximum_frame_bytes();
    let maximum_plaintext = link_maximum
        .min(NOISE_MAX_MESSAGE)
        .checked_sub(NOISE_TAG_BYTES + NOISE_NONCE_BYTES)
        .ok_or_else(|| CryptoError::Link("link frame limit is too small for Noise".into()))?;
    let description = format!("noise+{}", inner.description());
    Ok(SecureLink {
        description,
        inner,
        transport,
        maximum_plaintext,
        remote_static,
        send_nonce: AtomicU64::new(0),
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
    DaemonKeyMismatch { expected: String, actual: String },
    Unauthorized(String),
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
            Self::Unauthorized(message) => write!(formatter, "authorization failed: {message}"),
        }
    }
}

impl std::error::Error for CryptoError {}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::link::test_support;

    struct TestAuthenticator {
        enrolled: [u8; 32],
        invitation: Option<(String, [u8; 32])>,
        seen: Mutex<Vec<AuthRequest>>,
    }

    #[async_trait]
    impl ServerAuthenticator for TestAuthenticator {
        async fn invitation_secret(&self, id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
            Ok(self
                .invitation
                .as_ref()
                .filter(|(expected, _)| expected == id)
                .map(|(_, secret)| *secret))
        }

        async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
            self.seen.lock().unwrap().push(request.clone());
            if request.mode != AuthKind::Carrier && request.device_public_key != self.enrolled {
                return Err("device is not enrolled".into());
            }
            Ok(AuthGrant {
                device_id: public_key_fingerprint(&request.device_public_key),
                daemon_name: "test-daemon".into(),
                revocation_generation: 4,
            })
        }
    }

    fn client_config(
        client: StaticIdentity,
        daemon: &StaticIdentity,
        auth: ClientAuthMode,
    ) -> ClientHandshake {
        ClientHandshake {
            identity: client,
            expected_daemon: Some(daemon.public_key()),
            auth,
            device_name: "test-client".into(),
            session: SessionId([3; 16]),
            lane: Lane::Interactive,
            lanes: vec![Lane::Interactive],
            generation: 0,
            resume: BTreeMap::from([(Lane::Interactive, 9)]),
        }
    }

    #[tokio::test]
    async fn enrolled_device_establishes_encrypted_link() {
        let daemon = StaticIdentity::generate().unwrap();
        let client = StaticIdentity::generate().unwrap();
        let auth = TestAuthenticator {
            enrolled: client.public_key(),
            invitation: None,
            seen: Mutex::new(Vec::new()),
        };
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let client_config = client_config(client.clone(), &daemon, ClientAuthMode::Enrolled);

        let (client_result, server_result) = tokio::join!(
            initiate_secure_link(Box::new(client_link), client_config),
            accept_secure_link(Box::new(server_link), &daemon, &auth, false),
        );
        let client_secure = client_result.unwrap();
        let accepted = server_result.unwrap();
        assert_eq!(accepted.grant.revocation_generation, 4);
        assert_eq!(accepted.resume.get(&Lane::Interactive), Some(&9));
        assert_eq!(accepted.session, SessionId([3; 16]));
        assert_eq!(accepted.lane, Lane::Interactive);
        assert_eq!(accepted.lanes, [Lane::Interactive]);
        assert_eq!(accepted.generation, 0);
        assert_eq!(client_secure.remote_static(), daemon.public_key());
        assert_eq!(accepted.link.remote_static(), client.public_key());

        client_secure.send(Bytes::from_static(b"secret input")).await.unwrap();
        assert_eq!(accepted.link.receive().await.unwrap().unwrap().as_ref(), b"secret input");
    }

    #[tokio::test]
    async fn client_rejects_substituted_daemon_key() {
        let daemon = StaticIdentity::generate().unwrap();
        let wrong_daemon = StaticIdentity::generate().unwrap();
        let client = StaticIdentity::generate().unwrap();
        let auth = TestAuthenticator {
            enrolled: client.public_key(),
            invitation: None,
            seen: Mutex::new(Vec::new()),
        };
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let config = client_config(client, &wrong_daemon, ClientAuthMode::Enrolled);

        let (client_result, _) = tokio::join!(
            initiate_secure_link(Box::new(client_link), config),
            accept_secure_link(Box::new(server_link), &daemon, &auth, false),
        );
        assert!(matches!(client_result, Err(CryptoError::DaemonKeyMismatch { .. })));
    }

    #[tokio::test]
    async fn invitation_requires_matching_psk() {
        let daemon = StaticIdentity::generate().unwrap();
        let client = StaticIdentity::generate().unwrap();
        let auth = TestAuthenticator {
            enrolled: client.public_key(),
            invitation: Some(("invite".into(), [7; 32])),
            seen: Mutex::new(Vec::new()),
        };
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let config = client_config(
            client,
            &daemon,
            ClientAuthMode::Invitation { id: "invite".into(), secret: Zeroizing::new([8; 32]) },
        );

        let (client_result, server_result) = tokio::join!(
            initiate_secure_link(Box::new(client_link), config),
            accept_secure_link(Box::new(server_link), &daemon, &auth, false),
        );
        assert!(client_result.is_err());
        assert!(server_result.is_err());
    }
}
