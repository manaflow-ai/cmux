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
use tokio::sync::{Mutex, Notify, oneshot, watch};

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
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const ENROLLMENT_RETRY_GRACE: Duration = Duration::from_secs(60);
const MAX_INVITATION_RELAY_ROUTES: usize = 2;
const MAX_RELAY_SLOT_BYTES: usize = 256;
const MAX_RELAY_TICKET_BYTES: usize = 4 * 1024;
const MAX_RECORDED_CONNECTION_ATTEMPTS: usize = 4_096;
const ENROLLMENT_URI_PREFIX: &str = "cmux://enroll/";
const CLIENT_STATE_FILE: &str = "known-daemons.json";
pub const MAX_INVITATION_URI_BYTES: usize = ENROLLMENT_URI_PREFIX.len() + 16 * 1024;

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
        let path = state_dir.join(CLIENT_STATE_FILE);
        let lock_path = sibling_lock_path(&path).map_err(IdentityError::Io)?;
        let _path_lock = OwnerFileLock::acquire(&lock_path).map_err(IdentityError::Io)?;
        let (state, routes_changed) =
            load_client_state(&path)?.unwrap_or_else(|| (PersistedClientState::default(), false));
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
        let (_path_lock, mut candidate, _) = self.reload_client_state_locked(&mut state).await?;
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
        let (_path_lock, mut candidate, routes_changed) =
            self.reload_client_state_locked(&mut state).await?;
        let Some(existing) = candidate.daemons.get_mut(fingerprint) else {
            if routes_changed {
                self.commit_client_state_locked(&mut state, candidate)?;
            }
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
        let mut state = self.state.lock().await;
        let (_path_lock, candidate, routes_changed) =
            self.reload_client_state_locked(&mut state).await?;
        let key = candidate
            .daemons
            .get(fingerprint)
            .map(|daemon| decode_key(&daemon.public_key))
            .transpose()?;
        if routes_changed {
            self.commit_client_state_locked(&mut state, candidate)?;
        }
        Ok(key)
    }

    pub async fn forget_daemon(&self, fingerprint: &str) -> Result<bool, IdentityError> {
        let mut state = self.state.lock().await;
        let (_path_lock, mut candidate, routes_changed) =
            self.reload_client_state_locked(&mut state).await?;
        let removed = candidate.daemons.remove(fingerprint).is_some();
        if removed || routes_changed {
            self.commit_client_state_locked(&mut state, candidate)?;
        }
        Ok(removed)
    }

    async fn reload_client_state_locked(
        &self,
        state: &mut PersistedClientState,
    ) -> Result<(OwnerFileLock, PersistedClientState, bool), IdentityError> {
        let path = self.state_dir.join(CLIENT_STATE_FILE);
        let lock_path = sibling_lock_path(&path).map_err(IdentityError::Io)?;
        let path_lock = OwnerFileLock::acquire_async(lock_path).await.map_err(IdentityError::Io)?;
        let (disk_state, routes_changed) =
            load_client_state(&path)?.unwrap_or_else(|| (state.clone(), false));
        *state = disk_state.clone();
        Ok((path_lock, disk_state, routes_changed))
    }

    fn commit_client_state_locked(
        &self,
        state: &mut PersistedClientState,
        candidate: PersistedClientState,
    ) -> Result<(), IdentityError> {
        match self.persist_client_locked(&candidate) {
            Ok(()) => {
                *state = candidate;
                Ok(())
            }
            Err(error @ IdentityError::Committed(_)) => {
                *state = candidate;
                Err(error)
            }
            Err(error) => Err(error),
        }
    }

    fn persist_client_locked(&self, state: &PersistedClientState) -> Result<(), IdentityError> {
        atomic_json(&self.state_dir.join(CLIENT_STATE_FILE), state)
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
    #[cfg(test)]
    hooks: Arc<PersistenceTestHooks>,
}

struct PersistenceWorkerShared {
    path: PathBuf,
    state: StdMutex<PersistenceCoordinatorState>,
    changed: Condvar,
    #[cfg(test)]
    hooks: Arc<PersistenceTestHooks>,
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
        #[cfg(test)]
        let hooks = Arc::new(PersistenceTestHooks::default());
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
            #[cfg(test)]
            hooks: hooks.clone(),
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
        Ok(Self {
            shared,
            worker: StdMutex::new(Some(worker)),
            #[cfg(test)]
            hooks,
        })
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

    #[cfg(test)]
    fn durable_revision(&self) -> u64 {
        self.lock_state().durable_revision
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

            #[cfg(test)]
            let result = self
                .hooks
                .before_write(revision)
                .map_err(PersistenceFailure::Uncommitted)
                .and_then(|()| {
                    FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| {
                        fail.set(self.hooks.take_parent_sync_failure());
                    });
                    let result = atomic_json(&self.path, &snapshot)
                        .map_err(PersistenceFailure::from_identity_error);
                    FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(false));
                    self.hooks.after_write(result.is_ok());
                    result
                });
            #[cfg(not(test))]
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

#[cfg(test)]
#[derive(Default)]
struct PersistenceTestHooks {
    writes_started: std::sync::atomic::AtomicUsize,
    writes_succeeded: std::sync::atomic::AtomicUsize,
    fail_next: std::sync::atomic::AtomicUsize,
    fail_next_parent_sync: std::sync::atomic::AtomicUsize,
    panic_next: std::sync::atomic::AtomicUsize,
    started_revisions: StdMutex<Vec<u64>>,
    blocked: StdMutex<bool>,
    released: Condvar,
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
            .panic_next
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| remaining.checked_sub(1))
            .is_ok()
        {
            panic!("injected persistence worker panic for revision {revision}");
        }
        if self
            .fail_next
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| remaining.checked_sub(1))
            .is_ok()
        {
            return Err(format!("injected persistence failure for revision {revision}"));
        }
        if let Some(gate) = std::env::var_os("CMUX_TEST_AUTH_PERSISTENCE_GATE") {
            let gate = PathBuf::from(gate);
            while !gate.exists() {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        Ok(())
    }

    fn after_write(&self, succeeded: bool) {
        if succeeded {
            self.writes_succeeded.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }

    fn take_parent_sync_failure(&self) -> bool {
        use std::sync::atomic::Ordering;

        self.fail_next_parent_sync
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| remaining.checked_sub(1))
            .is_ok()
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

#[cfg(test)]
#[derive(Default)]
struct PendingWaitTestHooks {
    pause_after_empty: std::sync::atomic::AtomicBool,
    empty_checked: Notify,
    resume: Notify,
}

#[cfg(test)]
impl PendingWaitTestHooks {
    async fn pause_after_empty(&self) {
        use std::sync::atomic::Ordering;

        if self.pause_after_empty.swap(false, Ordering::SeqCst) {
            self.empty_checked.notify_one();
            self.resume.notified().await;
        }
    }
}

pub struct AuthDatabase {
    state_dir: PathBuf,
    daemon_name: String,
    identity: StaticIdentity,
    allow_carrier: bool,
    state: Arc<Mutex<AuthState>>,
    persistence: Arc<PersistenceCoordinator>,
    pending_changed: Notify,
    #[cfg(test)]
    pending_wait_hooks: PendingWaitTestHooks,
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
        Self::load(
            state_dir.into(),
            daemon_name.into(),
            allow_carrier,
            AuthStateLoadMode::CurrentOnly,
        )
    }

    /// Open current authorization state or explicitly migrate the legacy
    /// version after the caller has fenced every predecessor process.
    pub fn load_or_migrate_legacy(
        state_dir: impl Into<PathBuf>,
        daemon_name: impl Into<String>,
        allow_carrier: bool,
    ) -> Result<Arc<Self>, IdentityError> {
        Self::load(
            state_dir.into(),
            daemon_name.into(),
            allow_carrier,
            AuthStateLoadMode::MigrateLegacy,
        )
    }

    fn load(
        state_dir: PathBuf,
        daemon_name: String,
        allow_carrier: bool,
        load_mode: AuthStateLoadMode,
    ) -> Result<Arc<Self>, IdentityError> {
        secure_directory(&state_dir)?;
        let state_path = state_dir.join("devices.json");
        let lease_path = sibling_lock_path(&state_path).map_err(IdentityError::Io)?;
        let state_lease = OwnerFileLock::try_acquire(&lease_path).map_err(IdentityError::Io)?;
        // Persist the rollback fence while the authorization lease is held and
        // before creating identity.json. A crash cannot leave a directory that
        // a retry mistakes for unfenced legacy authorization state.
        let persisted = load_auth_state(&state_path, load_mode)?;
        let identity = load_or_create_identity(&state_dir.join("identity.json"))?;
        let (revocation_tx, _) = watch::channel(persisted.revocation_generation);
        let persistence =
            Arc::new(PersistenceCoordinator::new(state_path, persisted.revision, state_lease)?);
        Ok(Arc::new(Self {
            state_dir,
            daemon_name,
            identity,
            allow_carrier,
            state: Arc::new(Mutex::new(AuthState::from_persisted(persisted))),
            persistence,
            pending_changed: Notify::new(),
            #[cfg(test)]
            pending_wait_hooks: PendingWaitTestHooks::default(),
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

    /// Stop accepting authorization mutations, durably flush the final
    /// accepted revision, and join the persistence owner before process exit.
    pub async fn shutdown(&self) -> Result<(), IdentityError> {
        self.shutdown_with_cleanup(|_| Ok(())).await
    }

    /// Finalize authorization persistence while retaining its exclusive state
    /// lease through lifecycle cleanup. The cleanup observes the authoritative
    /// terminal persistence result before the lease is released.
    pub async fn shutdown_with_cleanup(
        &self,
        cleanup: impl FnOnce(&Result<(), IdentityError>) -> Result<(), IdentityError> + Send,
    ) -> Result<(), IdentityError> {
        let final_write = {
            let mut state = self.state.lock().await;
            if state.closing {
                None
            } else {
                state.closing = true;
                Some(self.persistence.submit(state.to_persisted()))
            }
        };
        if let Some(final_write) = final_write {
            // The coordinator retains the authoritative terminal result, so a
            // cancelled caller or worker failure remains observable after join.
            let _ = final_write.wait().await;
        }
        self.persistence.close_and_join_with_cleanup(cleanup)
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
        let invitation = EnrollmentInvitation {
            version: STATE_VERSION,
            id: id.clone(),
            secret: encode_key(&secret),
            daemon_public_key: encode_key(&self.identity.public_key()),
            daemon_fingerprint: self.identity.fingerprint(),
            daemon_name: self.daemon_name.clone(),
            expires_at_unix,
            route_hints,
            relay_access,
            approval_required: true,
        };
        invitation.to_uri()?;
        let mut state = self.state.lock().await;
        state.ensure_open()?;
        state.prune_invitations(now);
        state.invitations.insert(
            id,
            InvitationRecord {
                secret,
                expires_at_unix,
                route_hints: invitation.route_hints.clone(),
                claimed_by: None,
            },
        );
        let persistence = self.submit_mutation_locked(&mut state)?;
        drop(state);
        persistence.wait().await?;
        Ok(invitation)
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
        self.pending_snapshot().await.unwrap_or_default()
    }

    /// Return a snapshot only when at least one enrollment is pending.
    ///
    /// Waiting callers used to clone every pending request merely to check
    /// whether the map was empty. Keeping the emptiness check under the same
    /// lock as the snapshot avoids that O(P) allocation on every notification
    /// cycle while preserving the existing snapshot semantics.
    async fn pending_snapshot(&self) -> Option<Vec<PendingEnrollment>> {
        let state = self.state.lock().await;
        if state.pending.is_empty() {
            return None;
        }
        Some(state.pending.values().map(|pending| pending.request.clone()).collect())
    }

    pub async fn wait_for_pending(
        &self,
        timeout: Duration,
    ) -> Result<Vec<PendingEnrollment>, IdentityError> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let notified = self.pending_changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Some(pending) = self.pending_snapshot().await {
                return Ok(pending);
            }
            #[cfg(test)]
            self.pending_wait_hooks.pause_after_empty().await;
            if tokio::time::timeout_at(deadline, notified.as_mut()).await.is_err() {
                return self.pending_snapshot().await.ok_or(IdentityError::Timeout);
            }
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
        state.ensure_open()?;
        let pending = state
            .pending
            .remove(invitation_id)
            .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
        let invitation = state
            .invitations
            .get_mut(invitation_id)
            .ok_or_else(|| IdentityError::InvitationExpired(invitation_id.into()))?;
        let approval_deadline =
            pending.request.requested_at_unix.saturating_add(APPROVAL_TIMEOUT.as_secs());
        if approval_deadline <= now {
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
        match persistence.wait_result().await {
            Ok(()) => {
                drop(state);
                let _ = pending.decision.send(Ok(grant));
                Ok(record)
            }
            Err(PersistenceFailure::Committed(message)) => {
                drop(state);
                let _ = pending.decision.send(Ok(grant));
                Err(IdentityError::Committed(message))
            }
            Err(PersistenceFailure::Uncommitted(message)) => {
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
            state.ensure_open()?;
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
            let result = persistence.wait_result().await;
            let authorization = match &result {
                Ok(()) | Err(PersistenceFailure::Committed(_)) => Err("enrollment denied".into()),
                Err(error) => Err(error.message()),
            };
            let _ = decision.send(authorization);
            let _ = completed_tx.send(result);
        });
        completed_rx
            .await
            .unwrap_or_else(|_| {
                Err(PersistenceFailure::Uncommitted(
                    "identity denial persistence task stopped".into(),
                ))
            })
            .map_err(PersistenceFailure::into_identity_error)
    }

    pub async fn revoke(&self, device_id: &str) -> Result<(), IdentityError> {
        let now = unix_time()?;
        let (generation, persistence) = {
            let mut state = self.state.lock().await;
            state.ensure_open()?;
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
            state.ensure_open()?;
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
    pub(crate) fn test_fail_next_parent_syncs(&self, count: usize) {
        self.persistence
            .hooks
            .fail_next_parent_sync
            .store(count, std::sync::atomic::Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn test_panic_next_persistence_writes(&self, count: usize) {
        self.persistence.hooks.panic_next.store(count, std::sync::atomic::Ordering::SeqCst);
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
    fn test_pause_wait_for_pending_after_empty(&self) {
        self.pending_wait_hooks.pause_after_empty.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    #[cfg(test)]
    async fn test_wait_for_pending_empty_check(&self) {
        self.pending_wait_hooks.empty_checked.notified().await;
    }

    #[cfg(test)]
    fn test_resume_wait_for_pending(&self) {
        self.pending_wait_hooks.resume.notify_one();
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
        debug_assert!(!state.closing);
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
        let (secret, persistence) = {
            let mut state = self.state.lock().await;
            let persistence = if state.prune_invitations(now) {
                state.ensure_open().map_err(|error| CryptoError::Link(error.to_string()))?;
                Some(
                    self.submit_mutation_locked(&mut state)
                        .map_err(|error| CryptoError::Link(error.to_string()))?,
                )
            } else {
                None
            };
            let secret = state
                .invitations
                .get(id)
                .filter(|invitation| invitation.expires_at_unix > now)
                .map(|invitation| invitation.secret);
            (secret, persistence)
        };
        if let Some(persistence) = persistence {
            persistence.wait().await.map_err(|error| CryptoError::Link(error.to_string()))?;
        }
        Ok(secret)
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
                let pending_token = Arc::new(());
                {
                    let mut state = self.state.lock().await;
                    state.ensure_open().map_err(|error| error.to_string())?;
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
                            token: Arc::clone(&pending_token),
                        },
                    );
                }
                let mut cleanup =
                    PendingDecisionCleanup::new(&self.state, invitation_id.clone(), pending_token);
                self.pending_changed.notify_waiters();
                let result = match tokio::time::timeout(APPROVAL_TIMEOUT, decision_rx).await {
                    Ok(Ok(result)) => result,
                    Ok(Err(_)) => Err("enrollment approval channel closed".into()),
                    Err(_) => Err("enrollment approval timed out".into()),
                };
                cleanup.finish().await;
                result
            }
        }
    }
}

struct AuthState {
    revision: u64,
    revocation_generation: u64,
    closing: bool,
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
            closing: false,
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

    fn ensure_open(&self) -> Result<(), IdentityError> {
        if self.closing {
            return Err(IdentityError::Persistence("authorization state is shutting down".into()));
        }
        Ok(())
    }

    fn to_persisted(&self) -> PersistedState {
        PersistedState {
            version: AUTH_STATE_VERSION,
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

    fn prune_invitations(&mut self, now: u64) -> bool {
        let previous = self.invitations.len();
        self.invitations.retain(|id, invitation| {
            invitation.expires_at_unix > now || self.pending.contains_key(id)
        });
        self.invitations.len() != previous
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
    token: Arc<()>,
}

struct PendingDecisionCleanup {
    state: Weak<Mutex<AuthState>>,
    invitation_id: String,
    token: Arc<()>,
    armed: bool,
}

impl PendingDecisionCleanup {
    fn new(state: &Arc<Mutex<AuthState>>, invitation_id: String, token: Arc<()>) -> Self {
        Self { state: Arc::downgrade(state), invitation_id, token, armed: true }
    }

    async fn finish(&mut self) {
        if let Some(state) = self.state.upgrade() {
            let mut locked = state.lock().await;
            remove_pending_decision(&mut locked, &self.invitation_id, &self.token);
        }
        self.armed = false;
    }
}

impl Drop for PendingDecisionCleanup {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let Some(state) = self.state.upgrade() else {
            return;
        };
        if let Ok(mut locked) = state.try_lock() {
            remove_pending_decision(&mut locked, &self.invitation_id, &self.token);
            return;
        }
        let invitation_id = self.invitation_id.clone();
        let token = Arc::clone(&self.token);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let mut locked = state.lock().await;
                remove_pending_decision(&mut locked, &invitation_id, &token);
            });
            return;
        }

        let synchronous_fallback = Arc::clone(&state);
        let fallback_invitation_id = invitation_id.clone();
        let fallback_token = Arc::clone(&token);
        if std::thread::Builder::new()
            .name("cmux-pending-enrollment-cleanup".into())
            .spawn(move || {
                let mut locked = state.blocking_lock();
                remove_pending_decision(&mut locked, &invitation_id, &token);
            })
            .is_err()
        {
            let mut locked = synchronous_fallback.blocking_lock();
            remove_pending_decision(&mut locked, &fallback_invitation_id, &fallback_token);
        }
    }
}

fn remove_pending_decision(state: &mut AuthState, invitation_id: &str, token: &Arc<()>) {
    if state.pending.get(invitation_id).is_some_and(|pending| Arc::ptr_eq(&pending.token, token)) {
        state.pending.remove(invitation_id);
    }
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

#[cfg(test)]
fn load_state(path: &Path) -> Result<PersistedState, IdentityError> {
    load_auth_state(path, AuthStateLoadMode::CurrentOnly)
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

    #[test]
    fn auth_database_rejects_legacy_state_until_explicit_migration() {
        let temp = tempfile::tempdir().unwrap();
        atomic_json(
            &temp.path().join("devices.json"),
            &PersistedState { version: STATE_VERSION, ..PersistedState::default() },
        )
        .unwrap();

        let error = AuthDatabase::load_or_create(temp.path(), "daemon", false)
            .expect_err("legacy authorization state opened without explicit migration");

        assert!(error.to_string().contains("migration"), "{error}");
        assert_eq!(persisted_auth_state_version(temp.path()).unwrap(), Some(STATE_VERSION));
        assert!(
            !temp.path().join("identity.json").exists(),
            "rejected legacy state created a daemon identity"
        );
    }

    #[test]
    fn auth_database_explicit_migration_persists_rollback_fence_before_opening() {
        let temp = tempfile::tempdir().unwrap();
        atomic_json(
            &temp.path().join("devices.json"),
            &PersistedState { version: STATE_VERSION, revision: 7, ..PersistedState::default() },
        )
        .unwrap();

        let database = AuthDatabase::load_or_migrate_legacy(temp.path(), "daemon", false)
            .expect("explicit legacy migration failed");
        assert_eq!(persisted_auth_state_version(temp.path()).unwrap(), Some(AUTH_STATE_VERSION));
        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 8);
        drop(database);

        AuthDatabase::load_or_create(temp.path(), "daemon", false)
            .expect("migrated authorization state was not current");
    }

    #[test]
    fn auth_database_reconfirms_visible_fence_after_migration_directory_sync_failure() {
        let temp = tempfile::tempdir().unwrap();
        atomic_json(
            &temp.path().join("devices.json"),
            &PersistedState { version: STATE_VERSION, ..PersistedState::default() },
        )
        .unwrap();
        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(true));

        let migration = AuthDatabase::load_or_migrate_legacy(temp.path(), "daemon", false)
            .expect_err("injected migration durability failure was ignored");
        assert!(matches!(migration, IdentityError::Committed(_)), "{migration}");
        assert_eq!(persisted_auth_state_version(temp.path()).unwrap(), Some(AUTH_STATE_VERSION));
        assert!(!temp.path().join("identity.json").exists());

        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(true));
        AuthDatabase::load_or_create(temp.path(), "daemon", false)
            .expect_err("visible version-2 state was trusted without a directory sync");
        assert!(
            !temp.path().join("identity.json").exists(),
            "unconfirmed authorization state created a daemon identity"
        );
    }

    #[test]
    fn auth_database_explicit_migration_never_downgrades_unknown_state() {
        let temp = tempfile::tempdir().unwrap();
        atomic_json(
            &temp.path().join("devices.json"),
            &PersistedState { version: AUTH_STATE_VERSION + 1, ..PersistedState::default() },
        )
        .unwrap();

        let error = AuthDatabase::load_or_migrate_legacy(temp.path(), "daemon", false)
            .expect_err("unknown authorization state was downgraded");

        assert!(error.to_string().contains("unsupported"), "{error}");
        assert_eq!(
            persisted_auth_state_version(temp.path()).unwrap(),
            Some(AUTH_STATE_VERSION + 1)
        );
        assert!(!temp.path().join("identity.json").exists());
    }

    #[test]
    fn fresh_auth_state_persists_rollback_fence_before_identity_creation() {
        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing");
        assert_eq!(persisted_auth_state_version(&missing).unwrap(), None);
        assert!(!missing.exists(), "read-only version inspection created state");

        fs::create_dir(temp.path().join("identity.json")).unwrap();
        AuthDatabase::load_or_create(temp.path(), "daemon", false)
            .expect_err("identity creation unexpectedly accepted a directory");

        assert_eq!(
            persisted_auth_state_version(temp.path()).unwrap(),
            Some(AUTH_STATE_VERSION),
            "identity failure happened before the rollback fence was durable"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;

            assert_eq!(
                fs::metadata(temp.path().join("devices.json")).unwrap().permissions().mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn auth_database_exclusively_owns_its_state_directory() {
        let temp = tempfile::tempdir().unwrap();
        let first = AuthDatabase::load_or_create(temp.path(), "first", false).unwrap();

        let second = AuthDatabase::load_or_create(temp.path(), "second", false);
        assert!(
            matches!(
                second,
                Err(IdentityError::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock
            ),
            "a second live database opened the same authorization state"
        );

        drop(first);
        AuthDatabase::load_or_create(temp.path(), "successor", false)
            .expect("the state lease remained held after its database was dropped");
    }

    #[tokio::test]
    async fn auth_state_lease_outlives_a_database_with_an_in_flight_write() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "first", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        let mutation = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("persistence writer did not start");
        mutation.abort();
        assert!(mutation.await.unwrap_err().is_cancelled());
        let drop_thread = std::thread::spawn(move || drop(database));

        let successor = AuthDatabase::load_or_create(temp.path(), "successor", false);
        assert!(
            matches!(
                successor,
                Err(IdentityError::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock
            ),
            "the database released its state lease while a detached write was still running"
        );

        drop(blocked);
        drop_thread.join().unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                match AuthDatabase::load_or_create(temp.path(), "successor", false) {
                    Ok(successor) => return successor,
                    Err(IdentityError::Io(error))
                        if error.kind() == std::io::ErrorKind::WouldBlock =>
                    {
                        tokio::task::yield_now().await;
                    }
                    Err(error) => panic!("successor failed after persistence completed: {error}"),
                }
            }
        })
        .await
        .expect("the state lease remained held after persistence completed");
    }

    #[test]
    fn auth_state_lease_outlives_runtime_shutdown_during_a_blocking_write() {
        let temp = tempfile::tempdir().unwrap();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap();
        let hooks = runtime.block_on(async {
            let database = AuthDatabase::load_or_create(temp.path(), "first", false).unwrap();
            let hooks = database.persistence.hooks.clone();
            hooks.block();
            tokio::spawn({
                let database = database.clone();
                async move {
                    let _ = database.create_invitation(Duration::from_secs(60), Vec::new()).await;
                }
            });
            tokio::time::timeout(Duration::from_secs(1), hooks.wait_for_started(1))
                .await
                .expect("persistence writer did not start");
            drop(database);
            hooks
        });
        let blocked = PersistenceReleaseGuard(hooks);

        runtime.shutdown_timeout(Duration::from_millis(10));
        let successor = AuthDatabase::load_or_create(temp.path(), "successor", false);
        assert!(
            matches!(
                successor,
                Err(IdentityError::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock
            ),
            "runtime shutdown released the state lease while its blocking write was still running"
        );

        drop(blocked);
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        loop {
            match AuthDatabase::load_or_create(temp.path(), "successor", false) {
                Ok(_) => break,
                Err(IdentityError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "the state lease remained held after the blocking write completed"
                    );
                    std::thread::yield_now();
                }
                Err(error) => panic!("successor failed after persistence completed: {error}"),
            };
        }
    }

    #[test]
    fn auth_persistence_drains_queued_revisions_after_runtime_shutdown() {
        let temp = tempfile::tempdir().unwrap();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap();
        let (database, hooks) = runtime.block_on(async {
            let database = AuthDatabase::load_or_create(temp.path(), "first", false).unwrap();
            let hooks = database.persistence.hooks.clone();
            hooks.block();
            tokio::spawn({
                let database = database.clone();
                async move {
                    let _ = database.create_invitation(Duration::from_secs(60), Vec::new()).await;
                }
            });
            tokio::time::timeout(Duration::from_secs(1), hooks.wait_for_started(1))
                .await
                .expect("first persistence write did not start");
            tokio::spawn({
                let database = database.clone();
                async move {
                    let _ = database.create_invitation(Duration::from_secs(60), Vec::new()).await;
                }
            });
            tokio::time::timeout(Duration::from_secs(1), async {
                loop {
                    if database.state.lock().await.revision == 2 {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("second authorization revision was not accepted");
            (database, hooks)
        });
        let blocked = PersistenceReleaseGuard(hooks);

        runtime.shutdown_timeout(Duration::from_millis(10));
        let drop_thread = std::thread::spawn(move || drop(database));
        drop(blocked);
        drop_thread.join().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        loop {
            match AuthDatabase::load_or_create(temp.path(), "successor", false) {
                Ok(successor) => {
                    drop(successor);
                    break;
                }
                Err(IdentityError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "the state lease remained held after queued persistence completed"
                    );
                    std::thread::yield_now();
                }
                Err(error) => panic!("successor failed after persistence completed: {error}"),
            }
        }

        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 2);
        assert_eq!(persisted.invitations.len(), 2);
    }

    #[tokio::test]
    async fn auth_shutdown_drains_accepted_revisions_and_releases_the_state_lease() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "first", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        let first = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("first persistence write did not start");
        let second = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.revision == 2 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("second authorization revision was not accepted");

        let shutdown = tokio::spawn({
            let database = database.clone();
            async move { database.shutdown().await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.closing {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("authorization mutation admission did not close");
        let rejected =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap_err();
        assert!(
            matches!(rejected, IdentityError::Persistence(message) if message.contains("shutting down"))
        );

        drop(blocked);
        shutdown.await.unwrap().unwrap();
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        database.shutdown().await.unwrap();

        let successor = AuthDatabase::load_or_create(temp.path(), "successor", false)
            .expect("joined persistence worker retained the state lease");
        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 2);
        assert_eq!(persisted.invitations.len(), 2);
        drop(successor);
    }

    #[tokio::test]
    async fn cancelled_auth_shutdown_preserves_its_persistence_failure_for_later_callers() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        database.test_fail_next_persistence_writes(1);
        let mutation = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("persistence write did not start");
        mutation.abort();
        assert!(mutation.await.unwrap_err().is_cancelled());

        let shutdown = tokio::spawn({
            let database = database.clone();
            async move { database.shutdown().await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.closing {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("authorization mutation admission did not close");
        shutdown.abort();
        assert!(shutdown.await.unwrap_err().is_cancelled());

        drop(blocked);
        for _ in 0..2 {
            let error = database.shutdown().await.unwrap_err();
            assert!(
                matches!(error, IdentityError::Persistence(message) if message.contains("injected"))
            );
        }
    }

    #[tokio::test]
    async fn auth_shutdown_cleans_up_lifecycle_metadata_after_terminal_persistence_failure() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        database.test_fail_next_persistence_writes(1);
        let mutation = tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("persistence write did not start");
        mutation.abort();
        assert!(mutation.await.unwrap_err().is_cancelled());

        let cleanup_called = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let cleanup_retained_lease = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let cleanup_saw_failure = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let shutdown = tokio::spawn({
            let database = database.clone();
            let cleanup_called = cleanup_called.clone();
            let cleanup_retained_lease = cleanup_retained_lease.clone();
            let cleanup_saw_failure = cleanup_saw_failure.clone();
            let state_dir = temp.path().to_path_buf();
            async move {
                database
                    .shutdown_with_cleanup(move |finalization| {
                        cleanup_called.store(true, std::sync::atomic::Ordering::SeqCst);
                        cleanup_saw_failure
                            .store(finalization.is_err(), std::sync::atomic::Ordering::SeqCst);
                        let successor = AuthDatabase::load_or_create(state_dir, "successor", false);
                        cleanup_retained_lease.store(
                            matches!(
                                successor,
                                Err(IdentityError::Io(error))
                                    if error.kind() == std::io::ErrorKind::WouldBlock
                            ),
                            std::sync::atomic::Ordering::SeqCst,
                        );
                        Ok(())
                    })
                    .await
            }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.closing {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("authorization mutation admission did not close");

        drop(blocked);
        let error = shutdown.await.unwrap().unwrap_err();
        assert!(
            matches!(error, IdentityError::Persistence(message) if message.contains("injected"))
        );
        assert!(
            cleanup_called.load(std::sync::atomic::Ordering::SeqCst),
            "terminal persistence failure left lifecycle metadata behind"
        );
        assert!(
            cleanup_retained_lease.load(std::sync::atomic::Ordering::SeqCst),
            "lifecycle cleanup ran after releasing the authorization state lease"
        );
        assert!(
            cleanup_saw_failure.load(std::sync::atomic::Ordering::SeqCst),
            "lifecycle cleanup could not inspect the terminal persistence failure"
        );
        drop(
            AuthDatabase::load_or_create(temp.path(), "successor", false)
                .expect("shutdown retained its state lease after lifecycle cleanup"),
        );
    }

    #[tokio::test]
    async fn auth_shutdown_reports_a_persistence_worker_panic_without_hanging() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        database.test_fail_next_persistence_writes(1);
        database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap_err();
        database.test_panic_next_persistence_writes(1);

        let error = tokio::time::timeout(Duration::from_secs(1), database.shutdown())
            .await
            .expect("authorization shutdown hung after its persistence worker panicked")
            .unwrap_err()
            .to_string();

        assert!(error.contains("panicked"), "{error}");
    }

    #[test]
    fn auth_persistence_child_process() {
        let Some(state_dir) = std::env::var_os("CMUX_TEST_AUTH_PERSISTENCE_STATE") else {
            return;
        };
        let queued = PathBuf::from(std::env::var_os("CMUX_TEST_AUTH_PERSISTENCE_QUEUED").unwrap());
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap();
        let database = runtime.block_on(async {
            let database = AuthDatabase::load_or_create(state_dir, "child", false).unwrap();
            let hooks = database.persistence.hooks.clone();
            tokio::spawn({
                let database = database.clone();
                async move {
                    let _ = database.create_invitation(Duration::from_secs(60), Vec::new()).await;
                }
            });
            tokio::time::timeout(Duration::from_secs(1), hooks.wait_for_started(1))
                .await
                .expect("child persistence write did not start");
            tokio::spawn({
                let database = database.clone();
                async move {
                    let _ = database.create_invitation(Duration::from_secs(60), Vec::new()).await;
                }
            });
            tokio::time::timeout(Duration::from_secs(1), async {
                loop {
                    if database.state.lock().await.revision == 2 {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("child did not accept its second authorization revision");
            fs::write(queued, b"queued").unwrap();
            database
        });

        runtime.shutdown_timeout(Duration::from_millis(10));
        drop(database);
    }

    #[test]
    fn auth_persistence_process_exit_joins_queued_revisions() {
        use std::process::{Command, Stdio};

        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let gate = temp.path().join("release-write");
        let queued = temp.path().join("queued");
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "identity::tests::auth_persistence_child_process", "--nocapture"])
            .env("CMUX_TEST_AUTH_PERSISTENCE_STATE", &state_dir)
            .env("CMUX_TEST_AUTH_PERSISTENCE_GATE", &gate)
            .env("CMUX_TEST_AUTH_PERSISTENCE_QUEUED", &queued)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !queued.exists() {
            if let Some(status) = child.try_wait().unwrap() {
                panic!("persistence child exited before queueing its second revision: {status}");
            }
            assert!(
                std::time::Instant::now() < deadline,
                "persistence child did not queue its second revision"
            );
            std::thread::sleep(Duration::from_millis(1));
        }

        fs::write(&gate, b"release").unwrap();
        let status = child.wait().unwrap();
        assert!(status.success(), "persistence child failed: {status}");
        let persisted = load_state(&state_dir.join("devices.json")).unwrap();
        assert_eq!(persisted.revision, 2);
        assert_eq!(persisted.invitations.len(), 2);
    }

    #[cfg(unix)]
    #[test]
    fn identity_creation_waits_for_the_path_lock() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir().unwrap();
        let identity_path = directory.path().join("client-identity.json");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(directory.path().join("client-identity.json.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let creator = std::thread::spawn(move || {
            sender.send(load_or_create_identity(&identity_path)).unwrap();
        });
        let early = receiver.recv_timeout(Duration::from_millis(100)).ok();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        let completed_while_locked = early.is_some();
        let identity = early
            .unwrap_or_else(|| {
                receiver
                    .recv_timeout(Duration::from_secs(1))
                    .expect("identity creation stayed blocked after releasing its path lock")
            })
            .unwrap();
        creator.join().unwrap();

        assert!(!completed_while_locked, "identity creation ignored the cross-process path lock");
        assert_eq!(
            load_or_create_identity(&directory.path().join("client-identity.json"))
                .unwrap()
                .public_key(),
            identity.public_key()
        );
    }

    #[test]
    fn concurrent_identity_creation_converges_on_one_key() {
        const CREATORS: usize = 8;

        let directory = tempfile::tempdir().unwrap();
        let identity_path = Arc::new(directory.path().join("client-identity.json"));
        let start = Arc::new(std::sync::Barrier::new(CREATORS));
        let creators = (0..CREATORS)
            .map(|_| {
                let identity_path = identity_path.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    load_or_create_identity(&identity_path).unwrap().public_key()
                })
            })
            .collect::<Vec<_>>();
        let public_keys =
            creators.into_iter().map(|creator| creator.join().unwrap()).collect::<Vec<_>>();

        assert!(public_keys.iter().all(|public_key| *public_key == public_keys[0]));
    }

    #[cfg(unix)]
    #[test]
    fn auth_state_rejects_an_intermediate_symlink_without_creating_under_its_target() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let result = AuthDatabase::load_or_create(alias.join("missing"), "daemon", false);

        assert!(result.is_err(), "intermediate symlink was accepted");
        assert!(!target.join("missing").exists());
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
        assert!(
            store.daemon_key(&fingerprint).await.is_err(),
            "an unreadable authority store must fail closed"
        );
        fs::remove_dir(&state_path).unwrap();
        assert_eq!(store.daemon_key(&fingerprint).await.unwrap(), None);
    }

    #[tokio::test]
    async fn stale_client_store_cannot_overwrite_another_process_pin() {
        let temp = tempfile::tempdir().unwrap();
        let first = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let second = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let first_key = StaticIdentity::generate().unwrap().public_key();
        let second_key = StaticIdentity::generate().unwrap().public_key();
        let first_fingerprint = public_key_fingerprint(&first_key);
        let second_fingerprint = public_key_fingerprint(&second_key);

        first.pin_daemon("first".into(), first_key, Vec::new()).await.unwrap();
        second.pin_daemon("second".into(), second_key, Vec::new()).await.unwrap();

        let reloaded = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        assert_eq!(reloaded.daemon_key(&first_fingerprint).await.unwrap(), Some(first_key));
        assert_eq!(reloaded.daemon_key(&second_fingerprint).await.unwrap(), Some(second_key));
    }

    #[tokio::test]
    async fn stale_client_store_cannot_restore_a_forgotten_daemon() {
        let temp = tempfile::tempdir().unwrap();
        let seed = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let forgotten_key = StaticIdentity::generate().unwrap().public_key();
        let forgotten =
            seed.pin_daemon("forgotten".into(), forgotten_key, Vec::new()).await.unwrap();
        let remover = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let stale = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let retained_key = StaticIdentity::generate().unwrap().public_key();
        let retained_fingerprint = public_key_fingerprint(&retained_key);

        assert!(remover.forget_daemon(&forgotten.fingerprint).await.unwrap());
        stale.pin_daemon("retained".into(), retained_key, Vec::new()).await.unwrap();

        let reloaded = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        assert_eq!(reloaded.daemon_key(&forgotten.fingerprint).await.unwrap(), None);
        assert_eq!(reloaded.daemon_key(&retained_fingerprint).await.unwrap(), Some(retained_key));
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
        assert!(
            store.daemon_key(&known.fingerprint).await.is_err(),
            "an unreadable authority store must fail closed"
        );

        fs::remove_dir(&state_path).unwrap();
        assert_eq!(store.daemon_key(&known.fingerprint).await.unwrap(), Some(public_key));
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
    async fn published_known_daemon_state_remains_live_after_parent_sync_failure() {
        let temp = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let public_key = StaticIdentity::generate().unwrap().public_key();
        let fingerprint = public_key_fingerprint(&public_key);
        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(true));

        let error =
            store.pin_daemon("host".into(), public_key, Vec::new()).await.unwrap_err().to_string();

        FAIL_ATOMIC_JSON_PARENT_SYNC.with(|fail| fail.set(false));
        assert!(error.contains("committed"), "{error}");
        assert_eq!(store.daemon_key(&fingerprint).await.unwrap(), Some(public_key));
        drop(store);
        let reloaded = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        assert_eq!(reloaded.daemon_key(&fingerprint).await.unwrap(), Some(public_key));
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
    async fn pending_auth_persistence_keeps_only_the_newest_full_snapshot() {
        const MUTATIONS: usize = 32;

        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let blocked = PersistenceReleaseGuard::new(database.persistence.hooks.clone());
        let mut mutations = Vec::with_capacity(MUTATIONS);
        mutations.push(tokio::spawn({
            let database = database.clone();
            async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
        }));
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_persistence_writes(1))
            .await
            .expect("first persistence write did not start");
        for _ in 1..MUTATIONS {
            mutations.push(tokio::spawn({
                let database = database.clone();
                async move { database.create_invitation(Duration::from_secs(60), Vec::new()).await }
            }));
        }
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if database.state.lock().await.revision == MUTATIONS as u64 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("authorization mutations did not enter the persistence queue");

        {
            let persistence = database.persistence.lock_state();
            assert_eq!(
                persistence.pending.keys().copied().collect::<Vec<_>>(),
                [MUTATIONS as u64],
                "superseded full snapshots accumulated behind the blocked writer"
            );
        }
        drop(blocked);
        for mutation in mutations {
            mutation.await.unwrap().unwrap();
        }

        let persisted = load_state(&temp.path().join("devices.json")).unwrap();
        assert_eq!(persisted.revision, MUTATIONS as u64);
        assert_eq!(persisted.invitations.len(), MUTATIONS);
        assert_eq!(database.test_persistence_writes_started(), 2);
    }

    #[tokio::test]
    async fn older_snapshot_cannot_overwrite_newer_identity_state() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("devices.json");
        let lease_path = sibling_lock_path(&path).unwrap();
        let state_lease = OwnerFileLock::try_acquire(&lease_path).unwrap();
        let coordinator =
            Arc::new(PersistenceCoordinator::new(path.clone(), 0, state_lease).unwrap());
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
            version: AUTH_STATE_VERSION,
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
            version: AUTH_STATE_VERSION,
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

    #[tokio::test]
    async fn committed_approval_survives_parent_sync_failure_in_memory_and_after_reload() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let client = StaticIdentity::generate().unwrap();
        let fingerprint = public_key_fingerprint(&client.public_key());
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "phone".into(),
            session: SessionId([29; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
        };
        let authorization = tokio::spawn({
            let database = database.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        database.test_fail_next_parent_syncs(1);

        let error = database.approve(&invitation.id).await.unwrap_err().to_string();

        assert!(error.contains("committed"), "{error}");
        assert_eq!(authorization.await.unwrap().unwrap().device_id, fingerprint);
        assert!(database.device_is_active(&fingerprint).await);
        drop(database);
        let reloaded = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        assert!(reloaded.device_is_active(&fingerprint).await);
    }

    #[test]
    fn device_state_without_revision_loads_at_revision_zero() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("devices.json");
        fs::write(
            &path,
            serde_json::json!({
                "version": AUTH_STATE_VERSION,
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
    async fn independent_client_stores_merge_known_daemon_updates() {
        let temp = tempfile::tempdir().unwrap();
        let first = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let second = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let first_key = StaticIdentity::generate().unwrap().public_key();
        let second_key = StaticIdentity::generate().unwrap().public_key();

        first
            .pin_daemon("first".into(), first_key, vec!["wss://first.example".into()])
            .await
            .unwrap();
        second
            .pin_daemon("second".into(), second_key, vec!["wss://second.example".into()])
            .await
            .unwrap();

        let reloaded = ClientIdentityStore::load_or_create(temp.path()).unwrap();
        let daemons = reloaded.known_daemons().await;
        assert_eq!(daemons.len(), 2);
        assert!(daemons.iter().any(|daemon| daemon.name == "first"));
        assert!(daemons.iter().any(|daemon| daemon.name == "second"));
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
    async fn pending_enrollment_notification_cannot_be_lost_between_check_and_wait() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let client = StaticIdentity::generate().unwrap();
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "notification-race".into(),
            session: SessionId([31; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
        };

        database.test_pause_wait_for_pending_after_empty();
        let waiter = tokio::spawn({
            let database = Arc::clone(&database);
            async move { database.wait_for_pending(Duration::from_millis(250)).await }
        });
        tokio::time::timeout(Duration::from_secs(1), database.test_wait_for_pending_empty_check())
            .await
            .expect("pending waiter never completed its empty-state check");

        let pending_changed = database.pending_changed.notified();
        tokio::pin!(pending_changed);
        pending_changed.as_mut().enable();
        let authorization = tokio::spawn({
            let database = Arc::clone(&database);
            async move { database.authorize(request).await }
        });
        tokio::time::timeout(Duration::from_secs(1), pending_changed)
            .await
            .expect("authorization never published its pending enrollment");
        database.test_resume_wait_for_pending();

        let result = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("pending waiter did not finish")
            .unwrap();
        database.deny(&invitation.id).await.unwrap();
        assert_eq!(authorization.await.unwrap().unwrap_err(), "enrollment denied");

        let pending = result.expect("pending waiter lost the enrollment notification");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].invitation_id, invitation.id);
    }

    #[test]
    fn pending_cleanup_without_a_runtime_waits_off_thread_for_a_contended_lock() {
        let invitation_id = "contended-invitation".to_string();
        let token = Arc::new(());
        let (decision, _decision_rx) = oneshot::channel();
        let mut auth = AuthState::from_persisted(PersistedState::default());
        auth.pending.insert(
            invitation_id.clone(),
            PendingDecision {
                request: PendingEnrollment {
                    invitation_id: invitation_id.clone(),
                    device_name: "device".into(),
                    device_fingerprint: "fingerprint".into(),
                    requested_at_unix: 1,
                },
                device_public_key: [7; 32],
                decision,
                token: Arc::clone(&token),
            },
        );
        let state = Arc::new(Mutex::new(auth));
        let cleanup = PendingDecisionCleanup::new(&state, invitation_id.clone(), token);
        let (locked_tx, locked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let holder = std::thread::spawn({
            let state = Arc::clone(&state);
            move || {
                let _locked = state.blocking_lock();
                locked_tx.send(()).unwrap();
                release_rx.recv().unwrap();
            }
        });
        locked_rx.recv().unwrap();

        drop(cleanup);
        release_tx.send(()).unwrap();
        holder.join().unwrap();

        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        loop {
            if let Ok(locked) = state.try_lock()
                && !locked.pending.contains_key(&invitation_id)
            {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "pending enrollment cleanup never completed"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[tokio::test]
    async fn cancelled_authorization_releases_its_pending_invitation() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let client = StaticIdentity::generate().unwrap();
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "cancelled-client".into(),
            session: SessionId([32; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
        };

        let first = tokio::spawn({
            let database = Arc::clone(&database);
            let request = request.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        first.abort();
        assert!(first.await.unwrap_err().is_cancelled());

        let retry = tokio::spawn({
            let database = Arc::clone(&database);
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        database.deny(&invitation.id).await.unwrap();

        assert_eq!(retry.await.unwrap().unwrap_err(), "enrollment denied");
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
                        handshake_timeout: Duration::from_secs(5),
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

        drop(database);
        let reloaded = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        assert_eq!(reloaded.list_devices().await, vec![record]);
    }

    #[tokio::test]
    async fn canceled_enrollment_releases_its_invitation_for_retry() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: StaticIdentity::generate().unwrap().public_key(),
            device_name: "cancelled".into(),
            session: SessionId([7; 16]),
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
        first.abort();
        assert!(first.await.unwrap_err().is_cancelled());
        tokio::time::timeout(Duration::from_secs(1), async {
            while !database.pending_enrollments().await.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("cancelled enrollment remained pending");

        let retry = tokio::spawn({
            let database = database.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        retry.abort();
        assert!(retry.await.unwrap_err().is_cancelled());
    }

    #[tokio::test]
    async fn expired_invitation_secret_is_removed_from_persisted_state() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let persistence = {
            let mut state = database.state.lock().await;
            state.invitations.get_mut(&invitation.id).unwrap().expires_at_unix = 0;
            database.submit_mutation_locked(&mut state).unwrap()
        };
        persistence.wait().await.unwrap();

        assert!(database.invitation_secret(&invitation.id).await.unwrap().is_none());
        let persisted = fs::read_to_string(temp.path().join("devices.json")).unwrap();
        assert!(!persisted.contains(&invitation.id));
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
    async fn pending_claim_keeps_its_approval_window_after_invitation_expiry() {
        let temp = tempfile::tempdir().unwrap();
        let database = AuthDatabase::load_or_create(temp.path(), "daemon", false).unwrap();
        let invitation =
            database.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
        let client = StaticIdentity::generate().unwrap();
        let request = AuthRequest {
            mode: AuthKind::Invitation,
            invitation_id: Some(invitation.id.clone()),
            device_public_key: client.public_key(),
            device_name: "phone".into(),
            session: SessionId([31; 16]),
            lane: Lane::Control,
            lanes: vec![Lane::Control],
            generation: 0,
            inbound: InboundAuthEvidence::Network(NetworkPeer::Tls),
        };
        let authorization = tokio::spawn({
            let database = database.clone();
            async move { database.authorize(request).await }
        });
        database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
        {
            let mut state = database.state.lock().await;
            state.invitations.get_mut(&invitation.id).unwrap().expires_at_unix =
                unix_time().unwrap();
        }

        let record = database.approve(&invitation.id).await.unwrap();

        assert_eq!(authorization.await.unwrap().unwrap().device_id, record.id);
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
