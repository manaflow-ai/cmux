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
use tokio::sync::{Mutex, Notify, RwLock, oneshot, watch};

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
/// How long a probe sent because the network changed may take, write and answer, before the
/// link is redialed. A route that survived the change answers well within it.
const NETWORK_CHANGE_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

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
    /// The wait before the second redial of a recovery. Each later redial in
    /// the same burst waits four times longer, up to `maximum_delay`.
    pub initial_delay: Duration,
    /// The longest wait between two redials, and the wait a parked link
    /// takes between bursts when nothing wakes it sooner.
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
    /// `None` keeps the link: after each burst of `attempts_per_recovery`
    /// redials it parks and tries again on the next caller action, network
    /// change or budget refill, until the client closes. A finite value ends
    /// a recovery with [`ConnectionError::ReconnectExhausted`] after that many
    /// redials, for one-shot agent commands that prefer a bounded failure time.
    pub maximum_attempts: Option<u32>,
    /// Bound the complete recovery window, including backoff and transport
    /// discovery. `None` is retained for callers that explicitly own a longer
    /// lived connection, but Cloud supplies a finite deadline.
    pub maximum_duration: Option<Duration>,
    /// Redials in one burst. The first goes at once, the rest after the
    /// jittered `initial_delay` steps; then the link parks.
    pub attempts_per_recovery: u32,
    /// The token bucket every redial spends from, across recoveries.
    pub redial_budget: RedialBudget,
}

/// A token bucket shared by every recovery of one connection. Each redial
/// spends a token; tokens come back one per `refill_interval` whatever the
/// link's state. Over any window of `t`, a connection therefore dials at most
/// `capacity + t / refill_interval` times, no matter how many heartbeats,
/// readers, senders or network changes ask it to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RedialBudget {
    pub capacity: u32,
    pub refill_interval: Duration,
}

impl Default for RedialBudget {
    /// A burst of three redials plus one for the network change or action
    /// that ends the outage, then one redial per 2 s at most.
    fn default() -> Self {
        Self { capacity: 4, refill_interval: Duration::from_secs(2) }
    }
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_millis(150),
            maximum_delay: Duration::from_secs(5),
            attempt_timeout: Duration::from_secs(15),
            full_jitter: true,
            // A probe every 2 s answered within 4 s: a link that goes silent
            // right after a probe is declared dead 6 s later at most.
            heartbeat_interval: Some(Duration::from_secs(2)),
            heartbeat_timeout: Duration::from_secs(4),
            maximum_attempts: None,
            // Long-lived interactive links, including direct SSH sessions,
            // must keep retrying until their owner closes them. Callers that
            // run bounded one-shot work can opt into a recovery deadline.
            maximum_duration: None,
            attempts_per_recovery: 3,
            redial_budget: RedialBudget::default(),
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
        if self.attempts_per_recovery == 0
            || self.redial_budget.capacity == 0
            || self.redial_budget.refill_interval.is_zero()
        {
            return Err(ConnectionError::Protocol(
                "reconnect burst, budget capacity and refill interval must be positive".into(),
            ));
        }
        Ok(())
    }

    /// Applies this policy's jitter setting to the current backoff ceiling.
    pub fn retry_delay(self, ceiling: Duration) -> Duration {
        jittered_delay(ceiling, self.full_jitter)
    }
}

/// The redial budget's state. Tokio's clock, so a paused test clock drives it.
#[derive(Debug)]
pub(crate) struct TokenBucket {
    budget: RedialBudget,
    tokens: u32,
    refilled_at: tokio::time::Instant,
}

impl TokenBucket {
    pub(crate) fn new(budget: RedialBudget, now: tokio::time::Instant) -> Self {
        Self { budget, tokens: budget.capacity, refilled_at: now }
    }

    fn refill(&mut self, now: tokio::time::Instant) {
        if self.tokens >= self.budget.capacity {
            self.refilled_at = now;
            return;
        }
        let interval = self.budget.refill_interval.as_nanos().max(1);
        let earned = now.saturating_duration_since(self.refilled_at).as_nanos() / interval;
        if earned == 0 {
            return;
        }
        let earned = u32::try_from(earned).unwrap_or(u32::MAX);
        self.tokens = self.tokens.saturating_add(earned).min(self.budget.capacity);
        self.refilled_at = if self.tokens >= self.budget.capacity {
            now
        } else {
            self.refilled_at + self.budget.refill_interval * earned
        };
    }

    /// Spend a token, or say when the next one arrives.
    pub(crate) fn take(&mut self, now: tokio::time::Instant) -> Result<(), tokio::time::Instant> {
        self.refill(now);
        if self.tokens == 0 {
            return Err(self.refilled_at + self.budget.refill_interval);
        }
        self.tokens -= 1;
        Ok(())
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

/// Told how each attempt to reattach an established session's carrier (a
/// resume) ended, for a caller that logs every connect.
pub trait ResumeHooks: Send + Sync {
    /// One attempt ended after `elapsed`.
    fn attempt_ended(&self, result: Result<(), &ConnectionError>, elapsed: Duration);
}

pub struct ClientConnection {
    config: ClientConnectionConfig,
    group: Arc<RwLock<Arc<dyn LinkGroup>>>,
    reconnect_groups: Option<Arc<dyn ReconnectGroupSource>>,
    resume_hooks: StdMutex<Option<Arc<dyn ResumeHooks>>>,
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
    /// Woken on every received frame, so a heartbeat whose answer an
    /// application reader consumed sees it at once.
    received: Notify,
    closed: AtomicBool,
    close_state: watch::Sender<CloseState>,
    /// The daemon refused a reconnect because it no longer has the session.
    /// Permanent: the connection never dials that session again.
    session_unavailable: AtomicBool,
    /// Every redial spends a token here, across recoveries.
    redial_budget: StdMutex<TokenBucket>,
    /// The published link state, for owners that wait on it instead of
    /// redialing themselves.
    state: watch::Sender<ConnectionState>,
    /// Bumped by a caller action that waits on the link: wakes a parked
    /// recovery without waiting out its backoff.
    actions: watch::Sender<u64>,
    /// Bumped by [`ClientConnection::network_changed`]: probes a live link at
    /// once, abandons a dial on the old network and wakes a parked recovery.
    network: watch::Sender<u64>,
    /// Why the last redial failed, until one succeeds: the reason a waiter
    /// that runs out of time is given.
    last_failure: StdMutex<Option<String>>,
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
        let redial_budget = config.reconnect.redial_budget;
        let connection = Arc::new(Self {
            config,
            group: Arc::new(RwLock::new(group)),
            reconnect_groups,
            resume_hooks: StdMutex::new(None),
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
            received: Notify::new(),
            closed: AtomicBool::new(false),
            close_state,
            session_unavailable: AtomicBool::new(false),
            redial_budget: StdMutex::new(TokenBucket::new(
                redial_budget,
                tokio::time::Instant::now(),
            )),
            state: watch::channel(ConnectionState::Connected).0,
            actions: watch::channel(0).0,
            network: watch::channel(0).0,
            last_failure: StdMutex::new(None),
        });
        Self::spawn_heartbeat(&connection);
        Ok(connection)
    }

    pub fn session_id(&self) -> SessionId {
        self.config.session
    }

    /// Install hooks that every later resume attempt calls.
    pub fn set_resume_hooks(&self, hooks: Arc<dyn ResumeHooks>) {
        *self.resume_hooks.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(hooks);
    }

    fn resume_hooks(&self) -> Option<Arc<dyn ResumeHooks>> {
        self.resume_hooks.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    pub fn daemon_public_key(&self) -> [u8; 32] {
        self.daemon_public_key
    }

    pub fn subscribe_generation(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }

    /// The link's state as it changes: `Connected`, `Reconnecting` while a
    /// redial is in flight, `Disconnected` while a recovery is parked or has
    /// given up, and `Closed`. This connection is the only layer that
    /// redials; an owner follows this instead of retrying on its own.
    pub fn subscribe_state(&self) -> watch::Receiver<ConnectionState> {
        self.state.subscribe()
    }

    /// Tell the link the network changed (an interface came up or went
    /// away, the default route moved). A live link is probed at once instead
    /// of at its next heartbeat; a redial in flight on the old network is
    /// abandoned and dialed again; a parked recovery dials now. Every redial
    /// still spends from the budget, so a noisy watcher cannot make a storm.
    pub fn network_changed(&self) {
        self.network.send_modify(|generation| *generation = generation.wrapping_add(1));
    }

    /// Wait until the link is connected or `deadline` passes. An action
    /// passes its own remaining time: a dead link is redialed within it (a
    /// parked recovery wakes now), and no recovery this starts outlives it.
    /// Past the deadline the answer is
    /// [`ConnectionError::ReconnectDeadlineExceeded`]; the link itself keeps
    /// its state and goes on waiting for the next trigger.
    pub async fn await_ready(&self, deadline: tokio::time::Instant) -> Result<(), ConnectionError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ConnectionError::Closed);
        }
        if self.session_unavailable() {
            return Err(ConnectionError::SessionUnavailable);
        }
        // The published generation, not the session's: replay holds the
        // session lock for its whole run, and a wait for it would outlive the
        // deadline, then read the replayed generation and redial a link that
        // just came back. Read before the state, so a recovery that publishes
        // in between is either seen as connected or ends `recover_by` at once.
        let generation = *self.generation.borrow();
        if *self.state.borrow() == ConnectionState::Connected {
            return Ok(());
        }
        self.recover_by(generation, Some(deadline)).await
    }

    /// [`ClientConnection::send`], with the action's deadline: a recovery
    /// the send needs ends by `deadline`.
    pub async fn send_by(
        &self,
        deadline: tokio::time::Instant,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ConnectionError> {
        self.send_with(None, Some(deadline), lane, stream, payload, flags).await
    }

    /// Why the last redial failed, or `None` when the link has not failed a
    /// redial since it last connected.
    pub fn last_failure(&self) -> Option<String> {
        self.last_failure.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    fn set_last_failure(&self, failure: Option<String>) {
        *self.last_failure.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = failure;
    }

    /// Whether the daemon refused a reconnect because it no longer has this
    /// session (it outlived the daemon's resume lease, or was closed there).
    /// Permanent: every later operation fails with
    /// [`ConnectionError::SessionUnavailable`] and nothing redials.
    pub fn session_unavailable(&self) -> bool {
        self.session_unavailable.load(Ordering::Acquire)
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
            self.state.send_if_modified(|published| {
                let changed = *published != state;
                *published = state;
                changed
            });
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
        self.send_with(expected_generation, None, lane, stream, payload, flags).await
    }

    async fn send_with(
        &self,
        expected_generation: Option<u64>,
        deadline: Option<tokio::time::Instant>,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, ConnectionError> {
        // Another send may hold this lane through an unbounded recovery, and
        // replay holds the session lock; a send with a deadline waits for
        // neither past it.
        let _lane = self.by_deadline(deadline, self.lane_sends[lane as usize].lock()).await?;
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            if self.session_unavailable() {
                return Err(ConnectionError::SessionUnavailable);
            }
            let session = self.by_deadline(deadline, self.session.read()).await?.clone();
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
                    self.recover_by(generation, deadline).await?;
                    let actual = *self.generation.borrow();
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

    /// Await `wait`, but not past `deadline` when there is one: then the
    /// answer is [`ConnectionError::ReconnectDeadlineExceeded`]. A caller
    /// with a deadline that waits on a link that is not connected is an
    /// action, so a parked recovery dials now.
    async fn by_deadline<T>(
        &self,
        deadline: Option<tokio::time::Instant>,
        wait: impl Future<Output = T>,
    ) -> Result<T, ConnectionError> {
        let Some(deadline) = deadline else { return Ok(wait.await) };
        if *self.state.borrow() != ConnectionState::Connected {
            self.actions.send_modify(|count| *count = count.wrapping_add(1));
        }
        // The deadline is polled first: a wait that is ready at or past it
        // still loses, so nothing goes on after its deadline.
        tokio::select! {
            biased;
            () = tokio::time::sleep_until(deadline) => {
                Err(ConnectionError::ReconnectDeadlineExceeded { attempts: 0 })
            }
            value = wait => Ok(value),
        }
    }

    pub async fn receive(&self) -> Result<Option<ReceivedFrame>, ConnectionError> {
        let _receiving = self.receiving.lock().await;
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Ok(None);
            }
            if self.session_unavailable() {
                return Err(ConnectionError::SessionUnavailable);
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
        let _receiving = match self.receiving.try_lock() {
            Ok(receiving) => receiving,
            // An application reader holds the receive side and consumes the
            // answer itself: any frame after the probe proves the link live.
            // Waiting only for its lock held every probe to its timeout. A
            // reader cancelled before the answer leaves it unread, so the
            // probe takes the receive side over when that reader lets go.
            Err(_) => tokio::select! {
                biased;
                () = self.received_after(observed) => return true,
                receiving = self.receiving.lock() => receiving,
            },
        };
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
        if self.session_unavailable() {
            return Err(ConnectionError::SessionUnavailable);
        }
        let previous_state = self.diagnostics_state();
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = tokio::select! {
            biased;
            _ = close_state.changed() => Err(ConnectionError::Closed),
            result = self.reconnect_once(group) => result,
        };
        let gone = matches!(result, Err(ConnectionError::SessionUnavailable));
        if gone {
            self.session_unavailable.store(true, Ordering::Release);
            self.retire_gone_session().await;
        }
        // Explicit route replacement preserves the previously published
        // carrier when setup or replay of the candidate fails, unless the
        // daemon said the session itself is gone.
        if !self.closed.load(Ordering::Acquire) {
            self.set_diagnostics_state(if result.is_ok() {
                ConnectionState::Connected
            } else if gone {
                ConnectionState::Disconnected
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
                self.state.send_replace(ConnectionState::Connected);
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
        self.received.notify_waiters();
    }

    /// Resolves once a frame arrives after `observed`.
    async fn received_after(&self, observed: Instant) {
        loop {
            let notified = self.received.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.last_received() > observed {
                return;
            }
            notified.await;
        }
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
        self.recover_by(observed_generation, None).await
    }

    /// Recover the carrier of `observed_generation`. One recovery owns the
    /// redials at a time; a caller with a deadline that finds one running
    /// wakes it and waits for its result, never longer than the deadline.
    async fn recover_by(
        &self,
        observed_generation: u64,
        deadline: Option<tokio::time::Instant>,
    ) -> Result<(), ConnectionError> {
        if self.session_unavailable() {
            return Err(ConnectionError::SessionUnavailable);
        }
        let mut close_state = self.close_state.subscribe();
        let _reconnecting = match deadline {
            None => self.lock_reconnecting(&mut close_state).await?,
            Some(deadline) => {
                // An action is a trigger: a parked recovery dials now.
                self.actions.send_modify(|count| *count = count.wrapping_add(1));
                let mut generation = self.generation.subscribe();
                let mut owner_close = self.close_state.subscribe();
                let lock = self.lock_reconnecting(&mut owner_close);
                tokio::select! {
                    biased;
                    guard = lock => guard?,
                    _ = generation.wait_for(|generation| *generation != observed_generation) => {
                        return Ok(());
                    }
                    () = tokio::time::sleep_until(deadline) => {
                        return Err(ConnectionError::ReconnectDeadlineExceeded { attempts: 0 });
                    }
                }
            }
        };
        if self.session.read().await.generation() != observed_generation {
            return Ok(());
        }
        // A recovery that failed before ended in a typed error; the session
        // stays gone, and nothing redials it.
        if self.session_unavailable() {
            return Err(ConnectionError::SessionUnavailable);
        }
        self.set_diagnostics_state(ConnectionState::Reconnecting);
        let result = self.recover_locked(&mut close_state, deadline).await;
        if matches!(result, Err(ConnectionError::SessionUnavailable)) {
            self.session_unavailable.store(true, Ordering::Release);
        }
        if result.is_err() && !self.closed.load(Ordering::Acquire) {
            self.set_diagnostics_state(ConnectionState::Disconnected);
        }
        if self.session_unavailable() {
            self.retire_gone_session().await;
        }
        result
    }

    /// Close the carrier of a session the daemon no longer has, so a reader
    /// still blocked on it wakes and sees the typed end instead of waiting
    /// on a link nothing will answer. Bounded and detached, as retirement is.
    async fn retire_gone_session(&self) {
        let current = self.session.read().await.clone();
        tokio::spawn(async move {
            let _ = tokio::time::timeout(TERMINAL_SHUTDOWN_TIMEOUT, current.close()).await;
        });
    }

    /// Spend one redial token, waiting for the refill when the bucket is
    /// empty. A token that would arrive after `deadline` ends the wait now.
    async fn spend_redial_token(
        &self,
        deadline: Option<tokio::time::Instant>,
        attempts: u32,
        close_state: &mut watch::Receiver<CloseState>,
    ) -> Result<(), ConnectionError> {
        loop {
            let next = {
                let mut bucket =
                    self.redial_budget.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                match bucket.take(tokio::time::Instant::now()) {
                    Ok(()) => return Ok(()),
                    Err(next) => next,
                }
            };
            if deadline.is_some_and(|deadline| next > deadline) {
                return Err(ConnectionError::ReconnectDeadlineExceeded { attempts });
            }
            self.set_diagnostics_state(ConnectionState::Disconnected);
            tokio::select! {
                biased;
                _ = close_state.changed() => return Err(ConnectionError::Closed),
                () = tokio::time::sleep_until(next) => {}
            }
        }
    }

    /// Redial in bursts until the carrier is back, the caller's deadline or
    /// the policy's bound passes, or a non-retryable error. A burst is
    /// `attempts_per_recovery` redials: the first at once, then after the
    /// jittered `initial_delay` and four times that. Then the recovery parks
    /// until a caller action, a network change or the jittered
    /// `maximum_delay`, whichever is first. Every redial spends a budget
    /// token. A network change abandons a dial in flight and dials again.
    async fn recover_locked(
        &self,
        close_state: &mut watch::Receiver<CloseState>,
        caller_deadline: Option<tokio::time::Instant>,
    ) -> Result<(), ConnectionError> {
        let policy = self.config.reconnect;
        let policy_deadline = match policy.maximum_duration {
            Some(duration) => {
                Some(tokio::time::Instant::now().checked_add(duration).ok_or_else(|| {
                    ConnectionError::Protocol(
                        "reconnect maximum duration cannot be represented".into(),
                    )
                })?)
            }
            None => None,
        };
        let recovery_deadline = match (policy_deadline, caller_deadline) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let remaining = |bound: Duration| {
            recovery_deadline
                .map(|deadline| {
                    bound.min(deadline.saturating_duration_since(tokio::time::Instant::now()))
                })
                .unwrap_or(bound)
        };
        let mut actions = self.actions.subscribe();
        actions.borrow_and_update();
        let mut network = self.network.subscribe();
        network.borrow_and_update();
        let mut attempt = 0_u32;
        let mut in_burst = 0_u32;
        let mut delay = policy.initial_delay;
        let mut group = self.group.read().await.clone();
        eprintln!("G4TRACE recovery start deadline={:?}", recovery_deadline.map(|d| d.saturating_duration_since(tokio::time::Instant::now())));
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            if recovery_deadline.is_some_and(|deadline| tokio::time::Instant::now() >= deadline) {
                return Err(ConnectionError::ReconnectDeadlineExceeded { attempts: attempt });
            }
            eprintln!("G4TRACE loop top attempt={attempt}");
            self.spend_redial_token(recovery_deadline, attempt, close_state).await?;
            eprintln!("G4TRACE token spent");
            attempt = attempt.saturating_add(1);
            in_burst = in_burst.saturating_add(1);
            self.set_diagnostics_state(ConnectionState::Reconnecting);
            let attempt_timeout = remaining(policy.attempt_timeout);
            let attempt_started = tokio::time::Instant::now();
            // This dial starts on the network as it is now; only a change
            // while it is in flight abandons it.
            network.borrow_and_update();
            let mut network_moved = false;
            let reconnect = tokio::select! {
                biased;
                _ = close_state.changed() => return Err(ConnectionError::Closed),
                reconnect = tokio::time::timeout(attempt_timeout, self.reconnect_once(group.clone())) => reconnect,
                // A dial on the network that just went away may hang until
                // its timeout; drop it and dial on the new one.
                _ = network.changed() => {
                    network_moved = true;
                    Ok(Err(ConnectionError::Link(LinkError::Transport(
                        "network changed during the redial".into(),
                    ))))
                }
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
                            timeout: policy.attempt_timeout,
                        }
                    },
                ),
            };
            eprintln!("G4TRACE reconnect_once ended ok={}", result.is_ok());
            if self.closed.load(Ordering::Acquire) && result.is_ok() {
                return Err(ConnectionError::Closed);
            }
            if let Some(hooks) = self.resume_hooks() {
                hooks.attempt_ended(result.as_ref().map(|_| ()), attempt_started.elapsed());
            }
            // Every failed redial is the reason the link reports, a gone session too.
            self.set_last_failure(result.as_ref().err().map(ToString::to_string));
            match result {
                Ok(()) => {
                    if !self.closed.load(Ordering::Acquire) {
                        self.set_diagnostics_state(ConnectionState::Connected);
                    }
                    return Ok(());
                }
                Err(error) if retryable_connection_error(&error) => {
                    if policy.maximum_attempts.is_some_and(|maximum| attempt >= maximum) {
                        return Err(ConnectionError::ReconnectExhausted {
                            attempts: attempt,
                            last: error.to_string(),
                        });
                    }
                    if let Some(source) = &self.reconnect_groups {
                        let next = tokio::select! {
                            biased;
                            _ = close_state.changed() => return Err(ConnectionError::Closed),
                            // Discovery dials relay or peer transports too; one
                            // on the network that went away is dropped, and the
                            // new burst below dials the current group at once.
                            _ = network.changed() => {
                                network_moved = true;
                                None
                            }
                            next = async {
                                if let Some(deadline) = recovery_deadline
                                    && tokio::time::Instant::now() >= deadline
                                {
                                    return None;
                                }
                                let discovery = resolve_reconnect_group(
                                    source.as_ref(), policy.attempt_timeout,
                                );
                                match recovery_deadline {
                                    Some(deadline) => tokio::time::timeout_at(deadline, discovery).await.unwrap_or(None),
                                    None => tokio::time::timeout(policy.attempt_timeout, discovery).await.unwrap_or(None),
                                }
                            } => next,
                        };
                        eprintln!("G4TRACE next_group some={}", next.is_some());
                        if let Some(next) = next {
                            group = next;
                        }
                    }
                    if network_moved || network.has_changed().unwrap_or(false) {
                        // A new network starts a new burst at once.
                        network.borrow_and_update();
                        in_burst = 0;
                        delay = policy.initial_delay;
                        continue;
                    }
                    let parking = in_burst >= policy.attempts_per_recovery;
                    let wait = if parking {
                        self.set_diagnostics_state(ConnectionState::Disconnected);
                        policy.retry_delay(policy.maximum_delay)
                    } else {
                        policy.retry_delay(delay)
                    };
                    let wait = remaining(wait);
                    eprintln!("G4TRACE wait {wait:?} parking={parking}");
                    // Any change seen before this wait counts: an action
                    // while a redial was in flight still wakes the park.
                    let woken = tokio::select! {
                        biased;
                        _ = close_state.changed() => return Err(ConnectionError::Closed),
                        _ = network.changed() => true,
                        _ = actions.changed(), if parking => true,
                        () = tokio::time::sleep(wait) => false,
                    };
                    if parking || woken {
                        in_burst = 0;
                        delay = policy.initial_delay;
                    } else {
                        delay = delay.saturating_mul(4).min(policy.maximum_delay);
                    }
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
    // A network change probes at once instead of at the next interval.
    let mut network = initial.network.subscribe();
    network.borrow_and_update();
    drop(initial);
    loop {
        let network_moved = tokio::select! {
            biased;
            _ = close_state.changed() => return,
            _ = network.changed() => true,
            _ = tokio::time::sleep(interval) => false,
        };
        let Some(connection) = weak.upgrade() else { return };
        if connection.closed.load(Ordering::Acquire) || connection.session_unavailable() {
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
        // After a network change the old route may be gone with a write stuck on it: the
        // probe queues behind that write and never goes out. Waiting the full answer window
        // for it held a blocked link up to 4 s past the change; give it the short one.
        let timeout =
            if network_moved { timeout.min(NETWORK_CHANGE_PROBE_TIMEOUT) } else { timeout };
        let mut deadline = tokio::time::Instant::now() + timeout;
        let send = connection.send_in_generation(
            Some(generation),
            Lane::Control,
            0,
            Bytes::new(),
            FrameFlags::HEARTBEAT_REQUEST,
        );
        let Ok(send_result) = probe_by(send, &mut deadline, &mut network, &mut close_state).await
        else {
            return;
        };
        match send_result {
            Some(Ok(_)) => {}
            Some(Err(_)) => continue,
            None => {
                let _ = connection.recover(generation).await;
                continue;
            }
        }
        let answer = connection.probe_liveness(generation, observed);
        let Ok(live) = probe_by(answer, &mut deadline, &mut network, &mut close_state).await else {
            return;
        };
        let live = live.unwrap_or(false);
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

/// Await one phase of a heartbeat probe until `deadline`: `Ok(None)` when it passes, `Err` when
/// the connection closes. A network change meanwhile pulls `deadline` in to
/// [`NETWORK_CHANGE_PROBE_TIMEOUT`] from the change, so a probe already stuck behind a write
/// on the route that went away does not wait out the full answer window.
async fn probe_by<T>(
    phase: impl Future<Output = T>,
    deadline: &mut tokio::time::Instant,
    network: &mut watch::Receiver<u64>,
    close_state: &mut watch::Receiver<CloseState>,
) -> Result<Option<T>, ()> {
    tokio::pin!(phase);
    loop {
        tokio::select! {
            biased;
            result = tokio::time::timeout_at(*deadline, phase.as_mut()) => return Ok(result.ok()),
            _ = close_state.changed() => return Err(()),
            Ok(()) = network.changed() => {
                let short = tokio::time::Instant::now() + NETWORK_CHANGE_PROBE_TIMEOUT;
                *deadline = (*deadline).min(short);
            }
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
            return Err(ConnectionError::SessionUnavailable);
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
    GenerationChanged {
        expected: u64,
        actual: u64,
    },
    ReconnectExhausted {
        attempts: u32,
        last: String,
    },
    ReconnectAttemptTimedOut {
        timeout: Duration,
    },
    ReconnectDeadlineExceeded {
        attempts: u32,
    },
    ShutdownTimedOut,
    Closed,
    /// The daemon refused the reconnect because it no longer has the logical
    /// session: it outlived the daemon's resume lease, or the daemon closed
    /// it. Not retryable: nothing can resume it, so the caller should stop
    /// redialing and offer a new session.
    SessionUnavailable,
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
            Self::SessionUnavailable => formatter.write_str(
                "daemon no longer has the requested logical session (it expired or was closed)",
            ),
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
