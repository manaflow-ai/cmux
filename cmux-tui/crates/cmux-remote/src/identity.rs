use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
#[cfg(unix)]
use std::fs::File;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex as StdMutex, Weak};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, Notify, OwnedMutexGuard, oneshot, watch};

use crate::crypto::{
    AuthGrant, AuthKind, AuthRequest, ConnectionAttemptId, CryptoError, InboundAuthEvidence,
    ServerAuthenticator, StaticIdentity, public_key_fingerprint,
};
use crate::owner_lock::{OwnerFileLock, sibling_lock_path};
use crate::secure_directory::{DirectoryAccess, ensure_secure_directory};

const STATE_VERSION: u32 = 1;
/// Current on-disk authorization schema. Version 2 fences binaries that only
/// understand the original version-1 state.
pub const AUTH_STATE_VERSION: u32 = 2;
const MAX_INVITATION_TTL: Duration = Duration::from_secs(5 * 60);
const MAX_LIVE_INVITATIONS: usize = 256;
/// How long a daemon holds an invitation's enrollment for a person's approval.
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// Device-id prefix of a grant issued by a trusted-network listener. Such a
/// connection is admitted by the network it arrived on; it is never revoked by
/// the daemon's device list or its carrier policy, only by leaving the network.
pub const TRUSTED_NETWORK_DEVICE_PREFIX: &str = "network:";
const ENROLLMENT_RETRY_GRACE: Duration = Duration::from_secs(60);
const MAX_INVITATION_RELAY_ROUTES: usize = 2;
const MAX_RELAY_SLOT_BYTES: usize = 256;
const MAX_RELAY_TICKET_BYTES: usize = 4 * 1024;
const MAX_RECORDED_CONNECTION_ATTEMPTS: usize = 4_096;
const MAX_BOUND_DEVICE_NAME_BYTES: usize = 128;
const ENROLLMENT_URI_PREFIX: &str = "cmux://enroll/";
const CLIENT_STATE_FILE: &str = "known-daemons.json";
pub const MAX_INVITATION_URI_BYTES: usize = ENROLLMENT_URI_PREFIX.len() + 16 * 1024;

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
    /// The minting machine's hub route: its node key as the hub knows it (`daemonId`,
    /// `wgPublicKey` in `acpmux machine status --json`, standard base64 of 32 bytes). Its route
    /// hints are often only its own loopback daemon; another machine reaches that through its
    /// acpmux and the hub carrier (`--via-machine KEY`), and redeeming uses this when the person
    /// named none. Absent on invitations from before it, and on machines not joined to a hub.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via_machine: Option<String>,
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
            .field("via_machine", &self.via_machine)
            .finish()
    }
}

/// Whether `text` is a hub machine key (`daemonId`): standard padded base64 of 32 bytes, the
/// form `--via-machine` takes and the hub answers for.
pub fn is_hub_machine_key(text: &str) -> bool {
    base64::engine::general_purpose::STANDARD.decode(text).is_ok_and(|bytes| bytes.len() == 32)
}

fn validate_via_machine(via_machine: Option<&str>) -> Result<(), IdentityError> {
    match via_machine {
        Some(key) if !is_hub_machine_key(key) => Err(IdentityError::Invalid(
            "invitation via_machine is not a machine node key (base64 of 32 bytes)".into(),
        )),
        _ => Ok(()),
    }
}

impl EnrollmentInvitation {
    pub fn secret_bytes(&self) -> Result<[u8; 32], IdentityError> {
        decode_key(&self.secret)
    }

    pub fn to_uri(&self) -> Result<String, IdentityError> {
        validate_relay_access(&self.route_hints, &self.relay_access)?;
        validate_via_machine(self.via_machine.as_deref())?;
        let json = serde_json::to_vec(self).map_err(IdentityError::Json)?;
        let uri = format!(
            "{ENROLLMENT_URI_PREFIX}{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
        );
        if uri.len() > MAX_INVITATION_URI_BYTES {
            return Err(IdentityError::Invalid("enrollment URI is too large".into()));
        }
        Ok(uri)
    }

    pub fn from_uri(uri: &str) -> Result<Self, IdentityError> {
        let encoded = uri
            .strip_prefix(ENROLLMENT_URI_PREFIX)
            .ok_or_else(|| IdentityError::Invalid("enrollment URI has the wrong scheme".into()))?;
        if encoded.len() > MAX_INVITATION_URI_BYTES - ENROLLMENT_URI_PREFIX.len() {
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
        validate_via_machine(invitation.via_machine.as_deref())?;
        Ok(invitation)
    }
}

/// The one device an invitation admits: its Noise public key, and the name
/// the owner gave it. A bound invitation enrolls that key as soon as it
/// presents the invitation, with no approval step, and refuses every other key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundDevice {
    pub public_key: [u8; 32],
    pub name: Option<String>,
}

impl BoundDevice {
    /// Parse a device key as `cmux remote device-key` prints it (unpadded
    /// URL-safe base64 of the 32-byte public key).
    pub fn parse(public_key: &str, name: Option<String>) -> Result<Self, IdentityError> {
        let public_key = decode_key(public_key.trim())?;
        let name = name.map(|name| name.trim().to_owned());
        if let Some(name) = &name
            && (name.is_empty()
                || name.len() > MAX_BOUND_DEVICE_NAME_BYTES
                || name.chars().any(char::is_control))
        {
            return Err(IdentityError::Invalid(format!(
                "device name must be 1 to {MAX_BOUND_DEVICE_NAME_BYTES} bytes with no control characters"
            )));
        }
        Ok(Self { public_key, name })
    }

    pub fn fingerprint(&self) -> String {
        public_key_fingerprint(&self.public_key)
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
    /// The daemon's machine on the hub ([`EnrollmentInvitation::via_machine`]), kept from the
    /// invitation that enrolled it, so a later connect reaches its loopback route the same way.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via_machine: Option<String>,
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
            .field("via_machine", &self.via_machine)
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
    state: StdMutex<ClientStateCache>,
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
        let path = state_dir.join(CLIENT_STATE_FILE);
        let lock_path = sibling_lock_path(&path).map_err(IdentityError::Io)?;
        let _path_lock = OwnerFileLock::acquire(&lock_path).map_err(IdentityError::Io)?;
        let (state, routes_changed) =
            load_client_state(&path)?.unwrap_or_else(|| (PersistedClientState::default(), false));
        if routes_changed {
            atomic_json(&path, &state)?;
        }
        Ok(Arc::new(Self {
            state_dir,
            identity,
            state: StdMutex::new(ClientStateCache { persisted: state, generation: 0 }),
        }))
    }

    pub fn identity(&self) -> StaticIdentity {
        self.identity.clone()
    }

    /// This client's device public key, encoded the way `enroll create
    /// --device-key` reads it.
    pub fn device_public_key(&self) -> String {
        encode_key(&self.identity.public_key())
    }

    pub async fn known_daemons(&self) -> Vec<KnownDaemon> {
        let mut daemons = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .persisted
            .daemons
            .values()
            .cloned()
            .collect::<Vec<_>>();
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
        let (transaction, mut candidate) = self.reload_client_state().await?;
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
            self.commit_client_state(transaction, candidate)?;
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
            via_machine: None,
        };
        candidate.daemons.insert(fingerprint, record.clone());
        self.commit_client_state(transaction, candidate)?;
        Ok(record)
    }

    /// Keep `via_machine`, the hub machine key the daemon `fingerprint` is reached through
    /// ([`KnownDaemon::via_machine`]). None when no daemon has that fingerprint.
    pub async fn remember_via_machine(
        &self,
        fingerprint: &str,
        via_machine: &str,
    ) -> Result<Option<KnownDaemon>, IdentityError> {
        validate_via_machine(Some(via_machine))?;
        let (transaction, mut candidate) = self.reload_client_state().await?;
        let routes_changed = transaction.routes_changed;
        let Some(existing) = candidate.daemons.get_mut(fingerprint) else {
            if routes_changed {
                self.commit_client_state(transaction, candidate)?;
            }
            return Ok(None);
        };
        existing.via_machine = Some(via_machine.to_owned());
        let record = existing.clone();
        self.commit_client_state(transaction, candidate)?;
        Ok(Some(record))
    }

    pub async fn remember_verified_route(
        &self,
        fingerprint: &str,
        route: &str,
    ) -> Result<Option<KnownDaemon>, IdentityError> {
        let route = credential_free_route_hint(route)?;
        let now = unix_time()?;
        let (transaction, mut candidate) = self.reload_client_state().await?;
        let routes_changed = transaction.routes_changed;
        let Some(existing) = candidate.daemons.get_mut(fingerprint) else {
            if routes_changed {
                self.commit_client_state(transaction, candidate)?;
            }
            return Ok(None);
        };
        existing.last_used_at_unix = now;
        if !existing.route_hints.contains(&route) {
            existing.route_hints.push(route);
        }
        let record = existing.clone();
        self.commit_client_state(transaction, candidate)?;
        Ok(Some(record))
    }

    pub async fn daemon_key(&self, fingerprint: &str) -> Result<Option<[u8; 32]>, IdentityError> {
        let (transaction, candidate) = self.reload_client_state().await?;
        let routes_changed = transaction.routes_changed;
        let key = candidate
            .daemons
            .get(fingerprint)
            .map(|daemon| decode_key(&daemon.public_key))
            .transpose()?;
        if routes_changed {
            self.commit_client_state(transaction, candidate)?;
        }
        Ok(key)
    }

    pub async fn forget_daemon(&self, fingerprint: &str) -> Result<bool, IdentityError> {
        let (transaction, mut candidate) = self.reload_client_state().await?;
        let routes_changed = transaction.routes_changed;
        let removed = candidate.daemons.remove(fingerprint).is_some();
        if removed || routes_changed {
            self.commit_client_state(transaction, candidate)?;
        }
        Ok(removed)
    }

    async fn reload_client_state(
        &self,
    ) -> Result<(ClientStateTransaction, PersistedClientState), IdentityError> {
        let path = self.state_dir.join(CLIENT_STATE_FILE);
        let lock_path = sibling_lock_path(&path).map_err(IdentityError::Io)?;
        loop {
            let (generation, fallback) = {
                let cache = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                (cache.generation, cache.persisted.clone())
            };
            let path_lock =
                OwnerFileLock::acquire_async(lock_path.clone()).await.map_err(IdentityError::Io)?;
            let loaded = load_client_state(&path)?;
            let mut cache = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if cache.generation != generation {
                // A transaction completed while this operation waited for the
                // owner-file lock. Reload under a new lease so the disk state
                // and cache generation describe the same point in history.
                continue;
            }
            let (candidate, routes_changed) = loaded.unwrap_or((fallback, false));
            cache.replace(candidate.clone())?;
            let generation = cache.generation;
            drop(cache);
            return Ok((
                ClientStateTransaction { _path_lock: path_lock, routes_changed, generation },
                candidate,
            ));
        }
    }

    fn commit_client_state(
        &self,
        transaction: ClientStateTransaction,
        candidate: PersistedClientState,
    ) -> Result<(), IdentityError> {
        {
            let cache = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if cache.generation != transaction.generation {
                return Err(IdentityError::Persistence(
                    "client identity cache changed while its owner-file lock was held".into(),
                ));
            }
        }
        let result = match self.persist_client_state(&candidate) {
            Ok(()) => {
                self.state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .replace(candidate)?;
                Ok(())
            }
            Err(error @ IdentityError::Committed(_)) => {
                self.state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .replace(candidate)?;
                Err(error)
            }
            Err(error) => Err(error),
        };
        // Keep the cross-process lease through both the durable write and the
        // matching cache publication.
        drop(transaction);
        result
    }

    fn persist_client_state(&self, state: &PersistedClientState) -> Result<(), IdentityError> {
        atomic_json(&self.state_dir.join(CLIENT_STATE_FILE), state)
    }
}

struct ClientStateCache {
    persisted: PersistedClientState,
    generation: u64,
}

impl ClientStateCache {
    fn replace(&mut self, persisted: PersistedClientState) -> Result<(), IdentityError> {
        if self.persisted != persisted {
            self.generation = self.generation.checked_add(1).ok_or_else(|| {
                IdentityError::Invalid("client state generation exhausted".into())
            })?;
            self.persisted = persisted;
        }
        Ok(())
    }
}

struct ClientStateTransaction {
    _path_lock: OwnerFileLock,
    routes_changed: bool,
    generation: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
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
    receiver: oneshot::Receiver<Result<(), PersistenceFailure>>,
}

impl PersistenceWaiter {
    async fn wait_result(self) -> Result<(), PersistenceFailure> {
        self.receiver.await.unwrap_or_else(|_| {
            Err(PersistenceFailure::Uncommitted("identity persistence coordinator stopped".into()))
        })
    }

    async fn wait(self) -> Result<(), IdentityError> {
        self.wait_result().await.map_err(PersistenceFailure::into_identity_error)
    }
}

#[derive(Debug, Clone)]
enum PersistenceFailure {
    Uncommitted(String),
    Committed(String),
}

impl PersistenceFailure {
    fn from_identity_error(error: IdentityError) -> Self {
        match error {
            IdentityError::Committed(message) => Self::Committed(message),
            error => Self::Uncommitted(error.to_string()),
        }
    }

    fn into_identity_error(self) -> IdentityError {
        match self {
            Self::Uncommitted(message) => IdentityError::Persistence(message),
            Self::Committed(message) => IdentityError::Committed(message),
        }
    }

    fn message(&self) -> String {
        match self {
            Self::Uncommitted(message) => message.clone(),
            Self::Committed(message) => {
                format!(
                    "identity state was committed but durability confirmation failed: {message}"
                )
            }
        }
    }
}

struct PersistenceCoordinator {
    shared: Arc<PersistenceWorkerShared>,
    worker: StdMutex<Option<std::thread::JoinHandle<OwnerFileLock>>>,
}

struct PersistenceWorkerShared {
    path: PathBuf,
    state: StdMutex<PersistenceCoordinatorState>,
    changed: Condvar,
}

struct PersistenceCoordinatorState {
    durable_revision: u64,
    highest_seen_revision: u64,
    in_flight: Option<u64>,
    pending: BTreeMap<u64, PersistedState>,
    waiters: BTreeMap<u64, Vec<oneshot::Sender<Result<(), PersistenceFailure>>>>,
    last_failure: Option<(u64, PersistenceFailure)>,
    terminal_failure: Option<PersistenceFailure>,
    closing: bool,
}

impl PersistenceCoordinator {
    fn new(
        path: PathBuf,
        durable_revision: u64,
        state_lease: OwnerFileLock,
    ) -> Result<Self, IdentityError> {
        let shared = Arc::new(PersistenceWorkerShared {
            path,
            state: StdMutex::new(PersistenceCoordinatorState {
                durable_revision,
                highest_seen_revision: durable_revision,
                in_flight: None,
                pending: BTreeMap::new(),
                waiters: BTreeMap::new(),
                last_failure: None,
                terminal_failure: None,
                closing: false,
            }),
            changed: Condvar::new(),
        });
        let worker_shared = Arc::clone(&shared);
        let worker = std::thread::Builder::new()
            .name("cmux-auth-persistence".into())
            .spawn(move || {
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    worker_shared.drain();
                }))
                .is_err()
                {
                    worker_shared.fail_terminal(PersistenceFailure::Uncommitted(
                        "identity persistence worker panicked".into(),
                    ));
                }
                state_lease
            })
            .map_err(IdentityError::Io)?;
        Ok(Self { shared, worker: StdMutex::new(Some(worker)) })
    }

    /// Accept a snapshot synchronously so cancellation at the caller's next
    /// await cannot discard an in-memory mutation.
    fn submit(&self, snapshot: PersistedState) -> PersistenceWaiter {
        let revision = snapshot.revision;
        let (sender, receiver) = oneshot::channel();
        let mut sender = Some(sender);
        let mut immediate = None;
        let mut wake_worker = false;
        {
            let mut state = self.lock_state();
            if state.closing {
                immediate = Some(Err(PersistenceFailure::Uncommitted(
                    "identity persistence coordinator is shutting down".into(),
                )));
            } else if revision <= state.durable_revision {
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
                                PersistenceFailure::Uncommitted(format!(
                                    "identity revision {revision} was superseded before it became durable"
                                ))
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
                        state.pending.clear();
                        state.pending.insert(revision, snapshot);
                        wake_worker = true;
                    }
                }
            }
        }
        if let Some(result) = immediate {
            let _ = sender.expect("immediate persistence waiter is available").send(result);
        }
        if wake_worker {
            self.shared.changed.notify_one();
        }
        PersistenceWaiter { receiver }
    }

    fn close_and_join(&self) -> Result<(), IdentityError> {
        self.close_and_join_with_cleanup(|_| Ok(()))
    }

    fn close_and_join_with_cleanup(
        &self,
        cleanup: impl FnOnce(&Result<(), IdentityError>) -> Result<(), IdentityError>,
    ) -> Result<(), IdentityError> {
        {
            let mut state = self.lock_state();
            state.closing = true;
        }
        self.shared.changed.notify_all();
        let mut worker = self.worker.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(worker_handle) = worker.take() else {
            drop(worker);
            return self.terminal_result();
        };
        let state_lease = match worker_handle.join() {
            Ok(state_lease) => Some(state_lease),
            Err(_) => {
                self.lock_state().terminal_failure = Some(PersistenceFailure::Uncommitted(
                    "identity persistence worker panicked".into(),
                ));
                None
            }
        };
        drop(worker);
        let result = self.terminal_result();
        let cleanup_result = if state_lease.is_some() { cleanup(&result) } else { Ok(()) };
        drop(state_lease);
        match (result, cleanup_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
            (Err(finalization), Err(cleanup)) => Err(IdentityError::Persistence(format!(
                "{finalization}; lifecycle cleanup also failed: {cleanup}"
            ))),
        }
    }

    fn terminal_result(&self) -> Result<(), IdentityError> {
        let state = self.lock_state();
        if let Some(failure) = &state.terminal_failure {
            return Err(failure.clone().into_identity_error());
        }
        if state.durable_revision >= state.highest_seen_revision {
            return Ok(());
        }
        if let Some((failed_revision, failure)) = &state.last_failure
            && *failed_revision >= state.highest_seen_revision
        {
            return Err(failure.clone().into_identity_error());
        }
        Err(IdentityError::Persistence(format!(
            "identity revision {} did not become durable (latest durable revision {})",
            state.highest_seen_revision, state.durable_revision
        )))
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, PersistenceCoordinatorState> {
        self.shared.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn durable_revision_at_least(&self, revision: u64) -> bool {
        self.lock_state().durable_revision >= revision
    }
}

impl Drop for PersistenceCoordinator {
    fn drop(&mut self) {
        // This waits for the worker's current durable write, including fsync,
        // so the exclusive state lease cannot be released early. Async callers
        // should use AuthDatabase::shutdown or drop from a blocking thread.
        let _ = self.close_and_join();
    }
}

impl PersistenceWorkerShared {
    fn drain(&self) {
        loop {
            let next = {
                let mut state =
                    self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                while state.pending.is_empty() && !state.closing {
                    state =
                        self.changed.wait(state).unwrap_or_else(std::sync::PoisonError::into_inner);
                }
                let next = state.pending.pop_first();
                if let Some((revision, _)) = &next {
                    state.in_flight = Some(*revision);
                }
                next
            };
            let Some((revision, snapshot)) = next else {
                return;
            };

            let result =
                atomic_json(&self.path, &snapshot).map_err(PersistenceFailure::from_identity_error);

            let waiters = {
                let mut state =
                    self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
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

    fn fail_terminal(&self, failure: PersistenceFailure) {
        let waiters = {
            let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state.in_flight = None;
            state.pending.clear();
            state.closing = true;
            state.terminal_failure = Some(failure.clone());
            std::mem::take(&mut state.waiters).into_values().flatten().collect::<Vec<_>>()
        };
        for waiter in waiters {
            let _ = waiter.send(Err(failure.clone()));
        }
    }
}

fn take_waiters_through(
    waiters: &mut BTreeMap<u64, Vec<oneshot::Sender<Result<(), PersistenceFailure>>>>,
    revision: u64,
) -> Vec<oneshot::Sender<Result<(), PersistenceFailure>>> {
    let revisions = waiters.range(..=revision).map(|(revision, _)| *revision).collect::<Vec<_>>();
    revisions
        .into_iter()
        .flat_map(|revision| waiters.remove(&revision).unwrap_or_default())
        .collect()
}

#[path = "identity/auth_database.rs"]
mod auth_database;
pub use auth_database::AuthDatabase;

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
            version: AUTH_STATE_VERSION,
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
    /// The bound device's public key. State written before bound invitations
    /// existed has none and loads unbound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bound_device: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bound_device_name: Option<String>,
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
            .field("bound_device", &self.bound_device)
            .finish()
    }
}

fn load_or_create_identity(path: &Path) -> Result<StaticIdentity, IdentityError> {
    let lock_path = sibling_lock_path(path).map_err(IdentityError::Io)?;
    let _path_lock = OwnerFileLock::acquire(&lock_path).map_err(IdentityError::Io)?;
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

fn load_client_state(path: &Path) -> Result<Option<(PersistedClientState, bool)>, IdentityError> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    let mut state: PersistedClientState =
        serde_json::from_slice(&data).map_err(IdentityError::Json)?;
    if state.version != STATE_VERSION {
        return Err(IdentityError::Invalid(format!(
            "known-daemon state version {} is unsupported",
            state.version
        )));
    }
    let mut routes_changed = false;
    for daemon in state.daemons.values_mut() {
        routes_changed |= sanitize_loaded_known_daemon(daemon);
    }
    Ok(Some((state, routes_changed)))
}

#[derive(Clone, Copy)]
enum AuthStateLoadMode {
    CurrentOnly,
    MigrateLegacy,
}

#[derive(Deserialize)]
struct PersistedAuthStateVersion {
    version: u32,
}

/// Read-only classification of the persisted daemon authorization schema.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PersistedAuthStateSchema {
    /// No authorization state has been committed.
    Missing,
    /// Version 1 requires an explicitly process-fenced migration.
    Legacy,
    /// The current rollback-fenced schema is present.
    Current,
    /// A newer or otherwise unknown schema must not be rewritten.
    Unsupported(u32),
}

/// Read the on-disk authorization schema without creating or modifying state.
pub fn persisted_auth_state_version(state_dir: &Path) -> Result<Option<u32>, IdentityError> {
    let data = match fs::read(state_dir.join("devices.json")) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    let version: PersistedAuthStateVersion =
        serde_json::from_slice(&data).map_err(IdentityError::Json)?;
    Ok(Some(version.version))
}

/// Classify authorization state without creating or modifying it.
pub fn persisted_auth_state_schema(
    state_dir: &Path,
) -> Result<PersistedAuthStateSchema, IdentityError> {
    Ok(match persisted_auth_state_version(state_dir)? {
        None => PersistedAuthStateSchema::Missing,
        Some(STATE_VERSION) => PersistedAuthStateSchema::Legacy,
        Some(AUTH_STATE_VERSION) => PersistedAuthStateSchema::Current,
        Some(version) => PersistedAuthStateSchema::Unsupported(version),
    })
}

fn load_auth_state(
    path: &Path,
    load_mode: AuthStateLoadMode,
) -> Result<PersistedState, IdentityError> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let state = PersistedState::default();
            atomic_json(path, &state)?;
            return Ok(state);
        }
        Err(error) => return Err(IdentityError::Io(error)),
    };
    let mut state: PersistedState = serde_json::from_slice(&data).map_err(IdentityError::Json)?;
    let migrating_legacy =
        state.version == STATE_VERSION && matches!(load_mode, AuthStateLoadMode::MigrateLegacy);
    if state.version == STATE_VERSION && !migrating_legacy {
        return Err(IdentityError::Invalid(
            "device state version 1 requires explicit migration".into(),
        ));
    }
    if state.version != AUTH_STATE_VERSION && !migrating_legacy {
        return Err(IdentityError::Invalid(format!(
            "device state version {} is unsupported",
            state.version
        )));
    }
    let mut state_changed = migrating_legacy;
    if migrating_legacy {
        state.version = AUTH_STATE_VERSION;
    }
    let now = unix_time()?;
    let invitation_count = state.invitations.len();
    state.invitations.retain(|invitation| invitation.expires_at_unix > now);
    state_changed |= state.invitations.len() != invitation_count;
    for invitation in &mut state.invitations {
        let sanitized = credential_free_route_hints_lossy(&invitation.route_hints);
        state_changed |= sanitized != invitation.route_hints;
        invitation.route_hints = sanitized;
    }
    if state_changed {
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or_else(|| IdentityError::Invalid("identity revision exhausted".into()))?;
        atomic_json(path, &state)?;
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| IdentityError::Invalid("state path has no parent".into()))?;
        // A previous atomic rename may have become visible before its parent
        // directory sync failed. Reconfirm that directory entry before
        // trusting version 2 as a durable rollback fence.
        sync_parent_directory(parent)?;
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
        restrict_file(&temporary)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, path).map_err(IdentityError::Io)?;
        if let Err(error) = sync_parent_directory(parent) {
            return Err(IdentityError::Committed(error.to_string()));
        }
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
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn secure_directory(path: &Path) -> Result<(), IdentityError> {
    ensure_secure_directory(path, DirectoryAccess::ManagedOwnerOnly).map_err(IdentityError::Io)
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
    // Every Apple target keeps app state under Library/Application Support;
    // on iOS HOME is the app's sandbox container. On macOS cmux NEXT owns
    // `Application Support/cmux-next`; `Application Support/cmux` is Classic's.
    #[cfg(target_vendor = "apple")]
    {
        let app_dir = if cfg!(target_os = "macos") { "cmux-next" } else { "cmux" };
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library/Application Support").join(app_dir).join("remote"))
    }
    #[cfg(not(target_vendor = "apple"))]
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
    let mut seen = HashSet::with_capacity(routes.len());
    for route in routes {
        let route = credential_free_route_hint(&route)?;
        if seen.insert(route.clone()) {
            sanitized.push(route);
        }
    }
    Ok(sanitized)
}

fn credential_free_route_hints_lossy(routes: &[String]) -> Vec<String> {
    let mut sanitized = Vec::with_capacity(routes.len());
    let mut seen = HashSet::with_capacity(routes.len());
    for route in routes {
        if let Ok(route) = credential_free_route_hint(route)
            && seen.insert(route.clone())
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
    Committed(String),
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
            Self::Committed(message) => write!(
                formatter,
                "identity state was committed but durability confirmation failed: {message}"
            ),
            Self::Invalid(message) => write!(formatter, "invalid identity state: {message}"),
            Self::InvitationExpired(id) => write!(
                formatter,
                "invitation {id} is expired; make a new one with `cmux remote enroll create`"
            ),
            Self::UnknownPending(id) => write!(
                formatter,
                "no pending enrollment for {id}; `cmux remote enroll pending` lists the waiting devices"
            ),
            Self::UnknownDevice(id) => write!(
                formatter,
                "unknown device {id}; `cmux remote enroll devices` lists the enrolled devices"
            ),
            Self::Timeout => formatter.write_str("timed out waiting for enrollment"),
        }
    }
}

impl std::error::Error for IdentityError {}

#[cfg(test)]
mod tests {
    #[test]
    fn identity_refusals_name_the_command_that_lists_the_ids() {
        assert!(IdentityError::UnknownPending("x".into()).to_string().contains("enroll pending"));
        assert!(IdentityError::UnknownDevice("x".into()).to_string().contains("enroll devices"));
        assert!(IdentityError::InvitationExpired("x".into()).to_string().contains("enroll create"));
    }

    use super::*;
    use crate::crypto::NetworkPeer;
    use cmux_remote_protocol::{Lane, SessionId};

    /// Long enough that only an approval wait reaches it; a bound claim
    /// answers at once.
    const BOUND_CLAIM_DEADLINE: Duration = Duration::from_secs(10);

    fn invitation_request(
        invitation_id: &str,
        device: &StaticIdentity,
        device_name: &str,
    ) -> AuthRequest {
        AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation_id.into()),
            grant: None,
            connection_attempt: ConnectionAttemptId([7; 16]),
            device_public_key: device.public_key(),
            device_name: device_name.into(),
            session: SessionId([9; 16]),
            lane: Lane::Interactive,
            lanes: vec![Lane::Interactive],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tcp),
        }
    }

    async fn bound_invitation(
        auth: &AuthDatabase,
        device: &StaticIdentity,
        name: Option<&str>,
    ) -> EnrollmentInvitation {
        let bound =
            BoundDevice::parse(&encode_key(&device.public_key()), name.map(Into::into)).unwrap();
        auth.create_invitation_for_device(
            Duration::from_secs(60),
            Vec::new(),
            Vec::new(),
            Some(bound),
        )
        .await
        .unwrap()
    }

    async fn claim(auth: &Arc<AuthDatabase>, request: AuthRequest) -> Result<AuthGrant, String> {
        let auth = Arc::clone(auth);
        tokio::time::timeout(BOUND_CLAIM_DEADLINE, async move { auth.authorize(request).await })
            .await
            .expect("a bound invitation answers at once, never waiting for an approval")
    }

    #[tokio::test]
    async fn a_bound_invitation_refuses_another_device_and_queues_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let bound = StaticIdentity::generate().unwrap();
        let stranger = StaticIdentity::generate().unwrap();
        let invitation = bound_invitation(&auth, &bound, None).await;
        assert!(!invitation.approval_required);

        let error = claim(&auth, invitation_request(&invitation.id, &stranger, "stranger"))
            .await
            .unwrap_err();

        assert_eq!(error, "invitation is bound to another device");
        assert!(auth.pending_enrollments().await.is_empty());
        assert!(matches!(
            auth.wait_for_pending(Duration::from_millis(50)).await,
            Err(IdentityError::Timeout)
        ));
        assert!(auth.list_devices().await.is_empty());
        // The refusal leaves the invitation to its device.
        let grant = claim(&auth, invitation_request(&invitation.id, &bound, "bound")).await;
        assert_eq!(grant.unwrap().device_id, bound.fingerprint());
    }

    #[tokio::test]
    async fn a_bound_invitation_enrolls_its_device_with_no_approval() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let device = StaticIdentity::generate().unwrap();
        let invitation = bound_invitation(&auth, &device, Some("agent-vm")).await;

        let grant =
            claim(&auth, invitation_request(&invitation.id, &device, "client-name")).await.unwrap();

        assert_eq!(grant.device_id, device.fingerprint());
        assert!(auth.grant_is_current(&grant).await);
        assert!(auth.pending_enrollments().await.is_empty());
        let devices = auth.list_devices().await;
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].fingerprint, device.fingerprint());
        assert_eq!(devices[0].public_key, encode_key(&device.public_key()));
        // The owner's name for the device wins over the one the client sends.
        assert_eq!(devices[0].name, "agent-vm");
        {
            let state = auth.state.lock().await;
            let record = &state.invitations[&invitation.id];
            assert_eq!(record.claimed_by.as_deref(), Some(device.fingerprint().as_str()));
        }
        // The same device may present the invitation again within its retry grace.
        let again =
            claim(&auth, invitation_request(&invitation.id, &device, "client-name")).await.unwrap();
        assert_eq!(again.device_id, device.fingerprint());
        // Once enrolled, the device needs no invitation at all.
        let mut enrolled = invitation_request(&invitation.id, &device, "client-name");
        enrolled.mode = AuthKind::Enrolled;
        enrolled.invitation_id = None;
        assert_eq!(auth.authorize(enrolled).await.unwrap().device_id, device.fingerprint());
    }

    #[tokio::test]
    async fn a_bound_invitation_survives_a_daemon_restart() {
        let directory = tempfile::tempdir().unwrap();
        let device = StaticIdentity::generate().unwrap();
        let stranger = StaticIdentity::generate().unwrap();
        let invitation = {
            let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
            let invitation = bound_invitation(&auth, &device, Some("agent-vm")).await;
            auth.shutdown().await.unwrap();
            invitation
        };
        let persisted = fs::read_to_string(directory.path().join("devices.json")).unwrap();
        assert!(persisted.contains(&encode_key(&device.public_key())), "{persisted}");

        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let error = claim(&auth, invitation_request(&invitation.id, &stranger, "stranger"))
            .await
            .unwrap_err();
        assert_eq!(error, "invitation is bound to another device");
        let grant =
            claim(&auth, invitation_request(&invitation.id, &device, "client")).await.unwrap();
        assert_eq!(grant.device_id, device.fingerprint());
        assert_eq!(auth.list_devices().await[0].name, "agent-vm");
    }

    #[tokio::test]
    async fn revoking_a_device_enrolled_by_a_bound_invitation_cuts_it_off() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let device = StaticIdentity::generate().unwrap();
        let invitation = bound_invitation(&auth, &device, None).await;
        let grant =
            claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap();

        let revoked = auth.revoke(&grant.device_id).await.unwrap();

        // The reply names the device, so `enroll revoke` can say which one.
        assert_eq!(revoked.id, grant.device_id);
        assert_eq!(revoked.fingerprint, device.fingerprint());
        assert!(revoked.revoked_at_unix.is_some());
        assert!(!auth.grant_is_current(&grant).await);
        assert!(!auth.device_is_active(&grant.device_id).await);
        let error =
            claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap_err();
        assert_eq!(error, "device enrollment is no longer active");
    }

    /// Review finding P1-F1: a second, unused invitation bound to the same
    /// key must not re-enroll a device the owner revoked.
    #[tokio::test]
    async fn revoking_a_device_voids_its_unused_bound_invitations() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let device = StaticIdentity::generate().unwrap();
        let other = StaticIdentity::generate().unwrap();
        let first = bound_invitation(&auth, &device, None).await;
        let spare = bound_invitation(&auth, &device, None).await;
        let others = bound_invitation(&auth, &other, None).await;
        let grant = claim(&auth, invitation_request(&first.id, &device, "agent")).await.unwrap();

        auth.revoke(&grant.device_id).await.unwrap();

        let error =
            claim(&auth, invitation_request(&spare.id, &device, "agent")).await.unwrap_err();
        assert_eq!(error, "invitation is unknown or expired");
        assert!(!auth.device_is_active(&grant.device_id).await);
        // Voided durably: a restarted daemon has no such invitation either.
        auth.shutdown().await.unwrap();
        drop(auth);
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let error =
            claim(&auth, invitation_request(&spare.id, &device, "agent")).await.unwrap_err();
        assert_eq!(error, "invitation is unknown or expired");
        assert!(!auth.device_is_active(&grant.device_id).await);
        // Another device's bound invitation is untouched.
        assert!(claim(&auth, invitation_request(&others.id, &other, "other")).await.is_ok());
        // The owner can still re-enroll the device on purpose, with a new invitation.
        let fresh = bound_invitation(&auth, &device, None).await;
        let regrant = claim(&auth, invitation_request(&fresh.id, &device, "agent")).await;
        assert!(auth.device_is_active(&regrant.unwrap().device_id).await);
    }

    #[tokio::test]
    async fn an_expired_bound_invitation_is_refused() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let device = StaticIdentity::generate().unwrap();
        let invitation = bound_invitation(&auth, &device, None).await;
        auth.state.lock().await.invitations.get_mut(&invitation.id).unwrap().expires_at_unix =
            unix_time().unwrap() - 1;

        let error =
            claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap_err();

        assert_eq!(error, "invitation is expired");
        assert!(auth.list_devices().await.is_empty());
    }

    #[tokio::test]
    async fn bound_invitations_keep_the_live_invitation_limit() {
        let directory = tempfile::tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let device = StaticIdentity::generate().unwrap();
        for _ in 0..MAX_LIVE_INVITATIONS {
            bound_invitation(&auth, &device, None).await;
        }
        let bound = BoundDevice::parse(&encode_key(&device.public_key()), None).unwrap();
        let error = auth
            .create_invitation_for_device(
                Duration::from_secs(60),
                Vec::new(),
                Vec::new(),
                Some(bound),
            )
            .await
            .unwrap_err();
        assert!(error.to_string().contains("maximum invitation count"), "{error}");
    }

    #[test]
    fn a_bound_device_needs_a_32_byte_key_and_a_plain_name() {
        let key = encode_key(&[7; 32]);
        assert!(BoundDevice::parse(&key, None).is_ok());
        assert_eq!(BoundDevice::parse(&key, Some(" vm ".into())).unwrap().name.unwrap(), "vm");
        assert!(BoundDevice::parse(&encode_key(&[7; 32])[..20], None).is_err());
        assert!(BoundDevice::parse("not base64!", None).is_err());
        assert!(BoundDevice::parse(&key, Some("  ".into())).is_err());
        assert!(BoundDevice::parse(&key, Some("a\nb".into())).is_err());
        assert!(BoundDevice::parse(&key, Some("x".repeat(129))).is_err());
    }

    #[tokio::test]
    async fn state_written_before_bound_invitations_loads_them_unbound() {
        let directory = tempfile::tempdir().unwrap();
        let expires_at_unix = unix_time().unwrap() + 120;
        let old_state = serde_json::json!({
            "version": AUTH_STATE_VERSION,
            "revision": 3,
            "revocation_generation": 0,
            "devices": [],
            "invitations": [{
                "id": "old-invitation",
                "secret": encode_key(&[5; 32]),
                "expires_at_unix": expires_at_unix,
                "route_hints": [],
                "claimed_by": null,
            }],
        });
        fs::write(directory.path().join("devices.json"), old_state.to_string()).unwrap();

        let auth = AuthDatabase::load_or_create(directory.path(), "old", false).unwrap();

        {
            let state = auth.state.lock().await;
            let invitation = &state.invitations["old-invitation"];
            assert!(invitation.bound_device.is_none());
            assert_eq!(invitation.expires_at_unix, expires_at_unix);
        }
        // An unbound invitation still waits for the owner's approval.
        let device = StaticIdentity::generate().unwrap();
        let request = invitation_request("old-invitation", &device, "old-client");
        let attempt = tokio::spawn({
            let auth = Arc::clone(&auth);
            async move { auth.authorize(request).await }
        });
        let pending = auth.wait_for_pending(BOUND_CLAIM_DEADLINE).await.unwrap();
        assert_eq!(pending[0].device_fingerprint, device.fingerprint());
        auth.approve("old-invitation").await.unwrap();
        assert_eq!(attempt.await.unwrap().unwrap().device_id, device.fingerprint());
    }

    #[tokio::test]
    async fn a_binding_that_does_not_decode_drops_its_invitation() {
        let directory = tempfile::tempdir().unwrap();
        let state = serde_json::json!({
            "version": AUTH_STATE_VERSION,
            "invitations": [{
                "id": "damaged",
                "secret": encode_key(&[5; 32]),
                "expires_at_unix": unix_time().unwrap() + 120,
                "route_hints": [],
                "bound_device": "not-a-key",
            }],
        });
        fs::write(directory.path().join("devices.json"), state.to_string()).unwrap();

        let auth = AuthDatabase::load_or_create(directory.path(), "damaged", false).unwrap();

        assert!(auth.state.lock().await.invitations.is_empty());
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

    fn invitation_with(via_machine: Option<String>) -> EnrollmentInvitation {
        let daemon = StaticIdentity::generate().unwrap();
        EnrollmentInvitation {
            version: STATE_VERSION,
            id: "invite".into(),
            secret: encode_key(&[7; 32]),
            daemon_public_key: encode_key(&daemon.public_key()),
            daemon_fingerprint: public_key_fingerprint(&daemon.public_key()),
            daemon_name: "agent-remote".into(),
            expires_at_unix: unix_time().unwrap() + 600,
            route_hints: vec!["ws://127.0.0.1:7781/".into()],
            relay_access: vec![],
            approval_required: true,
            via_machine,
        }
    }

    const NODE_KEY: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";

    /// An invitation carries its machine's hub route, so a machine elsewhere can reach the
    /// loopback-only daemon it names; the field is additive and absent when unset.
    #[test]
    fn an_invitation_carries_its_machines_hub_route() {
        let invitation = invitation_with(Some(NODE_KEY.into()));
        let uri = invitation.to_uri().unwrap();
        let decoded = EnrollmentInvitation::from_uri(&uri).unwrap();
        assert_eq!(decoded.via_machine.as_deref(), Some(NODE_KEY));
        assert_eq!(decoded, invitation);
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(uri.trim_start_matches(ENROLLMENT_URI_PREFIX))
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&json).unwrap();
        assert_eq!(json.get("via_machine").and_then(|v| v.as_str()), Some(NODE_KEY));
        let plain = invitation_with(None).to_uri().unwrap();
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(plain.trim_start_matches(ENROLLMENT_URI_PREFIX))
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&json).unwrap();
        assert!(json.get("via_machine").is_none(), "{json}");
    }

    /// An invitation from before the field (no `via_machine` key) still decodes, with none.
    #[test]
    fn an_invitation_from_before_the_hub_route_still_decodes() {
        let invitation = invitation_with(None);
        let mut json = serde_json::to_value(&invitation).unwrap();
        json.as_object_mut().unwrap().remove("via_machine");
        let uri = format!(
            "{ENROLLMENT_URI_PREFIX}{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(serde_json::to_vec(&json).unwrap())
        );
        assert_eq!(EnrollmentInvitation::from_uri(&uri).unwrap().via_machine, None);
    }

    /// A hub route that is no node key is refused both ways, never dialed.
    #[test]
    fn an_invitation_hub_route_must_be_a_node_key() {
        assert!(is_hub_machine_key(NODE_KEY));
        assert!(!is_hub_machine_key("cmux16"));
        let invitation = invitation_with(Some("cmux16".into()));
        assert!(invitation.to_uri().is_err());
        let json = serde_json::to_vec(&invitation).unwrap();
        let uri = format!(
            "{ENROLLMENT_URI_PREFIX}{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
        );
        assert!(EnrollmentInvitation::from_uri(&uri).is_err());
    }

    /// A daemon enrolled through an invitation keeps its hub route for later connects.
    #[tokio::test]
    async fn a_known_daemon_keeps_its_hub_route() {
        let directory = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(directory.path()).unwrap();
        let daemon = StaticIdentity::generate().unwrap();
        let pinned = store
            .pin_daemon(
                "agent-remote".into(),
                daemon.public_key(),
                vec!["ws://127.0.0.1:7781/".into()],
            )
            .await
            .unwrap();
        assert_eq!(pinned.via_machine, None);
        let kept =
            store.remember_via_machine(&pinned.fingerprint, NODE_KEY).await.unwrap().unwrap();
        assert_eq!(kept.via_machine.as_deref(), Some(NODE_KEY));
        let reloaded = ClientIdentityStore::load_or_create(directory.path()).unwrap();
        let known = reloaded.known_daemons().await;
        assert_eq!(known.first().and_then(|d| d.via_machine.as_deref()), Some(NODE_KEY));
        assert!(store.remember_via_machine("nope", NODE_KEY).await.unwrap().is_none());
        assert!(store.remember_via_machine(&pinned.fingerprint, "cmux16").await.is_err());
    }
}
