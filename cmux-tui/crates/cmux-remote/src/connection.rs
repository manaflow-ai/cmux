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

    /// Replace a failed provider group while preserving reliable application
    /// sequence numbers and replaying only frames the daemon did not ack.
    pub async fn reconnect(&self, group: Arc<dyn LinkGroup>) -> Result<(), ConnectionError> {
        let _reconnecting = self.reconnecting.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        let previous_state = self.diagnostics_state();
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = self.reconnect_once(group).await;
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
        // Take both publication guards before the cancellation-sensitive replay
        // transition. ReliableSession commits only after replay succeeds, and
        // there is no await between that commit and publishing both wrappers.
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
        let next = current.reconnect_to(Arc::new(link), &daemon_resume, generation).await?;
        // Shutdown takes this gate before publishing its start signal. This
        // gives reconnect publication and shutdown a clear linearization
        // point without holding the gate across dialing or replay.
        let _shutdown_gate = self.shutdown_gate.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
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
        drop(_shutdown_gate);
        drop(active_session);
        drop(active_group);
        // Publishing the replacement first lets blocked readers recover onto
        // it when closing the prior carrier wakes them. The provider group may
        // be reused across generations, so close the old session link even
        // when the group identity did not change.
        let close_previous_group = !Arc::ptr_eq(&previous, &group);
        let _ = tokio::time::timeout(TERMINAL_SHUTDOWN_TIMEOUT, async {
            if close_previous_group {
                let _ = tokio::join!(current.close(), previous.close());
            } else {
                let _ = current.close().await;
            }
        })
        .await;
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
        let _reconnecting = self.reconnecting.lock().await;
        if self.session.read().await.generation() != observed_generation {
            return Ok(());
        }
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = self.recover_locked().await;
        if result.is_err() && !self.closed.load(Ordering::Acquire) {
            self.set_diagnostics_state(ConnectionState::Disconnected);
        }
        result
    }

    async fn recover_locked(&self) -> Result<(), ConnectionError> {
        let mut attempt = 0_u32;
        let mut delay = self.config.reconnect.initial_delay;
        let mut group = self.group.read().await.clone();
        let mut close_state = self.close_state.subscribe();
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            attempt = attempt.saturating_add(1);
            let reconnect = tokio::select! {
                _ = close_state.changed() => return Err(ConnectionError::Closed),
                reconnect = tokio::time::timeout(
                    self.config.reconnect.attempt_timeout,
                    self.reconnect_once(group.clone()),
                ) => reconnect,
            };
            let result = match reconnect {
                Ok(result) => result,
                Err(_) => Err(ConnectionError::ReconnectAttemptTimedOut {
                    timeout: self.config.reconnect.attempt_timeout,
                }),
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
                    if let Some(source) = &self.reconnect_groups
                        && let Some(next) = resolve_reconnect_group(
                            source.as_ref(),
                            self.config.reconnect.attempt_timeout,
                        )
                        .await
                    {
                        group = next;
                    }
                    let retry_delay = self.config.reconnect.retry_delay(delay);
                    tokio::select! {
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
    drop(initial);
    loop {
        tokio::select! {
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use async_trait::async_trait;
    use cmux_remote_protocol::Service;
    use tempfile::tempdir;
    use tokio::sync::{Notify, Semaphore, mpsc};

    use super::*;
    use crate::daemon::{InboundLink, RemoteDaemon};
    use crate::identity::AuthDatabase;
    use crate::provider::{CarrierEvidence, ProviderCapabilities};
    use crate::service::{EndpointRole, ServiceError, ServiceMultiplexer};

    #[test]
    fn provider_link_carrier_failures_are_retryable() {
        for error in [LinkError::Closed, LinkError::Transport("HTTP error: 530".into())] {
            assert!(
                retryable_connection_error(&ConnectionError::Provider(ProviderError::Link(error))),
                "provider link carrier failure was treated as terminal"
            );
        }
        assert!(!retryable_connection_error(&ConnectionError::Provider(ProviderError::Link(
            LinkError::Protocol("invalid peer frame".into())
        ))));
        assert!(!retryable_connection_error(&ConnectionError::Crypto(CryptoError::Link(
            "invalid secure-link setup".into()
        ))));
        assert!(!retryable_connection_error(&ConnectionError::Link(LinkError::Protocol(
            "invalid physical frame".into()
        ))));
    }

    #[test]
    fn reconnect_classifier_excludes_terminal_transport_failures() {
        for error in [
            ConnectionError::Provider(ProviderError::Transport("wrong Unix peer owner".into())),
            ConnectionError::Crypto(CryptoError::Link("Noise frame limit is too small".into())),
            ConnectionError::Crypto(CryptoError::LinkError(LinkError::Protocol(
                "invalid handshake frame".into(),
            ))),
            ConnectionError::Link(LinkError::FrameTooLarge { actual: 2, maximum: 1 }),
            ConnectionError::Session(SessionError::Link(LinkError::Protocol(
                "invalid session frame".into(),
            ))),
        ] {
            assert!(!retryable_connection_error(&error), "terminal failure was retryable: {error}");
        }

        for error in [
            ConnectionError::Crypto(CryptoError::LinkError(LinkError::Closed)),
            ConnectionError::Link(LinkError::Transport("carrier disappeared".into())),
            ConnectionError::Session(SessionError::Link(LinkError::Closed)),
        ] {
            assert!(retryable_connection_error(&error), "carrier failure became terminal: {error}");
        }
    }

    #[test]
    fn session_recovery_classifier_excludes_terminal_link_failures() {
        for error in [
            SessionError::Link(LinkError::Protocol("invalid session frame".into())),
            SessionError::Link(LinkError::FrameTooLarge { actual: 2, maximum: 1 }),
        ] {
            assert!(!reconnectable_session_error(&error), "terminal failure was recoverable");
        }

        for error in [
            SessionError::Link(LinkError::Closed),
            SessionError::Link(LinkError::Transport("carrier disappeared".into())),
            SessionError::LinkMessage("carrier sender stopped".into()),
            SessionError::SchedulerClosed,
        ] {
            assert!(reconnectable_session_error(&error), "carrier failure became terminal");
        }
    }

    struct DelayedReconnectGroupSource {
        delay: Duration,
        resolution_timeout: Option<Duration>,
        completed: Arc<AtomicBool>,
    }

    struct HangingReconnectGroupSource {
        entered: Arc<Notify>,
        release: Arc<Notify>,
    }

    #[async_trait]
    impl ReconnectGroupSource for DelayedReconnectGroupSource {
        fn resolution_timeout(&self, reconnect_attempt_timeout: Duration) -> Duration {
            self.resolution_timeout.unwrap_or(reconnect_attempt_timeout)
        }

        async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
            tokio::time::sleep(self.delay).await;
            self.completed.store(true, Ordering::Release);
            Err(ProviderError::Transport("delayed test source completed".into()))
        }
    }

    #[async_trait]
    impl ReconnectGroupSource for HangingReconnectGroupSource {
        fn resolution_timeout(&self, _reconnect_attempt_timeout: Duration) -> Duration {
            Duration::from_secs(60 * 60)
        }

        async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
            self.entered.notify_one();
            self.release.notified().await;
            Err(ProviderError::Transport("released test source".into()))
        }
    }

    #[tokio::test]
    async fn reconnect_group_resolution_uses_only_an_explicitly_extended_deadline() {
        let ordinary_completed = Arc::new(AtomicBool::new(false));
        let ordinary = DelayedReconnectGroupSource {
            delay: Duration::from_millis(200),
            resolution_timeout: None,
            completed: ordinary_completed.clone(),
        };
        tokio::time::timeout(
            Duration::from_millis(100),
            resolve_reconnect_group(&ordinary, Duration::from_millis(20)),
        )
        .await
        .expect("ordinary reconnect source exceeded its carrier attempt timeout");
        assert!(!ordinary_completed.load(Ordering::Acquire));

        let extended_completed = Arc::new(AtomicBool::new(false));
        let extended = DelayedReconnectGroupSource {
            delay: Duration::from_millis(60),
            resolution_timeout: Some(Duration::from_millis(200)),
            completed: extended_completed.clone(),
        };
        tokio::time::timeout(
            Duration::from_millis(500),
            resolve_reconnect_group(&extended, Duration::from_millis(20)),
        )
        .await
        .expect("explicit reconnect resolution deadline was ignored");
        assert!(extended_completed.load(Ordering::Acquire));
    }

    #[tokio::test]
    async fn close_cancels_reconnect_group_resolution() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "close-group-resolution", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(OneShotGroup {
            daemon,
            opens: AtomicUsize::new(0),
            epoch: StdMutex::new(None),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let source = Arc::new(HangingReconnectGroupSource {
            entered: entered.clone(),
            release: release.clone(),
        });
        let client = ClientConnection::connect_with_reconnect_groups(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "close-group-resolution-client".into(),
                session: SessionId([95; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(1),
                    attempt_timeout: Duration::from_millis(100),
                    full_jitter: false,
                    heartbeat_interval: None,
                    heartbeat_timeout: Duration::from_secs(1),
                    maximum_attempts: None,
                },
            },
            Some(source),
        )
        .await
        .unwrap();
        let _server = tokio::time::timeout(Duration::from_secs(2), accepted.recv())
            .await
            .unwrap()
            .unwrap();

        group.fail();
        let send = tokio::spawn({
            let client = client.clone();
            async move {
                client
                    .send(Lane::Control, 7, Bytes::from_static(b"blocked"), FrameFlags::empty())
                    .await
            }
        });
        tokio::time::timeout(Duration::from_secs(1), entered.notified())
            .await
            .expect("reconnect group resolver did not start");

        let mut closing = Box::pin(client.close());
        let closed = tokio::time::timeout(Duration::from_millis(250), &mut closing).await;
        release.notify_waiters();
        let _ = tokio::time::timeout(Duration::from_secs(1), &mut closing).await;
        let _ = tokio::time::timeout(Duration::from_secs(1), send).await;
        assert!(closed.is_ok(), "close waited for a provider resolver after shutdown began");
    }

    struct FaultEpoch {
        failed: AtomicBool,
        changed: Notify,
    }

    impl FaultEpoch {
        fn fail(&self) {
            self.failed.store(true, Ordering::Release);
            self.changed.notify_waiters();
        }
    }

    struct FaultLink {
        name: &'static str,
        incoming: Mutex<mpsc::Receiver<Bytes>>,
        outgoing: mpsc::Sender<Bytes>,
        epoch: Arc<FaultEpoch>,
    }

    fn fault_pair() -> (FaultLink, FaultLink, Arc<FaultEpoch>) {
        let (left_tx, left_rx) = mpsc::channel(64);
        let (right_tx, right_rx) = mpsc::channel(64);
        let epoch = Arc::new(FaultEpoch { failed: AtomicBool::new(false), changed: Notify::new() });
        (
            FaultLink {
                name: "fault-client",
                incoming: Mutex::new(right_rx),
                outgoing: left_tx,
                epoch: epoch.clone(),
            },
            FaultLink {
                name: "fault-daemon",
                incoming: Mutex::new(left_rx),
                outgoing: right_tx,
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
            65_535
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.epoch.failed.load(Ordering::Acquire) {
                return Err(LinkError::Closed);
            }
            self.outgoing.send(frame).await.map_err(|_| LinkError::Closed)
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            if self.epoch.failed.load(Ordering::Acquire) {
                return Err(LinkError::Closed);
            }
            let changed = self.epoch.changed.notified();
            let mut incoming = self.incoming.lock().await;
            tokio::select! {
                _ = changed => Err(LinkError::Closed),
                frame = incoming.recv() => Ok(frame),
            }
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.epoch.fail();
            Ok(())
        }
    }

    #[tokio::test]
    async fn link_ready_eof_is_a_retryable_carrier_failure() {
        let (client, daemon, _) = fault_pair();
        drop(daemon);

        let error = receive_control::<LinkHandshakeResponse>(&client).await.unwrap_err();

        assert!(
            matches!(error, ConnectionError::Link(LinkError::Closed)),
            "link-ready EOF was not classified as a closed carrier: {error}"
        );
        assert!(
            retryable_connection_error(&error),
            "link-ready EOF would terminate reconnect instead of trying a fresh carrier"
        );
    }

    /// A transport whose endpoint accepts the connection and then goes silent:
    /// sends are swallowed and no frame ever arrives, like a preview-gateway
    /// edge that still accepts TCP for a deleted machine.
    struct SilentEndpointLink {
        closed: Arc<AtomicBool>,
        close_signal: Arc<Notify>,
    }

    #[async_trait]
    impl FrameLink for SilentEndpointLink {
        fn description(&self) -> &str {
            "silent-endpoint-link"
        }

        fn maximum_frame_bytes(&self) -> usize {
            65_535
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            if self.closed.load(Ordering::Acquire) {
                return Err(LinkError::Closed);
            }
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            loop {
                let notified = self.close_signal.notified();
                if self.closed.load(Ordering::Acquire) {
                    return Err(LinkError::Closed);
                }
                notified.await;
            }
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.closed.store(true, Ordering::Release);
            self.close_signal.notify_waiters();
            Ok(())
        }
    }

    struct SilentEndpointGroup {
        link_closed: Arc<AtomicBool>,
        close_signal: Arc<Notify>,
        evidence: CarrierEvidence,
    }

    #[async_trait]
    impl LinkGroup for SilentEndpointGroup {
        fn description(&self) -> &str {
            "silent-endpoint-group"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::STREAM
        }

        fn evidence(&self) -> &CarrierEvidence {
            &self.evidence
        }

        async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            Ok(Box::new(SilentEndpointLink {
                closed: self.link_closed.clone(),
                close_signal: self.close_signal.clone(),
            }))
        }

        async fn close(&self) -> Result<(), ProviderError> {
            self.link_closed.store(true, Ordering::Release);
            self.close_signal.notify_waiters();
            Ok(())
        }
    }

    #[tokio::test]
    async fn initial_connect_fails_fast_when_the_endpoint_accepts_but_never_handshakes() {
        let link_closed = Arc::new(AtomicBool::new(false));
        let group = Arc::new(SilentEndpointGroup {
            link_closed: link_closed.clone(),
            close_signal: Arc::new(Notify::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let connect = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "silent-endpoint-client".into(),
                session: SessionId([77; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    attempt_timeout: Duration::from_millis(200),
                    maximum_attempts: Some(1),
                    ..ReconnectPolicy::default()
                },
            },
        );
        // The outer timeout converts the historical symptom (the dial holds the
        // dead endpoint's transport open forever) into a deterministic failure.
        let result = tokio::time::timeout(Duration::from_secs(5), connect)
            .await
            .expect("connect held a silent endpoint open past its handshake deadline");
        let error =
            result.expect_err("connect succeeded against an endpoint that never handshakes");
        assert!(
            error.to_string().contains("handshake timed out"),
            "handshake deadline produced the wrong error: {error}"
        );
        assert!(
            error.is_retryable_carrier_failure(),
            "a handshake timeout must stay a retryable carrier failure: {error}"
        );
        assert!(
            link_closed.load(Ordering::Acquire),
            "handshake deadline left the physical link open"
        );
    }

    struct BlockingReplayClientLink {
        inner: FaultLink,
        received_frames: AtomicUsize,
        block_sends: AtomicBool,
        replay_started: Arc<Semaphore>,
        release_replay: Arc<Semaphore>,
    }

    #[async_trait]
    impl FrameLink for BlockingReplayClientLink {
        fn description(&self) -> &str {
            "blocking-replay-client"
        }

        fn maximum_frame_bytes(&self) -> usize {
            self.inner.maximum_frame_bytes()
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.block_sends.load(Ordering::Acquire) {
                self.replay_started.add_permits(1);
                self.release_replay.acquire().await.unwrap().forget();
            }
            self.inner.send(frame).await
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            let frame = self.inner.receive().await?;
            // The third inbound physical frame is link-ready: Noise message 2,
            // the encrypted welcome, then link-ready. Block the next send so
            // reconnect_to deterministically holds both publication locks in
            // the replay await.
            if frame.is_some() && self.received_frames.fetch_add(1, Ordering::AcqRel) == 2 {
                self.block_sends.store(true, Ordering::Release);
            }
            Ok(frame)
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.inner.close().await
        }
    }

    struct BlockingHeartbeatLink {
        inner: FaultLink,
        block_next_send: Arc<AtomicBool>,
        send_started: Arc<Semaphore>,
        release_send: Arc<Semaphore>,
    }

    #[async_trait]
    impl FrameLink for BlockingHeartbeatLink {
        fn description(&self) -> &str {
            "blocking-heartbeat-client"
        }

        fn maximum_frame_bytes(&self) -> usize {
            self.inner.maximum_frame_bytes()
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.block_next_send.swap(false, Ordering::AcqRel) {
                self.send_started.add_permits(1);
                self.release_send.acquire().await.unwrap().forget();
            }
            self.inner.send(frame).await
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            self.inner.receive().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.inner.close().await
        }
    }

    struct FaultGroup {
        daemon: Arc<RemoteDaemon>,
        epochs: Mutex<Vec<Arc<FaultEpoch>>>,
        evidence: CarrierEvidence,
    }

    impl FaultGroup {
        async fn fail_current(&self) {
            self.epochs.lock().await.last().unwrap().fail();
        }
    }

    #[async_trait]
    impl LinkGroup for FaultGroup {
        fn description(&self) -> &str {
            "fault-group"
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
                let inbound =
                    InboundLink::same_owner_kernel_peer(Box::new(daemon), 501, 501).unwrap();
                let _ = remote.accept(inbound).await;
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

    struct HangingCloseGroup {
        inner: Arc<FaultGroup>,
    }

    struct MutableSnapshotGroup {
        inner: Arc<FaultGroup>,
        transport: StdMutex<crate::observability::TransportSnapshot>,
    }

    #[async_trait]
    impl LinkGroup for MutableSnapshotGroup {
        fn description(&self) -> &str {
            self.inner.description()
        }

        fn capabilities(&self) -> ProviderCapabilities {
            self.inner.capabilities()
        }

        fn evidence(&self) -> &CarrierEvidence {
            self.inner.evidence()
        }

        async fn transport_snapshot(&self) -> crate::observability::TransportSnapshot {
            self.transport.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
        }

        async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            self.inner.open(request).await
        }

        async fn close(&self) -> Result<(), ProviderError> {
            self.inner.close().await
        }
    }

    struct BlockingReplayGroup {
        daemon: Arc<RemoteDaemon>,
        epochs: Mutex<Vec<Arc<FaultEpoch>>>,
        replay_started: Arc<Semaphore>,
        release_replay: Arc<Semaphore>,
        evidence: CarrierEvidence,
    }

    struct BlockingHeartbeatGroup {
        daemon: Arc<RemoteDaemon>,
        opens: AtomicUsize,
        epochs: Mutex<Vec<Arc<FaultEpoch>>>,
        block_next_send: Arc<AtomicBool>,
        send_started: Arc<Semaphore>,
        release_send: Arc<Semaphore>,
        evidence: CarrierEvidence,
    }

    #[async_trait]
    impl LinkGroup for BlockingHeartbeatGroup {
        fn description(&self) -> &str {
            "blocking-heartbeat-group"
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
                let inbound =
                    InboundLink::same_owner_kernel_peer(Box::new(daemon), 501, 501).unwrap();
                let _ = remote.accept(inbound).await;
            });
            if self.opens.fetch_add(1, Ordering::AcqRel) == 0 {
                Ok(Box::new(BlockingHeartbeatLink {
                    inner: client,
                    block_next_send: self.block_next_send.clone(),
                    send_started: self.send_started.clone(),
                    release_send: self.release_send.clone(),
                }))
            } else {
                Ok(Box::new(client))
            }
        }

        async fn close(&self) -> Result<(), ProviderError> {
            for epoch in self.epochs.lock().await.iter() {
                epoch.fail();
            }
            Ok(())
        }
    }

    #[async_trait]
    impl LinkGroup for BlockingReplayGroup {
        fn description(&self) -> &str {
            "blocking-replay-group"
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
                let inbound =
                    InboundLink::same_owner_kernel_peer(Box::new(daemon), 501, 501).unwrap();
                let _ = remote.accept(inbound).await;
            });
            Ok(Box::new(BlockingReplayClientLink {
                inner: client,
                received_frames: AtomicUsize::new(0),
                block_sends: AtomicBool::new(false),
                replay_started: self.replay_started.clone(),
                release_replay: self.release_replay.clone(),
            }))
        }

        async fn close(&self) -> Result<(), ProviderError> {
            for epoch in self.epochs.lock().await.iter() {
                epoch.fail();
            }
            Ok(())
        }
    }

    struct OneShotGroup {
        daemon: Arc<RemoteDaemon>,
        opens: AtomicUsize,
        epoch: StdMutex<Option<Arc<FaultEpoch>>>,
        evidence: CarrierEvidence,
    }

    impl OneShotGroup {
        fn fail(&self) {
            if let Some(epoch) =
                self.epoch.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref()
            {
                epoch.fail();
            }
        }
    }

    #[async_trait]
    impl LinkGroup for OneShotGroup {
        fn description(&self) -> &str {
            "one-shot-group"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::STREAM
        }

        fn evidence(&self) -> &CarrierEvidence {
            &self.evidence
        }

        async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            if self.opens.fetch_add(1, Ordering::AcqRel) != 0 {
                return Err(ProviderError::Link(LinkError::Transport(
                    "replacement carrier unavailable".into(),
                )));
            }
            let (client, daemon, epoch) = fault_pair();
            *self.epoch.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(epoch);
            let remote = self.daemon.clone();
            tokio::spawn(async move {
                let inbound =
                    InboundLink::same_owner_kernel_peer(Box::new(daemon), 501, 501).unwrap();
                let _ = remote.accept(inbound).await;
            });
            Ok(Box::new(client))
        }

        async fn close(&self) -> Result<(), ProviderError> {
            self.fail();
            Ok(())
        }
    }

    #[async_trait]
    impl LinkGroup for HangingCloseGroup {
        fn description(&self) -> &str {
            "hanging-close-group"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            self.inner.capabilities()
        }

        fn evidence(&self) -> &CarrierEvidence {
            self.inner.evidence()
        }

        async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            self.inner.open(request).await
        }

        async fn close(&self) -> Result<(), ProviderError> {
            std::future::pending().await
        }
    }

    #[tokio::test]
    async fn failed_carrier_reconnects_and_replays_the_original_sequence() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "reconnect", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "reconnecting-client".into(),
                session: SessionId([91; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(10),
                    maximum_attempts: Some(3),
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        let initial = client.snapshot().await;
        assert_eq!(initial.generation, 0);
        assert_eq!(initial.state, ConnectionState::Connected);
        assert_eq!(initial.lane_bindings, vec![Lane::ALL.to_vec()]);
        assert_eq!(initial.physical_link_count, 1);
        assert_eq!(initial.transport, crate::observability::TransportSnapshot::unknown());

        client
            .send(Lane::Control, 7, Bytes::from_static(b"before"), FrameFlags::empty())
            .await
            .unwrap();
        assert_eq!(server.receive().await.unwrap().unwrap().payload, b"before".as_slice());

        group.fail_current().await;
        let sequence = tokio::time::timeout(
            Duration::from_secs(2),
            client.send(Lane::Control, 7, Bytes::from_static(b"after"), FrameFlags::empty()),
        )
        .await
        .unwrap()
        .unwrap();
        let received = tokio::time::timeout(Duration::from_secs(2), server.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(received.sequence, sequence);
        assert_eq!(received.payload, b"after".as_slice());
        let reconnected = client.snapshot().await;
        assert_eq!(reconnected.generation, 1);
        assert_eq!(reconnected.state, ConnectionState::Connected);
    }

    #[tokio::test]
    async fn heartbeat_timeout_includes_a_blocked_probe_send() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "heartbeat-send", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let block_next_send = Arc::new(AtomicBool::new(false));
        let send_started = Arc::new(Semaphore::new(0));
        let release_send = Arc::new(Semaphore::new(0));
        let group = Arc::new(BlockingHeartbeatGroup {
            daemon,
            opens: AtomicUsize::new(0),
            epochs: Mutex::new(Vec::new()),
            block_next_send: block_next_send.clone(),
            send_started: send_started.clone(),
            release_send: release_send.clone(),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "heartbeat-send-client".into(),
                session: SessionId([90; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(1),
                    attempt_timeout: Duration::from_secs(1),
                    full_jitter: false,
                    heartbeat_interval: Some(Duration::from_millis(20)),
                    heartbeat_timeout: Duration::from_millis(40),
                    maximum_attempts: Some(2),
                },
            },
        )
        .await
        .unwrap();
        let _server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();
        let mut generation = client.subscribe_generation();
        block_next_send.store(true, Ordering::Release);
        tokio::time::timeout(Duration::from_secs(1), send_started.acquire())
            .await
            .expect("heartbeat never reached the blocked carrier send")
            .unwrap()
            .forget();

        let recovered = tokio::time::timeout(Duration::from_millis(500), async {
            while *generation.borrow() == 0 {
                generation.changed().await.unwrap();
            }
        })
        .await
        .is_ok();
        release_send.add_permits(1);
        let _ = tokio::time::timeout(Duration::from_secs(2), client.close()).await;

        assert!(
            recovered,
            "heartbeat send remained blocked beyond the configured liveness deadline"
        );
    }

    #[tokio::test]
    async fn heartbeat_reads_responses_without_an_application_receive_poll() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "idle-heartbeat", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "idle-heartbeat-client".into(),
                session: SessionId([90; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(5),
                    attempt_timeout: Duration::from_millis(100),
                    full_jitter: false,
                    heartbeat_interval: Some(Duration::from_millis(10)),
                    heartbeat_timeout: Duration::from_millis(30),
                    maximum_attempts: Some(2),
                },
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();
        let receiving_server = server.clone();
        let server_reader =
            tokio::spawn(
                async move { while receiving_server.receive().await.unwrap().is_some() {} },
            );
        server
            .send(
                Lane::Control,
                44,
                Bytes::from_static(b"deferred while idle"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        tokio::time::sleep(Duration::from_millis(150)).await;
        assert_eq!(client.snapshot().await.generation, 0);
        assert_eq!(client.receive().await.unwrap().unwrap().payload, b"deferred while idle"[..]);
        client.close().await.unwrap();
        server_reader.await.unwrap();
    }

    #[tokio::test]
    async fn owner_disconnected_session_stops_instead_of_reconnecting_forever() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "owner-disconnect", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(FaultGroup {
            daemon: daemon.clone(),
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "owner-disconnected-client".into(),
                session: SessionId([99; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(1),
                    attempt_timeout: Duration::from_millis(100),
                    full_jitter: false,
                    heartbeat_interval: None,
                    heartbeat_timeout: Duration::from_secs(1),
                    maximum_attempts: None,
                },
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        assert!(
            daemon.disconnect(&server.device_id, client.session_id()).await.unwrap(),
            "owner disconnect did not remove the logical session"
        );
        let error = tokio::time::timeout(Duration::from_millis(500), client.receive())
            .await
            .expect("owner-disconnected client kept reconnecting")
            .unwrap_err();
        assert!(
            matches!(
                error,
                ConnectionError::Protocol(ref message)
                    if message == "daemon no longer has the requested logical session"
            ),
            "unexpected terminal error: {error}"
        );
    }

    #[tokio::test]
    async fn replay_window_pressure_backpressures_until_ack_instead_of_failing_bulk_send() {
        let directory = tempdir().unwrap();
        let limits = SessionLimits { replay_frames_per_lane: 1, ..SessionLimits::default() };
        let auth =
            AuthDatabase::load_or_create(directory.path(), "replay-backpressure", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, limits);
        let group = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "replay-backpressure-client".into(),
                session: SessionId([93; 16]),
                lane_policy: LanePolicy::Single,
                limits,
                reconnect: ReconnectPolicy::default(),
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        server
            .send(Lane::Bulk, 9, Bytes::from_static(b"first"), FrameFlags::empty())
            .await
            .unwrap();
        let first = client.receive().await.unwrap().unwrap();
        assert_eq!(first.payload, b"first".as_slice());

        let second = tokio::spawn({
            let server = server.clone();
            async move {
                server.send(Lane::Bulk, 9, Bytes::from_static(b"second"), FrameFlags::empty()).await
            }
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(
            !second.is_finished(),
            "a full replay window failed the bulk stream instead of applying backpressure"
        );

        client
            .send(Lane::Bulk, 10, Bytes::from_static(b"ack carrier"), FrameFlags::empty())
            .await
            .unwrap();
        let acknowledgement = server.receive().await.unwrap().unwrap();
        assert_eq!(acknowledgement.payload, b"ack carrier".as_slice());
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), second)
                .await
                .expect("bulk send remained blocked after its replay entry was acknowledged")
                .unwrap()
                .unwrap(),
            2
        );
        let delivered = client.receive().await.unwrap().unwrap();
        assert_eq!(delivered.sequence, 2);
        assert_eq!(delivered.payload, b"second".as_slice());
    }

    #[tokio::test]
    async fn snapshot_refreshes_a_live_provider_path_without_reconnect() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "path-change", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(MutableSnapshotGroup {
            inner: Arc::new(FaultGroup {
                daemon,
                epochs: Mutex::new(Vec::new()),
                evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
            }),
            transport: StdMutex::new(crate::observability::TransportSnapshot {
                provider: "mutable-test".into(),
                route: "test://daemon".into(),
                selected_path: Some(crate::observability::TransportPathSnapshot {
                    kind: crate::observability::TransportPathKind::Direct,
                    remote: Some("192.0.2.1:443".into()),
                    rtt_micros: Some(1_000),
                }),
            }),
        });
        let client = ClientConnection::connect(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "path-changing-client".into(),
                session: SessionId([95; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    heartbeat_interval: None,
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let _server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        let initial = client.snapshot().await;
        assert_eq!(
            initial.transport.selected_path.unwrap().kind,
            crate::observability::TransportPathKind::Direct
        );
        *group.transport.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            crate::observability::TransportSnapshot {
                provider: "mutable-test".into(),
                route: "test://daemon".into(),
                selected_path: Some(crate::observability::TransportPathSnapshot {
                    kind: crate::observability::TransportPathKind::Relay,
                    remote: Some("relay.example:443".into()),
                    rtt_micros: Some(8_000),
                }),
            };

        let migrated = client.snapshot().await;
        assert_eq!(migrated.generation, 0);
        assert_eq!(migrated.state, ConnectionState::Connected);
        assert_eq!(
            migrated.transport.selected_path.unwrap().kind,
            crate::observability::TransportPathKind::Relay
        );
    }

    #[tokio::test]
    async fn snapshot_is_prompt_and_reconnecting_while_client_replay_blocks() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "client-replay", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let initial_group = Arc::new(FaultGroup {
            daemon: daemon.clone(),
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            initial_group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "blocked-replay-client".into(),
                session: SessionId([94; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    heartbeat_interval: None,
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let _server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        client
            .send(
                Lane::Control,
                9,
                Bytes::from_static(b"pending client replay"),
                FrameFlags::empty(),
            )
            .await
            .unwrap();

        let replay_started = Arc::new(Semaphore::new(0));
        let release_replay = Arc::new(Semaphore::new(0));
        let replacement = Arc::new(BlockingReplayGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            replay_started: replay_started.clone(),
            release_replay: release_replay.clone(),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let reconnect = tokio::spawn({
            let client = client.clone();
            async move { client.reconnect(replacement).await }
        });
        tokio::time::timeout(Duration::from_secs(2), replay_started.acquire())
            .await
            .expect("client replay did not reach the blocking link")
            .unwrap()
            .forget();

        let snapshot = tokio::time::timeout(Duration::from_millis(50), client.snapshot())
            .await
            .expect("client replay blocked cached connection diagnostics");
        assert_eq!(snapshot.generation, 0);
        assert_eq!(snapshot.state, ConnectionState::Reconnecting);
        assert_eq!(snapshot.lane_bindings, vec![Lane::ALL.to_vec()]);

        release_replay.add_permits(1);
        reconnect.await.unwrap().unwrap();
        let snapshot = client.snapshot().await;
        assert_eq!(snapshot.generation, 1);
        assert_eq!(snapshot.state, ConnectionState::Connected);
    }

    #[tokio::test]
    async fn cancelled_reconnect_after_commit_stays_observably_connected() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "cancel-reconnect", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let initial = Arc::new(HangingCloseGroup {
            inner: Arc::new(FaultGroup {
                daemon: daemon.clone(),
                epochs: Mutex::new(Vec::new()),
                evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
            }),
        });
        let client = ClientConnection::connect(
            initial,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "cancel-reconnect-client".into(),
                session: SessionId([96; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    heartbeat_interval: None,
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let replacement = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let mut generation = client.subscribe_generation();
        let reconnect = tokio::spawn({
            let client = client.clone();
            async move { client.reconnect(replacement).await }
        });

        tokio::time::timeout(Duration::from_secs(2), async {
            while *generation.borrow() == 0 {
                generation.changed().await.unwrap();
            }
        })
        .await
        .expect("replacement generation was not committed");
        assert!(!reconnect.is_finished(), "old carrier retirement did not remain pending");
        assert_eq!(client.snapshot().await.state, ConnectionState::Connected);

        reconnect.abort();
        assert!(reconnect.await.unwrap_err().is_cancelled());
        let snapshot = client.snapshot().await;
        assert_eq!(snapshot.generation, 1);
        assert_eq!(snapshot.state, ConnectionState::Connected);
        client.close().await.unwrap();
    }

    #[tokio::test]
    async fn exhausted_recovery_stays_observably_disconnected() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "disconnected", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(OneShotGroup {
            daemon,
            opens: AtomicUsize::new(0),
            epoch: StdMutex::new(None),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "disconnected-client".into(),
                session: SessionId([92; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(1),
                    maximum_attempts: Some(1),
                    heartbeat_interval: None,
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let _server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();

        group.fail();
        let error = client
            .send(Lane::Control, 7, Bytes::from_static(b"cannot deliver"), FrameFlags::empty())
            .await
            .unwrap_err();
        assert!(matches!(error, ConnectionError::ReconnectExhausted { attempts: 1, .. }));
        assert_eq!(client.snapshot().await.state, ConnectionState::Disconnected);
        client.reconnect(group).await.unwrap_err();
        assert_eq!(
            client.snapshot().await.state,
            ConnectionState::Disconnected,
            "a failed manual candidate must restore the prior disconnected state"
        );
        client.close().await.unwrap();
        assert_eq!(client.snapshot().await.state, ConnectionState::Closed);
        // A reconnect that passed its open check before close may publish
        // afterward. The terminal diagnostics state must still win.
        client.set_diagnostics_state(ConnectionState::Reconnecting);
        assert_eq!(client.snapshot().await.state, ConnectionState::Closed);
    }

    #[tokio::test]
    async fn cancelled_close_still_finishes_after_in_flight_reconnect_publication() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "close-reconnect", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "closing-client".into(),
                session: SessionId([93; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        )
        .await
        .unwrap();

        let publication = client.reconnecting.lock().await;
        let mut close_state = client.close_state.subscribe();
        let closing = tokio::spawn({
            let client = client.clone();
            async move { client.close().await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !client.closed.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("close did not begin");
        tokio::time::timeout(Duration::from_secs(1), close_state.changed())
            .await
            .expect("shutdown start was not published while cleanup was blocked")
            .expect("close state channel closed before shutdown completed");
        assert!(matches!(*close_state.borrow(), CloseState::Started));
        assert!(!closing.is_finished(), "close bypassed reconnect publication serialization");
        closing.abort();
        assert!(closing.await.unwrap_err().is_cancelled());

        drop(publication);
        tokio::time::timeout(Duration::from_secs(1), client.close())
            .await
            .expect("detached close did not finish after reconnect publication completed")
            .unwrap();
    }

    #[tokio::test]
    async fn cancelled_close_publishes_a_later_cleanup_failure() {
        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(directory.path(), "failed-close", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(HangingCloseGroup {
            inner: Arc::new(FaultGroup {
                daemon,
                epochs: Mutex::new(Vec::new()),
                evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
            }),
        });
        let client = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "failed-close-client".into(),
                session: SessionId([94; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        )
        .await
        .unwrap();

        let publication = client.reconnecting.lock().await;
        let closing = tokio::spawn({
            let client = client.clone();
            async move { client.close().await }
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !client.closed.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("close did not begin");
        closing.abort();
        assert!(closing.await.unwrap_err().is_cancelled());
        drop(publication);

        let error = tokio::time::timeout(Duration::from_secs(3), client.close())
            .await
            .expect("repeat close did not observe detached cleanup failure")
            .unwrap_err();
        assert!(matches!(error, ConnectionError::ShutdownTimedOut));
    }

    #[tokio::test]
    async fn physical_reconnect_resets_tunnels_and_keeps_workspace_streams() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path(), "service-reconnect", true).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let group = Arc::new(FaultGroup {
            daemon,
            epochs: Mutex::new(Vec::new()),
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
        });
        let client = ClientConnection::connect(
            group.clone(),
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "service-reconnecting-client".into(),
                session: SessionId([92; 16]),
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    initial_delay: Duration::from_millis(1),
                    maximum_delay: Duration::from_millis(10),
                    maximum_attempts: Some(3),
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap();
        let server =
            tokio::time::timeout(Duration::from_secs(2), accepted.recv()).await.unwrap().unwrap();
        let client_services = ServiceMultiplexer::new(client, EndpointRole::Client);
        let daemon_services = ServiceMultiplexer::new(server, EndpointRole::Daemon);

        let client_tunnel =
            client_services.open(Service::TcpTunnel, BTreeMap::new()).await.unwrap();
        let daemon_tunnel = daemon_services.accept().await.unwrap().unwrap().stream;
        let workspace = client_services.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
        let daemon_workspace = daemon_services.accept().await.unwrap().unwrap().stream;

        group.fail_current().await;
        for stream in [&client_tunnel, &daemon_tunnel] {
            let error = tokio::time::timeout(Duration::from_secs(2), stream.receive())
                .await
                .expect("tunnel stream survived physical reconnect")
                .unwrap_err();
            assert!(matches!(error, ServiceError::GenerationChanged { expected: 0, actual: 1 }));
        }

        workspace.send(Bytes::from_static(b"workspace continues")).await.unwrap();
        let resumed = tokio::time::timeout(Duration::from_secs(2), daemon_workspace.receive())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(resumed.payload, b"workspace continues".as_slice());
    }
}
