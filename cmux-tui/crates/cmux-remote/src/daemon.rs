use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::io;
use std::net::SocketAddr;
#[cfg(unix)]
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::connect_info::{ConnectInfo, Connected};
use axum::extract::{State, WebSocketUpgrade};
use axum::http::header::ORIGIN;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::serve::{IncomingStream, Listener};
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, SessionId};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Mutex, Notify, OwnedSemaphorePermit, RwLock, Semaphore, mpsc, oneshot, watch};
use tokio::task::JoinSet;

use crate::connection::{ConnectionError, LinkRejection, send_link_ready, send_link_rejection};
use crate::crypto::{
    AcceptedSecureLink, AuthKind, ConnectionAttemptId, CryptoError, authorize_secure_link,
    verify_secure_link,
};
pub use crate::crypto::{
    InboundAuthEvidence, NetworkPeer, VerifiedKernelPeer, VerifiedSshPrincipal,
};
use crate::identity::{AuthDatabase, IdentityError};
use crate::link::{FrameLink, LaneMuxLink, LinkError, LinkRoute};
use crate::observability::{ConnectionState, ServerConnectionSnapshot};
use crate::provider::AxumWebSocketLink;
use crate::session::{ReceivedFrame, ReliableSession, SessionError, SessionLimits};
#[cfg(unix)]
use crate::unix_socket::{OwnedUnixListener, UnixAcceptBackoff, UnixSocketCleanup};

const PENDING_LINK_TTL: Duration = Duration::from_secs(30);
const MAX_PENDING_LINK_GROUPS: usize = 256;
const MAX_CLIENT_CONNECTIONS: usize = 64;
const MAX_CONCURRENT_HANDSHAKES: usize = 256;
const MAX_PENDING_APPROVALS: usize = 64;
const PREAUTH_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const AUTHORIZATION_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_DIRECT_HTTP_CONNECTIONS: usize = 512;
const MAX_UNIX_CONNECTIONS: usize = 64;
const DIRECT_HTTP_UPGRADE_TIMEOUT: Duration = Duration::from_secs(10);
const TERMINAL_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);
pub const DEFAULT_RESUME_LEASE: Duration = Duration::from_secs(2 * 60);
pub const MAX_RESUME_LEASE: Duration = Duration::from_secs(24 * 60 * 60);

/// A raw inbound transport link paired with server-established auth evidence.
pub struct InboundLink {
    link: Box<dyn FrameLink>,
    evidence: InboundAuthEvidence,
}

impl InboundLink {
    pub fn new(link: Box<dyn FrameLink>, evidence: InboundAuthEvidence) -> Self {
        Self { link, evidence }
    }

    pub fn network(link: Box<dyn FrameLink>, peer: NetworkPeer) -> Self {
        Self::new(link, InboundAuthEvidence::Network(peer))
    }

    /// A link from a listener the operator marked trusted (`DirectWebSocketOptions::
    /// trusted_carrier`): the network admitted the peer, so carrier authentication
    /// is granted without enrollment.
    pub fn trusted_network(link: Box<dyn FrameLink>, peer: NetworkPeer) -> Self {
        Self::new(link, InboundAuthEvidence::TrustedNetwork(peer))
    }

    pub fn evidence(&self) -> &InboundAuthEvidence {
        &self.evidence
    }

    pub(crate) fn same_owner_kernel_peer(
        link: Box<dyn FrameLink>,
        peer_uid: u32,
        effective_uid: u32,
    ) -> Option<Self> {
        let evidence =
            InboundAuthEvidence::verified_same_owner_kernel_peer(peer_uid, effective_uid)?;
        Some(Self::new(link, evidence))
    }

    fn into_parts(self) -> (Box<dyn FrameLink>, InboundAuthEvidence) {
        (self.link, self.evidence)
    }
}

impl fmt::Debug for InboundLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("InboundLink")
            .field("description", &self.link.description())
            .field("evidence", &self.evidence)
            .finish()
    }
}

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
    close_requested: Notify,
    lifecycle: Mutex<ServerLifecycle>,
    diagnostics: StdMutex<ServerDiagnostics>,
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

#[derive(Debug)]
struct ResumeExpiryTask(Option<tokio::task::AbortHandle>);

impl ResumeExpiryTask {
    fn new(task: tokio::task::AbortHandle) -> Self {
        Self(Some(task))
    }

    fn disarm(mut self) {
        self.0.take();
    }
}

impl Drop for ResumeExpiryTask {
    fn drop(&mut self) {
        if let Some(task) = self.0.take() {
            task.abort();
        }
    }
}

#[derive(Debug)]
struct PendingLinkExpiryTask(Option<tokio::task::AbortHandle>);

impl PendingLinkExpiryTask {
    fn new(task: tokio::task::AbortHandle) -> Self {
        Self(Some(task))
    }

    fn disarm(mut self) {
        self.0.take();
    }
}

impl Drop for PendingLinkExpiryTask {
    fn drop(&mut self) {
        if let Some(task) = self.0.take() {
            task.abort();
        }
    }
}

#[derive(Debug)]
struct ServerLifecycle {
    disconnected_generation: Option<u64>,
    resume_deadline: Option<Instant>,
    resume_expiry_task: Option<ResumeExpiryTask>,
    lane_bindings: Vec<Vec<Lane>>,
}

#[derive(Debug)]
struct ServerDiagnostics {
    generation: u64,
    state: ConnectionState,
    resume_deadline: Option<Instant>,
    lane_bindings: Vec<Vec<Lane>>,
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
    fn new(
        owner: &Arc<RemoteDaemon>,
        key: ClientKey,
        session: ReliableSession,
        lane_bindings: Vec<Vec<Lane>>,
    ) -> Arc<Self> {
        let device_id = key.device_id.clone();
        let session_id = key.session;
        let owner = Arc::downgrade(owner);
        let initial_generation = session.generation();
        let (generation, _) = watch::channel(initial_generation);
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
            close_requested: Notify::new(),
            lifecycle: Mutex::new(ServerLifecycle {
                disconnected_generation: None,
                resume_deadline: None,
                resume_expiry_task: None,
                lane_bindings: lane_bindings.clone(),
            }),
            diagnostics: StdMutex::new(ServerDiagnostics {
                generation: initial_generation,
                state: ConnectionState::Connected,
                resume_deadline: None,
                lane_bindings,
            }),
            lane_sends: std::array::from_fn(|_| Mutex::new(())),
            closed: AtomicBool::new(false),
            close_state,
        })
    }

    fn current_generation(&self) -> u64 {
        *self.generation.borrow()
    }

    pub async fn snapshot(&self) -> ServerConnectionSnapshot {
        let diagnostics =
            self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let resume_lease_remaining_ms = diagnostics.resume_deadline.map(|deadline| {
            deadline.saturating_duration_since(Instant::now()).as_millis().min(u64::MAX as u128)
                as u64
        });
        ServerConnectionSnapshot {
            device_id: self.device_id.clone(),
            session_id: format!("{:?}", self.session_id),
            generation: diagnostics.generation,
            state: diagnostics.state,
            resume_lease_remaining_ms,
            lane_bindings: diagnostics.lane_bindings.clone(),
            physical_link_count: diagnostics.lane_bindings.len(),
        }
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
            match session.send_with_backpressure(lane, stream, payload.clone(), flags).await {
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
        lane_bindings: Vec<Vec<Lane>>,
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
            lifecycle.resume_expiry_task =
                Some(owner.schedule_resume_expiry(connection, expected_generation, deadline));
            let mut diagnostics =
                self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            diagnostics.state = ConnectionState::Reconnecting;
            diagnostics.resume_deadline = Some(deadline);
        }
        let reconnecting = current.clone();
        let deadline =
            lifecycle.resume_deadline.expect("a reconnecting generation always has a deadline");
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(DaemonError::Closed);
        }
        let close_requested = self.close_requested.notified();
        tokio::pin!(close_requested);
        close_requested.as_mut().enable();
        if self.closed.load(Ordering::Acquire) {
            return Err(DaemonError::Closed);
        }
        let reconnect = reconnecting.reconnect_to(link, peer_resume, generation);
        let next = tokio::select! {
            biased;
            _ = &mut close_requested => return Err(DaemonError::Closed),
            result = tokio::time::timeout(remaining, reconnect) => {
                result.map_err(|_| DaemonError::Closed)??
            }
        };
        let generation = next.generation();
        let previous = std::mem::replace(&mut *current, next);
        drop(lifecycle.resume_expiry_task.take());
        lifecycle.disconnected_generation = None;
        lifecycle.resume_deadline = None;
        lifecycle.lane_bindings = lane_bindings;
        self.generation.send_replace(generation);
        {
            let mut diagnostics =
                self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            diagnostics.generation = generation;
            diagnostics.state = ConnectionState::Connected;
            diagnostics.resume_deadline = None;
            diagnostics.lane_bindings = lifecycle.lane_bindings.clone();
        }
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
        let mut lifecycle = self.lifecycle.lock().await;
        if self.closed.load(Ordering::Acquire)
            || self.current_generation() != generation
            || lifecycle.disconnected_generation == Some(generation)
        {
            return;
        }
        lifecycle.disconnected_generation = Some(generation);
        lifecycle.resume_deadline = Some(deadline);
        drop(
            lifecycle
                .resume_expiry_task
                .replace(owner.schedule_resume_expiry(connection, generation, deadline)),
        );
        let mut diagnostics =
            self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        diagnostics.state = ConnectionState::Reconnecting;
        diagnostics.resume_deadline = Some(deadline);
    }

    async fn claim_resume_expiry(&self, generation: u64, deadline: Instant) -> bool {
        let mut lifecycle = self.lifecycle.lock().await;
        if self.closed.load(Ordering::Acquire)
            || lifecycle.disconnected_generation != Some(generation)
            || lifecycle.resume_deadline != Some(deadline)
        {
            return false;
        }
        let Some(expiry) = lifecycle.resume_expiry_task.take() else {
            return false;
        };
        expiry.disarm();
        true
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
        // Explicit shutdown publishes cancellation before waiting for replay's
        // lifecycle guard. Reconnect watches this notification, so revocation
        // and owner disconnect cannot be delayed by a stalled replay write.
        if disconnected_generation.is_none() {
            if self.closed.swap(true, Ordering::AcqRel) {
                return false;
            }
            self.close_requested.notify_waiters();
        }
        let mut lifecycle = self.lifecycle.lock().await;
        if let Some(expected) = disconnected_generation
            && (self.closed.load(Ordering::Acquire)
                || lifecycle.disconnected_generation != Some(expected)
                || self.current_generation() != expected)
        {
            return false;
        }
        if disconnected_generation.is_some() {
            self.closed.store(true, Ordering::Release);
            self.close_requested.notify_waiters();
        }
        drop(lifecycle.resume_expiry_task.take());
        lifecycle.disconnected_generation = None;
        lifecycle.resume_deadline = None;
        {
            let mut diagnostics =
                self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            diagnostics.state = ConnectionState::Closed;
            diagnostics.resume_deadline = None;
        }
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
    revocation_monitor: StdMutex<Option<tokio::task::AbortHandle>>,
}

struct DaemonState {
    clients: HashMap<ClientKey, Arc<ServerConnection>>,
    pending: HashMap<(ClientKey, u64, ConnectionAttemptId), PendingLinks>,
    registration_locks: HashMap<ClientKey, Weak<Mutex<()>>>,
}

struct PendingLinks {
    created_at: Instant,
    expiry_task: Option<PendingLinkExpiryTask>,
    routes: Vec<LinkRoute>,
    assigned: BTreeSet<Lane>,
    client_resume: BTreeMap<Lane, u64>,
    grant_generation: u64,
}

struct ReconnectRegistration<'a> {
    expected_generation: u64,
    generation: u64,
    link: Arc<dyn FrameLink>,
    lane_bindings: Vec<Vec<Lane>>,
    peer_resume: &'a BTreeMap<Lane, u64>,
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
            revocation_monitor: StdMutex::new(None),
        });
        daemon.spawn_revocation_monitor();
        Ok((daemon, accepted_rx))
    }

    pub fn auth(&self) -> &Arc<AuthDatabase> {
        &self.auth
    }

    pub async fn accept(self: &Arc<Self>, inbound: InboundLink) -> Result<(), DaemonError> {
        let (raw, evidence) = inbound.into_parts();
        let permit = self.handshakes.try_acquire().map_err(|_| DaemonError::HandshakeBusy)?;
        let verified = tokio::time::timeout(
            PREAUTH_HANDSHAKE_TIMEOUT,
            verify_secure_link(raw, &self.auth.identity(), &*self.auth, evidence),
        )
        .await
        .map_err(|_| DaemonError::HandshakeTimeout)??;
        drop(permit);
        let accepted = match verified.auth_kind() {
            AuthKind::Invitation => {
                let approval =
                    self.approvals.try_acquire().map_err(|_| DaemonError::ApprovalBusy)?;
                // AuthDatabase owns the five-minute approval deadline and its
                // cancellation cleanup. An outer timeout would cancel that cleanup
                // and leave a stale pending invitation.
                let accepted = authorize_secure_link(verified, &*self.auth).await?;
                drop(approval);
                accepted
            }
            AuthKind::Carrier | AuthKind::Enrolled => tokio::time::timeout(
                AUTHORIZATION_TIMEOUT,
                authorize_secure_link(verified, &*self.auth),
            )
            .await
            .map_err(|_| DaemonError::HandshakeTimeout)??,
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
        let (existing, expired) = {
            let mut state = self.state.lock().await;
            // Per-group timers normally remove these entries. This bounded
            // scan is the admission-time safety net when a timer is delayed
            // by runtime starvation, so stale groups cannot consume capacity.
            let expired_keys = state
                .pending
                .iter()
                .filter(|(_, pending)| now.duration_since(pending.created_at) >= PENDING_LINK_TTL)
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>();
            let expired = expired_keys
                .into_iter()
                .filter_map(|key| state.pending.remove(&key))
                .collect::<Vec<_>>();
            (state.clients.get(&key).cloned(), expired)
        };
        for pending in expired {
            close_pending_links(Some(pending)).await;
        }
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
                    send_link_rejection(&accepted.link, LinkRejection::SessionUnavailable).await?;
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

        let pending_key = (key.clone(), accepted.generation, accepted.connection_attempt);
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
        let mut created_pending_group = false;
        let pending = state.pending.entry(pending_key.clone()).or_insert_with(|| {
            created_pending_group = true;
            PendingLinks {
                created_at: now,
                expiry_task: None,
                routes: Vec::new(),
                assigned: BTreeSet::new(),
                client_resume: accepted.resume.clone(),
                grant_generation: accepted.grant.revocation_generation,
            }
        });
        for lane in &accepted.lanes {
            let lane_was_new = pending.assigned.insert(*lane);
            debug_assert!(lane_was_new);
        }
        pending.routes.push(LinkRoute { lanes: accepted.lanes, link: Arc::new(accepted.link) });
        if pending.assigned.len() != Lane::ALL.len() {
            if created_pending_group {
                pending.expiry_task = Some(self.schedule_pending_link_expiry(pending_key, now));
            }
            drop(state);
            return Ok(());
        }
        if pending.assigned.iter().copied().ne(Lane::ALL) {
            return Err(DaemonError::Protocol("physical links did not cover every lane".into()));
        }
        let mut pending = state.pending.remove(&pending_key).expect("pending entry exists");
        drop(pending.expiry_task.take());
        drop(state);
        let mut lane_bindings =
            pending.routes.iter().map(|route| route.lanes.clone()).collect::<Vec<_>>();
        lane_bindings
            .sort_by_key(|lanes| lanes.iter().map(|lane| lane.priority()).min().unwrap_or(u8::MAX));
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
            let rejected_mux = mux.clone();
            if let Err(error) = self
                .reconnect_registered_client(
                    &key,
                    &connection,
                    ReconnectRegistration {
                        expected_generation,
                        generation: accepted.generation,
                        link: mux,
                        lane_bindings,
                        peer_resume: &pending.client_resume,
                    },
                )
                .await
            {
                let _ = rejected_mux.close().await;
                if matches!(error, DaemonError::Closed) {
                    let _ = connection.close().await;
                }
                return Err(error);
            }
            (connection, false)
        } else {
            let reliable = ReliableSession::new(key.session, mux, self.limits);
            let connection = ServerConnection::new(self, key.clone(), reliable, lane_bindings);
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
        if let Err(error) =
            self.auth.record_connection_attempt(&key.device_id, accepted.connection_attempt).await
        {
            let _ = connection.close().await;
            return Err(DaemonError::Identity(error));
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
        registration: ReconnectRegistration<'_>,
    ) -> Result<(), DaemonError> {
        let still_registered = {
            let state = self.state.lock().await;
            state.clients.get(key).is_some_and(|current| {
                Arc::ptr_eq(current, connection)
                    && current.current_generation() == registration.expected_generation
            })
        };
        if !still_registered {
            return Err(DaemonError::Closed);
        }
        connection
            .reconnect_physical(
                registration.expected_generation,
                registration.generation,
                registration.link,
                registration.lane_bindings,
                registration.peer_resume,
            )
            .await
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
    ) -> ResumeExpiryTask {
        let daemon = Arc::downgrade(self);
        let connection = Arc::downgrade(&connection);
        let task = tokio::spawn(async move {
            tokio::time::sleep_until(deadline.into()).await;
            let (Some(_daemon), Some(connection)) = (daemon.upgrade(), connection.upgrade()) else {
                return;
            };
            if !connection.claim_resume_expiry(generation, deadline).await {
                return;
            }
            let _ = connection.close_if_disconnected_generation(Some(generation)).await;
        });
        ResumeExpiryTask::new(task.abort_handle())
    }

    fn schedule_pending_link_expiry(
        self: &Arc<Self>,
        key: (ClientKey, u64, ConnectionAttemptId),
        created_at: Instant,
    ) -> PendingLinkExpiryTask {
        let daemon = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            tokio::time::sleep_until((created_at + PENDING_LINK_TTL).into()).await;
            let Some(daemon) = daemon.upgrade() else {
                return;
            };
            let mut expired = {
                let mut state = daemon.state.lock().await;
                let matches =
                    state.pending.get(&key).is_some_and(|pending| pending.created_at == created_at);
                matches.then(|| state.pending.remove(&key)).flatten()
            };
            if let Some(expiry_task) =
                expired.as_mut().and_then(|pending| pending.expiry_task.take())
            {
                expiry_task.disarm();
            }
            close_pending_links(expired).await;
        });
        PendingLinkExpiryTask::new(task.abort_handle())
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
            state.pending.retain(|(pending_key, _, _), _| pending_key != key);
        }
        matches
    }

    pub async fn connections(&self) -> Vec<Arc<ServerConnection>> {
        self.state.lock().await.clients.values().cloned().collect()
    }

    pub async fn connection_snapshots(&self) -> Vec<ServerConnectionSnapshot> {
        let connections = self.connections().await;
        let mut snapshots = Vec::with_capacity(connections.len());
        for connection in connections {
            snapshots.push(connection.snapshot().await);
        }
        snapshots.sort_by(|left, right| {
            (&left.device_id, &left.session_id).cmp(&(&right.device_id, &right.session_id))
        });
        snapshots
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

    fn spawn_revocation_monitor(self: &Arc<Self>) {
        let mut changes = self.auth.subscribe_revocations();
        let daemon = Arc::downgrade(self);
        let monitor = tokio::spawn(async move {
            while changes.changed().await.is_ok() {
                let Some(daemon) = daemon.upgrade() else {
                    return;
                };
                let connections = daemon.connections().await;
                for connection in connections {
                    if !daemon.auth.device_is_active(&connection.device_id).await {
                        tokio::spawn(async move {
                            let _ = connection.close().await;
                        });
                    }
                }
            }
        });
        *self.revocation_monitor.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(monitor.abort_handle());
    }
}

impl Drop for RemoteDaemon {
    fn drop(&mut self) {
        if let Some(monitor) =
            self.revocation_monitor.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
        {
            monitor.abort();
        }
    }
}

async fn close_pending_links(pending: Option<PendingLinks>) {
    if let Some(mut pending) = pending {
        drop(pending.expiry_task.take());
        for route in pending.routes {
            let _ = tokio::time::timeout(TERMINAL_CLOSE_TIMEOUT, route.link.close()).await;
        }
    }
}

#[derive(Clone)]
struct WebSocketState {
    daemon: Arc<RemoteDaemon>,
    maximum_frame_bytes: usize,
    trusted_carrier: bool,
}

/// How a direct WebSocket listener admits links.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DirectWebSocketOptions {
    /// Bind plaintext off loopback (the carrier is expected to encrypt: WireGuard, TLS proxy).
    pub allow_insecure_non_loopback: bool,
    /// Grant carrier authentication to every link: the listener is reachable only
    /// from a network whose members are all authorized (a cmux Cloud machine's
    /// private VPC). Enrolled and invitation dials keep working alongside.
    pub trusted_carrier: bool,
}

struct LimitedTcpListener {
    inner: tokio::net::TcpListener,
    permits: Arc<Semaphore>,
    /// Spacing for accept errors that persist (descriptor exhaustion).
    accept_backoff: cmux_tui_core::backoff::Backoff,
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
                    self.accept_backoff.reset();
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
                Err(error) => {
                    drop(permit);
                    if cmux_tui_core::backoff::accept_error_needs_backoff(&error) {
                        tokio::time::sleep(self.accept_backoff.next_delay()).await;
                    }
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
    serve_direct_websocket_with_options(
        daemon,
        address,
        maximum_frame_bytes,
        DirectWebSocketOptions { allow_insecure_non_loopback, trusted_carrier: false },
    )
    .await
}

pub async fn serve_direct_websocket_with_options(
    daemon: Arc<RemoteDaemon>,
    address: SocketAddr,
    maximum_frame_bytes: usize,
    options: DirectWebSocketOptions,
) -> Result<DirectWebSocketServer, DaemonError> {
    let DirectWebSocketOptions { allow_insecure_non_loopback, trusted_carrier } = options;
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
    let state = WebSocketState { daemon, maximum_frame_bytes, trusted_carrier };
    let router = Router::new().route("/v1/link", get(upgrade_websocket)).with_state(state);
    let listener = LimitedTcpListener {
        accept_backoff: cmux_tui_core::backoff::Backoff::new(
            Duration::from_millis(10),
            Duration::from_secs(1),
        ),
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
    headers: HeaderMap,
    websocket: WebSocketUpgrade,
) -> Response {
    if headers.contains_key(ORIGIN) {
        return StatusCode::FORBIDDEN.into_response();
    }
    websocket
        .max_message_size(state.maximum_frame_bytes)
        .max_frame_size(state.maximum_frame_bytes)
        .on_upgrade(move |socket| async move {
            admission.upgraded.store(true, Ordering::Release);
            let link =
                AxumWebSocketLink::new("direct-websocket", state.maximum_frame_bytes, socket);
            let inbound = if state.trusted_carrier {
                InboundLink::trusted_network(Box::new(link), NetworkPeer::Tcp)
            } else {
                InboundLink::network(Box::new(link), NetworkPeer::Tcp)
            };
            let _ = state.daemon.accept(inbound).await;
        })
}

#[cfg(unix)]
pub struct UnixServer {
    path: PathBuf,
    socket_cleanup: Arc<UnixSocketCleanup>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), DaemonError>>>,
}

#[cfg(unix)]
impl UnixServer {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn shutdown(mut self) -> Result<(), DaemonError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            return task.await.map_err(|error| {
                DaemonError::Protocol(format!("Unix listener task failed: {error}"))
            })?;
        }
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for UnixServer {
    fn drop(&mut self) {
        // The listener is owned by the accept task. Unlink the path here as
        // well, because aborting a task only schedules cancellation; its
        // listener may not be dropped before this wrapper returns.
        let _ = self.socket_cleanup.unlink();
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

#[cfg(unix)]
pub async fn serve_unix(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    maximum_frame_bytes: usize,
) -> Result<UnixServer, DaemonError> {
    serve_unix_with_shutdown(daemon, path, maximum_frame_bytes, None).await
}

#[cfg(unix)]
pub async fn serve_unix_with_shutdown(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    maximum_frame_bytes: usize,
    owner_shutdown: Option<watch::Sender<bool>>,
) -> Result<UnixServer, DaemonError> {
    let path = path.into();
    let listener = OwnedUnixListener::bind(path.clone())
        .await
        .map_err(|error| DaemonError::Protocol(format!("could not own Unix socket: {error:#}")))?;
    let socket_cleanup = listener.cleanup();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_UNIX_CONNECTIONS));
    let task = tokio::spawn(async move {
        let mut accept_backoff = UnixAcceptBackoff::new();
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    connections.shutdown().await;
                    return Ok(())
                },
                Some(_) = connections.join_next(), if !connections.is_empty() => {},
                accepted = listener.listener().accept() => {
                    let (stream, _) = match accepted {
                        Ok(accepted) => {
                            accept_backoff.reset();
                            accepted
                        }
                        Err(error) => {
                            let Some(delay) = accept_backoff.retry_delay(&error) else {
                                if let Some(owner_shutdown) = &owner_shutdown {
                                    let _ = owner_shutdown.send(true);
                                }
                                return Err(DaemonError::Protocol(format!(
                                    "Unix listener accept failed: {error}"
                                )));
                            };
                            tokio::select! {
                                _ = &mut shutdown_rx => {
                                    connections.shutdown().await;
                                    return Ok(())
                                },
                                _ = tokio::time::sleep(delay) => {}
                            }
                            continue;
                        }
                    };
                    let Ok(peer) = stream.peer_cred() else { continue };
                    let owner = unsafe { libc::geteuid() };
                    let (reader, writer) = stream.into_split();
                    let link = crate::provider::LengthDelimitedLink::new(
                        "unix-daemon",
                        maximum_frame_bytes,
                        reader,
                        writer,
                    );
                    let Some(inbound) = InboundLink::same_owner_kernel_peer(
                        Box::new(link),
                        peer.uid(),
                        owner,
                    ) else {
                        continue;
                    };
                    let Ok(permit) = permits.clone().try_acquire_owned() else {
                        continue;
                    };
                    let daemon = daemon.clone();
                    connections.spawn(async move {
                        let _permit = permit;
                        let _ = daemon.accept(inbound).await;
                    });
                }
            }
        }
    });
    Ok(UnixServer { path, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

#[derive(Debug)]
pub enum DaemonError {
    Crypto(CryptoError),
    Identity(IdentityError),
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
            Self::Identity(error) => error.fmt(formatter),
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

impl From<IdentityError> for DaemonError {
    fn from(error: IdentityError) -> Self {
        Self::Identity(error)
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

    use tempfile::tempdir;
    #[cfg(unix)]
    use tokio::net::UnixListener;

    use super::*;

    #[cfg(unix)]
    #[test]
    fn unix_listener_retries_recoverable_accept_errors() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "daemon::tests::unix_listener_accept_exhaustion_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_UNIX_ACCEPT_EXHAUSTION", "1")
            .status()
            .unwrap();

        assert!(status.success(), "Unix listener stopped after a recoverable accept error");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_server_shutdown_reports_listener_task_failure() {
        let directory = tempdir().unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "failed-unix-task", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("link.sock");
        let server = serve_unix(daemon, &socket, 65_535).await.unwrap();
        server.task.as_ref().unwrap().abort();

        let error = server.shutdown().await.unwrap_err();

        assert!(error.to_string().contains("Unix listener task failed"), "{error}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_server_shutdown_aborts_active_handlers() {
        let directory = tempdir().unwrap();
        let state = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(state.path(), "active-unix-shutdown", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("link.sock");
        let server = serve_unix(daemon, &socket, 65_535).await.unwrap();

        // A connected peer with no protocol prelude keeps daemon.accept in its
        // handshake read. JoinSet::shutdown must abort that handler.
        let _peer = tokio::net::UnixStream::connect(&socket).await.unwrap();
        tokio::task::yield_now().await;
        tokio::time::timeout(Duration::from_secs(1), server.shutdown())
            .await
            .expect("Unix shutdown hung with an active handler")
            .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_server_connection_admission_recovers_after_handlers_finish() {
        let directory = tempdir().unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "admission-unix", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("link.sock");
        let server = serve_unix(daemon, &socket, 65_535).await.unwrap();

        // Fill the bounded handler set, then close every peer. A later peer
        // must still be admitted after the finished handlers release permits.
        let mut peers = Vec::with_capacity(MAX_UNIX_CONNECTIONS);
        for _ in 0..MAX_UNIX_CONNECTIONS {
            peers.push(tokio::net::UnixStream::connect(&socket).await.unwrap());
        }
        drop(peers);
        tokio::time::sleep(Duration::from_millis(25)).await;
        let recovered = tokio::net::UnixStream::connect(&socket).await;
        assert!(recovered.is_ok(), "Unix admission did not recover: {recovered:?}");
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_server_drop_removes_socket_path() {
        let directory = tempdir().unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "drop-unix", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("link.sock");
        let server = serve_unix(daemon, &socket, 65_535).await.unwrap();
        assert!(socket.exists());
        drop(server);
        assert!(!socket.exists(), "dropping UnixServer left its socket path behind");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn serve_unix_accepts_private_owner_directory() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempdir().unwrap();
        let parent = directory.path().join("private");
        std::fs::create_dir(&parent).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "safe-unix-parent", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

        let server = serve_unix(daemon, parent.join("link.sock"), 65_535).await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unix_server_shutdown_never_unlinks_a_bound_successor() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("link.sock");
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "socket-successor", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let server = serve_unix(daemon, &path, 65_535).await.unwrap();

        std::fs::remove_file(&path).unwrap();
        let successor = UnixListener::bind(&path).unwrap();
        server.shutdown().await.unwrap();
        let successor_preserved = path.exists();
        let reachable =
            tokio::time::timeout(Duration::from_secs(1), tokio::net::UnixStream::connect(&path))
                .await
                .is_ok_and(|result| result.is_ok());
        drop(successor);
        let _ = std::fs::remove_file(&path);

        assert!(successor_preserved, "old Unix server unlinked its successor socket");
        assert!(reachable, "successor Unix socket was unreachable after old-server shutdown");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn serve_unix_rejects_sticky_world_writable_parent() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempdir().unwrap();
        let parent = directory.path().join("shared");
        std::fs::create_dir(&parent).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o1777)).unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "unsafe-unix-parent", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

        match serve_unix(daemon, parent.join("link.sock"), 65_535).await {
            Err(DaemonError::Protocol(message)) => {
                assert!(message.contains("socket directory"), "{message}");
            }
            Err(error) => panic!("unexpected error: {error}"),
            Ok(server) => {
                server.shutdown().await.unwrap();
                panic!("sticky world-writable socket parent was accepted");
            }
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn serve_unix_rejects_symlink_parent() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let real_parent = directory.path().join("real-parent");
        let linked_parent = directory.path().join("linked-parent");
        std::fs::create_dir(&real_parent).unwrap();
        symlink(&real_parent, &linked_parent).unwrap();
        let state = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(state.path(), "symlink-unix-parent", false).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

        match serve_unix(daemon, linked_parent.join("link.sock"), 65_535).await {
            Err(DaemonError::Protocol(message)) => {
                assert!(message.contains("socket directory"), "{message}");
            }
            Err(error) => panic!("unexpected error: {error}"),
            Ok(server) => {
                server.shutdown().await.unwrap();
                panic!("symlink socket parent was accepted");
            }
        }
        assert!(!real_parent.join("link.sock").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn serve_unix_rejects_an_intermediate_symlink_before_creating_the_parent() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        std::fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();
        let state = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(state.path(), "intermediate-symlink-parent", false)
            .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

        match serve_unix(daemon, alias.join("missing/link.sock"), 65_535).await {
            Err(DaemonError::Protocol(_)) => {}
            Err(error) => panic!("unexpected error: {error}"),
            Ok(server) => {
                server.shutdown().await.unwrap();
                panic!("intermediate symlink was accepted");
            }
        }
        assert!(!target.join("missing").exists());
    }
}
