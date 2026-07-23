use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, Notify, oneshot, watch};

use crate::crypto::{
    AuthGrant, AuthKind, AuthRequest, CryptoError, ServerAuthenticator, StaticIdentity,
    public_key_fingerprint,
};

const STATE_VERSION: u32 = 1;
const MAX_INVITATION_TTL: Duration = Duration::from_secs(5 * 60);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const ENROLLMENT_RETRY_GRACE: Duration = Duration::from_secs(60);
const MAX_INVITATION_RELAY_ROUTES: usize = 2;
const MAX_RELAY_SLOT_BYTES: usize = 256;
const MAX_RELAY_TICKET_BYTES: usize = 4 * 1024;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnrollmentRelayAccess {
    pub route: String,
    pub slot: String,
    pub ticket: String,
}

impl std::fmt::Debug for EnrollmentRelayAccess {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EnrollmentRelayAccess")
            .field("route", &self.route)
            .field("slot", &self.slot)
            .field("ticket", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnrollmentInvitation {
    pub version: u32,
    pub id: String,
    pub secret: String,
    pub daemon_public_key: String,
    pub daemon_fingerprint: String,
    pub daemon_name: String,
    pub expires_at_unix: u64,
    pub route_hints: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub relay_access: Vec<EnrollmentRelayAccess>,
    pub approval_required: bool,
}

impl std::fmt::Debug for EnrollmentInvitation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EnrollmentInvitation")
            .field("version", &self.version)
            .field("id", &self.id)
            .field("secret", &"[REDACTED]")
            .field("daemon_fingerprint", &self.daemon_fingerprint)
            .field("daemon_name", &self.daemon_name)
            .field("expires_at_unix", &self.expires_at_unix)
            .field("route_hints", &self.route_hints)
            .field("relay_access_count", &self.relay_access.len())
            .field("approval_required", &self.approval_required)
            .finish()
    }
}

impl EnrollmentInvitation {
    pub fn secret_bytes(&self) -> Result<[u8; 32], IdentityError> {
        decode_key(&self.secret)
    }

    pub fn to_uri(&self) -> Result<String, IdentityError> {
        validate_relay_access(&self.route_hints, &self.relay_access)?;
        let json = serde_json::to_vec(self).map_err(IdentityError::Json)?;
        Ok(format!(
            "cmux://enroll/{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
        ))
    }

    pub fn from_uri(uri: &str) -> Result<Self, IdentityError> {
        let encoded = uri
            .strip_prefix("cmux://enroll/")
            .ok_or_else(|| IdentityError::Invalid("enrollment URI has the wrong scheme".into()))?;
        if encoded.len() > 16 * 1024 {
            return Err(IdentityError::Invalid("enrollment URI is too large".into()));
        }
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(encoded)
            .map_err(IdentityError::Base64)?;
        let invitation: Self = serde_json::from_slice(&json).map_err(IdentityError::Json)?;
        if invitation.version != STATE_VERSION {
            return Err(IdentityError::Invalid(format!(
                "invitation version {} is unsupported",
                invitation.version
            )));
        }
        if invitation.expires_at_unix <= unix_time()? {
            return Err(IdentityError::InvitationExpired(invitation.id));
        }
        let public = decode_key(&invitation.daemon_public_key)?;
        if public_key_fingerprint(&public) != invitation.daemon_fingerprint {
            return Err(IdentityError::Invalid(
                "invitation daemon key does not match its fingerprint".into(),
            ));
        }
        invitation.secret_bytes()?;
        validate_relay_access(&invitation.route_hints, &invitation.relay_access)?;
        Ok(invitation)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct KnownDaemon {
    pub fingerprint: String,
    pub name: String,
    pub public_key: String,
    pub route_hints: Vec<String>,
    #[serde(default)]
    pub auth: KnownDaemonAuth,
    pub first_seen_at_unix: u64,
    pub last_used_at_unix: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum KnownDaemonAuth {
    #[default]
    Enrolled,
    Carrier,
}

pub struct ClientIdentityStore {
    state_dir: PathBuf,
    identity: StaticIdentity,
    state: Mutex<PersistedClientState>,
}

impl std::fmt::Debug for ClientIdentityStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ClientIdentityStore")
            .field("state_dir", &self.state_dir)
            .field("device_fingerprint", &self.identity.fingerprint())
            .finish_non_exhaustive()
    }
}

impl ClientIdentityStore {
    pub fn load_or_create(state_dir: impl Into<PathBuf>) -> Result<Arc<Self>, IdentityError> {
        let state_dir = state_dir.into();
        secure_directory(&state_dir)?;
        let identity = load_or_create_identity(&state_dir.join("client-identity.json"))?;
        let path = state_dir.join("known-daemons.json");
        let state = if path.exists() {
            let data = fs::read(&path).map_err(IdentityError::Io)?;
            let state: PersistedClientState =
                serde_json::from_slice(&data).map_err(IdentityError::Json)?;
            if state.version != STATE_VERSION {
                return Err(IdentityError::Invalid(format!(
                    "known-daemon state version {} is unsupported",
                    state.version
                )));
            }
            state
        } else {
            PersistedClientState::default()
        };
        Ok(Arc::new(Self { state_dir, identity, state: Mutex::new(state) }))
    }

    pub fn identity(&self) -> StaticIdentity {
        self.identity.clone()
    }

    pub async fn known_daemons(&self) -> Vec<KnownDaemon> {
        let mut daemons = self.state.lock().await.daemons.values().cloned().collect::<Vec<_>>();
        daemons.sort_by(|left, right| left.name.cmp(&right.name));
        daemons
    }

    pub async fn pin_invitation(
        &self,
        invitation: &EnrollmentInvitation,
    ) -> Result<KnownDaemon, IdentityError> {
        let public = decode_key(&invitation.daemon_public_key)?;
        self.pin_daemon(invitation.daemon_name.clone(), public, invitation.route_hints.clone())
            .await
    }

    pub async fn pin_daemon(
        &self,
        name: String,
        public_key: [u8; 32],
        route_hints: Vec<String>,
    ) -> Result<KnownDaemon, IdentityError> {
        self.pin_daemon_with_auth(name, public_key, route_hints, KnownDaemonAuth::Enrolled).await
    }

    pub async fn pin_carrier_daemon(
        &self,
        name: String,
        public_key: [u8; 32],
        route_hints: Vec<String>,
    ) -> Result<KnownDaemon, IdentityError> {
        self.pin_daemon_with_auth(name, public_key, route_hints, KnownDaemonAuth::Carrier).await
    }

    async fn pin_daemon_with_auth(
        &self,
        name: String,
        public_key: [u8; 32],
        route_hints: Vec<String>,
        auth: KnownDaemonAuth,
    ) -> Result<KnownDaemon, IdentityError> {
        let fingerprint = public_key_fingerprint(&public_key);
        let now = unix_time()?;
        let mut state = self.state.lock().await;
        if let Some(existing) = state.daemons.get_mut(&fingerprint) {
            if decode_key(&existing.public_key)? != public_key {
                return Err(IdentityError::Invalid("known daemon fingerprint collision".into()));
            }
            existing.last_used_at_unix = now;
            if auth == KnownDaemonAuth::Carrier || existing.auth == KnownDaemonAuth::Carrier {
                for route in route_hints {
                    if !existing.route_hints.contains(&route) {
                        existing.route_hints.push(route);
                    }
                }
                if auth == KnownDaemonAuth::Enrolled {
                    existing.auth = KnownDaemonAuth::Enrolled;
                }
            } else {
                existing.route_hints = route_hints;
            }
            let record = existing.clone();
            self.persist_client_locked(&state)?;
            return Ok(record);
        }
        let record = KnownDaemon {
            fingerprint: fingerprint.clone(),
            name,
            public_key: encode_key(&public_key),
            route_hints,
            auth,
            first_seen_at_unix: now,
            last_used_at_unix: now,
        };
        state.daemons.insert(fingerprint, record.clone());
        self.persist_client_locked(&state)?;
        Ok(record)
    }

    pub async fn daemon_key(&self, fingerprint: &str) -> Result<Option<[u8; 32]>, IdentityError> {
        self.state
            .lock()
            .await
            .daemons
            .get(fingerprint)
            .map(|daemon| decode_key(&daemon.public_key))
            .transpose()
    }

    pub async fn forget_daemon(&self, fingerprint: &str) -> Result<bool, IdentityError> {
        let mut state = self.state.lock().await;
        let removed = state.daemons.remove(fingerprint).is_some();
        if removed {
            self.persist_client_locked(&state)?;
        }
        Ok(removed)
    }

    fn persist_client_locked(&self, state: &PersistedClientState) -> Result<(), IdentityError> {
        atomic_json(&self.state_dir.join("known-daemons.json"), state)
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedClientState {
    version: u32,
    #[serde(default)]
    daemons: HashMap<String, KnownDaemon>,
}

impl Default for PersistedClientState {
    fn default() -> Self {
        Self { version: STATE_VERSION, daemons: HashMap::new() }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
    pub public_key: String,
    pub fingerprint: String,
    pub created_at_unix: u64,
    pub last_seen_at_unix: u64,
    pub revoked_at_unix: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingEnrollment {
    pub invitation_id: String,
    pub device_name: String,
    pub device_fingerprint: String,
    pub requested_at_unix: u64,
}

pub struct AuthDatabase {
    state_dir: PathBuf,
    daemon_name: String,
    identity: StaticIdentity,
    allow_carrier: bool,
    state: Mutex<AuthState>,
    pending_changed: Notify,
    revocation_tx: watch::Sender<u64>,
}

impl std::fmt::Debug for AuthDatabase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AuthDatabase")
            .field("state_dir", &self.state_dir)
            .field("daemon_name", &self.daemon_name)
            .field("daemon_fingerprint", &self.identity.fingerprint())
            .field("allow_carrier", &self.allow_carrier)
            .finish_non_exhaustive()
    }
}

impl AuthDatabase {
    pub fn load_or_create(
        state_dir: impl Into<PathBuf>,
        daemon_name: impl Into<String>,
        allow_carrier: bool,
    ) -> Result<Arc<Self>, IdentityError> {
        let state_dir = state_dir.into();
        secure_directory(&state_dir)?;
        let identity = load_or_create_identity(&state_dir.join("identity.json"))?;
        let persisted = load_state(&state_dir.join("devices.json"))?;
        let (revocation_tx, _) = watch::channel(persisted.revocation_generation);
        Ok(Arc::new(Self {
            state_dir,
            daemon_name: daemon_name.into(),
            identity,
            allow_carrier,
            state: Mutex::new(AuthState::from_persisted(persisted)),
            pending_changed: Notify::new(),
            revocation_tx,
        }))
    }

    pub fn identity(&self) -> StaticIdentity {
        self.identity.clone()
    }

    pub fn daemon_name(&self) -> &str {
        &self.daemon_name
    }

    pub fn subscribe_revocations(&self) -> watch::Receiver<u64> {
        self.revocation_tx.subscribe()
    }

    pub async fn create_invitation(
        &self,
        ttl: Duration,
        route_hints: Vec<String>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        self.create_invitation_with_relay_access(ttl, route_hints, Vec::new()).await
    }

    pub async fn create_invitation_with_relay_access(
        &self,
        ttl: Duration,
        route_hints: Vec<String>,
        relay_access: Vec<EnrollmentRelayAccess>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        let ttl = ttl.min(MAX_INVITATION_TTL);
        if ttl.is_zero() {
            return Err(IdentityError::Invalid("invitation ttl must be positive".into()));
        }
        validate_relay_access(&route_hints, &relay_access)?;
        let now = unix_time()?;
        let expires_at_unix = now.saturating_add(ttl.as_secs());
        let id = random_token(16)?;
        let mut secret = [0_u8; 32];
        getrandom::fill(&mut secret).map_err(|error| IdentityError::Random(error.to_string()))?;
        let mut state = self.state.lock().await;
        state.prune_invitations(now);
        state.invitations.insert(
            id.clone(),
            InvitationRecord {
                secret,
                expires_at_unix,
                route_hints: route_hints.clone(),
                claimed_by: None,
            },
        );
        self.persist_locked(&state)?;
        Ok(EnrollmentInvitation {
            version: STATE_VERSION,
            id,
            secret: encode_key(&secret),
            daemon_public_key: encode_key(&self.identity.public_key()),
            daemon_fingerprint: self.identity.fingerprint(),
            daemon_name: self.daemon_name.clone(),
            expires_at_unix,
            route_hints,
            relay_access,
            approval_required: true,
        })
    }

    pub async fn list_devices(&self) -> Vec<DeviceRecord> {
        self.state.lock().await.devices.values().cloned().collect()
    }

    pub async fn device_is_active(&self, device_id: &str) -> bool {
        if device_id.starts_with("carrier:") {
            return self.allow_carrier;
        }
        self.state
            .lock()
            .await
            .devices
            .get(device_id)
            .is_some_and(|device| device.revoked_at_unix.is_none())
    }

    /// Revalidate an authorization result at the point where a connection is
    /// published. The generation check closes the race where a revocation can
    /// happen after the Noise handshake but before all physical lanes arrive.
    pub async fn grant_is_current(&self, grant: &AuthGrant) -> bool {
        if grant.device_id.starts_with("carrier:") {
            return self.allow_carrier;
        }
        let state = self.state.lock().await;
        grant.revocation_generation == state.revocation_generation
            && state
                .devices
                .get(&grant.device_id)
                .is_some_and(|device| device.revoked_at_unix.is_none())
    }

    pub async fn pending_enrollments(&self) -> Vec<PendingEnrollment> {
        self.state.lock().await.pending.values().map(|pending| pending.request.clone()).collect()
    }

    pub async fn wait_for_pending(
        &self,
        timeout: Duration,
    ) -> Result<Vec<PendingEnrollment>, IdentityError> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let pending = self.pending_enrollments().await;
            if !pending.is_empty() {
                return Ok(pending);
            }
            tokio::time::timeout_at(deadline, self.pending_changed.notified())
                .await
                .map_err(|_| IdentityError::Timeout)?;
        }
    }

    pub async fn approve(&self, invitation_id: &str) -> Result<DeviceRecord, IdentityError> {
        let now = unix_time()?;
        let (record, decision) = {
            let mut state = self.state.lock().await;
            let pending = state
                .pending
                .remove(invitation_id)
                .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
            let invitation = state
                .invitations
                .get_mut(invitation_id)
                .ok_or_else(|| IdentityError::InvitationExpired(invitation_id.into()))?;
            if invitation.expires_at_unix <= now {
                return Err(IdentityError::InvitationExpired(invitation_id.into()));
            }
            let fingerprint = public_key_fingerprint(&pending.device_public_key);
            invitation.claimed_by = Some(fingerprint.clone());
            invitation.expires_at_unix = invitation
                .expires_at_unix
                .max(now.saturating_add(ENROLLMENT_RETRY_GRACE.as_secs()));
            let record = DeviceRecord {
                id: fingerprint.clone(),
                name: pending.request.device_name.clone(),
                public_key: encode_key(&pending.device_public_key),
                fingerprint,
                created_at_unix: now,
                last_seen_at_unix: now,
                revoked_at_unix: None,
            };
            state.devices.insert(record.id.clone(), record.clone());
            self.persist_locked(&state)?;
            (record, pending.decision)
        };
        let grant = AuthGrant {
            device_id: record.id.clone(),
            daemon_name: self.daemon_name.clone(),
            revocation_generation: *self.revocation_tx.borrow(),
        };
        let _ = decision.send(Ok(grant));
        Ok(record)
    }

    pub async fn deny(&self, invitation_id: &str) -> Result<(), IdentityError> {
        let decision = {
            let mut state = self.state.lock().await;
            let pending = state
                .pending
                .remove(invitation_id)
                .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
            state.invitations.remove(invitation_id);
            self.persist_locked(&state)?;
            pending.decision
        };
        let _ = decision.send(Err("enrollment denied".into()));
        Ok(())
    }

    pub async fn revoke(&self, device_id: &str) -> Result<(), IdentityError> {
        let now = unix_time()?;
        let generation = {
            let mut state = self.state.lock().await;
            let device = state
                .devices
                .get_mut(device_id)
                .ok_or_else(|| IdentityError::UnknownDevice(device_id.into()))?;
            device.revoked_at_unix = Some(now);
            state.revocation_generation = state
                .revocation_generation
                .checked_add(1)
                .ok_or_else(|| IdentityError::Invalid("revocation generation exhausted".into()))?;
            let generation = state.revocation_generation;
            self.persist_locked(&state)?;
            generation
        };
        let _ = self.revocation_tx.send(generation);
        Ok(())
    }

    fn persist_locked(&self, state: &AuthState) -> Result<(), IdentityError> {
        let persisted = PersistedState {
            version: STATE_VERSION,
            revocation_generation: state.revocation_generation,
            devices: state.devices.values().cloned().collect(),
            invitations: state
                .invitations
                .iter()
                .map(|(id, invitation)| PersistedInvitation {
                    id: id.clone(),
                    secret: encode_key(&invitation.secret),
                    expires_at_unix: invitation.expires_at_unix,
                    route_hints: invitation.route_hints.clone(),
                    claimed_by: invitation.claimed_by.clone(),
                })
                .collect(),
        };
        atomic_json(&self.state_dir.join("devices.json"), &persisted)
    }
}

#[async_trait]
impl ServerAuthenticator for AuthDatabase {
    async fn invitation_secret(&self, id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        let now = unix_time().map_err(|error| CryptoError::Unauthorized(error.to_string()))?;
        let mut state = self.state.lock().await;
        state.prune_invitations(now);
        Ok(state.invitations.get(id).map(|invitation| invitation.secret))
    }

    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
        match request.mode {
            AuthKind::Enrolled => {
                let now = unix_time().map_err(|error| error.to_string())?;
                let fingerprint = public_key_fingerprint(&request.device_public_key);
                let mut state = self.state.lock().await;
                let generation = state.revocation_generation;
                let device = state
                    .devices
                    .get_mut(&fingerprint)
                    .ok_or_else(|| "device is not enrolled".to_string())?;
                if device.revoked_at_unix.is_some() {
                    return Err("device has been revoked".into());
                }
                if decode_key(&device.public_key).map_err(|error| error.to_string())?
                    != request.device_public_key
                {
                    return Err("device key does not match enrollment".into());
                }
                device.last_seen_at_unix = now;
                self.persist_locked(&state).map_err(|error| error.to_string())?;
                Ok(AuthGrant {
                    device_id: fingerprint,
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: generation,
                })
            }
            AuthKind::Carrier if self.allow_carrier && request.carrier_trusted => Ok(AuthGrant {
                device_id: format!(
                    "carrier:{}",
                    public_key_fingerprint(&request.device_public_key)
                ),
                daemon_name: self.daemon_name.clone(),
                revocation_generation: *self.revocation_tx.borrow(),
            }),
            AuthKind::Carrier => Err("trusted carrier access is disabled or unavailable".into()),
            AuthKind::Invitation => {
                let invitation_id = request
                    .invitation_id
                    .clone()
                    .ok_or_else(|| "invitation id is missing".to_string())?;
                let now = unix_time().map_err(|error| error.to_string())?;
                let fingerprint = public_key_fingerprint(&request.device_public_key);
                let (decision_tx, decision_rx) = oneshot::channel();
                {
                    let mut state = self.state.lock().await;
                    let invitation = state
                        .invitations
                        .get(&invitation_id)
                        .ok_or_else(|| "invitation is unknown or expired".to_string())?;
                    if invitation.expires_at_unix <= now {
                        return Err("invitation is expired".into());
                    }
                    if let Some(claimed_by) = &invitation.claimed_by {
                        if claimed_by != &fingerprint {
                            return Err("invitation was already claimed by another device".into());
                        }
                        let generation = state.revocation_generation;
                        let device = state.devices.get_mut(&fingerprint).ok_or_else(|| {
                            "claimed invitation has no enrolled device".to_string()
                        })?;
                        if device.revoked_at_unix.is_some()
                            || decode_key(&device.public_key).map_err(|error| error.to_string())?
                                != request.device_public_key
                        {
                            return Err("device enrollment is no longer active".into());
                        }
                        device.last_seen_at_unix = now;
                        self.persist_locked(&state).map_err(|error| error.to_string())?;
                        return Ok(AuthGrant {
                            device_id: fingerprint,
                            daemon_name: self.daemon_name.clone(),
                            revocation_generation: generation,
                        });
                    }
                    if state.pending.contains_key(&invitation_id) {
                        return Err("invitation already has a pending enrollment".into());
                    }
                    state.pending.insert(
                        invitation_id.clone(),
                        PendingDecision {
                            request: PendingEnrollment {
                                invitation_id: invitation_id.clone(),
                                device_name: request.device_name,
                                device_fingerprint: fingerprint,
                                requested_at_unix: now,
                            },
                            device_public_key: request.device_public_key,
                            decision: decision_tx,
                        },
                    );
                }
                self.pending_changed.notify_waiters();
                match tokio::time::timeout(APPROVAL_TIMEOUT, decision_rx).await {
                    Ok(Ok(result)) => result,
                    Ok(Err(_)) => Err("enrollment approval channel closed".into()),
                    Err(_) => {
                        self.state.lock().await.pending.remove(&invitation_id);
                        Err("enrollment approval timed out".into())
                    }
                }
            }
        }
    }
}

struct AuthState {
    revocation_generation: u64,
    devices: HashMap<String, DeviceRecord>,
    invitations: HashMap<String, InvitationRecord>,
    pending: HashMap<String, PendingDecision>,
}

impl AuthState {
    fn from_persisted(persisted: PersistedState) -> Self {
        let now = unix_time().unwrap_or(0);
        Self {
            revocation_generation: persisted.revocation_generation,
            devices: persisted
                .devices
                .into_iter()
                .map(|device| (device.id.clone(), device))
                .collect(),
            invitations: persisted
                .invitations
                .into_iter()
                .filter(|invitation| invitation.expires_at_unix > now)
                .filter_map(|invitation| {
                    Some((
                        invitation.id,
                        InvitationRecord {
                            secret: decode_key(&invitation.secret).ok()?,
                            expires_at_unix: invitation.expires_at_unix,
                            route_hints: invitation.route_hints,
                            claimed_by: invitation.claimed_by,
                        },
                    ))
                })
                .collect(),
            pending: HashMap::new(),
        }
    }

    fn prune_invitations(&mut self, now: u64) {
        self.invitations.retain(|id, invitation| {
            invitation.expires_at_unix > now || self.pending.contains_key(id)
        });
    }
}

struct InvitationRecord {
    secret: [u8; 32],
    expires_at_unix: u64,
    route_hints: Vec<String>,
    claimed_by: Option<String>,
}

struct PendingDecision {
    request: PendingEnrollment,
    device_public_key: [u8; 32],
    decision: oneshot::Sender<Result<AuthGrant, String>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedIdentity {
    version: u32,
    private_key: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedState {
    version: u32,
    #[serde(default)]
    revocation_generation: u64,
    #[serde(default)]
    devices: Vec<DeviceRecord>,
    #[serde(default)]
    invitations: Vec<PersistedInvitation>,
}

impl Default for PersistedState {
    fn default() -> Self {
        Self {
            version: STATE_VERSION,
            revocation_generation: 0,
            devices: Vec::new(),
            invitations: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedInvitation {
    id: String,
    secret: String,
    expires_at_unix: u64,
    route_hints: Vec<String>,
    #[serde(default)]
    claimed_by: Option<String>,
}

fn load_or_create_identity(path: &Path) -> Result<StaticIdentity, IdentityError> {
    if path.exists() {
        let data = fs::read(path).map_err(IdentityError::Io)?;
        let persisted: PersistedIdentity =
            serde_json::from_slice(&data).map_err(IdentityError::Json)?;
        if persisted.version != STATE_VERSION {
            return Err(IdentityError::Invalid(format!(
                "identity version {} is unsupported",
                persisted.version
            )));
        }
        return Ok(StaticIdentity::from_private(decode_key(&persisted.private_key)?));
    }
    let identity = StaticIdentity::generate().map_err(IdentityError::Crypto)?;
    atomic_json(
        path,
        &PersistedIdentity {
            version: STATE_VERSION,
            private_key: encode_key(identity.private_key()),
        },
    )?;
    Ok(identity)
}

fn load_state(path: &Path) -> Result<PersistedState, IdentityError> {
    if !path.exists() {
        return Ok(PersistedState::default());
    }
    let data = fs::read(path).map_err(IdentityError::Io)?;
    let state: PersistedState = serde_json::from_slice(&data).map_err(IdentityError::Json)?;
    if state.version != STATE_VERSION {
        return Err(IdentityError::Invalid(format!(
            "device state version {} is unsupported",
            state.version
        )));
    }
    Ok(state)
}

fn atomic_json(path: &Path, value: &impl Serialize) -> Result<(), IdentityError> {
    let parent =
        path.parent().ok_or_else(|| IdentityError::Invalid("state path has no parent".into()))?;
    secure_directory(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name().and_then(|name| name.to_str()).unwrap_or("state"),
        std::process::id(),
        random_token(6)?
    ));
    let data = serde_json::to_vec_pretty(value).map_err(IdentityError::Json)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary).map_err(IdentityError::Io)?;
    let result = (|| {
        file.write_all(&data).map_err(IdentityError::Io)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, path).map_err(IdentityError::Io)?;
        restrict_file(path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn secure_directory(path: &Path) -> Result<(), IdentityError> {
    fs::create_dir_all(path).map_err(IdentityError::Io)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(IdentityError::Io)?;
    }
    Ok(())
}

fn restrict_file(path: &Path) -> Result<(), IdentityError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(IdentityError::Io)?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

pub fn default_state_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_REMOTE_STATE_DIR") {
        return Some(path.into());
    }
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library/Application Support/cmux/remote"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .map(|state| state.join("cmux/remote"))
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .map(|home| home.join(".local/state/cmux/remote"))
            })
    }
}

fn validate_relay_access(
    route_hints: &[String],
    relay_access: &[EnrollmentRelayAccess],
) -> Result<(), IdentityError> {
    if relay_access.len() > MAX_INVITATION_RELAY_ROUTES {
        return Err(IdentityError::Invalid(format!(
            "an invitation can bootstrap at most {MAX_INVITATION_RELAY_ROUTES} relay routes"
        )));
    }
    let mut seen_routes = HashSet::new();
    for access in relay_access {
        let route = url::Url::parse(&access.route)
            .map_err(|_| IdentityError::Invalid("relay bootstrap route is invalid".into()))?;
        if !seen_routes.insert(route.clone()) {
            return Err(IdentityError::Invalid("relay bootstrap routes must be unique".into()));
        }
        if !route_hints
            .iter()
            .filter_map(|hint| url::Url::parse(hint).ok())
            .any(|hint| hint == route)
        {
            return Err(IdentityError::Invalid(
                "relay bootstrap route is not present in invitation route hints".into(),
            ));
        }
        if !matches!(route.scheme(), "relay+ws" | "relay+wss" | "relay+https" | "relay+do") {
            return Err(IdentityError::Invalid(
                "relay bootstrap route does not use a relay scheme".into(),
            ));
        }
        if access.slot.is_empty()
            || access.slot.len() > MAX_RELAY_SLOT_BYTES
            || access.slot.bytes().any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
        {
            return Err(IdentityError::Invalid("relay bootstrap slot is invalid".into()));
        }
        if access.ticket.is_empty()
            || access.ticket.len() > MAX_RELAY_TICKET_BYTES
            || !access.ticket.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
        {
            return Err(IdentityError::Invalid("relay bootstrap ticket is invalid".into()));
        }
    }
    Ok(())
}

fn encode_key(key: &[u8; 32]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key)
}

fn decode_key(encoded: &str) -> Result<[u8; 32], IdentityError> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(IdentityError::Base64)?;
    bytes.try_into().map_err(|bytes: Vec<u8>| {
        IdentityError::Invalid(format!("key is {} bytes, expected 32", bytes.len()))
    })
}

fn random_token(bytes: usize) -> Result<String, IdentityError> {
    let mut token = vec![0_u8; bytes];
    getrandom::fill(&mut token).map_err(|error| IdentityError::Random(error.to_string()))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token))
}

fn unix_time() -> Result<u64, IdentityError> {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|duration| duration.as_secs()).map_err(
        |error| IdentityError::Invalid(format!("system clock is before Unix epoch: {error}")),
    )
}

#[derive(Debug)]
pub enum IdentityError {
    Io(std::io::Error),
    Json(serde_json::Error),
    Base64(base64::DecodeError),
    Crypto(CryptoError),
    Random(String),
    Invalid(String),
    InvitationExpired(String),
    UnknownPending(String),
    UnknownDevice(String),
    Timeout,
}

impl std::fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "identity storage failed: {error}"),
            Self::Json(error) => write!(formatter, "identity JSON failed: {error}"),
            Self::Base64(error) => write!(formatter, "identity key encoding failed: {error}"),
            Self::Crypto(error) => write!(formatter, "identity crypto failed: {error}"),
            Self::Random(message) => write!(formatter, "secure randomness failed: {message}"),
            Self::Invalid(message) => write!(formatter, "invalid identity state: {message}"),
            Self::InvitationExpired(id) => write!(formatter, "invitation {id} is expired"),
            Self::UnknownPending(id) => write!(formatter, "no pending enrollment for {id}"),
            Self::UnknownDevice(id) => write!(formatter, "unknown device {id}"),
            Self::Timeout => formatter.write_str("timed out waiting for enrollment"),
        }
    }
}

impl std::error::Error for IdentityError {}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use cmux_remote_protocol::{Lane, SessionId};
    use zeroize::Zeroizing;

    use super::*;
    use crate::crypto::{
        ClientAuthMode, ClientHandshake, accept_secure_link, initiate_secure_link,
    };
    use crate::link::test_support;

    #[tokio::test]
    async fn identity_is_stable_and_files_are_private() {
        let temp = tempfile::tempdir().unwrap();
        let first = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let public = first.identity().public_key();
        drop(first);
        let second = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        assert_eq!(second.identity().public_key(), public);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(temp.path()).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(
                fs::metadata(temp.path().join("identity.json")).unwrap().permissions().mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn legacy_known_daemon_defaults_to_enrolled_auth() {
        let daemon: KnownDaemon = serde_json::from_value(serde_json::json!({
            "fingerprint": "fingerprint",
            "name": "daemon",
            "public_key": "key",
            "route_hints": ["wss://example.invalid/v1/link"],
            "first_seen_at_unix": 1,
            "last_used_at_unix": 2
        }))
        .unwrap();
        assert_eq!(daemon.auth, KnownDaemonAuth::Enrolled);
    }

    #[tokio::test]
    async fn carrier_daemon_reconnect_mode_is_persisted_and_can_be_promoted() {
        let temp = tempfile::tempdir().unwrap();
        let key = StaticIdentity::generate().unwrap().public_key();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let carrier =
            store.pin_carrier_daemon("host".into(), key, vec!["ssh://host".into()]).await.unwrap();
        assert_eq!(carrier.auth, KnownDaemonAuth::Carrier);
        drop(store);

        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        assert_eq!(store.known_daemons().await[0].auth, KnownDaemonAuth::Carrier);
        let enrolled = store
            .pin_daemon("host".into(), key, vec!["relay+wss://relay.example".into()])
            .await
            .unwrap();
        assert_eq!(enrolled.auth, KnownDaemonAuth::Enrolled);
        assert_eq!(
            enrolled.route_hints,
            vec!["ssh://host".to_string(), "relay+wss://relay.example".to_string()]
        );
        let through_carrier = store
            .pin_carrier_daemon("host".into(), key, vec!["unix:///tmp/cmux.sock".into()])
            .await
            .unwrap();
        assert_eq!(through_carrier.auth, KnownDaemonAuth::Enrolled);
        assert_eq!(
            through_carrier.route_hints,
            vec![
                "ssh://host".to_string(),
                "relay+wss://relay.example".to_string(),
                "unix:///tmp/cmux.sock".to_string()
            ]
        );

        let refreshed =
            store.pin_daemon("host".into(), key, vec!["iroh://node".into()]).await.unwrap();
        assert_eq!(refreshed.route_hints, vec!["iroh://node".to_string()]);
    }

    #[tokio::test]
    async fn invitation_carries_redacted_short_lived_relay_bootstrap() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let route = "relay+do://relay.example".to_string();
        let access = EnrollmentRelayAccess {
            route: route.clone(),
            slot: "0123456789abcdef0123456789abcdef".into(),
            ticket: "secret-connect-ticket".into(),
        };
        let invitation = database
            .create_invitation_with_relay_access(
                Duration::from_secs(60),
                vec![route],
                vec![access.clone()],
            )
            .await
            .unwrap();
        assert!(!format!("{invitation:?}").contains("secret-connect-ticket"));
        let decoded = EnrollmentInvitation::from_uri(&invitation.to_uri().unwrap()).unwrap();
        assert_eq!(decoded.relay_access, vec![access]);
    }

    #[test]
    fn invitation_rejects_duplicate_relay_bootstrap_routes() {
        let route = "relay+do://relay.example".to_string();
        let access = EnrollmentRelayAccess {
            route: route.clone(),
            slot: "0123456789abcdef0123456789abcdef".into(),
            ticket: "ticket".into(),
        };
        let error = validate_relay_access(&[route], &[access.clone(), access]).unwrap_err();
        assert!(matches!(error, IdentityError::Invalid(message) if message.contains("unique")));
    }

    #[tokio::test]
    async fn invitation_requires_owner_approval_then_persists_device() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation = database
            .create_invitation(Duration::from_secs(60), vec!["wss://relay.invalid".into()])
            .await
            .unwrap();
        let client = StaticIdentity::generate().unwrap();
        let daemon_identity = database.identity();
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let client_task = tokio::spawn({
            let invitation = invitation.clone();
            let client = client.clone();
            async move {
                initiate_secure_link(
                    Box::new(client_link),
                    ClientHandshake {
                        identity: client,
                        expected_daemon: Some(decode_key(&invitation.daemon_public_key).unwrap()),
                        auth: ClientAuthMode::Invitation {
                            id: invitation.id.clone(),
                            secret: Zeroizing::new(invitation.secret_bytes().unwrap()),
                        },
                        device_name: "phone".into(),
                        session: SessionId([8; 16]),
                        lane: Lane::Control,
                        lanes: vec![Lane::Control],
                        generation: 0,
                        resume: BTreeMap::new(),
                    },
                )
                .await
            }
        });
        let server_task = tokio::spawn({
            let database = database.clone();
            async move {
                accept_secure_link(Box::new(server_link), &daemon_identity, &*database, false).await
            }
        });

        let pending = database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        assert_eq!(pending[0].device_name, "phone");
        assert!(!client_task.is_finished());
        let record = database.approve(&pending[0].invitation_id).await.unwrap();
        assert_eq!(record.name, "phone");
        client_task.await.unwrap().unwrap();
        server_task.await.unwrap().unwrap();

        let reloaded = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        assert_eq!(reloaded.list_devices().await, vec![record]);
    }

    #[tokio::test]
    async fn approved_invitation_retries_only_for_the_claiming_device() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation = database
            .create_invitation(Duration::from_secs(60), vec!["wss://relay.invalid".into()])
            .await
            .unwrap();
        let client = StaticIdentity::generate().unwrap();
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "phone".into(),
            session: SessionId([8; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            carrier_trusted: false,
        };
        let first = tokio::spawn({
            let database = database.clone();
            let request = request.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        let enrolled = database.approve(&invitation.id).await.unwrap();
        assert_eq!(first.await.unwrap().unwrap().device_id, enrolled.id);

        let retried = database.authorize(request.clone()).await.unwrap();
        assert_eq!(retried.device_id, enrolled.id);
        assert!(database.invitation_secret(&invitation.id).await.unwrap().is_some());

        let mut attacker = request;
        attacker.device_public_key = StaticIdentity::generate().unwrap().public_key();
        let error = database.authorize(attacker).await.unwrap_err();
        assert_eq!(error, "invitation was already claimed by another device");
    }

    #[tokio::test]
    async fn revocation_increments_generation_and_rejects_device() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let client = StaticIdentity::generate().unwrap();
        let fingerprint = public_key_fingerprint(&client.public_key());
        {
            let mut state = database.state.lock().await;
            state.devices.insert(
                fingerprint.clone(),
                DeviceRecord {
                    id: fingerprint.clone(),
                    name: "laptop".into(),
                    public_key: encode_key(&client.public_key()),
                    fingerprint: fingerprint.clone(),
                    created_at_unix: 1,
                    last_seen_at_unix: 1,
                    revoked_at_unix: None,
                },
            );
            database.persist_locked(&state).unwrap();
        }
        let mut revocations = database.subscribe_revocations();
        database.revoke(&fingerprint).await.unwrap();
        revocations.changed().await.unwrap();
        assert_eq!(*revocations.borrow(), 1);
        let result = database
            .authorize(AuthRequest {
                mode: AuthKind::Enrolled,
                invitation_id: None,
                device_public_key: client.public_key(),
                device_name: "laptop".into(),
                session: SessionId([0; 16]),
                lane: Lane::Control,
                lanes: vec![Lane::Control],
                generation: 0,
                carrier_trusted: false,
            })
            .await;
        assert_eq!(result.unwrap_err(), "device has been revoked");
    }
}
