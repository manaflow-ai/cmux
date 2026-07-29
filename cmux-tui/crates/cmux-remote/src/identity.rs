use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
#[cfg(unix)]
use std::fs::File;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, Notify, oneshot, watch};

use crate::crypto::{
    AuthGrant, AuthKind, AuthRequest, ConnectionAttemptId, CryptoError, InboundAuthEvidence,
    ServerAuthenticator, StaticIdentity, public_key_fingerprint,
};

const STATE_VERSION: u32 = 1;
const MAX_INVITATION_TTL: Duration = Duration::from_secs(5 * 60);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const ENROLLMENT_RETRY_GRACE: Duration = Duration::from_secs(60);
const MAX_INVITATION_RELAY_ROUTES: usize = 2;
const MAX_RELAY_SLOT_BYTES: usize = 256;
const MAX_RELAY_TICKET_BYTES: usize = 4 * 1024;
const MAX_RECORDED_CONNECTION_ATTEMPTS: usize = 4_096;

#[cfg(test)]
std::thread_local! {
    static FAIL_ATOMIC_JSON_PARENT_SYNC: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
}

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
            .field("route", &route_debug_label(&self.route))
            .field("slot", &"[REDACTED]")
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
            .field("route_hints", &route_debug_labels(&self.route_hints))
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

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
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

impl std::fmt::Debug for KnownDaemon {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("KnownDaemon")
            .field("fingerprint", &self.fingerprint)
            .field("name", &daemon_name_debug_label(&self.name))
            .field("route_hints", &route_debug_labels(&self.route_hints))
            .field("auth", &self.auth)
            .field("first_seen_at_unix", &self.first_seen_at_unix)
            .field("last_used_at_unix", &self.last_used_at_unix)
            .finish_non_exhaustive()
    }
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
        let mut state = if path.exists() {
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
        let mut routes_changed = false;
        for daemon in state.daemons.values_mut() {
            routes_changed |= sanitize_loaded_known_daemon(daemon);
        }
        if routes_changed {
            atomic_json(&path, &state)?;
        }
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
        let name = credential_free_daemon_name(name);
        let route_hints = credential_free_route_hints(route_hints)?;
        let fingerprint = public_key_fingerprint(&public_key);
        let now = unix_time()?;
        let mut state = self.state.lock().await;
        let mut candidate = state.clone();
        if let Some(existing) = candidate.daemons.get_mut(&fingerprint) {
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
            self.commit_client_state_locked(&mut state, candidate)?;
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
        candidate.daemons.insert(fingerprint, record.clone());
        self.commit_client_state_locked(&mut state, candidate)?;
        Ok(record)
    }

    pub async fn remember_verified_route(
        &self,
        fingerprint: &str,
        route: &str,
    ) -> Result<Option<KnownDaemon>, IdentityError> {
        let route = credential_free_route_hint(route)?;
        let now = unix_time()?;
        let mut state = self.state.lock().await;
        let mut candidate = state.clone();
        let Some(existing) = candidate.daemons.get_mut(fingerprint) else {
            return Ok(None);
        };
        existing.last_used_at_unix = now;
        if !existing.route_hints.contains(&route) {
            existing.route_hints.push(route);
        }
        let record = existing.clone();
        self.commit_client_state_locked(&mut state, candidate)?;
        Ok(Some(record))
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
        let mut candidate = state.clone();
        let removed = candidate.daemons.remove(fingerprint).is_some();
        if removed {
            self.commit_client_state_locked(&mut state, candidate)?;
        }
        Ok(removed)
    }

    fn commit_client_state_locked(
        &self,
        state: &mut PersistedClientState,
        candidate: PersistedClientState,
    ) -> Result<(), IdentityError> {
        self.persist_client_locked(&candidate)?;
        *state = candidate;
        Ok(())
    }

    fn persist_client_locked(&self, state: &PersistedClientState) -> Result<(), IdentityError> {
        atomic_json(&self.state_dir.join("known-daemons.json"), state)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
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

struct PersistenceWaiter {
    receiver: oneshot::Receiver<Result<(), String>>,
}

impl PersistenceWaiter {
    async fn wait_message(self) -> Result<(), String> {
        self.receiver
            .await
            .unwrap_or_else(|_| Err("identity persistence coordinator stopped".into()))
    }

    async fn wait(self) -> Result<(), IdentityError> {
        self.wait_message().await.map_err(IdentityError::Persistence)
    }
}

struct PersistenceCoordinator {
    path: PathBuf,
    state: StdMutex<PersistenceCoordinatorState>,
    #[cfg(test)]
    hooks: Arc<PersistenceTestHooks>,
}

struct PersistenceCoordinatorState {
    durable_revision: u64,
    highest_seen_revision: u64,
    in_flight: Option<u64>,
    pending: BTreeMap<u64, PersistedState>,
    waiters: BTreeMap<u64, Vec<oneshot::Sender<Result<(), String>>>>,
    last_failure: Option<(u64, String)>,
    worker_running: bool,
}

impl PersistenceCoordinator {
    fn new(path: PathBuf, durable_revision: u64) -> Self {
        Self {
            path,
            state: StdMutex::new(PersistenceCoordinatorState {
                durable_revision,
                highest_seen_revision: durable_revision,
                in_flight: None,
                pending: BTreeMap::new(),
                waiters: BTreeMap::new(),
                last_failure: None,
                worker_running: false,
            }),
            #[cfg(test)]
            hooks: Arc::new(PersistenceTestHooks::default()),
        }
    }

    /// Accept a snapshot synchronously so cancellation at the caller's next
    /// await cannot discard an in-memory mutation.
    fn submit(self: &Arc<Self>, snapshot: PersistedState) -> PersistenceWaiter {
        let revision = snapshot.revision;
        let (sender, receiver) = oneshot::channel();
        let mut sender = Some(sender);
        let mut immediate = None;
        let mut spawn_worker = false;
        {
            let mut state = self.lock_state();
            if revision <= state.durable_revision {
                immediate = Some(Ok(()));
            } else {
                let covered_by_newer_work =
                    state.in_flight.is_some_and(|in_flight| in_flight >= revision)
                        || state.pending.range(revision..).next().is_some();
                if revision < state.highest_seen_revision {
                    if covered_by_newer_work {
                        state
                            .waiters
                            .entry(revision)
                            .or_default()
                            .push(sender.take().expect("persistence waiter is available"));
                    } else {
                        let message = state
                            .last_failure
                            .as_ref()
                            .filter(|(failed_revision, _)| *failed_revision >= revision)
                            .map(|(_, message)| message.clone())
                            .unwrap_or_else(|| {
                                format!(
                                    "identity revision {revision} was superseded before it became durable"
                                )
                            });
                        immediate = Some(Err(message));
                    }
                } else {
                    if revision > state.highest_seen_revision {
                        state.highest_seen_revision = revision;
                    }
                    state
                        .waiters
                        .entry(revision)
                        .or_default()
                        .push(sender.take().expect("persistence waiter is available"));
                    if !covered_by_newer_work {
                        state.pending.insert(revision, snapshot);
                    }
                    if !state.worker_running {
                        state.worker_running = true;
                        spawn_worker = true;
                    }
                }
            }
        }
        if let Some(result) = immediate {
            let _ = sender.expect("immediate persistence waiter is available").send(result);
        }
        if spawn_worker {
            let coordinator = Arc::clone(self);
            tokio::spawn(async move {
                coordinator.drain().await;
            });
        }
        PersistenceWaiter { receiver }
    }

    async fn drain(self: Arc<Self>) {
        loop {
            let Some((revision, snapshot)) = ({
                let mut state = self.lock_state();
                let next = state.pending.pop_first();
                if let Some((revision, _)) = &next {
                    state.in_flight = Some(*revision);
                } else {
                    state.worker_running = false;
                }
                next
            }) else {
                return;
            };

            let path = self.path.clone();
            #[cfg(test)]
            let hooks = self.hooks.clone();
            let result = tokio::task::spawn_blocking(move || -> Result<(), String> {
                #[cfg(test)]
                hooks.before_write(revision)?;
                let result = atomic_json(&path, &snapshot).map_err(|error| error.to_string());
                #[cfg(test)]
                hooks.after_write(result.is_ok());
                result
            })
            .await
            .unwrap_or_else(|error| {
                Err(format!("identity persistence worker failed to join: {error}"))
            });

            let waiters = {
                let mut state = self.lock_state();
                debug_assert_eq!(state.in_flight, Some(revision));
                state.in_flight = None;
                match &result {
                    Ok(()) => {
                        state.durable_revision = state.durable_revision.max(revision);
                        let durable_revision = state.durable_revision;
                        state
                            .pending
                            .retain(|queued_revision, _| *queued_revision > durable_revision);
                        if state.last_failure.as_ref().is_some_and(|(failed_revision, _)| {
                            *failed_revision <= durable_revision
                        }) {
                            state.last_failure = None;
                        }
                    }
                    Err(message) => {
                        state.last_failure = Some((revision, message.clone()));
                    }
                }
                take_waiters_through(&mut state.waiters, revision)
            };
            for waiter in waiters {
                let _ = waiter.send(result.clone());
            }
        }
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, PersistenceCoordinatorState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn durable_revision_at_least(&self, revision: u64) -> bool {
        self.lock_state().durable_revision >= revision
    }

    #[cfg(test)]
    fn durable_revision(&self) -> u64 {
        self.lock_state().durable_revision
    }
}

fn take_waiters_through(
    waiters: &mut BTreeMap<u64, Vec<oneshot::Sender<Result<(), String>>>>,
    revision: u64,
) -> Vec<oneshot::Sender<Result<(), String>>> {
    let revisions = waiters.range(..=revision).map(|(revision, _)| *revision).collect::<Vec<_>>();
    revisions
        .into_iter()
        .flat_map(|revision| waiters.remove(&revision).unwrap_or_default())
        .collect()
}

#[cfg(test)]
#[derive(Default)]
struct PersistenceTestHooks {
    writes_started: std::sync::atomic::AtomicUsize,
    writes_succeeded: std::sync::atomic::AtomicUsize,
    fail_next: std::sync::atomic::AtomicUsize,
    started_revisions: StdMutex<Vec<u64>>,
    blocked: StdMutex<bool>,
    released: std::sync::Condvar,
    started: Notify,
}

#[cfg(test)]
impl PersistenceTestHooks {
    fn before_write(&self, revision: u64) -> Result<(), String> {
        use std::sync::atomic::Ordering;

        self.writes_started.fetch_add(1, Ordering::SeqCst);
        self.started_revisions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(revision);
        self.started.notify_waiters();
        let mut blocked = self.blocked.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while *blocked {
            blocked =
                self.released.wait(blocked).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        drop(blocked);
        if self
            .fail_next
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| remaining.checked_sub(1))
            .is_ok()
        {
            return Err(format!("injected persistence failure for revision {revision}"));
        }
        Ok(())
    }

    fn after_write(&self, succeeded: bool) {
        if succeeded {
            self.writes_succeeded.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }

    fn block(&self) {
        *self.blocked.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    fn release(&self) {
        let mut blocked = self.blocked.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *blocked = false;
        self.released.notify_all();
    }

    async fn wait_for_started(&self, expected: usize) {
        use std::sync::atomic::Ordering;

        loop {
            let started = self.started.notified();
            if self.writes_started.load(Ordering::SeqCst) >= expected {
                return;
            }
            started.await;
        }
    }
}

pub struct AuthDatabase {
    state_dir: PathBuf,
    daemon_name: String,
    identity: StaticIdentity,
    allow_carrier: bool,
    state: Mutex<AuthState>,
    persistence: Arc<PersistenceCoordinator>,
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
        let persistence = Arc::new(PersistenceCoordinator::new(
            state_dir.join("devices.json"),
            persisted.revision,
        ));
        Ok(Arc::new(Self {
            state_dir,
            daemon_name: daemon_name.into(),
            identity,
            allow_carrier,
            state: Mutex::new(AuthState::from_persisted(persisted)),
            persistence,
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
        mut relay_access: Vec<EnrollmentRelayAccess>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        let ttl = ttl.min(MAX_INVITATION_TTL);
        if ttl.is_zero() {
            return Err(IdentityError::Invalid("invitation ttl must be positive".into()));
        }
        let route_hints = credential_free_route_hints(route_hints)?;
        for access in &mut relay_access {
            access.route = credential_free_route_hint(&access.route)?;
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
        let persistence = self.submit_mutation_locked(&mut state)?;
        drop(state);
        persistence.wait().await?;
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

    /// Keep the approval transaction alive if its admin caller disconnects.
    /// The transaction retains the authentication-state lock until its snapshot
    /// is durable, so no authorization reader can observe the staged device.
    pub async fn approve(
        self: &Arc<Self>,
        invitation_id: &str,
    ) -> Result<DeviceRecord, IdentityError> {
        let database = Arc::clone(self);
        let invitation_id = invitation_id.to_owned();
        tokio::spawn(async move { database.approve_durably(&invitation_id).await })
            .await
            .unwrap_or_else(|error| {
                Err(IdentityError::Persistence(format!(
                    "identity approval task failed to join: {error}"
                )))
            })
    }

    async fn approve_durably(&self, invitation_id: &str) -> Result<DeviceRecord, IdentityError> {
        let now = unix_time()?;
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
        let previous_claim = invitation.claimed_by.replace(fingerprint.clone());
        let previous_expiration = invitation.expires_at_unix;
        invitation.expires_at_unix =
            invitation.expires_at_unix.max(now.saturating_add(ENROLLMENT_RETRY_GRACE.as_secs()));
        let record = DeviceRecord {
            id: fingerprint.clone(),
            name: pending.request.device_name.clone(),
            public_key: encode_key(&pending.device_public_key),
            fingerprint,
            created_at_unix: now,
            last_seen_at_unix: now,
            revoked_at_unix: None,
        };
        let previous_device = state.devices.insert(record.id.clone(), record.clone());
        let generation = state.revocation_generation;
        let persistence = match self.submit_mutation_locked(&mut state) {
            Ok(persistence) => persistence,
            Err(error) => {
                rollback_approval(
                    &mut state,
                    invitation_id,
                    &record.id,
                    previous_claim,
                    previous_expiration,
                    previous_device,
                );
                let _ = pending.decision.send(Err(error.to_string()));
                return Err(error);
            }
        };
        let grant = AuthGrant {
            device_id: record.id.clone(),
            daemon_name: self.daemon_name.clone(),
            revocation_generation: generation,
        };
        match persistence.wait_message().await {
            Ok(()) => {
                drop(state);
                let _ = pending.decision.send(Ok(grant));
                Ok(record)
            }
            Err(message) => {
                rollback_approval(
                    &mut state,
                    invitation_id,
                    &record.id,
                    previous_claim,
                    previous_expiration,
                    previous_device,
                );
                drop(state);
                let _ = pending.decision.send(Err(message.clone()));
                Err(IdentityError::Persistence(message))
            }
        }
    }

    pub async fn deny(&self, invitation_id: &str) -> Result<(), IdentityError> {
        let (decision, persistence) = {
            let mut state = self.state.lock().await;
            let pending = state
                .pending
                .remove(invitation_id)
                .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
            state.invitations.remove(invitation_id);
            let persistence = self.submit_mutation_locked(&mut state)?;
            (pending.decision, persistence)
        };
        let (completed_tx, completed_rx) = oneshot::channel();
        tokio::spawn(async move {
            let result = persistence.wait_message().await;
            let authorization = match &result {
                Ok(()) => Err("enrollment denied".into()),
                Err(message) => Err(message.clone()),
            };
            let _ = decision.send(authorization);
            let _ = completed_tx.send(result);
        });
        completed_rx
            .await
            .unwrap_or_else(|_| Err("identity denial persistence task stopped".into()))
            .map_err(IdentityError::Persistence)
    }

    pub async fn revoke(&self, device_id: &str) -> Result<(), IdentityError> {
        let now = unix_time()?;
        let (generation, persistence) = {
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
            let persistence = self.submit_mutation_locked(&mut state)?;
            (generation, persistence)
        };
        // Revocation takes effect in memory immediately. Durability still
        // gates the method's successful return.
        let _ = self.revocation_tx.send(generation);
        persistence.wait().await
    }

    pub async fn record_connection_attempt(
        &self,
        device_id: &str,
        connection_attempt: ConnectionAttemptId,
    ) -> Result<(), IdentityError> {
        if device_id.starts_with("carrier:") {
            return Ok(());
        }
        let now = unix_time()?;
        let key = (device_id.to_string(), connection_attempt);
        let persistence = {
            let mut state = self.state.lock().await;
            if let Some(revision) = state.recorded_connection_attempts.get(&key).copied() {
                if self.persistence.durable_revision_at_least(revision) {
                    return Ok(());
                }
                self.persistence.submit(state.to_persisted())
            } else {
                let device = state
                    .devices
                    .get_mut(device_id)
                    .ok_or_else(|| IdentityError::UnknownDevice(device_id.into()))?;
                if device.revoked_at_unix.is_some() {
                    return Err(IdentityError::Invalid(format!(
                        "device {device_id} has been revoked"
                    )));
                }
                device.last_seen_at_unix = now;
                let persistence = self.submit_mutation_locked(&mut state)?;
                let revision = state.revision;
                if state.recorded_connection_attempts.len() >= MAX_RECORDED_CONNECTION_ATTEMPTS
                    && let Some(stale) = state.recorded_connection_attempt_order.pop_front()
                {
                    state.recorded_connection_attempts.remove(&stale);
                }
                state.recorded_connection_attempts.insert(key.clone(), revision);
                state.recorded_connection_attempt_order.push_back(key);
                persistence
            }
        };
        persistence.wait().await
    }

    #[cfg(test)]
    pub(crate) async fn test_wait_for_persistence_writes(&self, expected: usize) {
        self.persistence.hooks.wait_for_started(expected).await;
    }

    #[cfg(test)]
    pub(crate) fn test_fail_next_persistence_writes(&self, count: usize) {
        self.persistence.hooks.fail_next.store(count, std::sync::atomic::Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn test_persistence_writes_started(&self) -> usize {
        self.persistence.hooks.writes_started.load(std::sync::atomic::Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(crate) fn test_persistence_writes_succeeded(&self) -> usize {
        self.persistence.hooks.writes_succeeded.load(std::sync::atomic::Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(crate) fn test_persistence_started_revisions(&self) -> Vec<u64> {
        self.persistence
            .hooks
            .started_revisions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    #[cfg(test)]
    pub(crate) fn test_durable_revision(&self) -> u64 {
        self.persistence.durable_revision()
    }

    #[cfg(test)]
    async fn test_retry_persistence(&self) -> Result<(), IdentityError> {
        let persistence = {
            let state = self.state.lock().await;
            self.persistence.submit(state.to_persisted())
        };
        persistence.wait().await
    }

    fn submit_mutation_locked(
        &self,
        state: &mut AuthState,
    ) -> Result<PersistenceWaiter, IdentityError> {
        let snapshot = state.snapshot_after_mutation()?;
        Ok(self.persistence.submit(snapshot))
    }
}

fn rollback_approval(
    state: &mut AuthState,
    invitation_id: &str,
    device_id: &str,
    previous_claim: Option<String>,
    previous_expiration: u64,
    previous_device: Option<DeviceRecord>,
) {
    let invitation = state
        .invitations
        .get_mut(invitation_id)
        .expect("approval keeps its invitation while persistence is pending");
    invitation.claimed_by = previous_claim;
    invitation.expires_at_unix = previous_expiration;
    if let Some(previous_device) = previous_device {
        state.devices.insert(device_id.to_owned(), previous_device);
    } else {
        state.devices.remove(device_id);
    }
}

#[async_trait]
impl ServerAuthenticator for AuthDatabase {
    async fn invitation_secret(&self, id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        let now = unix_time().map_err(|error| CryptoError::Unauthorized(error.to_string()))?;
        let state = self.state.lock().await;
        Ok(state
            .invitations
            .get(id)
            .filter(|invitation| invitation.expires_at_unix > now)
            .map(|invitation| invitation.secret))
    }

    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
        match request.mode {
            AuthKind::Enrolled => {
                let fingerprint = public_key_fingerprint(&request.device_public_key);
                let state = self.state.lock().await;
                let generation = state.revocation_generation;
                let device = state
                    .devices
                    .get(&fingerprint)
                    .ok_or_else(|| "device is not enrolled".to_string())?;
                if device.revoked_at_unix.is_some() {
                    return Err("device has been revoked".into());
                }
                if decode_key(&device.public_key).map_err(|error| error.to_string())?
                    != request.device_public_key
                {
                    return Err("device key does not match enrollment".into());
                }
                Ok(AuthGrant {
                    device_id: fingerprint,
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: generation,
                })
            }
            AuthKind::Carrier
                if self.allow_carrier
                    && matches!(
                        &request.inbound,
                        InboundAuthEvidence::Kernel(_) | InboundAuthEvidence::Ssh(_)
                    ) =>
            {
                Ok(AuthGrant {
                    device_id: format!(
                        "carrier:{}",
                        public_key_fingerprint(&request.device_public_key)
                    ),
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: *self.revocation_tx.borrow(),
                })
            }
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
                        let device = state.devices.get(&fingerprint).ok_or_else(|| {
                            "claimed invitation has no enrolled device".to_string()
                        })?;
                        if device.revoked_at_unix.is_some()
                            || decode_key(&device.public_key).map_err(|error| error.to_string())?
                                != request.device_public_key
                        {
                            return Err("device enrollment is no longer active".into());
                        }
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
    revision: u64,
    revocation_generation: u64,
    devices: HashMap<String, DeviceRecord>,
    invitations: HashMap<String, InvitationRecord>,
    pending: HashMap<String, PendingDecision>,
    recorded_connection_attempts: HashMap<(String, ConnectionAttemptId), u64>,
    recorded_connection_attempt_order: VecDeque<(String, ConnectionAttemptId)>,
}

impl AuthState {
    fn from_persisted(persisted: PersistedState) -> Self {
        let now = unix_time().unwrap_or(0);
        Self {
            revision: persisted.revision,
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
            recorded_connection_attempts: HashMap::new(),
            recorded_connection_attempt_order: VecDeque::new(),
        }
    }

    fn snapshot_after_mutation(&mut self) -> Result<PersistedState, IdentityError> {
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| IdentityError::Invalid("identity revision exhausted".into()))?;
        Ok(self.to_persisted())
    }

    fn to_persisted(&self) -> PersistedState {
        PersistedState {
            version: STATE_VERSION,
            revision: self.revision,
            revocation_generation: self.revocation_generation,
            devices: self.devices.values().cloned().collect(),
            invitations: self
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

#[derive(Serialize, Deserialize)]
struct PersistedIdentity {
    version: u32,
    private_key: String,
}

impl std::fmt::Debug for PersistedIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PersistedIdentity")
            .field("version", &self.version)
            .field("private_key", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedState {
    version: u32,
    #[serde(default)]
    revision: u64,
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
            revision: 0,
            revocation_generation: 0,
            devices: Vec::new(),
            invitations: Vec::new(),
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedInvitation {
    id: String,
    secret: String,
    expires_at_unix: u64,
    route_hints: Vec<String>,
    #[serde(default)]
    claimed_by: Option<String>,
}

impl std::fmt::Debug for PersistedInvitation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PersistedInvitation")
            .field("id", &self.id)
            .field("secret", &"[REDACTED]")
            .field("expires_at_unix", &self.expires_at_unix)
            .field("route_hints", &route_debug_labels(&self.route_hints))
            .field("claimed_by", &self.claimed_by)
            .finish()
    }
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
    let mut state: PersistedState = serde_json::from_slice(&data).map_err(IdentityError::Json)?;
    if state.version != STATE_VERSION {
        return Err(IdentityError::Invalid(format!(
            "device state version {} is unsupported",
            state.version
        )));
    }
    let mut routes_changed = false;
    for invitation in &mut state.invitations {
        let sanitized = credential_free_route_hints_lossy(&invitation.route_hints);
        routes_changed |= sanitized != invitation.route_hints;
        invitation.route_hints = sanitized;
    }
    if routes_changed {
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or_else(|| IdentityError::Invalid("identity revision exhausted".into()))?;
        atomic_json(path, &state)?;
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
        sync_parent_directory(parent)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn sync_parent_directory(path: &Path) -> Result<(), IdentityError> {
    #[cfg(unix)]
    File::open(path).and_then(|directory| directory.sync_all()).map_err(IdentityError::Io)?;
    #[cfg(test)]
    if FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.replace(false)) {
        return Err(IdentityError::Io(std::io::Error::other(
            "injected parent directory sync failure",
        )));
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
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

/// Normalizes a reconnect route before identity state persists it.
///
/// Carrier credentials, fragments, and capability-bearing network paths are
/// removed. SSH usernames, Unix socket paths, Iroh node IDs, and Iroh's
/// explicitly non-secret routing hints remain because reconnect needs them.
pub fn credential_free_route_hint(route: &str) -> Result<String, IdentityError> {
    let mut endpoint = url::Url::parse(route)
        .map_err(|_| IdentityError::Invalid("route hint is not a valid URL".into()))?;
    let scheme = endpoint.scheme().to_string();
    clear_url_password(&mut endpoint)?;
    endpoint.set_fragment(None);

    match scheme.as_str() {
        "ssh" => {
            endpoint.set_path("");
            endpoint.set_query(None);
        }
        "unix" => {
            clear_url_username(&mut endpoint)?;
            endpoint.set_query(None);
        }
        "iroh" => {
            clear_url_username(&mut endpoint)?;
            let routing = endpoint
                .query_pairs()
                .filter_map(|(key, value)| {
                    let key = key.into_owned();
                    let value = value.into_owned();
                    match key.as_str() {
                        "node_id" | "direct" | "direct_addrs" => Some((key, value)),
                        "relay" | "relay_url" => {
                            sanitize_nested_route(&value).map(|route| (key, route))
                        }
                        _ => None,
                    }
                })
                .collect::<Vec<_>>();
            endpoint.set_query(None);
            if !routing.is_empty() {
                let mut query = endpoint.query_pairs_mut();
                for (key, value) in routing {
                    query.append_pair(&key, &value);
                }
            }
        }
        _ => {
            clear_url_username(&mut endpoint)?;
            endpoint.set_path("");
            endpoint.set_query(None);
        }
    }
    Ok(endpoint.to_string())
}

fn credential_free_route_hints(routes: Vec<String>) -> Result<Vec<String>, IdentityError> {
    let mut sanitized = Vec::with_capacity(routes.len());
    for route in routes {
        let route = credential_free_route_hint(&route)?;
        if !sanitized.contains(&route) {
            sanitized.push(route);
        }
    }
    Ok(sanitized)
}

fn credential_free_route_hints_lossy(routes: &[String]) -> Vec<String> {
    let mut sanitized = Vec::with_capacity(routes.len());
    for route in routes {
        if let Ok(route) = credential_free_route_hint(route)
            && !sanitized.contains(&route)
        {
            sanitized.push(route);
        }
    }
    sanitized
}

fn sanitize_loaded_known_daemon(daemon: &mut KnownDaemon) -> bool {
    let original_routes = std::mem::take(&mut daemon.route_hints);
    let original_name = std::mem::take(&mut daemon.name);
    daemon.name = credential_free_daemon_name(original_name.clone());
    daemon.route_hints = credential_free_route_hints_lossy(&original_routes);
    daemon.name != original_name || daemon.route_hints != original_routes
}

fn credential_free_daemon_name(name: String) -> String {
    if !name.contains("://") {
        return name;
    }
    credential_free_route_hint(&name).unwrap_or(name)
}

fn clear_url_username(endpoint: &mut url::Url) -> Result<(), IdentityError> {
    if !endpoint.username().is_empty() {
        endpoint
            .set_username("")
            .map_err(|_| IdentityError::Invalid("route hint user information is invalid".into()))?;
    }
    Ok(())
}

fn clear_url_password(endpoint: &mut url::Url) -> Result<(), IdentityError> {
    if endpoint.password().is_some() {
        endpoint
            .set_password(None)
            .map_err(|_| IdentityError::Invalid("route hint user information is invalid".into()))?;
    }
    Ok(())
}

fn sanitize_nested_route(route: &str) -> Option<String> {
    let mut endpoint = url::Url::parse(route).ok()?;
    if !endpoint.username().is_empty() && endpoint.set_username("").is_err() {
        return None;
    }
    if endpoint.password().is_some() && endpoint.set_password(None).is_err() {
        return None;
    }
    endpoint.set_path("");
    endpoint.set_query(None);
    endpoint.set_fragment(None);
    Some(endpoint.to_string())
}

fn route_debug_labels(routes: &[String]) -> Vec<String> {
    routes.iter().map(|route| route_debug_label(route)).collect()
}

fn route_debug_label(route: &str) -> String {
    crate::provider::sanitized_route_text(route)
}

fn daemon_name_debug_label(name: &str) -> String {
    if name.contains("://") && url::Url::parse(name).is_ok() {
        route_debug_label(name)
    } else {
        name.to_string()
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
    Persistence(String),
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
            Self::Persistence(message) => {
                write!(formatter, "identity persistence failed: {message}")
            }
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
        ClientAuthMode, ClientHandshake, NetworkPeer, accept_secure_link, initiate_secure_link,
    };
    use crate::link::test_support;

    struct PersistenceReleaseGuard(Arc<PersistenceTestHooks>);

    impl PersistenceReleaseGuard {
        fn new(hooks: Arc<PersistenceTestHooks>) -> Self {
            hooks.block();
            Self(hooks)
        }
    }

    impl Drop for PersistenceReleaseGuard {
        fn drop(&mut self) {
            self.0.release();
        }
    }

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

    #[tokio::test]
    async fn failed_known_daemon_pin_does_not_publish_live_trust() {
        let temp = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let state_path = temp.path().join("known-daemons.json");
        fs::create_dir(&state_path).unwrap();
        let public_key = StaticIdentity::generate().unwrap().public_key();
        let fingerprint = public_key_fingerprint(&public_key);

        assert!(store.pin_daemon("host".into(), public_key, Vec::new()).await.is_err());
        assert_eq!(store.daemon_key(&fingerprint).await.unwrap(), None);
    }

    #[tokio::test]
    async fn failed_known_daemon_forget_keeps_live_trust() {
        let temp = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let public_key = StaticIdentity::generate().unwrap().public_key();
        let known = store.pin_daemon("host".into(), public_key, Vec::new()).await.unwrap();
        let state_path = temp.path().join("known-daemons.json");
        fs::remove_file(&state_path).unwrap();
        fs::create_dir(&state_path).unwrap();

        assert!(store.forget_daemon(&known.fingerprint).await.is_err());
        assert_eq!(store.daemon_key(&known.fingerprint).await.unwrap(), Some(public_key));

        fs::remove_dir(&state_path).unwrap();
        assert!(store.forget_daemon(&known.fingerprint).await.unwrap());
        assert_eq!(store.daemon_key(&known.fingerprint).await.unwrap(), None);
    }

    #[cfg(unix)]
    #[test]
    fn atomic_json_propagates_parent_directory_sync_failure() {
        let temp = tempfile::tempdir().unwrap();
        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(true));
        let result = atomic_json(&temp.path().join("state.json"), &PersistedClientState::default());
        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(false));

        assert!(result.is_err(), "atomic state replacement ignored directory sync failure");
    }

    #[tokio::test]
    async fn failed_known_daemon_route_refresh_keeps_live_state_unchanged() {
        let temp = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let public_key = StaticIdentity::generate().unwrap().public_key();
        let known = store
            .pin_daemon("host".into(), public_key, vec!["wss://old.example/v1/link".into()])
            .await
            .unwrap();
        let state_path = temp.path().join("known-daemons.json");
        fs::remove_file(&state_path).unwrap();
        fs::create_dir(&state_path).unwrap();

        assert!(
            store
                .remember_verified_route(&known.fingerprint, "wss://new.example/v1/link")
                .await
                .is_err()
        );
        assert_eq!(store.known_daemons().await, [known]);
    }

    #[tokio::test]
    async fn persistence_runs_off_lock_and_success_waits_for_durability() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        let create = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });

        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("persistence writer did not start");
        let state = tokio::time::timeout(Duration::from_millis(100), database.state.lock()).await;
        let returned_before_durable = create.is_finished();
        let durable_revision = database.test_durable_revision();
        drop(blocked);

        assert!(state.is_ok(), "persistence writer held the authentication state lock");
        assert!(!returned_before_durable, "mutation returned before its revision was durable");
        assert_eq!(durable_revision, 0);
        create.await.unwrap().unwrap();
        assert_eq!(database.test_durable_revision(), 1);
        assert_eq!(database.test_persistence_writes_succeeded(), 1);
    }

    #[tokio::test]
    async fn cancelled_mutation_still_persists_before_newer_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        let first = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("first persistence write did not start");
        first.abort();
        assert!(first.await.unwrap_err().is_cancelled());

        let second = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.revision == 2 {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("newer mutation was not accepted while the first write was blocked");
        drop(blocked);

        second.await.unwrap().unwrap();
        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 2);
        assert_eq!(persisted.invitations.len(), 2);
        assert_eq!(database.test_persistence_started_revisions(), [1, 2]);
        assert_eq!(database.test_persistence_writes_succeeded(), 2);
    }

    #[tokio::test]
    async fn older_snapshot_cannot_overwrite_newer_identity_state() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("devices.json");
        let coordinator = Arc::new(PersistenceCoordinator::new(path.clone(), 0));
        let blocked = PersistenceReleaseGuard::new(coordinator.hooks.clone());
        let device = DeviceRecord {
            id: "device".into(),
            name: "current device".into(),
            public_key: encode_key(&[7; 32]),
            fingerprint: "device".into(),
            created_at_unix: 1,
            last_seen_at_unix: 9,
            revoked_at_unix: Some(9),
        };
        let newer = PersistedState {
            version: STATE_VERSION,
            revision: 2,
            revocation_generation: 1,
            devices: vec![device],
            invitations: vec![PersistedInvitation {
                id: "current-invitation".into(),
                secret: encode_key(&[8; 32]),
                expires_at_unix: u64::MAX,
                route_hints: vec!["wss://current.invalid/".into()],
                claimed_by: Some("device".into()),
            }],
        };
        let older = PersistedState {
            version: STATE_VERSION,
            revision: 1,
            revocation_generation: 0,
            devices: Vec::new(),
            invitations: Vec::new(),
        };

        let newer_waiter = coordinator.submit(newer);
        tokio::time::timeout(Duration::from_secs(1), coordinator.hooks.wait_for_started(1))
            .await
            .expect("newer persistence write did not start");
        let older_waiter = coordinator.submit(older);
        drop(blocked);
        newer_waiter.wait().await.unwrap();
        older_waiter.wait().await.unwrap();

        let persisted = load_state(&path).unwrap();
        assert_eq!(persisted.revision, 2);
        assert_eq!(persisted.revocation_generation, 1);
        assert_eq!(persisted.devices[0].revoked_at_unix, Some(9));
        assert_eq!(persisted.invitations[0].id, "current-invitation");
        assert_eq!(coordinator.hooks.writes_succeeded.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(
            *coordinator
                .hooks
                .started_revisions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            [2]
        );
    }

    #[tokio::test]
    async fn persistence_failure_wakes_waiter_and_retry_advances_durability() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        database.test_fail_next_persistence_writes(1);

        let error =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap_err();
        assert!(
            matches!(error, IdentityError::Persistence(message) if message.contains("injected"))
        );
        assert_eq!(database.test_durable_revision(), 0);
        assert_eq!(database.test_persistence_writes_started(), 1);
        assert_eq!(database.test_persistence_writes_succeeded(), 0);

        database.test_retry_persistence().await.unwrap();
        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 1);
        assert_eq!(persisted.invitations.len(), 1);
        assert_eq!(database.test_durable_revision(), 1);
        assert_eq!(database.test_persistence_writes_started(), 2);
        assert_eq!(database.test_persistence_writes_succeeded(), 1);
    }

    #[tokio::test]
    async fn failed_approval_never_exposes_transient_device_authorization() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let client = StaticIdentity::generate().unwrap();
        let invitation_request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "phone".into(),
            session: SessionId([19; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
        };
        let invitation_authorization = tokio::spawn({
            let database = database.clone();
            let request = invitation_request.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();

        let baseline_writes = database.test_persistence_writes_started();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        database.test_fail_next_persistence_writes(1);
        let approval = tokio::spawn({
            let database = database.clone();
            let invitation_id = invitation.id.clone();
            async move { database.approve(&invitation_id).await }
        });
        tokio::time::timeout(
            Duration::from_secs(1),
            database.test_wait_for_persistence_writes(baseline_writes + 1),
        )
        .await
        .expect("approval persistence writer did not start");

        let mut enrolled_authorization = tokio::spawn({
            let database = database.clone();
            let mut request = invitation_request.clone();
            request.mode = AuthKind::Enrolled;
            request.invitation_id = None;
            async move { database.authorize(request).await }
        });
        assert!(
            tokio::time::timeout(Duration::from_millis(100), &mut enrolled_authorization)
                .await
                .is_err(),
            "device authorization became visible before approval was durable"
        );

        drop(blocked);
        let approval_error = approval.await.unwrap().unwrap_err();
        assert!(
            matches!(approval_error, IdentityError::Persistence(message) if message.contains("injected"))
        );
        assert!(
            invitation_authorization.await.unwrap().unwrap_err().contains("injected"),
            "the pending invitation handshake did not receive the persistence failure"
        );
        assert_eq!(enrolled_authorization.await.unwrap().unwrap_err(), "device is not enrolled");
        assert!(!database.device_is_active(&public_key_fingerprint(&client.public_key())).await);

        let retry = tokio::spawn({
            let database = database.clone();
            async move { database.authorize(invitation_request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        database.deny(&invitation.id).await.unwrap();
        assert_eq!(retry.await.unwrap().unwrap_err(), "enrollment denied");
    }

    #[test]
    fn legacy_device_state_without_revision_loads_at_revision_zero() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("devices.json");
        fs::write(
            &path,
            serde_json::json!({
                "version": STATE_VERSION,
                "revocation_generation": 0,
                "devices": [],
                "invitations": [],
            })
            .to_string(),
        )
        .unwrap();

        let persisted = load_state(&path).unwrap();
        assert_eq!(persisted.revision, 0);
    }

    #[tokio::test]
    async fn authorization_is_read_only_until_logical_attempt_is_recorded() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let client = StaticIdentity::generate().unwrap();
        let fingerprint = public_key_fingerprint(&client.public_key());
        let persistence = {
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
            database.submit_mutation_locked(&mut state).unwrap()
        };
        persistence.wait().await.unwrap();
        let baseline = database.test_persistence_writes_succeeded();

        for lane in Lane::ALL {
            database
                .authorize(AuthRequest {
                    mode: AuthKind::Enrolled,
                    invitation_id: None,
                    device_public_key: client.public_key(),
                    device_name: "laptop".into(),
                    session: SessionId([2; 16]),
                    lane,
                    lanes: vec![lane],
                    generation: 0,
                    inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
                })
                .await
                .unwrap();
        }
        assert_eq!(database.test_persistence_writes_succeeded(), baseline);

        let first_attempt = ConnectionAttemptId([3; 16]);
        database.record_connection_attempt(&fingerprint, first_attempt).await.unwrap();
        assert_eq!(database.test_persistence_writes_succeeded(), baseline + 1);
        database.record_connection_attempt(&fingerprint, first_attempt).await.unwrap();
        assert_eq!(database.test_persistence_writes_succeeded(), baseline + 1);
        database
            .record_connection_attempt(&fingerprint, ConnectionAttemptId([4; 16]))
            .await
            .unwrap();
        assert_eq!(database.test_persistence_writes_succeeded(), baseline + 2);
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
    async fn known_daemon_routes_are_persisted_without_credentials() {
        let temp = tempfile::tempdir().unwrap();
        let key = StaticIdentity::generate().unwrap().public_key();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();

        let daemon = store
            .pin_daemon(
                "wss://name-user-marker:name-password-marker@daemon-name.test/\
                 name-path-marker?ticket=name-query-marker"
                    .into(),
                key,
                vec![
                    "wss://route-user-marker:route-password-marker@example.test/\
                     route-private-marker?ticket=route-secret-marker#route-fragment-marker"
                        .into(),
                ],
            )
            .await
            .unwrap();

        assert_eq!(daemon.route_hints, vec!["wss://example.test/"]);
        assert_eq!(daemon.name, "wss://daemon-name.test/");
        let persisted = fs::read_to_string(temp.path().join("known-daemons.json")).unwrap();
        for secret in [
            "name-user-marker",
            "name-password-marker",
            "name-path-marker",
            "name-query-marker",
            "route-user-marker",
            "route-password-marker",
            "route-private-marker",
            "route-secret-marker",
            "route-fragment-marker",
        ] {
            assert!(!persisted.contains(secret), "{secret:?} leaked in {persisted:?}");
        }
    }

    #[test]
    fn credential_free_routes_preserve_only_reconnect_material() {
        assert_eq!(credential_free_daemon_name("daemon:dev".into()), "daemon:dev");

        let websocket = url::Url::parse(
            &credential_free_route_hint(
                "wss://user:password@example.test/private?ticket=secret#fragment",
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(websocket.as_str(), "wss://example.test/");

        let ssh = url::Url::parse(
            &credential_free_route_hint(
                "ssh://alice:password@example.test:2222/private?ticket=secret#fragment",
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(ssh.username(), "alice");
        assert_eq!(ssh.password(), None);
        assert_eq!(ssh.host_str(), Some("example.test"));
        assert_eq!(ssh.port(), Some(2222));
        assert!(matches!(ssh.path(), "" | "/"));
        assert!(ssh.query().is_none());
        assert!(ssh.fragment().is_none());

        let unix = url::Url::parse(
            &credential_free_route_hint("unix:///tmp/cmux-remote.sock?ticket=secret#fragment")
                .unwrap(),
        )
        .unwrap();
        assert_eq!(unix.path(), "/tmp/cmux-remote.sock");
        assert!(unix.query().is_none());
        assert!(unix.fragment().is_none());

        let iroh = url::Url::parse(
            &credential_free_route_hint(
                "iroh://node-id?direct=127.0.0.1%3A7777&relay=\
                 https%3A%2F%2Fuser%3Apassword%40relay.test%2Fprivate%3Fticket%3Dsecret&\
                 ticket=drop-me",
            )
            .unwrap(),
        )
        .unwrap();
        let routing = iroh.query_pairs().into_owned().collect::<HashMap<_, _>>();
        assert_eq!(routing["direct"], "127.0.0.1:7777");
        assert_eq!(routing["relay"], "https://relay.test/");
        assert!(!routing.contains_key("ticket"));
    }

    #[tokio::test]
    async fn verified_route_refreshes_known_daemon_route_and_last_used_time() {
        let temp = tempfile::tempdir().unwrap();
        let key = StaticIdentity::generate().unwrap().public_key();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let known = store
            .pin_daemon("host".into(), key, vec!["wss://old.example/v1/link".into()])
            .await
            .unwrap();
        {
            let mut state = store.state.lock().await;
            state.daemons.get_mut(&known.fingerprint).unwrap().last_used_at_unix = 1;
            store.persist_client_locked(&state).unwrap();
        }

        let refreshed = store
            .remember_verified_route(
                &known.fingerprint,
                "wss://refresh-user-marker:refresh-password-marker@new.example/\
                 refresh-path-marker?ticket=refresh-query-marker",
            )
            .await
            .unwrap()
            .unwrap();

        assert!(refreshed.last_used_at_unix > 1);
        assert_eq!(refreshed.route_hints, ["wss://old.example/", "wss://new.example/"]);
        let persisted = fs::read_to_string(temp.path().join("known-daemons.json")).unwrap();
        for secret in [
            "refresh-user-marker",
            "refresh-password-marker",
            "refresh-path-marker",
            "refresh-query-marker",
        ] {
            assert!(!persisted.contains(secret), "{secret:?} leaked in {persisted:?}");
        }
    }

    #[test]
    fn identity_debug_output_redacts_keys_secrets_and_route_credentials() {
        let relay = EnrollmentRelayAccess {
            route: "relay+wss://user:password@relay.test/private?ticket=secret".into(),
            slot: "slot-secret-marker".into(),
            ticket: "relay-ticket".into(),
        };
        let invitation = EnrollmentInvitation {
            version: STATE_VERSION,
            id: "invitation".into(),
            secret: "invitation-secret".into(),
            daemon_public_key: "daemon-public-key".into(),
            daemon_fingerprint: "daemon-fingerprint".into(),
            daemon_name: "daemon".into(),
            expires_at_unix: 1,
            route_hints: vec![
                "wss://user:password@example.test/private?ticket=route-secret".into(),
            ],
            relay_access: vec![relay.clone()],
            approval_required: true,
        };
        let known = KnownDaemon {
            fingerprint: "fingerprint".into(),
            name: "wss://name-user-marker:name-password-marker@known.test/name-path-marker".into(),
            public_key: "public-key".into(),
            route_hints: invitation.route_hints.clone(),
            auth: KnownDaemonAuth::Enrolled,
            first_seen_at_unix: 1,
            last_used_at_unix: 2,
        };
        let persisted_identity =
            PersistedIdentity { version: STATE_VERSION, private_key: "private-key".into() };
        let persisted_invitation = PersistedInvitation {
            id: "persisted".into(),
            secret: "persisted-secret".into(),
            expires_at_unix: 1,
            route_hints: invitation.route_hints.clone(),
            claimed_by: None,
        };

        let output = format!(
            "{relay:?} {invitation:?} {known:?} {persisted_identity:?} {persisted_invitation:?}"
        );
        for secret in [
            "password",
            "private?",
            "route-secret",
            "relay-ticket",
            "slot-secret-marker",
            "invitation-secret",
            "private-key",
            "persisted-secret",
            "name-user-marker",
            "name-password-marker",
            "name-path-marker",
        ] {
            assert!(!output.contains(secret), "{secret:?} leaked in {output:?}");
        }
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
                        connection_attempt: ConnectionAttemptId([8; 16]),
                        resume: BTreeMap::new(),
                    },
                )
                .await
            }
        });
        let server_task = tokio::spawn({
            let database = database.clone();
            async move {
                accept_secure_link(
                    Box::new(server_link),
                    &daemon_identity,
                    &*database,
                    InboundAuthEvidence::Network(NetworkPeer::Tcp),
                )
                .await
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
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
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
            let persistence = database.submit_mutation_locked(&mut state).unwrap();
            drop(state);
            persistence.wait().await.unwrap();
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
                inbound: InboundAuthEvidence::Network(NetworkPeer::Relay),
            })
            .await;
        assert_eq!(result.unwrap_err(), "device has been revoked");
    }
}
