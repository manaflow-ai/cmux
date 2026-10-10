use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use futures_util::stream::{FuturesUnordered, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock, oneshot, watch};

use crate::crypto::{
    ClientAuthMode, ClientHandshake, ConnectionAttemptId, CryptoError, StaticIdentity,
    initiate_secure_link,
};
use crate::link::{FrameLink, LaneMuxLink, LinkError, LinkRoute};
use crate::observability::{ClientConnectionSnapshot, ConnectionState};
use crate::provider::{LinkGroup, LinkRequest, ProviderError, lane_bindings};
use crate::session::{ReceivedFrame, ReliableSession, SessionError, SessionLimits};

const TERMINAL_CLOSE_SEND_TIMEOUT: Duration = Duration::from_secs(1);
const TERMINAL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone)]
pub struct ClientConnectionConfig {
    pub identity: StaticIdentity,
    pub expected_daemon: Option<[u8; 32]>,
    pub auth: ClientAuthMode,
    pub device_name: String,
    pub session: SessionId,
    pub lane_policy: LanePolicy,
    pub limits: SessionLimits,
    pub reconnect: ReconnectPolicy,
}

#[derive(Debug, Clone, Copy)]
pub struct ReconnectPolicy {
    pub initial_delay: Duration,
    pub maximum_delay: Duration,
    /// Bound one carrier reattachment, including authentication and replay.
    /// Also deadlines each link's prelude and Noise exchange on every dial,
    /// including an invitation dial whose overall budget is the much larger
    /// enrollment window, so an endpoint that accepts the transport and then
    /// never speaks fails instead of holding the connection open.
    pub attempt_timeout: Duration,
    /// Randomize each backoff uniformly between zero and its current ceiling.
    pub full_jitter: bool,
    /// `None` disables active liveness probes.
    pub heartbeat_interval: Option<Duration>,
    /// How long a heartbeat request may remain unanswered before reconnect.
    pub heartbeat_timeout: Duration,
    /// `None` retries until the client closes. A finite value is useful for
    /// one-shot agent commands that prefer a bounded failure time.
    pub maximum_attempts: Option<u32>,
    /// Bound the complete recovery window, including backoff and transport
    /// discovery. `None` is retained for callers that explicitly own a longer
    /// lived connection, but Cloud supplies a finite deadline.
    pub maximum_duration: Option<Duration>,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_millis(100),
            maximum_delay: Duration::from_secs(5),
            attempt_timeout: Duration::from_secs(15),
            full_jitter: true,
            heartbeat_interval: Some(Duration::from_secs(5)),
            heartbeat_timeout: Duration::from_secs(15),
            maximum_attempts: None,
            // Long-lived interactive links, including direct SSH sessions,
            // must keep retrying until their owner closes them. Callers that
            // run bounded one-shot work can opt into a recovery deadline.
            maximum_duration: None,
        }
    }
}

impl ReconnectPolicy {
    pub fn validate(self) -> Result<(), ConnectionError> {
        if self.initial_delay.is_zero()
            || self.maximum_delay < self.initial_delay
            || self.attempt_timeout.is_zero()
        {
            return Err(ConnectionError::Protocol(
                "reconnect delays and attempt timeout must be positive, with max delay at least initial"
                    .into(),
            ));
        }
        if self.maximum_attempts == Some(0) {
            return Err(ConnectionError::Protocol(
                "reconnect maximum attempts must be positive or unlimited".into(),
            ));
        }
        if self.maximum_duration.is_some_and(|duration| duration.is_zero()) {
            return Err(ConnectionError::Protocol(
                "reconnect maximum duration must be positive or unlimited".into(),
            ));
        }
        if self.heartbeat_interval.is_some_and(|interval| interval.is_zero())
            || (self.heartbeat_interval.is_some() && self.heartbeat_timeout.is_zero())
        {
            return Err(ConnectionError::Protocol(
                "heartbeat interval and timeout must be positive when heartbeats are enabled"
                    .into(),
            ));
        }
        Ok(())
    }

    /// Applies this policy's jitter setting to the current backoff ceiling.
    pub fn retry_delay(self, ceiling: Duration) -> Duration {
        jittered_delay(ceiling, self.full_jitter)
    }
}

/// Supplies a fresh transport group after the current route fails. The
/// authentication/session layer stays above this interface, so cycling from a
/// direct socket to Iroh or a relay cannot change daemon authority.
#[async_trait]
pub trait ReconnectGroupSource: Send + Sync {
    /// Bounds transport discovery separately from carrier authentication and
    /// replay. Sources with one-time setup may extend this deadline without
    /// slowing the ordinary reconnect path.
    fn resolution_timeout(&self, reconnect_attempt_timeout: Duration) -> Duration {
        reconnect_attempt_timeout
    }

    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError>;
}

pub struct ClientConnection {
    config: ClientConnectionConfig,
    group: Arc<RwLock<Arc<dyn LinkGroup>>>,
    reconnect_groups: Option<Arc<dyn ReconnectGroupSource>>,
    session: Arc<RwLock<ReliableSession>>,
    generation: watch::Sender<u64>,
    diagnostics: StdMutex<ClientConnectionSnapshot>,
    next_generation: AtomicU64,
    daemon_public_key: [u8; 32],
    reconnecting: Arc<Mutex<()>>,
    lane_sends: [Mutex<()>; 4],
    receiving: Mutex<()>,
    /// Linearizes shutdown start with the short reconnect publication window.
    /// Reconnect attempts do not hold this gate while dialing or replaying.
    shutdown_gate: Mutex<()>,
    deferred_receive: StdMutex<Option<Result<ReceivedFrame, ConnectionError>>>,
    last_received: StdMutex<Instant>,
    closed: AtomicBool,
    close_state: watch::Sender<CloseState>,
}

#[derive(Clone, Debug)]
enum CloseState {
    Pending,
    /// Shutdown has started, but the cleanup task has not published its
    /// terminal result yet. Background work uses this transition as its
    /// cancellation signal; callers still wait for `Complete` or `Failed`.
    Started,
    Complete,
    Failed(CloseFailure),
}

#[derive(Clone, Debug)]
enum CloseFailure {
    ShutdownTimedOut,
    Other(Arc<str>),
}

impl CloseFailure {
    fn from_error(error: &ConnectionError) -> Self {
        match error {
            ConnectionError::ShutdownTimedOut => Self::ShutdownTimedOut,
            _ => Self::Other(error.to_string().into()),
        }
    }

    fn to_error(&self) -> ConnectionError {
        match self {
            Self::ShutdownTimedOut => ConnectionError::ShutdownTimedOut,
            Self::Other(message) => {
                ConnectionError::Protocol(format!("previous connection shutdown failed: {message}"))
            }
        }
    }
}

struct CloseCompletionGuard {
    state: watch::Sender<CloseState>,
    published: bool,
}

impl CloseCompletionGuard {
    fn new(state: watch::Sender<CloseState>) -> Self {
        Self { state, published: false }
    }

    fn publish(mut self, state: CloseState) {
        self.state.send_replace(state);
        self.published = true;
    }
}

impl Drop for CloseCompletionGuard {
    fn drop(&mut self) {
        if !self.published {
            self.state.send_replace(CloseState::Failed(CloseFailure::Other(
                "connection shutdown task stopped".into(),
            )));
        }
    }
}

impl fmt::Debug for ClientConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ClientConnection")
            .field("session", &self.config.session)
            .field("lane_policy", &self.config.lane_policy)
            .field(
                "daemon_fingerprint",
                &crate::crypto::public_key_fingerprint(&self.daemon_public_key),
            )
            .finish_non_exhaustive()
    }
}

impl ClientConnection {
    pub async fn connect(
        group: Arc<dyn LinkGroup>,
        config: ClientConnectionConfig,
    ) -> Result<Arc<Self>, ConnectionError> {
        Self::connect_with_reconnect_groups(group, config, None).await
    }

    pub async fn connect_with_reconnect_groups(
        group: Arc<dyn LinkGroup>,
        config: ClientConnectionConfig,
        reconnect_groups: Option<Arc<dyn ReconnectGroupSource>>,
    ) -> Result<Arc<Self>, ConnectionError> {
        config.reconnect.validate()?;
        let (link, daemon_public_key, _) =
            establish_physical_links(group.clone(), &config, 0, BTreeMap::new()).await?;
        let session = ReliableSession::new(config.session, Arc::new(link), config.limits);
        let (generation, _) = watch::channel(session.generation());
        let lane_bindings = lane_bindings(config.lane_policy, group.capabilities());
        let transport = group.transport_snapshot().await;
        let diagnostics = ClientConnectionSnapshot {
            session_id: format!("{:?}", config.session),
            generation: session.generation(),
            state: ConnectionState::Connected,
            physical_link_count: lane_bindings.len(),
            lane_bindings,
            transport,
        };
        let (close_state, _) = watch::channel(CloseState::Pending);
        let connection = Arc::new(Self {
            config,
            group: Arc::new(RwLock::new(group)),
            reconnect_groups,
            session: Arc::new(RwLock::new(session)),
            generation,
            diagnostics: StdMutex::new(diagnostics),
            next_generation: AtomicU64::new(1),
            daemon_public_key,
            reconnecting: Arc::new(Mutex::new(())),
            lane_sends: std::array::from_fn(|_| Mutex::new(())),
            receiving: Mutex::new(()),
            shutdown_gate: Mutex::new(()),
            deferred_receive: StdMutex::new(None),
            last_received: StdMutex::new(Instant::now()),
            closed: AtomicBool::new(false),
            close_state,
        });
        Self::spawn_heartbeat(&connection);
        Ok(connection)
    }

    pub fn session_id(&self) -> SessionId {
        self.config.session
    }

    pub fn daemon_public_key(&self) -> [u8; 32] {
        self.daemon_public_key
    }

    pub fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    /// Returns a consistent, credential-free view of the last published
    /// transport. Reconnect replay holds the group and session publication
    /// locks, so generation and topology are cached separately and never wait
    /// for them. When the group is available, refresh its non-blocking live
    /// path snapshot so provider path migration remains observable.
    pub async fn snapshot(&self) -> ClientConnectionSnapshot {
        let group = match self.group.try_read() {
            Ok(group) => group.clone(),
            Err(_) => {
                return self
                    .diagnostics
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone();
            }
        };
        let observed_generation =
            self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner).generation;
        let transport = group.transport_snapshot().await;
        let Ok(active_group) = self.group.try_read() else {
            return self
                .diagnostics
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone();
        };
        if !Arc::ptr_eq(&active_group, &group) {
            return self
                .diagnostics
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone();
        }
        let mut diagnostics =
            self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if diagnostics.generation == observed_generation {
            diagnostics.transport = transport;
        }
        diagnostics.clone()
    }

    fn set_diagnostics_state(&self, state: ConnectionState) {
        let mut diagnostics =
            self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // `close` publishes the atomic flag before waiting for this mutex. A
        // reconnect that passed an earlier open check must not overwrite the
        // terminal state after close wins the race.
        if state == ConnectionState::Closed || !self.closed.load(Ordering::Acquire) {
            diagnostics.state = state;
        }
    }

    fn diagnostics_state(&self) -> ConnectionState {
        self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner).state
    }

    pub async fn send(
        &self,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ConnectionError> {
        self.send_in_generation(None, lane, stream, payload, flags).await
    }

    pub(crate) async fn send_in_generation(
        &self,
        expected_generation: Option<u64>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ConnectionError> {
        let _lane = self.lane_sends[lane as usize].lock().await;
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            let session = self.session.read().await.clone();
            let generation = session.generation();
            if let Some(expected) = expected_generation
                && expected != generation
            {
                return Err(ConnectionError::GenerationChanged { expected, actual: generation });
            }
            let sequence = session.next_outbound_sequence(lane);
            match session.send_with_backpressure(lane, stream, payload.clone(), flags).await {
                Ok(sequence) => return Ok(sequence),
                Err(SessionError::StaleGeneration { expected: actual, .. }) => {
                    if let Some(expected) = expected_generation {
                        return Err(ConnectionError::GenerationChanged { expected, actual });
                    }
                    if !lane.replays_across_generations() {
                        return Err(ConnectionError::GenerationChanged {
                            expected: generation,
                            actual,
                        });
                    }
                    continue;
                }
                Err(error) if reconnectable_session_error(&error) => {
                    self.recover(generation).await?;
                    let actual = self.session.read().await.generation();
                    if expected_generation.is_some() || !lane.replays_across_generations() {
                        return Err(ConnectionError::GenerationChanged {
                            expected: expected_generation.unwrap_or(generation),
                            actual,
                        });
                    }
                    // Replayable traffic was retained and recovery sent it
                    // with the original sequence on the new generation.
                    return Ok(sequence);
                }
                Err(error) => {
                    session.rollback_unscheduled(lane, sequence);
                    return Err(error.into());
                }
            }
        }
    }

    pub async fn receive(&self) -> Result<Option<ReceivedFrame>, ConnectionError> {
        let _receiving = self.receiving.lock().await;
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Ok(None);
            }
            if let Some(received) = self
                .deferred_receive
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                return received.map(Some);
            }
            let session = self.session.read().await.clone();
            let generation = session.generation();
            match session.receive().await {
                Ok(Some(frame)) => {
                    self.mark_received();
                    if frame.flags.contains(FrameFlags::HEARTBEAT_RESPONSE) {
                        continue;
                    }
                    if frame.flags.contains(FrameFlags::HEARTBEAT_REQUEST) {
                        self.send(Lane::Control, 0, Bytes::new(), FrameFlags::HEARTBEAT_RESPONSE)
                            .await?;
                        continue;
                    }
                    return Ok(Some(frame));
                }
                Err(SessionError::StaleGeneration { .. }) => continue,
                Ok(None) => self.recover(generation).await?,
                Err(error) if reconnectable_session_error(&error) => {
                    self.recover(generation).await?;
                }
                Err(error) => return Err(error.into()),
            }
        }
    }

    /// Drive one idle receive while no application reader owns the session.
    /// Heartbeat control frames are consumed internally. At most one
    /// application frame or terminal error is deferred, which keeps liveness
    /// independent of caller polling without creating an unbounded side queue.
    async fn probe_liveness(&self, generation: u64, observed: Instant) -> bool {
        let _receiving = self.receiving.lock().await;
        if self.closed.load(Ordering::Acquire)
            || self.session.read().await.generation() != generation
            || self.last_received() > observed
        {
            return true;
        }
        if self.deferred_receive.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
        {
            // The application is applying receive backpressure. Do not mistake
            // that local condition for a dead carrier.
            return true;
        }
        let session = self.session.read().await.clone();
        if session.generation() != generation {
            return true;
        }
        match session.receive().await {
            Ok(Some(frame)) => {
                self.mark_received();
                if frame.flags.contains(FrameFlags::HEARTBEAT_RESPONSE) {
                    return true;
                }
                if frame.flags.contains(FrameFlags::HEARTBEAT_REQUEST) {
                    return self
                        .send_in_generation(
                            Some(generation),
                            Lane::Control,
                            0,
                            Bytes::new(),
                            FrameFlags::HEARTBEAT_RESPONSE,
                        )
                        .await
                        .is_ok();
                }
                *self.deferred_receive.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some(Ok(frame));
                true
            }
            Err(SessionError::StaleGeneration { .. }) => true,
            Ok(None) => false,
            Err(error) if reconnectable_session_error(&error) => false,
            Err(error) => {
                *self.deferred_receive.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some(Err(error.into()));
                true
            }
        }
    }

    /// Acquire the single reconnect owner while remaining interruptible by
    /// shutdown. A Tokio mutex queues waiters, so subscribing before the lock
    /// avoids making a waiter sit behind cleanup after close has started.
    async fn lock_reconnecting(
        &self,
        close_state: &mut watch::Receiver<CloseState>,
    ) -> Result<tokio::sync::OwnedMutexGuard<()>, ConnectionError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        let lock = self.reconnecting.clone().lock_owned();
        tokio::pin!(lock);
        tokio::select! {
            biased;
            _ = close_state.changed() => Err(ConnectionError::Closed),
            guard = &mut lock => {
                if self.closed.load(Ordering::Acquire) {
                    drop(guard);
                    Err(ConnectionError::Closed)
                } else {
                    Ok(guard)
                }
            }
        }
    }

    /// Replace a failed provider group while preserving reliable application
    /// sequence numbers and replaying only frames the daemon did not ack.
    pub async fn reconnect(&self, group: Arc<dyn LinkGroup>) -> Result<(), ConnectionError> {
        let mut close_state = self.close_state.subscribe();
        let _reconnecting = self.lock_reconnecting(&mut close_state).await?;
        let previous_state = self.diagnostics_state();
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = tokio::select! {
            biased;
            _ = close_state.changed() => Err(ConnectionError::Closed),
            result = self.reconnect_once(group) => result,
        };
        // Explicit route replacement preserves the previously published
        // carrier when setup or replay of the candidate fails.
        if !self.closed.load(Ordering::Acquire) {
            self.set_diagnostics_state(if result.is_ok() {
                ConnectionState::Connected
            } else {
                previous_state
            });
        }
        result
    }

    async fn reconnect_once(&self, group: Arc<dyn LinkGroup>) -> Result<(), ConnectionError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        let current = self.session.read().await.clone();
        // Allocate, rather than derive, the generation. A timed-out or
        // cancelled attempt may already have committed remotely. Burning its
        // number lets the next attempt move both peers forward instead of
        // retrying a generation the daemon now considers stale.
        let generation = self
            .next_generation
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |generation| {
                generation.checked_add(1)
            })
            .map_err(|_| ConnectionError::GenerationExhausted)?;
        let mut reconnect_config = self.config.clone();
        reconnect_config.expected_daemon = Some(self.daemon_public_key);
        reconnect_config.auth = match reconnect_config.auth {
            ClientAuthMode::Invitation { .. } => ClientAuthMode::Enrolled,
            other => other,
        };
        let (link, daemon_key, daemon_resume) = establish_physical_links(
            group.clone(),
            &reconnect_config,
            generation,
            current.resume_cursors(),
        )
        .await?;
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        if daemon_key != self.daemon_public_key {
            return Err(ConnectionError::Crypto(CryptoError::DaemonKeyMismatch {
                expected: crate::crypto::public_key_fingerprint(&self.daemon_public_key),
                actual: crate::crypto::public_key_fingerprint(&daemon_key),
            }));
        }
        let lane_bindings = lane_bindings(self.config.lane_policy, group.capabilities());
        let physical_link_count = lane_bindings.len();
        let transport = group.transport_snapshot().await;
        // Keep the connection publication locks while preparing the candidate,
        // but do not mutate shared reliability state until shutdown owns the
        // publication gate below. A dropped preparation therefore leaves the
        // old session fully usable.
        let mut active_group = self.group.write().await;
        let mut active_session = self.session.write().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        if active_session.generation() != current.generation() {
            return Err(ConnectionError::GenerationChanged {
                expected: current.generation(),
                actual: active_session.generation(),
            });
        }
        let prepared =
            current.prepare_reconnect_to(Arc::new(link), &daemon_resume, generation).await?;
        // The transaction has not changed shared reliability state yet. Once
        // this gate is acquired, `commit` and all wrapper publication below
        // contain no await points, so close cannot observe a half-published
        // generation and cancellation cannot strand one.
        let shutdown_gate = self.shutdown_gate.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        let next = prepared.commit()?;
        let generation = next.generation();
        let previous = std::mem::replace(&mut *active_group, group.clone());
        *active_session = next;
        self.mark_received();
        self.generation.send_replace(generation);
        {
            let mut diagnostics =
                self.diagnostics.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            diagnostics.generation = generation;
            diagnostics.lane_bindings = lane_bindings;
            diagnostics.physical_link_count = physical_link_count;
            diagnostics.transport = transport;
            // Generation, topology, and Connected form one committed
            // diagnostic snapshot. The best-effort retirement of the old
            // carrier below is cancellation-sensitive, so an aborted caller
            // must not leave a fully published replacement labeled as
            // Reconnecting forever.
            if !self.closed.load(Ordering::Acquire) {
                diagnostics.state = ConnectionState::Connected;
            }
        }
        drop(shutdown_gate);
        drop(active_session);
        drop(active_group);
        // Publishing the replacement first lets blocked readers recover onto
        // it when closing the prior carrier wakes them. The provider group may
        // be reused across generations, so close the old session link even
        // when the group identity did not change. Keep this bounded retirement
        // in an owned task. If the caller is cancelled after publication, the
        // dropped JoinHandle detaches a task that still owns both old carriers
        // and closes them instead of leaking the displaced group.
        let close_previous_group = !Arc::ptr_eq(&previous, &group);
        let retirement = tokio::spawn(async move {
            let _ = tokio::time::timeout(TERMINAL_SHUTDOWN_TIMEOUT, async {
                if close_previous_group {
                    let _ = tokio::join!(current.close(), previous.close());
                } else {
                    let _ = current.close().await;
                }
            })
            .await;
        });
        let _ = retirement.await;
        Ok(())
    }

    fn mark_received(&self) {
        *self.last_received.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Instant::now();
    }

    fn last_received(&self) -> Instant {
        *self.last_received.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn spawn_heartbeat(connection: &Arc<Self>) {
        let Some(interval) = connection.config.reconnect.heartbeat_interval else { return };
        let timeout = connection.config.reconnect.heartbeat_timeout;
        let weak = Arc::downgrade(connection);
        tokio::spawn(run_heartbeat(weak, interval, timeout));
    }

    async fn recover(&self, observed_generation: u64) -> Result<(), ConnectionError> {
        let mut close_state = self.close_state.subscribe();
        let _reconnecting = self.lock_reconnecting(&mut close_state).await?;
        if self.session.read().await.generation() != observed_generation {
            return Ok(());
        }
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = self.recover_locked(&mut close_state).await;
        if result.is_err() && !self.closed.load(Ordering::Acquire) {
            self.set_diagnostics_state(ConnectionState::Disconnected);
        }
        result
    }

    async fn recover_locked(
        &self,
        close_state: &mut watch::Receiver<CloseState>,
    ) -> Result<(), ConnectionError> {
        let mut attempt = 0_u32;
        let mut delay = self.config.reconnect.initial_delay;
        let recovery_deadline = match self.config.reconnect.maximum_duration {
            Some(duration) => {
                Some(tokio::time::Instant::now().checked_add(duration).ok_or_else(|| {
                    ConnectionError::Protocol(
                        "reconnect maximum duration cannot be represented".into(),
                    )
                })?)
            }
            None => None,
        };
        let mut group = self.group.read().await.clone();
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            attempt = attempt.saturating_add(1);
            if recovery_deadline.is_some_and(|deadline| tokio::time::Instant::now() >= deadline) {
                return Err(ConnectionError::ReconnectDeadlineExceeded {
                    attempts: attempt.saturating_sub(1),
                });
            }
            let attempt_timeout = recovery_deadline
                .map(|deadline| {
                    self.config
                        .reconnect
                        .attempt_timeout
                        .min(deadline.saturating_duration_since(tokio::time::Instant::now()))
                })
                .unwrap_or(self.config.reconnect.attempt_timeout);
            let reconnect = tokio::select! {
                biased;
                _ = close_state.changed() => return Err(ConnectionError::Closed),
                reconnect = tokio::time::timeout(attempt_timeout, self.reconnect_once(group.clone())) => reconnect,
            };
            let result = match reconnect {
                Ok(result) => result,
                Err(_) => Err(
                    if recovery_deadline
                        .is_some_and(|deadline| tokio::time::Instant::now() >= deadline)
                    {
                        ConnectionError::ReconnectDeadlineExceeded { attempts: attempt }
                    } else {
                        ConnectionError::ReconnectAttemptTimedOut {
                            timeout: self.config.reconnect.attempt_timeout,
                        }
                    },
                ),
            };
            if self.closed.load(Ordering::Acquire) && result.is_ok() {
                return Err(ConnectionError::Closed);
            }
            match result {
                Ok(()) => {
                    if !self.closed.load(Ordering::Acquire) {
                        self.set_diagnostics_state(ConnectionState::Connected);
                    }
                    return Ok(());
                }
                Err(error) if retryable_connection_error(&error) => {
                    if self
                        .config
                        .reconnect
                        .maximum_attempts
                        .is_some_and(|maximum| attempt >= maximum)
                    {
                        return Err(ConnectionError::ReconnectExhausted {
                            attempts: attempt,
                            last: error.to_string(),
                        });
                    }
                    if let Some(source) = &self.reconnect_groups {
                        let next = tokio::select! {
                            biased;
                            _ = close_state.changed() => return Err(ConnectionError::Closed),
                            next = async {
                                if let Some(deadline) = recovery_deadline
                                    && tokio::time::Instant::now() >= deadline
                                {
                                    return None;
                                }
                                let timeout = recovery_deadline
                                    .map(|deadline| self.config.reconnect.attempt_timeout.min(deadline.saturating_duration_since(tokio::time::Instant::now())))
                                    .unwrap_or(self.config.reconnect.attempt_timeout);
                                let discovery = resolve_reconnect_group(
                                    source.as_ref(), self.config.reconnect.attempt_timeout,
                                );
                                match recovery_deadline {
                                    Some(deadline) => tokio::time::timeout_at(deadline, discovery).await.unwrap_or(None),
                                    None => tokio::time::timeout(timeout, discovery).await.unwrap_or(None),
                                }
                            } => next,
                        };
                        if let Some(next) = next {
                            group = next;
                        }
                    }
                    let retry_delay = self.config.reconnect.retry_delay(delay);
                    let retry_delay = recovery_deadline
                        .map(|deadline| {
                            retry_delay.min(
                                deadline.saturating_duration_since(tokio::time::Instant::now()),
                            )
                        })
                        .unwrap_or(retry_delay);
                    tokio::select! {
                        biased;
                        _ = tokio::time::sleep(retry_delay) => {}
                        _ = close_state.changed() => return Err(ConnectionError::Closed),
                    }
                    delay = (delay * 2).min(self.config.reconnect.maximum_delay);
                }
                Err(error) => return Err(error),
            }
        }
    }

    pub async fn close(&self) -> Result<(), ConnectionError> {
        // Acquire the short publication gate before making shutdown visible.
        // A reconnect that already owns it finishes publishing first; one
        // that has not reached publication observes `closed` and aborts.
        let shutdown_gate = self.shutdown_gate.lock().await;
        if self.closed.swap(true, Ordering::AcqRel) {
            drop(shutdown_gate);
            return wait_for_close(self.close_state.subscribe()).await;
        }
        // Publish shutdown intent before taking any cleanup locks. Reconnect
        // and heartbeat tasks may be blocked in transport futures for a long
        // time, so waiting only for the eventual terminal state would leave
        // them alive after the caller has requested close.
        self.close_state.send_replace(CloseState::Started);
        drop(shutdown_gate);
        self.set_diagnostics_state(ConnectionState::Closed);
        // The cleanup task owns every lock needed to snapshot the final carrier.
        // It therefore survives cancellation of this caller after `closed` is
        // published, while reconnect observes `closed` and releases its lock.
        let reconnecting = self.reconnecting.clone();
        let session = self.session.clone();
        let group = self.group.clone();
        let close_complete = CloseCompletionGuard::new(self.close_state.clone());
        let (result_tx, result_rx) = oneshot::channel();
        tokio::spawn(async move {
            let _close_complete = close_complete;
            let result: Result<(), ConnectionError> = async {
                // A reconnect publishes its group and session while holding this
                // lock. Snapshotting afterward prevents a fresh carrier from
                // escaping shutdown behind an old snapshot.
                let _reconnecting = reconnecting.lock().await;
                let session = session.read().await.clone();
                // This authenticated frame releases daemon replay state early.
                // Delivery remains best effort because lease expiry is the
                // fallback when the carrier is already broken.
                let _ = tokio::time::timeout(
                    TERMINAL_CLOSE_SEND_TIMEOUT,
                    session.send(Lane::Control, 0, Bytes::new(), FrameFlags::SESSION_CLOSE),
                )
                .await;
                let group = group.read().await.clone();
                tokio::time::timeout(TERMINAL_SHUTDOWN_TIMEOUT, async move {
                    let (session_close, group_close) = tokio::join!(session.close(), group.close());
                    session_close?;
                    group_close?;
                    Ok(())
                })
                .await
                .map_err(|_| ConnectionError::ShutdownTimedOut)?
            }
            .await;
            let outcome = match &result {
                Ok(()) => CloseState::Complete,
                Err(error) => CloseState::Failed(CloseFailure::from_error(error)),
            };
            _close_complete.publish(outcome);
            let _ = result_tx.send(result);
        });
        match result_rx.await {
            Ok(result) => result,
            Err(_) => wait_for_close(self.close_state.subscribe()).await,
        }
    }
}

async fn resolve_reconnect_group(
    source: &dyn ReconnectGroupSource,
    reconnect_attempt_timeout: Duration,
) -> Option<Arc<dyn LinkGroup>> {
    tokio::time::timeout(source.resolution_timeout(reconnect_attempt_timeout), source.next_group())
        .await
        .ok()?
        .ok()
}

async fn wait_for_close(mut state: watch::Receiver<CloseState>) -> Result<(), ConnectionError> {
    loop {
        match state.borrow().clone() {
            CloseState::Pending | CloseState::Started => {}
            CloseState::Complete => return Ok(()),
            CloseState::Failed(failure) => return Err(failure.to_error()),
        }
        state
            .changed()
            .await
            .map_err(|_| ConnectionError::Protocol("connection shutdown state stopped".into()))?;
    }
}

async fn run_heartbeat(weak: Weak<ClientConnection>, interval: Duration, timeout: Duration) {
    let Some(initial) = weak.upgrade() else { return };
    let mut close_state = initial.close_state.subscribe();
    // A new watch receiver considers the current value seen. The atomic flag
    // closes the gap when shutdown started immediately before subscription.
    if initial.closed.load(Ordering::Acquire) {
        return;
    }
    drop(initial);
    loop {
        tokio::select! {
            biased;
            _ = tokio::time::sleep(interval) => {}
            _ = close_state.changed() => return,
        }
        let Some(connection) = weak.upgrade() else { return };
        if connection.closed.load(Ordering::Acquire) {
            return;
        }
        if connection
            .deferred_receive
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            // The consumer must drain its deferred frame before another probe
            // can be observed without expanding local buffering.
            continue;
        }
        let observed = connection.last_received();
        let generation = connection.session.read().await.generation();
        let deadline = tokio::time::Instant::now() + timeout;
        let send = connection.send_in_generation(
            Some(generation),
            Lane::Control,
            0,
            Bytes::new(),
            FrameFlags::HEARTBEAT_REQUEST,
        );
        let send_result = tokio::select! {
            biased;
            result = tokio::time::timeout_at(deadline, send) => result,
            _ = close_state.changed() => return,
        };
        match send_result {
            Ok(Ok(_)) => {}
            Ok(Err(_)) => continue,
            Err(_) => {
                let _ = connection.recover(generation).await;
                continue;
            }
        }
        let live = tokio::select! {
            biased;
            result = tokio::time::timeout_at(deadline, connection.probe_liveness(generation, observed)) => result.unwrap_or(false),
            _ = close_state.changed() => return,
        };
        if connection.closed.load(Ordering::Acquire)
            || connection.session.read().await.generation() != generation
        {
            continue;
        }
        if !live && connection.last_received() <= observed {
            let _ = connection.recover(generation).await;
        }
    }
}

fn jittered_delay(ceiling: Duration, full_jitter: bool) -> Duration {
    if !full_jitter {
        return ceiling;
    }
    let mut random = [0_u8; 8];
    if getrandom::fill(&mut random).is_err() {
        return ceiling;
    }
    let fraction = u64::from_be_bytes(random) as f64 / u64::MAX as f64;
    ceiling.mul_f64(fraction)
}

async fn establish_physical_links(
    group: Arc<dyn LinkGroup>,
    config: &ClientConnectionConfig,
    generation: u64,
    resume: BTreeMap<Lane, u64>,
) -> Result<(LaneMuxLink, [u8; 32], BTreeMap<Lane, u64>), ConnectionError> {
    let mut connection_attempt = [0_u8; 16];
    getrandom::fill(&mut connection_attempt)
        .map_err(|error| ConnectionError::Crypto(CryptoError::Random(error.to_string())))?;
    let connection_attempt = ConnectionAttemptId(connection_attempt);
    let bindings = lane_bindings(config.lane_policy, group.capabilities());
    let first_lanes = bindings.first().expect("lane bindings are never empty").clone();
    let (_, first, daemon_resume) = authenticate_one(
        group.clone(),
        config,
        config.auth.clone(),
        first_lanes.clone(),
        resume.clone(),
        LinkHandshakeContext {
            generation,
            expected_daemon: config.expected_daemon,
            connection_attempt,
        },
    )
    .await?;
    let daemon_key = first.remote_static();
    let mut routes = vec![LinkRoute { lanes: first_lanes, link: Arc::new(first) }];

    let subsequent_auth = match config.auth {
        ClientAuthMode::Invitation { .. } => ClientAuthMode::Enrolled,
        ref other => other.clone(),
    };
    let mut pending = FuturesUnordered::new();
    for lanes in bindings.into_iter().skip(1) {
        pending.push(authenticate_one(
            group.clone(),
            config,
            subsequent_auth.clone(),
            lanes,
            resume.clone(),
            LinkHandshakeContext {
                generation,
                expected_daemon: Some(daemon_key),
                connection_attempt,
            },
        ));
    }
    while let Some(result) = pending.next().await {
        let (lanes, link, link_resume) = result?;
        if link_resume != daemon_resume {
            return Err(ConnectionError::Protocol(
                "daemon reported inconsistent resume cursors across lane links".into(),
            ));
        }
        routes.push(LinkRoute { lanes, link: Arc::new(link) });
    }
    let link = LaneMuxLink::new(format!("lanes+{}", group.description()), routes)?;
    Ok((link, daemon_key, daemon_resume))
}

#[derive(Clone, Copy)]
struct LinkHandshakeContext {
    generation: u64,
    expected_daemon: Option<[u8; 32]>,
    connection_attempt: ConnectionAttemptId,
}

async fn authenticate_one(
    group: Arc<dyn LinkGroup>,
    config: &ClientConnectionConfig,
    auth: ClientAuthMode,
    lanes: Vec<Lane>,
    resume: BTreeMap<Lane, u64>,
    context: LinkHandshakeContext,
) -> Result<(Vec<Lane>, crate::crypto::SecureLink, BTreeMap<Lane, u64>), ConnectionError> {
    let primary = lanes[0];
    let physical =
        group.open(LinkRequest { lane: primary, generation: context.generation }).await?;
    let secure = initiate_secure_link(
        physical,
        ClientHandshake {
            identity: config.identity.clone(),
            expected_daemon: context.expected_daemon,
            auth,
            device_name: config.device_name.clone(),
            session: config.session,
            lane: primary,
            lanes: lanes.clone(),
            generation: context.generation,
            connection_attempt: context.connection_attempt,
            resume,
            handshake_timeout: config.reconnect.attempt_timeout,
        },
    )
    .await?;
    let ready = match receive_control::<LinkHandshakeResponse>(&secure).await? {
        LinkHandshakeResponse::Ready(ready) => ready,
        LinkHandshakeResponse::Rejected(LinkRejected {
            rejected: LinkRejection::SessionUnavailable,
        }) => {
            return Err(ConnectionError::Protocol(
                "daemon no longer has the requested logical session".into(),
            ));
        }
    };
    if ready.session != config.session || ready.generation != context.generation {
        return Err(ConnectionError::Protocol(
            "daemon link-ready metadata does not match the requested session".into(),
        ));
    }
    Ok((lanes, secure, ready.daemon_resume))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct LinkReady {
    session: SessionId,
    generation: u64,
    daemon_resume: BTreeMap<Lane, u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
enum LinkHandshakeResponse {
    Ready(LinkReady),
    Rejected(LinkRejected),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LinkRejected {
    rejected: LinkRejection,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum LinkRejection {
    SessionUnavailable,
}

pub(crate) async fn send_link_ready(
    link: &dyn FrameLink,
    session: SessionId,
    generation: u64,
    daemon_resume: BTreeMap<Lane, u64>,
) -> Result<(), ConnectionError> {
    let payload = serde_json::to_vec(&LinkReady { session, generation, daemon_resume })
        .map_err(|error| ConnectionError::Protocol(error.to_string()))?;
    link.send(Bytes::from(payload)).await?;
    Ok(())
}

pub(crate) async fn send_link_rejection(
    link: &dyn FrameLink,
    rejection: LinkRejection,
) -> Result<(), ConnectionError> {
    let payload = serde_json::to_vec(&LinkRejected { rejected: rejection })
        .map_err(|error| ConnectionError::Protocol(error.to_string()))?;
    link.send(Bytes::from(payload)).await?;
    Ok(())
}

async fn receive_control<T: for<'de> Deserialize<'de>>(
    link: &dyn FrameLink,
) -> Result<T, ConnectionError> {
    let payload = link.receive().await?.ok_or(LinkError::Closed)?;
    serde_json::from_slice(&payload).map_err(|error| ConnectionError::Protocol(error.to_string()))
}

#[derive(Debug)]
pub enum ConnectionError {
    Provider(ProviderError),
    Crypto(CryptoError),
    Link(LinkError),
    Session(SessionError),
    Protocol(String),
    GenerationExhausted,
    GenerationChanged { expected: u64, actual: u64 },
    ReconnectExhausted { attempts: u32, last: String },
    ReconnectAttemptTimedOut { timeout: Duration },
    ReconnectDeadlineExceeded { attempts: u32 },
    ShutdownTimedOut,
    Closed,
}

impl ConnectionError {
    /// Whether the error represents an unavailable carrier rather than a
    /// rejected identity, invalid configuration, or protocol violation.
    pub fn is_retryable_carrier_failure(&self) -> bool {
        match self {
            Self::Provider(error) => error.is_retryable_carrier_failure(),
            Self::Crypto(CryptoError::LinkError(LinkError::Closed | LinkError::Transport(_)))
            | Self::Crypto(CryptoError::UnexpectedEof)
            | Self::Crypto(CryptoError::HandshakeTimeout { .. })
            | Self::Link(LinkError::Closed | LinkError::Transport(_))
            | Self::Session(SessionError::Link(LinkError::Closed | LinkError::Transport(_)))
            | Self::Session(SessionError::LinkMessage(_))
            | Self::Session(SessionError::SchedulerClosed)
            | Self::ReconnectAttemptTimedOut { .. } => true,
            _ => false,
        }
    }
}

impl fmt::Display for ConnectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Provider(error) => error.fmt(formatter),
            Self::Crypto(error) => error.fmt(formatter),
            Self::Link(error) => error.fmt(formatter),
            Self::Session(error) => error.fmt(formatter),
            Self::Protocol(message) => write!(formatter, "connection protocol failed: {message}"),
            Self::GenerationExhausted => formatter.write_str("connection generation exhausted"),
            Self::GenerationChanged { expected, actual } => {
                write!(formatter, "connection generation changed from {expected} to {actual}")
            }
            Self::ReconnectExhausted { attempts, last } => {
                write!(formatter, "reconnect failed after {attempts} attempts: {last}")
            }
            Self::ReconnectAttemptTimedOut { timeout } => {
                write!(formatter, "reconnect attempt timed out after {}ms", timeout.as_millis())
            }
            Self::ReconnectDeadlineExceeded { attempts } => {
                write!(formatter, "reconnect deadline expired after {attempts} attempts")
            }
            Self::ShutdownTimedOut => formatter.write_str("connection shutdown timed out"),
            Self::Closed => formatter.write_str("connection is closed"),
        }
    }
}

fn reconnectable_session_error(error: &SessionError) -> bool {
    matches!(
        error,
        SessionError::Link(LinkError::Closed | LinkError::Transport(_))
            | SessionError::LinkMessage(_)
            | SessionError::SchedulerClosed
    )
}

fn retryable_connection_error(error: &ConnectionError) -> bool {
    error.is_retryable_carrier_failure()
}

impl std::error::Error for ConnectionError {}

impl From<ProviderError> for ConnectionError {
    fn from(error: ProviderError) -> Self {
        Self::Provider(error)
    }
}

impl From<CryptoError> for ConnectionError {
    fn from(error: CryptoError) -> Self {
        Self::Crypto(error)
    }
}

impl From<LinkError> for ConnectionError {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

impl From<SessionError> for ConnectionError {
    fn from(error: SessionError) -> Self {
        Self::Session(error)
    }
}
