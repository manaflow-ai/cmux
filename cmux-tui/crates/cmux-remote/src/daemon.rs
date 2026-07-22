use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::io;
use std::net::SocketAddr;
#[cfg(unix)]
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
#[cfg(unix)]
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::connect_info::{ConnectInfo, Connected};
use axum::extract::{State, WebSocketUpgrade};
use axum::response::Response;
use axum::routing::get;
use axum::serve::{IncomingStream, Listener};
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, SessionId};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::{Mutex, Notify, OwnedSemaphorePermit, RwLock, Semaphore, mpsc, oneshot, watch};

use crate::connection::{ConnectionError, send_link_ready};
use crate::crypto::{
    AcceptedSecureLink, AuthKind, CryptoError, authorize_secure_link, verify_secure_link,
};
use crate::identity::AuthDatabase;
use crate::link::{FrameLink, LaneMuxLink, LinkError, LinkRoute};
use crate::provider::AxumWebSocketLink;
use crate::session::{ReceivedFrame, ReliableSession, SessionError, SessionLimits};

const PENDING_LINK_TTL: Duration = Duration::from_secs(30);
const MAX_PENDING_LINK_GROUPS: usize = 256;
const MAX_CLIENT_CONNECTIONS: usize = 64;
const MAX_CONCURRENT_HANDSHAKES: usize = 256;
const MAX_PENDING_APPROVALS: usize = 64;
const PREAUTH_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const AUTHORIZATION_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_DIRECT_HTTP_CONNECTIONS: usize = 512;
const DIRECT_HTTP_UPGRADE_TIMEOUT: Duration = Duration::from_secs(10);
const TERMINAL_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);
pub const DEFAULT_RESUME_LEASE: Duration = Duration::from_secs(2 * 60);
pub const MAX_RESUME_LEASE: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Debug, Clone, Copy)]
pub struct DaemonSessionPolicy {
    /// How long a disconnected logical session retains replay state while it
    /// waits for an authenticated reconnect. This is always finite so crashed
    /// clients cannot accumulate for the daemon's entire lifetime.
    pub resume_lease: Duration,
}

impl Default for DaemonSessionPolicy {
    fn default() -> Self {
        Self { resume_lease: DEFAULT_RESUME_LEASE }
    }
}

impl DaemonSessionPolicy {
    fn validate(self) -> Result<Self, DaemonError> {
        if self.resume_lease.is_zero() || self.resume_lease > MAX_RESUME_LEASE {
            return Err(DaemonError::Protocol(format!(
                "resume lease must be greater than zero and at most {}s",
                MAX_RESUME_LEASE.as_secs()
            )));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ClientKey {
    device_id: String,
    session: SessionId,
}

pub struct ServerConnection {
    pub device_id: String,
    pub session_id: SessionId,
    key: ClientKey,
    owner: Weak<RemoteDaemon>,
    self_weak: Weak<ServerConnection>,
    session: RwLock<ReliableSession>,
    generation: watch::Sender<u64>,
    changed: Notify,
    lifecycle: Mutex<ServerLifecycle>,
    lane_sends: [Mutex<()>; 4],
    closed: AtomicBool,
    close_state: watch::Sender<ServerCloseState>,
}

#[derive(Clone, Debug)]
enum ServerCloseState {
    Pending,
    Complete,
    Failed(ServerCloseFailure),
}

#[derive(Clone, Debug)]
enum ServerCloseFailure {
    Protocol(Arc<str>),
    Other(Arc<str>),
}

impl ServerCloseFailure {
    fn from_error(error: &DaemonError) -> Self {
        match error {
            DaemonError::Protocol(message) => Self::Protocol(message.clone().into()),
            _ => Self::Other(error.to_string().into()),
        }
    }

    fn to_error(&self) -> DaemonError {
        match self {
            Self::Protocol(message) => DaemonError::Protocol(message.to_string()),
            Self::Other(message) => DaemonError::Protocol(format!(
                "previous server connection shutdown failed: {message}"
            )),
        }
    }
}

struct ServerCloseCompletionGuard {
    state: watch::Sender<ServerCloseState>,
    published: bool,
}

impl ServerCloseCompletionGuard {
    fn new(state: watch::Sender<ServerCloseState>) -> Self {
        Self { state, published: false }
    }

    fn publish(mut self, state: ServerCloseState) {
        self.state.send_replace(state);
        self.published = true;
    }
}

impl Drop for ServerCloseCompletionGuard {
    fn drop(&mut self) {
        if !self.published {
            self.state.send_replace(ServerCloseState::Failed(ServerCloseFailure::Other(
                "server connection shutdown task stopped".into(),
            )));
        }
    }
}

#[derive(Debug, Default)]
struct ServerLifecycle {
    disconnected_generation: Option<u64>,
    resume_deadline: Option<Instant>,
}

enum ConnectionControlAction {
    Deliver,
    Continue,
    Close,
}

impl fmt::Debug for ServerConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ServerConnection")
            .field("device_id", &self.device_id)
            .field("session_id", &self.session_id)
            .field("closed", &self.closed.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

impl ServerConnection {
    fn new(owner: &Arc<RemoteDaemon>, key: ClientKey, session: ReliableSession) -> Arc<Self> {
        let device_id = key.device_id.clone();
        let session_id = key.session;
        let owner = Arc::downgrade(owner);
        let (generation, _) = watch::channel(session.generation());
        let (close_state, _) = watch::channel(ServerCloseState::Pending);
        Arc::new_cyclic(move |self_weak| Self {
            device_id,
            session_id,
            key,
            owner,
            self_weak: self_weak.clone(),
            session: RwLock::new(session),
            generation,
            changed: Notify::new(),
            lifecycle: Mutex::new(ServerLifecycle::default()),
            lane_sends: std::array::from_fn(|_| Mutex::new(())),
            closed: AtomicBool::new(false),
            close_state,
        })
    }

    fn current_generation(&self) -> u64 {
        *self.generation.borrow()
    }

    pub async fn send(
        &self,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, DaemonError> {
        self.send_in_generation(None, lane, stream, payload, flags).await
    }

    pub(crate) async fn send_in_generation(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, DaemonError> {
        let _lane_send = self.lane_sends[lane as usize].lock().await;
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(DaemonError::Closed);
            }
            let session = self.session.read().await.clone();
            let generation = session.generation();
            if let Some(expected) = expected_generation
                && expected != generation
            {
                return Err(DaemonError::Generation { expected, actual: generation });
            }
            let sequence = session.next_outbound_sequence(lane);
            match session.send(lane, stream, payload.clone(), flags).await {
                Ok(sequence) => return Ok(sequence),
                Err(SessionError::StaleGeneration { .. }) => {
                    let Some(actual) = self.wait_for_replacement(generation).await else {
                        return Err(DaemonError::Closed);
                    };
                    if let Some(expected) = expected_generation {
                        return Err(DaemonError::Generation { expected, actual });
                    }
                    if !lane.replays_across_generations() {
                        return Err(DaemonError::Generation { expected: generation, actual });
                    }
                }
                Err(error) if recoverable_server_session_error(&error) => {
                    self.note_transport_loss(generation).await;
                    if !lane.replays_across_generations() {
                        return Err(error.into());
                    }
                    let Some(actual) = self.wait_for_replacement(generation).await else {
                        return Err(DaemonError::Closed);
                    };
                    if let Some(expected) = expected_generation {
                        return Err(DaemonError::Generation { expected, actual });
                    }
                    // The failed send retained this reliable frame. Reconnect
                    // replayed it with the original application sequence.
                    return Ok(sequence);
                }
                Err(error) => return Err(error.into()),
            }
        }
    }

    pub async fn receive(&self) -> Result<Option<ReceivedFrame>, DaemonError> {
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Ok(None);
            }
            let session = self.session.read().await.clone();
            let generation = session.generation();
            match session.receive().await {
                Ok(Some(frame)) => match self.handle_connection_control(&frame).await? {
                    ConnectionControlAction::Deliver => return Ok(Some(frame)),
                    ConnectionControlAction::Continue => continue,
                    ConnectionControlAction::Close => return Ok(None),
                },
                Ok(None) => {
                    self.note_transport_loss(generation).await;
                    if self.wait_for_replacement(generation).await.is_none() {
                        return Ok(None);
                    }
                }
                Err(SessionError::StaleGeneration { .. }) => continue,
                Err(error) if recoverable_server_session_error(&error) => {
                    self.note_transport_loss(generation).await;
                    if self.wait_for_replacement(generation).await.is_none() {
                        return Ok(None);
                    }
                }
                Err(error) => {
                    let _ = self.close().await;
                    return Err(error.into());
                }
            }
        }
    }

    async fn handle_connection_control(
        &self,
        frame: &ReceivedFrame,
    ) -> Result<ConnectionControlAction, DaemonError> {
        if frame.lane != Lane::Control || frame.stream != 0 {
            return Ok(ConnectionControlAction::Deliver);
        }
        if frame.flags.contains(FrameFlags::SESSION_CLOSE) {
            // Logical closure and registry removal happen before the best-effort
            // carrier shutdown. A peer that closes immediately after this frame
            // must not turn an authenticated close into a service error.
            let _ = self.close().await;
            return Ok(ConnectionControlAction::Close);
        }
        if frame.flags.contains(FrameFlags::HEARTBEAT_RESPONSE) {
            return Ok(ConnectionControlAction::Continue);
        }
        if frame.flags.contains(FrameFlags::HEARTBEAT_REQUEST) {
            self.send(Lane::Control, 0, Bytes::new(), FrameFlags::HEARTBEAT_RESPONSE).await?;
            return Ok(ConnectionControlAction::Continue);
        }
        // Unknown control-stream-zero messages remain visible to services.
        Ok(ConnectionControlAction::Deliver)
    }

    async fn reconnect_physical(
        &self,
        expected_generation: u64,
        generation: u64,
        link: Arc<dyn FrameLink>,
        peer_resume: &BTreeMap<Lane, u64>,
    ) -> Result<(), DaemonError> {
        // This local lifecycle lock may span replay writes, but the daemon's
        // global registry lock never does. Holding the session write guard
        // makes the successful replay commit and wrapper replacement one
        // cancellation-safe operation.
        let mut lifecycle = self.lifecycle.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(DaemonError::Closed);
        }
        let mut current = self.session.write().await;
        if current.generation() != expected_generation {
            return Err(DaemonError::Generation {
                expected: expected_generation,
                actual: current.generation(),
            });
        }
        if lifecycle.disconnected_generation.is_none() {
            let owner = self.owner.upgrade().ok_or(DaemonError::Closed)?;
            let connection = self.self_weak.upgrade().ok_or(DaemonError::Closed)?;
            let deadline = Instant::now() + owner.policy.resume_lease;
            lifecycle.disconnected_generation = Some(expected_generation);
            lifecycle.resume_deadline = Some(deadline);
            owner.schedule_resume_expiry(connection, expected_generation, deadline);
        }
        let reconnecting = current.clone();
        let deadline =
            lifecycle.resume_deadline.expect("a reconnecting generation always has a deadline");
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(DaemonError::Closed);
        }
        let reconnect = reconnecting.reconnect_to(link, peer_resume, generation);
        let next =
            tokio::time::timeout(remaining, reconnect).await.map_err(|_| DaemonError::Closed)??;
        let generation = next.generation();
        let previous = std::mem::replace(&mut *current, next);
        lifecycle.disconnected_generation = None;
        lifecycle.resume_deadline = None;
        self.generation.send_replace(generation);
        self.changed.notify_waiters();
        drop(current);
        drop(lifecycle);

        // A receiver may still own a clone of the old session while blocked
        // inside its transport. Close that physical link only after the new
        // session and generation are fully published. The detached bounded
        // cleanup keeps cancellation from stranding the old carrier and never
        // delays or closes the replacement.
        tokio::spawn(async move {
            let _ = tokio::time::timeout(TERMINAL_CLOSE_TIMEOUT, previous.close()).await;
        });
        Ok(())
    }

    async fn note_transport_loss(&self, generation: u64) {
        let Some(owner) = self.owner.upgrade() else { return };
        let Some(connection) = self.self_weak.upgrade() else { return };
        let deadline = Instant::now() + owner.policy.resume_lease;
        let should_schedule = {
            let mut lifecycle = self.lifecycle.lock().await;
            if self.closed.load(Ordering::Acquire)
                || self.current_generation() != generation
                || lifecycle.disconnected_generation == Some(generation)
            {
                false
            } else {
                lifecycle.disconnected_generation = Some(generation);
                lifecycle.resume_deadline = Some(deadline);
                true
            }
        };
        if should_schedule {
            owner.schedule_resume_expiry(connection, generation, deadline);
        }
    }

    async fn wait_for_replacement(&self, generation: u64) -> Option<u64> {
        loop {
            let changed = self.changed.notified();
            if self.closed.load(Ordering::Acquire) {
                return None;
            }
            let actual = self.current_generation();
            if actual != generation {
                return Some(actual);
            }
            changed.await;
        }
    }

    async fn mark_closed(&self, disconnected_generation: Option<u64>) -> bool {
        let mut lifecycle = self.lifecycle.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        if let Some(expected) = disconnected_generation
            && (lifecycle.disconnected_generation != Some(expected)
                || self.current_generation() != expected)
        {
            return false;
        }
        self.closed.store(true, Ordering::Release);
        lifecycle.disconnected_generation = None;
        lifecycle.resume_deadline = None;
        self.changed.notify_waiters();
        true
    }

    async fn close_transport(&self) -> Result<(), DaemonError> {
        let session = self.session.read().await.clone();
        tokio::time::timeout(TERMINAL_CLOSE_TIMEOUT, session.close()).await.map_err(|_| {
            DaemonError::Protocol("timed out closing remote session transport".into())
        })??;
        Ok(())
    }

    pub fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    pub async fn close(&self) -> Result<(), DaemonError> {
        self.close_if_disconnected_generation(None).await.map(|_| ())
    }

    async fn close_if_disconnected_generation(
        &self,
        disconnected_generation: Option<u64>,
    ) -> Result<bool, DaemonError> {
        if !self.mark_closed(disconnected_generation).await {
            if self.closed.load(Ordering::Acquire) {
                wait_for_server_close(self.close_state.subscribe()).await?;
            }
            return Ok(false);
        }
        let Some(connection) = self.self_weak.upgrade() else {
            let error = DaemonError::Closed;
            self.close_state
                .send_replace(ServerCloseState::Failed(ServerCloseFailure::from_error(&error)));
            return Err(error);
        };
        let owner = self.owner.upgrade();
        let key = self.key.clone();
        let close_complete = ServerCloseCompletionGuard::new(self.close_state.clone());
        let (result_tx, result_rx) = oneshot::channel();
        tokio::spawn(async move {
            let close_complete = close_complete;
            let result = async {
                if let Some(owner) = owner {
                    owner.remove_connection_if(&key, &connection).await;
                }
                connection.close_transport().await
            }
            .await;
            let outcome = match &result {
                Ok(()) => ServerCloseState::Complete,
                Err(error) => ServerCloseState::Failed(ServerCloseFailure::from_error(error)),
            };
            close_complete.publish(outcome);
            let _ = result_tx.send(result);
        });
        match result_rx.await {
            Ok(result) => result?,
            Err(_) => wait_for_server_close(self.close_state.subscribe()).await?,
        }
        Ok(true)
    }
}

async fn wait_for_server_close(
    mut state: watch::Receiver<ServerCloseState>,
) -> Result<(), DaemonError> {
    loop {
        match state.borrow().clone() {
            ServerCloseState::Pending => {}
            ServerCloseState::Complete => return Ok(()),
            ServerCloseState::Failed(failure) => return Err(failure.to_error()),
        }
        state.changed().await.map_err(|_| {
            DaemonError::Protocol("server connection shutdown state stopped".into())
        })?;
    }
}

fn recoverable_server_session_error(error: &SessionError) -> bool {
    matches!(
        error,
        SessionError::Link(LinkError::Closed | LinkError::Transport(_))
            | SessionError::LinkMessage(_)
            | SessionError::SchedulerClosed
    )
}

pub struct RemoteDaemon {
    auth: Arc<AuthDatabase>,
    limits: SessionLimits,
    policy: DaemonSessionPolicy,
    state: Mutex<DaemonState>,
    accepted_tx: mpsc::Sender<Arc<ServerConnection>>,
    handshakes: Semaphore,
    approvals: Semaphore,
}

struct DaemonState {
    clients: HashMap<ClientKey, Arc<ServerConnection>>,
    pending: HashMap<(ClientKey, u64), PendingLinks>,
    registration_locks: HashMap<ClientKey, Weak<Mutex<()>>>,
}

struct PendingLinks {
    created_at: Instant,
    routes: Vec<LinkRoute>,
    assigned: BTreeSet<Lane>,
    client_resume: BTreeMap<Lane, u64>,
    grant_generation: u64,
}

impl RemoteDaemon {
    pub fn new(
        auth: Arc<AuthDatabase>,
        limits: SessionLimits,
    ) -> (Arc<Self>, mpsc::Receiver<Arc<ServerConnection>>) {
        Self::with_policy(auth, limits, DaemonSessionPolicy::default())
            .expect("the default daemon session policy is valid")
    }

    pub fn with_policy(
        auth: Arc<AuthDatabase>,
        limits: SessionLimits,
        policy: DaemonSessionPolicy,
    ) -> Result<(Arc<Self>, mpsc::Receiver<Arc<ServerConnection>>), DaemonError> {
        let policy = policy.validate()?;
        let (accepted_tx, accepted_rx) = mpsc::channel(64);
        let daemon = Arc::new(Self {
            auth,
            limits,
            policy,
            state: Mutex::new(DaemonState {
                clients: HashMap::new(),
                pending: HashMap::new(),
                registration_locks: HashMap::new(),
            }),
            accepted_tx,
            handshakes: Semaphore::new(MAX_CONCURRENT_HANDSHAKES),
            approvals: Semaphore::new(MAX_PENDING_APPROVALS),
        });
        daemon.clone().spawn_revocation_monitor();
        Ok((daemon, accepted_rx))
    }

    pub fn auth(&self) -> &Arc<AuthDatabase> {
        &self.auth
    }

    pub async fn accept(self: &Arc<Self>, raw: Box<dyn FrameLink>) -> Result<(), DaemonError> {
        self.accept_with_trust(raw, false).await
    }

    pub(crate) async fn accept_trusted_carrier(
        self: &Arc<Self>,
        raw: Box<dyn FrameLink>,
    ) -> Result<(), DaemonError> {
        self.accept_with_trust(raw, true).await
    }

    async fn accept_with_trust(
        self: &Arc<Self>,
        raw: Box<dyn FrameLink>,
        carrier_trusted: bool,
    ) -> Result<(), DaemonError> {
        let permit = self.handshakes.try_acquire().map_err(|_| DaemonError::HandshakeBusy)?;
        let verified = tokio::time::timeout(
            PREAUTH_HANDSHAKE_TIMEOUT,
            verify_secure_link(raw, &self.auth.identity(), &*self.auth, carrier_trusted),
        )
        .await
        .map_err(|_| DaemonError::HandshakeTimeout)??;
        drop(permit);
        let accepted = if verified.auth_kind() == AuthKind::Invitation {
            let approval = self.approvals.try_acquire().map_err(|_| DaemonError::ApprovalBusy)?;
            // AuthDatabase owns the five-minute approval deadline and its
            // cancellation cleanup. An outer timeout would cancel that cleanup
            // and leave a stale pending invitation.
            let accepted = authorize_secure_link(verified, &*self.auth).await?;
            drop(approval);
            accepted
        } else {
            tokio::time::timeout(
                AUTHORIZATION_TIMEOUT,
                authorize_secure_link(verified, &*self.auth),
            )
            .await
            .map_err(|_| DaemonError::HandshakeTimeout)??
        };
        self.register(accepted).await
    }

    async fn register(self: &Arc<Self>, accepted: AcceptedSecureLink) -> Result<(), DaemonError> {
        let key =
            ClientKey { device_id: accepted.grant.device_id.clone(), session: accepted.session };
        let registration = self.registration_lock(&key).await;
        let result = {
            let _registration = registration.lock().await;
            self.register_for_key(key.clone(), accepted).await
        };
        self.release_registration_lock(&key, &registration).await;
        result
    }

    async fn register_for_key(
        self: &Arc<Self>,
        key: ClientKey,
        accepted: AcceptedSecureLink,
    ) -> Result<(), DaemonError> {
        if !self.auth.grant_is_current(&accepted.grant).await {
            let _ = accepted.link.close().await;
            return Err(DaemonError::Crypto(CryptoError::Unauthorized(
                "device authorization changed during connection setup".into(),
            )));
        }
        let now = Instant::now();
        let existing = {
            let mut state = self.state.lock().await;
            state
                .pending
                .retain(|_, pending| now.duration_since(pending.created_at) < PENDING_LINK_TTL);
            state.clients.get(&key).cloned()
        };
        let (base_generation, daemon_resume) = match &existing {
            Some(connection) => {
                if connection.closed.load(Ordering::Acquire) {
                    return Err(DaemonError::Closed);
                }
                let current = connection.session.read().await;
                let expected =
                    current.generation().checked_add(1).ok_or(DaemonError::GenerationExhausted)?;
                if accepted.generation < expected {
                    return Err(DaemonError::Generation { expected, actual: accepted.generation });
                }
                (Some(current.generation()), current.resume_cursors())
            }
            None => {
                if accepted.generation != 0 {
                    return Err(DaemonError::Generation {
                        expected: 0,
                        actual: accepted.generation,
                    });
                }
                (None, Lane::ALL.into_iter().map(|lane| (lane, 0)).collect())
            }
        };
        send_link_ready(&accepted.link, accepted.session, accepted.generation, daemon_resume)
            .await?;

        let pending_key = (key.clone(), accepted.generation);
        let mut state = self.state.lock().await;
        let registry_matches = match (&existing, state.clients.get(&key)) {
            (Some(expected), Some(actual)) => {
                Arc::ptr_eq(expected, actual)
                    && base_generation == Some(actual.current_generation())
                    && !actual.closed.load(Ordering::Acquire)
            }
            (None, None) => true,
            _ => false,
        };
        if !registry_matches {
            drop(state);
            let _ = accepted.link.close().await;
            return Err(DaemonError::Closed);
        }
        if !state.pending.contains_key(&pending_key)
            && state.pending.len() >= MAX_PENDING_LINK_GROUPS
        {
            drop(state);
            let _ = accepted.link.close().await;
            return Err(DaemonError::Protocol("too many incomplete client links".into()));
        }
        if let Some(pending) = state.pending.get(&pending_key) {
            let duplicate_lane =
                accepted.lanes.iter().copied().find(|lane| pending.assigned.contains(lane));
            let metadata_mismatch = pending.client_resume != accepted.resume
                || pending.grant_generation != accepted.grant.revocation_generation;
            if metadata_mismatch || duplicate_lane.is_some() {
                let stale = state.pending.remove(&pending_key);
                drop(state);
                let _ = accepted.link.close().await;
                close_pending_links(stale).await;
                if let Some(lane) = duplicate_lane {
                    return Err(DaemonError::Protocol(format!(
                        "lane {lane} was attached more than once"
                    )));
                }
                return Err(DaemonError::Protocol(
                    "client authentication or resume cursors differ across physical links".into(),
                ));
            }
        }
        let pending = state.pending.entry(pending_key.clone()).or_insert_with(|| PendingLinks {
            created_at: now,
            routes: Vec::new(),
            assigned: BTreeSet::new(),
            client_resume: accepted.resume.clone(),
            grant_generation: accepted.grant.revocation_generation,
        });
        for lane in &accepted.lanes {
            debug_assert!(pending.assigned.insert(*lane));
        }
        pending.routes.push(LinkRoute { lanes: accepted.lanes, link: Arc::new(accepted.link) });
        if pending.assigned.len() != Lane::ALL.len() {
            return Ok(());
        }
        if pending.assigned.iter().copied().ne(Lane::ALL) {
            return Err(DaemonError::Protocol("physical links did not cover every lane".into()));
        }
        let pending = state.pending.remove(&pending_key).expect("pending entry exists");
        drop(state);
        let mux = Arc::new(LaneMuxLink::new(
            format!("daemon:{}:{:?}", key.device_id, key.session),
            pending.routes,
        )?);

        if !self.auth.grant_is_current(&accepted.grant).await {
            let _ = mux.close().await;
            return Err(DaemonError::Crypto(CryptoError::Unauthorized(
                "device authorization changed during connection setup".into(),
            )));
        }

        let (connection, is_new) = if let Some(connection) = existing {
            let expected_generation = base_generation.expect("an existing client has a generation");
            if let Err(error) = self
                .reconnect_registered_client(
                    &key,
                    &connection,
                    expected_generation,
                    accepted.generation,
                    mux.clone(),
                    &pending.client_resume,
                )
                .await
            {
                let _ = mux.close().await;
                if matches!(error, DaemonError::Closed) {
                    let _ = connection.close().await;
                }
                return Err(error);
            }
            (connection, false)
        } else {
            let reliable = ReliableSession::new(key.session, mux, self.limits);
            let connection = ServerConnection::new(self, key.clone(), reliable);
            let mut state = self.state.lock().await;
            if state.clients.contains_key(&key) {
                drop(state);
                let _ = connection.close().await;
                return Err(DaemonError::Protocol(
                    "client session was registered concurrently".into(),
                ));
            }
            if state.clients.len() >= MAX_CLIENT_CONNECTIONS {
                drop(state);
                let _ = connection.close().await;
                return Err(DaemonError::Protocol("too many connected clients".into()));
            }
            state.clients.insert(key.clone(), connection.clone());
            drop(state);
            (connection, true)
        };

        // The revocation monitor may have observed a generation change before
        // this connection was visible. Rechecking after publication covers
        // that ordering; a later revocation is handled by the monitor.
        if !self.auth.grant_is_current(&accepted.grant).await {
            let _ = connection.close().await;
            return Err(DaemonError::Crypto(CryptoError::Unauthorized(
                "device authorization changed during connection setup".into(),
            )));
        }
        if is_new && self.accepted_tx.send(connection.clone()).await.is_err() {
            let _ = connection.close().await;
            return Err(DaemonError::Protocol("daemon service receiver was dropped".into()));
        }
        Ok(())
    }

    async fn reconnect_registered_client(
        &self,
        key: &ClientKey,
        connection: &Arc<ServerConnection>,
        expected_generation: u64,
        generation: u64,
        link: Arc<dyn FrameLink>,
        peer_resume: &BTreeMap<Lane, u64>,
    ) -> Result<(), DaemonError> {
        let still_registered = {
            let state = self.state.lock().await;
            state.clients.get(key).is_some_and(|current| {
                Arc::ptr_eq(current, connection)
                    && current.current_generation() == expected_generation
            })
        };
        if !still_registered {
            return Err(DaemonError::Closed);
        }
        connection.reconnect_physical(expected_generation, generation, link, peer_resume).await
    }

    async fn registration_lock(&self, key: &ClientKey) -> Arc<Mutex<()>> {
        let mut state = self.state.lock().await;
        // A carrier task may be cancelled before explicit cleanup. Weak locks
        // make that safe; prune dead keys so random session IDs cannot grow
        // this reservation table over the daemon's lifetime.
        state.registration_locks.retain(|_, lock| lock.strong_count() != 0);
        if let Some(lock) = state.registration_locks.get(key).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(Mutex::new(()));
        state.registration_locks.insert(key.clone(), Arc::downgrade(&lock));
        lock
    }

    async fn release_registration_lock(&self, key: &ClientKey, registration: &Arc<Mutex<()>>) {
        let mut state = self.state.lock().await;
        let remove =
            state.registration_locks.get(key).and_then(Weak::upgrade).is_some_and(|current| {
                Arc::ptr_eq(&current, registration) && Arc::strong_count(&current) == 2
            });
        if remove {
            state.registration_locks.remove(key);
        }
    }

    fn schedule_resume_expiry(
        self: &Arc<Self>,
        connection: Arc<ServerConnection>,
        generation: u64,
        deadline: Instant,
    ) {
        let daemon = Arc::downgrade(self);
        let connection = Arc::downgrade(&connection);
        tokio::spawn(async move {
            tokio::time::sleep_until(deadline.into()).await;
            let (Some(_daemon), Some(connection)) = (daemon.upgrade(), connection.upgrade()) else {
                return;
            };
            let _ = connection.close_if_disconnected_generation(Some(generation)).await;
        });
    }

    async fn remove_connection_if(
        &self,
        key: &ClientKey,
        connection: &Arc<ServerConnection>,
    ) -> bool {
        let mut state = self.state.lock().await;
        let matches =
            state.clients.get(key).is_some_and(|current| Arc::ptr_eq(current, connection));
        if matches {
            state.clients.remove(key);
            state.pending.retain(|(pending_key, _), _| pending_key != key);
        }
        matches
    }

    pub async fn connections(&self) -> Vec<Arc<ServerConnection>> {
        self.state.lock().await.clients.values().cloned().collect()
    }

    /// Terminates one logical client session selected by the owner-only admin
    /// channel. Device authorization is unchanged, so the device can start a
    /// new session unless it is separately revoked.
    pub async fn disconnect(
        &self,
        device_id: &str,
        session: SessionId,
    ) -> Result<bool, DaemonError> {
        let key = ClientKey { device_id: device_id.to_string(), session };
        let connection = self.state.lock().await.clients.get(&key).cloned();
        let Some(connection) = connection else {
            return Ok(false);
        };
        connection.close().await?;
        Ok(true)
    }

    fn spawn_revocation_monitor(self: Arc<Self>) {
        let mut changes = self.auth.subscribe_revocations();
        tokio::spawn(async move {
            while changes.changed().await.is_ok() {
                let connections = self.connections().await;
                for connection in connections {
                    if !self.auth.device_is_active(&connection.device_id).await {
                        let _ = connection.close().await;
                    }
                }
            }
        });
    }
}

async fn close_pending_links(pending: Option<PendingLinks>) {
    if let Some(pending) = pending {
        for route in pending.routes {
            let _ = route.link.close().await;
        }
    }
}

#[derive(Clone)]
struct WebSocketState {
    daemon: Arc<RemoteDaemon>,
    maximum_frame_bytes: usize,
}

struct LimitedTcpListener {
    inner: tokio::net::TcpListener,
    permits: Arc<Semaphore>,
}

struct AdmissionIo {
    inner: tokio::net::TcpStream,
    _permit: OwnedSemaphorePermit,
    upgraded: Arc<AtomicBool>,
    deadline: Pin<Box<tokio::time::Sleep>>,
}

#[derive(Clone)]
struct AdmissionInfo {
    upgraded: Arc<AtomicBool>,
}

impl Listener for LimitedTcpListener {
    type Io = AdmissionIo;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            let permit = self
                .permits
                .clone()
                .acquire_owned()
                .await
                .expect("direct WebSocket admission semaphore is never closed");
            match self.inner.accept().await {
                Ok((inner, address)) => {
                    let _ = inner.set_nodelay(true);
                    return (
                        AdmissionIo {
                            inner,
                            _permit: permit,
                            upgraded: Arc::new(AtomicBool::new(false)),
                            deadline: Box::pin(tokio::time::sleep(DIRECT_HTTP_UPGRADE_TIMEOUT)),
                        },
                        address,
                    );
                }
                Err(_) => {
                    drop(permit);
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.inner.local_addr()
    }
}

impl Connected<IncomingStream<'_, LimitedTcpListener>> for AdmissionInfo {
    fn connect_info(stream: IncomingStream<'_, LimitedTcpListener>) -> Self {
        Self { upgraded: stream.io().upgraded.clone() }
    }
}

impl AsyncRead for AdmissionIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.upgraded.load(Ordering::Acquire) && self.deadline.as_mut().poll(context).is_ready()
        {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "WebSocket upgrade timed out",
            )));
        }
        Pin::new(&mut self.inner).poll_read(context, buffer)
    }
}

impl AsyncWrite for AdmissionIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(context, buffer)
    }

    fn poll_flush(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(context)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(context)
    }
}

pub struct DirectWebSocketServer {
    local_addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), io::Error>>>,
}

impl DirectWebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub async fn shutdown(mut self) -> Result<(), DaemonError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task
            .take()
            .expect("WebSocket server task is present")
            .await
            .map_err(|error| {
                DaemonError::Protocol(format!("WebSocket server task failed: {error}"))
            })?
            .map_err(|error| DaemonError::Protocol(format!("WebSocket server failed: {error}")))
    }
}

impl Drop for DirectWebSocketServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

pub async fn serve_direct_websocket(
    daemon: Arc<RemoteDaemon>,
    address: SocketAddr,
    maximum_frame_bytes: usize,
    allow_insecure_non_loopback: bool,
) -> Result<DirectWebSocketServer, DaemonError> {
    if !address.ip().is_loopback() && !allow_insecure_non_loopback {
        return Err(DaemonError::Protocol(format!(
            "refusing plaintext remote WebSocket bind {address}; use TLS or explicitly allow it"
        )));
    }
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|error| DaemonError::Protocol(format!("could not bind WebSocket: {error}")))?;
    let local_addr = listener.local_addr().map_err(|error| {
        DaemonError::Protocol(format!("could not read WebSocket address: {error}"))
    })?;
    let state = WebSocketState { daemon, maximum_frame_bytes };
    let router = Router::new().route("/v1/link", get(upgrade_websocket)).with_state(state);
    let listener = LimitedTcpListener {
        inner: listener,
        permits: Arc::new(Semaphore::new(MAX_DIRECT_HTTP_CONNECTIONS)),
    };
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, router.into_make_service_with_connect_info::<AdmissionInfo>())
            .with_graceful_shutdown(async move {
                let _ = shutdown_rx.await;
            })
            .await
    });
    Ok(DirectWebSocketServer { local_addr, shutdown: Some(shutdown_tx), task: Some(task) })
}

async fn upgrade_websocket(
    State(state): State<WebSocketState>,
    ConnectInfo(admission): ConnectInfo<AdmissionInfo>,
    websocket: WebSocketUpgrade,
) -> Response {
    websocket
        .max_message_size(state.maximum_frame_bytes)
        .max_frame_size(state.maximum_frame_bytes)
        .on_upgrade(move |socket| async move {
            admission.upgraded.store(true, Ordering::Release);
            let link =
                AxumWebSocketLink::new("direct-websocket", state.maximum_frame_bytes, socket);
            let _ = state.daemon.accept(Box::new(link)).await;
        })
}

#[cfg(unix)]
pub struct UnixServer {
    path: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

#[cfg(unix)]
impl UnixServer {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn shutdown(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(unix)]
impl Drop for UnixServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

#[cfg(unix)]
pub async fn serve_unix(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    maximum_frame_bytes: usize,
) -> Result<UnixServer, DaemonError> {
    let path = path.into();
    if let Some(parent) = path.parent() {
        let parent_existed = parent.exists();
        std::fs::create_dir_all(parent).map_err(|error| {
            DaemonError::Protocol(format!("could not create socket directory: {error}"))
        })?;
        if !parent_existed {
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700)).map_err(
                |error| {
                    DaemonError::Protocol(format!("could not secure socket directory: {error}"))
                },
            )?;
        } else {
            let mode = std::fs::metadata(parent)
                .map_err(|error| {
                    DaemonError::Protocol(format!("could not inspect socket directory: {error}"))
                })?
                .permissions()
                .mode();
            if mode & 0o022 != 0 && mode & 0o1000 == 0 {
                return Err(DaemonError::Protocol(format!(
                    "socket directory {} is writable by other users and is not sticky",
                    parent.display()
                )));
            }
        }
    }
    if let Ok(metadata) = std::fs::symlink_metadata(&path) {
        if !metadata.file_type().is_socket() {
            return Err(DaemonError::Protocol(format!(
                "refusing to replace non-socket path {}",
                path.display()
            )));
        }
        if tokio::net::UnixStream::connect(&path).await.is_ok() {
            return Err(DaemonError::Protocol(format!(
                "another daemon is listening at {}",
                path.display()
            )));
        }
        std::fs::remove_file(&path).map_err(|error| {
            DaemonError::Protocol(format!("could not remove stale socket: {error}"))
        })?;
    }
    let listener = UnixListener::bind(&path)
        .map_err(|error| DaemonError::Protocol(format!("could not bind Unix socket: {error}")))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| DaemonError::Protocol(format!("could not secure Unix socket: {error}")))?;
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let task_path = path.clone();
    let task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                accepted = listener.accept() => {
                    let Ok((stream, _)) = accepted else { break };
                    let Ok(peer) = stream.peer_cred() else { continue };
                    let owner = unsafe { libc::geteuid() };
                    if peer.uid() != owner {
                        continue;
                    }
                    let daemon = daemon.clone();
                    tokio::spawn(async move {
                        let (reader, writer) = stream.into_split();
                        let link = crate::provider::LengthDelimitedLink::new(
                            "unix-daemon",
                            maximum_frame_bytes,
                            reader,
                            writer,
                        );
                        let _ = daemon.accept_trusted_carrier(Box::new(link)).await;
                    });
                }
            }
        }
        let _ = std::fs::remove_file(task_path);
    });
    Ok(UnixServer { path, shutdown: Some(shutdown_tx), task: Some(task) })
}

#[derive(Debug)]
pub enum DaemonError {
    Crypto(CryptoError),
    Connection(ConnectionError),
    Link(LinkError),
    Session(SessionError),
    Protocol(String),
    Generation { expected: u64, actual: u64 },
    GenerationExhausted,
    HandshakeBusy,
    ApprovalBusy,
    HandshakeTimeout,
    Closed,
}

impl fmt::Display for DaemonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Crypto(error) => error.fmt(formatter),
            Self::Connection(error) => error.fmt(formatter),
            Self::Link(error) => error.fmt(formatter),
            Self::Session(error) => error.fmt(formatter),
            Self::Protocol(message) => write!(formatter, "daemon protocol failed: {message}"),
            Self::Generation { expected, actual } => {
                write!(
                    formatter,
                    "connection generation {actual} does not match expected {expected}"
                )
            }
            Self::GenerationExhausted => formatter.write_str("connection generation exhausted"),
            Self::HandshakeBusy => formatter.write_str("too many concurrent remote handshakes"),
            Self::ApprovalBusy => formatter.write_str("too many pending enrollment approvals"),
            Self::HandshakeTimeout => formatter.write_str("remote handshake timed out"),
            Self::Closed => formatter.write_str("daemon connection is closed"),
        }
    }
}

impl std::error::Error for DaemonError {}

impl From<CryptoError> for DaemonError {
    fn from(error: CryptoError) -> Self {
        Self::Crypto(error)
    }
}

impl From<ConnectionError> for DaemonError {
    fn from(error: ConnectionError) -> Self {
        Self::Connection(error)
    }
}

impl From<LinkError> for DaemonError {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

impl From<SessionError> for DaemonError {
    fn from(error: SessionError) -> Self {
        Self::Session(error)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use async_trait::async_trait;
    use cmux_remote_protocol::{LanePolicy, WireFrame};
    use tempfile::{TempDir, tempdir};
    use tokio::sync::{Mutex as AsyncMutex, Semaphore};

    use super::*;
    use crate::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
    use crate::crypto::{ClientAuthMode, StaticIdentity};
    use crate::link::test_support;
    use crate::provider::{
        CarrierEvidence, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    };

    struct FaultEpoch {
        failed: watch::Sender<bool>,
    }

    impl FaultEpoch {
        fn new() -> Self {
            let (failed, _) = watch::channel(false);
            Self { failed }
        }

        fn is_failed(&self) -> bool {
            *self.failed.borrow()
        }

        fn fail(&self) {
            self.failed.send_replace(true);
        }
    }

    struct FaultLink {
        name: &'static str,
        incoming: AsyncMutex<mpsc::Receiver<Bytes>>,
        outgoing: mpsc::Sender<Bytes>,
        epoch: Arc<FaultEpoch>,
    }

    fn fault_pair() -> (FaultLink, FaultLink, Arc<FaultEpoch>) {
        let (client_tx, daemon_rx) = mpsc::channel(64);
        let (daemon_tx, client_rx) = mpsc::channel(64);
        let epoch = Arc::new(FaultEpoch::new());
        (
            FaultLink {
                name: "fault-client",
                incoming: AsyncMutex::new(client_rx),
                outgoing: client_tx,
                epoch: epoch.clone(),
            },
            FaultLink {
                name: "fault-daemon",
                incoming: AsyncMutex::new(daemon_rx),
                outgoing: daemon_tx,
                epoch: epoch.clone(),
            },
            epoch,
        )
    }

    #[async_trait]
    impl FrameLink for FaultLink {
        fn description(&self) -> &str {
            self.name
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.epoch.is_failed() {
                return Err(LinkError::Transport("injected abrupt carrier loss".into()));
            }
            self.outgoing.send(frame).await.map_err(|_| LinkError::Closed)
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            let mut failed = self.epoch.failed.subscribe();
            let mut incoming = self.incoming.lock().await;
            if *failed.borrow() {
                if let Ok(frame) = incoming.try_recv() {
                    return Ok(Some(frame));
                }
                return Err(LinkError::Transport("injected abrupt carrier loss".into()));
            }
            tokio::select! {
                biased;
                frame = incoming.recv() => Ok(frame),
                _ = failed.changed() => Err(LinkError::Transport("injected abrupt carrier loss".into())),
            }
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.epoch.fail();
            Ok(())
        }
    }

    struct FaultGroup {
        daemon: Arc<RemoteDaemon>,
        epochs: AsyncMutex<Vec<Arc<FaultEpoch>>>,
        evidence: CarrierEvidence,
    }

    impl FaultGroup {
        async fn fail_current(&self) {
            self.epochs.lock().await.last().expect("an active carrier").fail();
        }
    }

    #[async_trait]
    impl LinkGroup for FaultGroup {
        fn description(&self) -> &str {
            "daemon-lifecycle-fault-group"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::STREAM
        }

        fn evidence(&self) -> &CarrierEvidence {
            &self.evidence
        }

        async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            let (client, daemon, epoch) = fault_pair();
            self.epochs.lock().await.push(epoch);
            let remote = self.daemon.clone();
            tokio::spawn(async move {
                let _ = remote.accept_trusted_carrier(Box::new(daemon)).await;
            });
            Ok(Box::new(client))
        }

        async fn close(&self) -> Result<(), ProviderError> {
            for epoch in self.epochs.lock().await.iter() {
                epoch.fail();
            }
            Ok(())
        }
    }

    async fn connected_fault_pair(
        lease: Duration,
        session: SessionId,
    ) -> (TempDir, Arc<RemoteDaemon>, Arc<FaultGroup>, Arc<ClientConnection>, Arc<ServerConnection>)
    {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "daemon-lifecycle", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::with_policy(
            auth,
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: lease },
        )
        .unwrap();
        let group = Arc::new(FaultGroup {
            daemon: daemon.clone(),
            epochs: AsyncMutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "daemon-lifecycle-client".into(),
                session,
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(5),
                    maximum_attempts: Some(4),
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();
        (directory, daemon, group, client, server)
    }

    async fn wait_for_disconnected(server: &ServerConnection, generation: u64) {
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if server.lifecycle.lock().await.disconnected_generation == Some(generation) {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("server did not observe abrupt carrier loss");
    }

    #[tokio::test]
    async fn abrupt_transport_suspends_replayable_server_send_until_reconnect() {
        let (_directory, _daemon, group, client, server) =
            connected_fault_pair(Duration::from_secs(5), SessionId([31; 16])).await;
        group.fail_current().await;

        let sending_server = server.clone();
        let mut send = tokio::spawn(async move {
            sending_server
                .send(
                    Lane::Control,
                    7,
                    Bytes::from_static(b"replayed from daemon"),
                    FrameFlags::empty(),
                )
                .await
        });
        wait_for_disconnected(&server, 0).await;
        assert!(tokio::time::timeout(Duration::from_millis(20), &mut send).await.is_err());

        let received = tokio::time::timeout(Duration::from_secs(2), client.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let sequence = send.await.unwrap().unwrap();
        assert_eq!(received.sequence, sequence);
        assert_eq!(received.payload, b"replayed from daemon".as_slice());
        assert_eq!(server.current_generation(), 1);
        client.close().await.unwrap();
    }

    #[tokio::test]
    async fn graceful_session_close_removes_connection_immediately() {
        let (_directory, daemon, _group, client, server) =
            connected_fault_pair(Duration::from_secs(5), SessionId([32; 16])).await;
        let receiving_server = server.clone();
        let receive = tokio::spawn(async move { receiving_server.receive().await });

        client.close().await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), receive)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .is_none()
        );
        assert!(daemon.connections().await.is_empty());
    }

    #[tokio::test]
    async fn cancelled_server_close_finishes_once_and_publishes_transport_failure() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "cancelled-close", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let key =
            ClientKey { device_id: "cancelled-close-device".into(), session: SessionId([36; 16]) };
        let session =
            ReliableSession::new(key.session, Arc::new(HangingCloseLink), SessionLimits::default());
        let connection = ServerConnection::new(&daemon, key.clone(), session);
        daemon.state.lock().await.clients.insert(key, connection.clone());

        let registry = daemon.state.lock().await;
        let closing = tokio::spawn({
            let connection = connection.clone();
            async move { connection.close().await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !connection.closed.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("server close did not begin");
        closing.abort();
        assert!(closing.await.unwrap_err().is_cancelled());
        drop(registry);

        let error = tokio::time::timeout(Duration::from_secs(2), connection.close())
            .await
            .expect("repeat close did not observe detached server cleanup")
            .unwrap_err();
        assert!(matches!(
            error,
            DaemonError::Protocol(ref message)
                if message == "timed out closing remote session transport"
        ));
        assert!(daemon.connections().await.is_empty());
    }

    #[tokio::test]
    async fn owner_disconnect_closes_exact_logical_session() {
        let session = SessionId([42; 16]);
        let (_directory, daemon, _group, _client, server) =
            connected_fault_pair(Duration::from_secs(5), session).await;
        let device_id = server.device_id.clone();

        assert!(daemon.disconnect(&device_id, session).await.unwrap());
        assert!(daemon.connections().await.is_empty());
        assert!(!daemon.disconnect(&device_id, session).await.unwrap());
    }

    #[tokio::test]
    async fn crashed_session_is_evicted_when_resume_lease_expires() {
        let (_directory, daemon, group, _client, server) =
            connected_fault_pair(Duration::from_millis(30), SessionId([33; 16])).await;
        let receiving_server = server.clone();
        let receive = tokio::spawn(async move { receiving_server.receive().await });
        group.fail_current().await;

        assert!(
            tokio::time::timeout(Duration::from_secs(1), receive)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .is_none()
        );
        assert!(server.closed.load(Ordering::Acquire));
        assert!(daemon.connections().await.is_empty());
    }

    struct BlockingReplayLink {
        started: Semaphore,
        release: Semaphore,
    }

    struct HangingCloseLink;

    #[async_trait]
    impl FrameLink for HangingCloseLink {
        fn description(&self) -> &str {
            "hanging-close"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            std::future::pending().await
        }
    }

    #[async_trait]
    impl FrameLink for BlockingReplayLink {
        fn description(&self) -> &str {
            "blocking-replay"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            self.started.add_permits(1);
            self.release.acquire().await.unwrap().forget();
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    struct BlockingReceiveLink {
        closed: watch::Sender<bool>,
        receive_started: Semaphore,
        close_called: Semaphore,
    }

    impl BlockingReceiveLink {
        fn new() -> Self {
            let (closed, _) = watch::channel(false);
            Self { closed, receive_started: Semaphore::new(0), close_called: Semaphore::new(0) }
        }
    }

    #[async_trait]
    impl FrameLink for BlockingReceiveLink {
        fn description(&self) -> &str {
            "blocking-previous-carrier"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            let mut closed = self.closed.subscribe();
            self.receive_started.add_permits(1);
            if *closed.borrow() {
                return Ok(None);
            }
            closed.changed().await.map_err(|_| LinkError::Closed)?;
            Ok(None)
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.closed.send_replace(true);
            self.close_called.add_permits(1);
            Ok(())
        }
    }

    struct TrackingMemoryLink {
        name: &'static str,
        incoming: AsyncMutex<mpsc::Receiver<Bytes>>,
        outgoing: AsyncMutex<Option<mpsc::Sender<Bytes>>>,
        closed: Arc<AtomicBool>,
    }

    fn tracking_pair() -> (TrackingMemoryLink, TrackingMemoryLink, Arc<AtomicBool>, Arc<AtomicBool>)
    {
        let (left_tx, right_rx) = mpsc::channel(16);
        let (right_tx, left_rx) = mpsc::channel(16);
        let left_closed = Arc::new(AtomicBool::new(false));
        let right_closed = Arc::new(AtomicBool::new(false));
        (
            TrackingMemoryLink {
                name: "tracking-replacement",
                incoming: AsyncMutex::new(left_rx),
                outgoing: AsyncMutex::new(Some(left_tx)),
                closed: left_closed.clone(),
            },
            TrackingMemoryLink {
                name: "tracking-peer",
                incoming: AsyncMutex::new(right_rx),
                outgoing: AsyncMutex::new(Some(right_tx)),
                closed: right_closed.clone(),
            },
            left_closed,
            right_closed,
        )
    }

    #[async_trait]
    impl FrameLink for TrackingMemoryLink {
        fn description(&self) -> &str {
            self.name
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.closed.load(Ordering::Acquire) {
                return Err(LinkError::Closed);
            }
            let outgoing = self.outgoing.lock().await.as_ref().cloned().ok_or(LinkError::Closed)?;
            outgoing.send(frame).await.map_err(|_| LinkError::Closed)
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.closed.store(true, Ordering::Release);
            self.outgoing.lock().await.take();
            Ok(())
        }
    }

    #[tokio::test]
    async fn reconnect_accepts_a_burned_generation_and_closes_the_previous_carrier() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "previous-carrier-close", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let key =
            ClientKey { device_id: "reconnecting-device".into(), session: SessionId([35; 16]) };
        let previous = Arc::new(BlockingReceiveLink::new());
        let session = ReliableSession::new(key.session, previous.clone(), SessionLimits::default());
        let connection = ServerConnection::new(&daemon, key.clone(), session);
        daemon.state.lock().await.clients.insert(key.clone(), connection.clone());

        let receiving_connection = connection.clone();
        let receive = tokio::spawn(async move { receiving_connection.receive().await });
        tokio::time::timeout(Duration::from_secs(1), previous.receive_started.acquire())
            .await
            .expect("the previous receiver did not block on its carrier")
            .unwrap()
            .forget();

        let (replacement, peer, replacement_closed, _peer_closed) = tracking_pair();
        let replacement: Arc<dyn FrameLink> = Arc::new(replacement);
        let resume = Lane::ALL.into_iter().map(|lane| (lane, 0)).collect();
        daemon
            .reconnect_registered_client(&key, &connection, 0, 3, replacement, &resume)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), previous.close_called.acquire())
            .await
            .expect("the previous carrier was not closed after publication")
            .unwrap()
            .forget();
        assert!(!replacement_closed.load(Ordering::Acquire));

        let frame = WireFrame {
            session: key.session,
            generation: 3,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE,
            sequence: 1,
            acknowledgement: 0,
            stream: 11,
            payload: b"replacement stayed open".to_vec(),
        };
        peer.send(Bytes::from(frame.encode().unwrap())).await.unwrap();
        let received = tokio::time::timeout(Duration::from_secs(1), receive)
            .await
            .expect("the old blocked receiver did not advance to the replacement")
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(received.generation, 3);
        assert_eq!(received.payload, b"replacement stayed open".as_slice());
        assert!(!replacement_closed.load(Ordering::Acquire));
    }

    #[tokio::test]
    async fn daemon_registry_remains_available_while_registration_replay_blocks() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "registration-lock", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let key = ClientKey { device_id: "registered-device".into(), session: SessionId([34; 16]) };
        let (server_link, _peer_link) = test_support::pair(128 * 1024);
        let session =
            ReliableSession::new(key.session, Arc::new(server_link), SessionLimits::default());
        let connection = ServerConnection::new(&daemon, key.clone(), session);
        daemon.state.lock().await.clients.insert(key.clone(), connection.clone());
        connection
            .send(Lane::Control, 9, Bytes::from_static(b"pending replay"), FrameFlags::empty())
            .await
            .unwrap();

        let blocking =
            Arc::new(BlockingReplayLink { started: Semaphore::new(0), release: Semaphore::new(0) });
        let reconnecting_daemon = daemon.clone();
        let reconnecting_connection = connection.clone();
        let reconnecting_key = key.clone();
        let reconnecting_link: Arc<dyn FrameLink> = blocking.clone();
        let registration = daemon.registration_lock(&key).await;
        let reconnect = tokio::spawn(async move {
            let _registration = registration.lock().await;
            let resume = Lane::ALL.into_iter().map(|lane| (lane, 0)).collect();
            reconnecting_daemon
                .reconnect_registered_client(
                    &reconnecting_key,
                    &reconnecting_connection,
                    0,
                    1,
                    reconnecting_link,
                    &resume,
                )
                .await
        });
        tokio::time::timeout(Duration::from_secs(1), blocking.started.acquire())
            .await
            .expect("replay did not reach the blocking link")
            .unwrap()
            .forget();

        let connections = tokio::time::timeout(Duration::from_millis(50), daemon.connections())
            .await
            .expect("registration replay held the global daemon state lock");
        assert_eq!(connections.len(), 1);
        blocking.release.add_permits(1);
        reconnect.await.unwrap().unwrap();
        assert_eq!(connection.current_generation(), 1);
    }
}
