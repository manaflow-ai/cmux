use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_braid_session::LinkFacts;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use futures_util::future::{AbortHandle, Abortable};
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

mod error;
mod handshake;
mod heartbeat;

pub use error::ConnectionError;
use error::{reconnectable_session_error, retryable_connection_error};

use handshake::{Established, establish_physical_links};
pub(crate) use handshake::{LinkRejected, send_link_ready, send_link_rejection};
use heartbeat::run_heartbeat;

const TERMINAL_CLOSE_SEND_TIMEOUT: Duration = Duration::from_secs(1);
const TERMINAL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a probe sent because the network changed may take, write and answer, before the
/// link is redialed. A route that survived the change answers well within it.
const NETWORK_CHANGE_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// The same window for a link on a direct path (our direct socket or a direct tailnet path) with
/// the fast fallback on ([`FAST_FALLBACK_ENV`]). A direct path rides the mapping the change may
/// have just broken, and the bench (hq#23971) saw both direct paths stall 4-5 s at a change while
/// both relays stalled 0; a direct link that answers nothing within this goes to the warm standby
/// at once ([`ReconnectGroupSource::take_standby`]), and the source's own pass races direct again
/// beside it.
const FAST_FALLBACK_PROBE_TIMEOUT: Duration = Duration::from_millis(250);
/// `CMUX_BRAID_FAST_FALLBACK=1` turns the fast fallback on (off by default).
pub const FAST_FALLBACK_ENV: &str = "CMUX_BRAID_FAST_FALLBACK";

fn fast_fallback_enabled() -> bool {
    std::env::var(FAST_FALLBACK_ENV).is_ok_and(|value| matches!(value.trim(), "1" | "on" | "true"))
}

/// How long a probe after a network change waits before the link is redialed: the short window
/// for a direct path when the fast fallback is on, the ordinary one otherwise.
fn network_change_window(direct: bool, fast_fallback: bool) -> Duration {
    if direct && fast_fallback { FAST_FALLBACK_PROBE_TIMEOUT } else { NETWORK_CHANGE_PROBE_TIMEOUT }
}

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

    /// How many routes other than a link's own this source can hand a redial (`None`: it does
    /// not say). A redial races that many behind its first route and no more: a second dial of
    /// one route gains nothing, and on a provider that keeps socket state per peer (iroh) it
    /// disturbs the first. A source that does not say is not raced.
    fn alternates(&self) -> Option<usize> {
        None
    }

    /// A live group already dialed on another route (a warm standby), taken for the redial
    /// about to start. A recovery tries it before the group that just failed, so a dead route
    /// is never redialed first. `None` (the default): no standby, redial as before.
    async fn take_standby(&self) -> Option<StandbyGroup> {
        None
    }
}

/// A warm standby handed to a redial ([`ReconnectGroupSource::take_standby`]).
pub struct StandbyGroup {
    pub group: Arc<dyn LinkGroup>,
    /// How long the redial on it may take before the recovery moves on: a few of its round
    /// trips, not the whole attempt timeout (a standby found dead must cost little).
    pub attempt_timeout: Duration,
    /// When the source's own pass ([`ReconnectGroupSource::next_group`]) starts beside the
    /// redial on the standby, so a standby that turns out dead already has a group behind it
    /// (`None`: only after it failed).
    pub race_after: Option<Duration>,
}

/// Whether the machine behind a link is asleep (a person paused it), read
/// without waking it. A paused Cloud VM is woken by any byte that reaches it,
/// so a link with a gate sends nothing while the gate says asleep and no
/// caller acts: no heartbeat and no redial. The first application send is an
/// action: it goes out as it would, and that byte is the wake.
#[async_trait]
pub trait SleepGate: Send + Sync {
    /// How long the link goes with no application send before it reads the
    /// gate, and how often an idle link reads it (and probes, when awake).
    fn look(&self) -> Duration;
    /// Whether the machine is asleep now. A read that fails answers false:
    /// the link probes as it would without a gate.
    async fn asleep(&self) -> bool;
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
    /// The daemon's last welcome said it takes Noise IK, so a reconnect's links run it and each
    /// gets its welcome one round trip sooner. Cleared when a reconnect fails past its carrier's
    /// open (a daemon rolled back to a build without IK), so the next one runs XX and relearns.
    daemon_takes_ik: AtomicBool,
    /// The daemon's last welcome said it takes early data: a reconnect's IK Control link carries
    /// the Control lane's replay in its first message, so the daemon reads it when the link group
    /// commits instead of a round trip later. Cleared with `daemon_takes_ik`.
    daemon_takes_early_data: AtomicBool,
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
    /// How long the last handshake that won a redial took, from its start to link-ready on
    /// every lane: the next redial starts its second route 1.5 times this after the first
    /// ([`ClientConnection::redial_stagger`]).
    last_handshake: StdMutex<Option<Duration>>,
    /// Read before an idle link sends a heartbeat or redials ([`SleepGate`]).
    sleep_gate: StdMutex<Option<Arc<dyn SleepGate>>>,
    /// When the application last sent a frame (heartbeats are not sends).
    last_action: StdMutex<Instant>,
    /// True while the gate said asleep and nothing acted since: the link
    /// sends nothing. An application send clears it.
    quiet: watch::Sender<bool>,
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
        let Established {
            link,
            daemon_key: daemon_public_key,
            daemon_takes_ik,
            daemon_takes_early_data,
            ..
        } = establish_physical_links(group.clone(), &config, 0, BTreeMap::new(), false, Vec::new())
            .await?;
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
            daemon_takes_ik: AtomicBool::new(daemon_takes_ik),
            daemon_takes_early_data: AtomicBool::new(daemon_takes_early_data),
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
            last_handshake: StdMutex::new(None),
            sleep_gate: StdMutex::new(None),
            last_action: StdMutex::new(Instant::now()),
            quiet: watch::channel(false).0,
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

    /// Install the gate an idle link reads before it sends a heartbeat or
    /// redials ([`SleepGate`]).
    pub fn set_sleep_gate(&self, gate: Arc<dyn SleepGate>) {
        *self.sleep_gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(gate);
    }

    fn sleep_gate(&self) -> Option<Arc<dyn SleepGate>> {
        self.sleep_gate.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Whether the link holds quiet: its gate said asleep and nothing acted since.
    pub fn is_quiet(&self) -> bool {
        *self.quiet.borrow()
    }

    /// An application send: the link is in use, and a quiet hold ends.
    fn note_action(&self) {
        *self.last_action.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Instant::now();
        self.quiet.send_if_modified(|quiet| std::mem::replace(quiet, false));
    }

    /// The gate's look time while the link has had no application send for
    /// that long; `None` without a gate or while the link is in use.
    fn idle_look(&self) -> Option<Duration> {
        let look = self.sleep_gate()?.look();
        let since = self.last_action.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        (since.elapsed() >= look).then_some(look)
    }

    /// Whether the link must send nothing now: it is idle and its gate says
    /// the machine is asleep. Reads the gate (only when idle) and records the
    /// answer as the quiet hold.
    async fn hold_quiet(&self) -> bool {
        let Some(gate) = self.sleep_gate() else { return false };
        if self.idle_look().is_none() {
            self.quiet.send_if_modified(|quiet| std::mem::replace(quiet, false));
            return false;
        }
        let asleep = gate.asleep().await;
        // An action while the read ran wins: its byte is the wake.
        let asleep = asleep && self.idle_look().is_some();
        self.quiet.send_if_modified(|quiet| std::mem::replace(quiet, asleep) != asleep);
        asleep
    }

    /// Returns once the link may send: at once unless it holds quiet, else
    /// at an action or a read that says the machine woke.
    async fn wait_while_asleep(
        &self,
        close_state: &mut watch::Receiver<CloseState>,
    ) -> Result<(), ConnectionError> {
        while self.hold_quiet().await {
            let look = self.sleep_gate().map_or(Duration::from_secs(1), |gate| gate.look());
            let mut quiet = self.quiet.subscribe();
            tokio::select! {
                biased;
                _ = close_state.changed() => return Err(ConnectionError::Closed),
                _ = quiet.wait_for(|quiet| !*quiet) => return Ok(()),
                () = tokio::time::sleep(look) => {}
            }
        }
        Ok(())
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
        if !flags.contains(FrameFlags::HEARTBEAT_REQUEST)
            && !flags.contains(FrameFlags::HEARTBEAT_RESPONSE)
        {
            self.note_action();
        }
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
                    // Replayable traffic the old session took (its sequence was used) was
                    // retained, and recovery sent it with the original sequence on the new
                    // generation. A send that found the old session already closed took
                    // nothing: send it now, or it is lost and the next frame takes its
                    // sequence (a 16 MiB transfer lost a frame at each reconnect).
                    let session = self.by_deadline(deadline, self.session.read()).await?.clone();
                    if session.next_outbound_sequence(lane) > sequence {
                        return Ok(sequence);
                    }
                    continue;
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
        let round = self.begin_redial().await?;
        let established = self.establish_redial(&round, group.clone(), true).await?;
        self.commit_redial(&round, group, established).await
    }

    /// Starts one redial round: burns its generation and fixes what every handshake of the
    /// round carries. A round may dial several routes at once ([`Self::race_redial`]); they
    /// share the generation, so the daemon keeps exactly one of them (it registers one link
    /// group per session and generation, and closes a second).
    async fn begin_redial(&self) -> Result<RedialRound, ConnectionError> {
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
        let mut config = self.config.clone();
        config.expected_daemon = Some(self.daemon_public_key);
        config.auth = match config.auth {
            ClientAuthMode::Invitation { .. } => ClientAuthMode::Enrolled,
            other => other,
        };
        let takes_ik = self.daemon_takes_ik.load(Ordering::Acquire);
        let early_facts = LinkFacts {
            invitation: false,
            pinned_peer: true,
            peer_takes_ik: takes_ik,
            // A resume re-admits the same key with no grant (`crypto::complete_handshake`).
            carries_bearer_secret: false,
        };
        let early = if cmux_braid_session::may_send_early(
            early_facts,
            generation,
            self.daemon_takes_early_data.load(Ordering::Acquire),
        ) {
            current.early_replay(generation, cmux_braid_session::EARLY_DATA_MAX_BYTES)
        } else {
            Vec::new()
        };
        Ok(RedialRound { current, generation, config, takes_ik, early })
    }

    /// One route's handshake in a redial round: transport, Noise and link-ready on every lane.
    /// Changes nothing the session reads, so a racer that loses is dropped with no trace here.
    /// Only the `lead` racer carries the round's early data: a racer started behind it replays
    /// after the commit, as a redial without early data does.
    async fn establish_redial(
        &self,
        round: &RedialRound,
        group: Arc<dyn LinkGroup>,
        lead: bool,
    ) -> Result<Established, ConnectionError> {
        let early = if lead { round.early.clone() } else { Vec::new() };
        let established = establish_physical_links(
            group,
            &round.config,
            round.generation,
            round.current.resume_cursors(),
            round.takes_ik,
            early,
        )
        .await;
        match established {
            Ok(established) => Ok(established),
            Err(error) => {
                // A carrier that would not open says nothing about the daemon; anything past
                // it might be a daemon that no longer takes IK.
                if !matches!(error, ConnectionError::Provider(_)) {
                    self.daemon_takes_ik.store(false, Ordering::Release);
                    self.daemon_takes_early_data.store(false, Ordering::Release);
                }
                Err(error)
            }
        }
    }

    /// Publishes the handshake that won a redial round as the session's new generation.
    async fn commit_redial(
        &self,
        round: &RedialRound,
        group: Arc<dyn LinkGroup>,
        established: Established,
    ) -> Result<(), ConnectionError> {
        let current = round.current.clone();
        let generation = round.generation;
        let Established {
            link,
            daemon_key,
            daemon_resume,
            daemon_takes_ik,
            daemon_takes_early_data,
        } = established;
        self.daemon_takes_ik.store(daemon_takes_ik, Ordering::Release);
        self.daemon_takes_early_data.store(daemon_takes_early_data, Ordering::Release);
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

    /// One racer of a redial round: its group, how long its handshake took, and how it ended.
    /// `bound` ends a racer early (a warm standby found dead must cost little).
    async fn redial_racer(
        &self,
        round: &RedialRound,
        group: Arc<dyn LinkGroup>,
        lead: bool,
        bound: Option<Duration>,
    ) -> (Arc<dyn LinkGroup>, Duration, Result<Established, ConnectionError>) {
        let began = tokio::time::Instant::now();
        let handshake = self.establish_redial(round, group.clone(), lead);
        let result = match bound {
            Some(bound) => tokio::time::timeout(bound, handshake)
                .await
                .unwrap_or(Err(ConnectionError::ReconnectAttemptTimedOut { timeout: bound })),
            None => handshake.await,
        };
        (group, began.elapsed(), result)
    }

    /// One redial round, raced (RFD 0164 Braid, slice B1: "first authenticated reply wins").
    /// The `lead` group dials at once. While no route has connected, the source's next route
    /// starts `stagger` after the one before it, or at once when one fails, at most
    /// [`REDIAL_RACERS`] in flight and never more than the source has routes
    /// ([`ReconnectGroupSource::alternates`]). The first whose handshake finishes (transport, Noise,
    /// link-ready on every lane) is committed; the rest are dropped, which closes them.
    ///
    /// Before this a redial dialed one route for the whole attempt timeout (15 s by default)
    /// and asked for another only after it failed, so a route that accepts a connection and
    /// never answers (a captive portal, a black hole, UDP blocked under QUIC) cost the link
    /// that long per dead route.
    ///
    /// Why two handshakes of one session are safe: every racer carries the round's generation
    /// and its own connection attempt id, and the daemon registers one link group per session
    /// and generation, so it keeps exactly one. A racer that loses has changed nothing here
    /// ([`Self::establish_redial`]). The daemon answers link-ready on a group's last link just
    /// before it registers the group, so two racers finishing within a round trip of each other
    /// can both look connected; if the one committed here is the one the daemon closed, its
    /// link fails at once and the next round redials, as after any lost link.
    ///
    /// Waves. A route that says nothing leaves its dial waiting on its transport's backoff: a
    /// TCP SYN is sent again after 1, 2, 4 and 8 s, a QUIC Initial likewise, so a network that
    /// comes back with no change event (a tunnel, a lift, 8 s of loss) carried the link 2.7 to
    /// 3.8 s later on the routes bench. So while the round has no winner, every
    /// [`REDIAL_WAVE`] the source runs one more pass, and the route it opens races the ones
    /// still hanging: a fresh dial, the same route included. A network change starts a wave at
    /// once and no longer ends the round (the round's dials on the network that stayed were
    /// dropped with it). At most [`REDIAL_WAVE_PASSES`] passes and [`REDIAL_WAVE_RACERS`]
    /// handshakes are in flight; the oldest makes room. `CMUX_REMOTE_REDIAL_WAVE_MS=0` turns
    /// waves off.
    ///
    /// `stagger: None` dials the lead alone (no source, or `CMUX_REMOTE_REDIAL_RACE=0`).
    /// `resolved` gets the last route the source handed over, for the caller's next round.
    async fn race_redial<'a>(
        &'a self,
        lead: Arc<dyn LinkGroup>,
        lead_bound: Option<Duration>,
        stagger: Option<Duration>,
        resolved: &StdMutex<Option<Arc<dyn LinkGroup>>>,
    ) -> Result<(), ConnectionError> {
        let round = self.begin_redial().await?;
        let source = self.reconnect_groups.as_deref().filter(|_| stagger.is_some());
        let wave = source.and(redial_wave());
        let stagger = stagger.unwrap_or_default();
        let resolution_bound = self.config.reconnect.attempt_timeout;
        let racers = REDIAL_RACERS.min(self.redial_alternates().saturating_add(1));
        let mut network = self.network.subscribe();
        network.borrow_and_update();
        // One racer: abortable, so a wave can take the oldest one's place.
        let racer = |group: Arc<dyn LinkGroup>, lead: bool, bound: Option<Duration>| {
            let (handle, registration) = AbortHandle::new_pair();
            (handle, Abortable::new(self.redial_racer(&round, group, lead, bound), registration))
        };
        // One pass of the source: the stagger chain's (`wave: false`) or a wave's.
        let pass = |source: &'a dyn ReconnectGroupSource, wave: bool| {
            let (handle, registration) = AbortHandle::new_pair();
            let pass =
                async move { (wave, resolve_reconnect_group(source, resolution_bound).await) };
            (handle, Abortable::new(Box::pin(pass), registration))
        };
        // Every group this round dialed (the winner's losers are closed), and the ones whose
        // handshake is still in flight, oldest first.
        let mut racing = vec![lead.clone()];
        let mut flying = std::collections::VecDeque::new();
        let mut handshakes = FuturesUnordered::new();
        let (handle, first) = racer(lead.clone(), true, lead_bound);
        flying.push_back((lead, handle));
        handshakes.push(first);
        let mut passes = FuturesUnordered::new();
        let mut wave_passes = std::collections::VecDeque::new();
        let mut chain_pending = false;
        let mut sourced_out = source.is_none();
        let mut next_at = Some(tokio::time::Instant::now() + stagger);
        let mut wave_at = wave.map(|wave| tokio::time::Instant::now() + wave);
        let mut last_error = None;
        loop {
            let may_start = !sourced_out && !chain_pending && racing.len() < racers;
            if flying.is_empty() && !chain_pending {
                if !may_start {
                    // Every route answered with a failure: the caller's backoff decides when
                    // to try again. Waves are for routes that say nothing.
                    return Err(last_error.unwrap_or(ConnectionError::ReconnectAttemptTimedOut {
                        timeout: resolution_bound,
                    }));
                }
                // Every racer failed: the next route starts now, not at its stagger.
                next_at = Some(tokio::time::Instant::now());
            }
            tokio::select! {
                biased;
                Some(ended) = handshakes.next(), if !handshakes.is_empty() => {
                    // An aborted racer: a wave took its place.
                    let Ok((group, took, result)) = ended else { continue };
                    flying.retain(|(racer, _)| !Arc::ptr_eq(racer, &group));
                    match result {
                        Ok(established) => {
                            // Closed now, not when its last handle drops: until then a
                            // loser's transport may keep a dead path selected for the peer.
                            for loser in racing.iter().filter(|racer| !Arc::ptr_eq(racer, &group)) {
                                loser.abandon();
                            }
                            *self
                                .last_handshake
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(took);
                            return self.commit_redial(&round, group, established).await;
                        }
                        // A failure no other route cures (the session is gone, the daemon's
                        // key changed) ends the round, as it ended the single redial.
                        Err(error) if !retryable_connection_error(&error) => return Err(error),
                        Err(error) => {
                            last_error = Some(error);
                            // A failed route frees its place: the next one starts at once.
                            next_at = Some(tokio::time::Instant::now());
                        }
                    }
                }
                Some(ended) = passes.next(), if !passes.is_empty() => {
                    match ended {
                        // The oldest wave pass, dropped for a newer one.
                        Err(_) => {}
                        Ok((false, found)) => {
                            chain_pending = false;
                            match found {
                                Some(group)
                                    if !racing.iter().any(|racer| same_route(racer, &group)) =>
                                {
                                    *resolved
                                        .lock()
                                        .unwrap_or_else(std::sync::PoisonError::into_inner) =
                                        Some(group.clone());
                                    racing.push(group.clone());
                                    let (handle, next) = racer(group.clone(), false, None);
                                    flying.push_back((group, handle));
                                    handshakes.push(next);
                                    next_at = Some(tokio::time::Instant::now() + stagger);
                                }
                                // The source has no other route (it handed back one already
                                // racing), or found none in time.
                                _ => sourced_out = true,
                            }
                        }
                        // A wave's pass opened a route just now, so the network carries it
                        // now: it races whatever is still hanging, the same route too (a dial
                        // from before a drop waits out its transport's backoff). The same
                        // group handed back is no fresh dial.
                        Ok((true, Some(group)))
                            if !flying.iter().any(|(racer, _)| Arc::ptr_eq(racer, &group)) =>
                        {
                            if flying.len() >= REDIAL_WAVE_RACERS
                                && let Some((oldest, handle)) = flying.pop_front()
                            {
                                handle.abort();
                                oldest.abandon();
                            }
                            *resolved.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                                Some(group.clone());
                            racing.push(group.clone());
                            let (handle, next) = racer(group.clone(), false, None);
                            flying.push_back((group, handle));
                            handshakes.push(next);
                        }
                        Ok((true, _)) => {}
                    }
                }
                // A network change is a wave now, not the end of the round: what is in flight
                // on the network that stayed keeps going, and a fresh pass dials on the new one.
                Ok(()) = network.changed(), if wave.is_some() => {
                    wave_at = Some(tokio::time::Instant::now());
                }
                () = sleep_until_or_never(next_at), if may_start => {
                    if let Some(source) = source {
                        let (_, next) = pass(source, false);
                        passes.push(next);
                        chain_pending = true;
                    }
                }
                () = sleep_until_or_never(wave_at), if wave.is_some() => {
                    if let (Some(source), Some(wave)) = (source, wave) {
                        if wave_passes.len() >= REDIAL_WAVE_PASSES
                            && let Some(oldest) = wave_passes.pop_front()
                        {
                            AbortHandle::abort(&oldest);
                        }
                        let (handle, next) = pass(source, true);
                        wave_passes.push_back(handle);
                        passes.push(next);
                        wave_at = Some(tokio::time::Instant::now() + wave);
                    }
                }
            }
        }
    }

    /// When a redial's second route starts beside its first: a warm standby's own stagger, else
    /// 1.5 times the last winning handshake (`cmux_braid_path::stagger_after`, at least
    /// [`cmux_braid_path::race::STAGGER_FLOOR`], at most [`REDIAL_STAGGER_CEILING`]), else
    /// [`REDIAL_STAGGER_UNKNOWN`]. `None`: the redial is not raced (its source has no other
    /// route to hand over, or `CMUX_REMOTE_REDIAL_RACE=0`).
    fn redial_stagger(&self, standby: Option<Duration>) -> Option<Duration> {
        if self.redial_alternates() == 0 || !redial_race_enabled() {
            return None;
        }
        if standby.is_some() {
            return standby;
        }
        let last = *self.last_handshake.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        Some(match last {
            Some(last) => cmux_braid_path::stagger_after(
                Some(last),
                cmux_braid_path::race::STAGGER_FLOOR,
                REDIAL_STAGGER_CEILING,
            ),
            None => REDIAL_STAGGER_UNKNOWN,
        })
    }

    /// The routes a redial may race behind its first ([`ReconnectGroupSource::alternates`]).
    fn redial_alternates(&self) -> usize {
        self.reconnect_groups.as_ref().and_then(|source| source.alternates()).unwrap_or(0)
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
        // A redial reaches the machine: a background recovery of an idle link
        // whose machine is asleep waits for an action (an application send)
        // or a read that says it woke, before its deadline starts.
        if deadline.is_none() {
            self.wait_while_asleep(&mut close_state).await?;
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
        // The path the link was on: a standby on the same one died with it.
        let failed_path =
            group.transport_snapshot().await.selected_path.and_then(|path| path.remote);
        // The link this recovery replaces failed: its QUIC connection would hold the next
        // stream on the dead path until iroh's 15 s path idle timeout (then a 10 s close), the
        // ~30 s reconnect the black-hole bench measured. A fresh dial takes one handshake.
        group.abandon();
        loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(ConnectionError::Closed);
            }
            if recovery_deadline.is_some_and(|deadline| tokio::time::Instant::now() >= deadline) {
                return Err(ConnectionError::ReconnectDeadlineExceeded { attempts: attempt });
            }
            self.spend_redial_token(recovery_deadline, attempt, close_state).await?;
            attempt = attempt.saturating_add(1);
            in_burst = in_burst.saturating_add(1);
            self.set_diagnostics_state(ConnectionState::Reconnecting);
            // A warm standby goes first, on a short bound, with the source's pass started
            // behind it: the group that just failed is not redialed while one is held.
            let standby = match &self.reconnect_groups {
                Some(source) => source.take_standby().await,
                None => None,
            };
            let standby = match standby {
                Some(standby) if on_path(&standby.group, failed_path.as_deref()).await => {
                    // Its transport moved it onto the path that just died: trying it would
                    // spend its bound on a black hole. Closed, and the redial goes as without one.
                    standby.group.abandon();
                    None
                }
                standby => standby,
            };
            // The redial races the source's other routes behind its first ([`Self::race_redial`]):
            // a standby says when (`race_after`; never, without one), a plain redial goes by the
            // last handshake's time.
            let stagger = match &standby {
                Some(standby) => {
                    standby.race_after.and_then(|after| self.redial_stagger(Some(after)))
                }
                None => self.redial_stagger(None),
            };
            // A raced round has the whole attempt timeout: only its standby is held to the
            // standby's short bound, so a slower route behind it is not cut off with it.
            let standby_bound =
                standby.as_ref().map(|standby| standby.attempt_timeout.min(policy.attempt_timeout));
            let attempt_bound = match (stagger, standby_bound) {
                (None, Some(bound)) => bound,
                _ => policy.attempt_timeout,
            };
            let attempt_timeout = remaining(attempt_bound);
            let attempt_started = tokio::time::Instant::now();
            let attempt_group =
                standby.as_ref().map_or_else(|| group.clone(), |standby| standby.group.clone());
            // Without the race, the source's pass still starts behind a standby, and its group
            // is the next round's.
            let behind_at = standby
                .as_ref()
                .and_then(|standby| standby.race_after)
                .filter(|_| self.reconnect_groups.is_some() && stagger.is_none())
                .map(|after| attempt_started + after);
            let resolved = StdMutex::new(None);
            let behind = async {
                match (behind_at, &self.reconnect_groups) {
                    (Some(at), Some(source)) => {
                        tokio::time::sleep_until(at).await;
                        resolve_reconnect_group(source.as_ref(), policy.attempt_timeout).await
                    }
                    _ => std::future::pending().await,
                }
            };
            tokio::pin!(behind);
            let mut raced: Option<Option<Arc<dyn LinkGroup>>> = None;
            // The attempt's report, owed even when this recovery is dropped:
            // a reader whose `select!` sees the published generation first
            // cancels the receive that runs it, after the new carrier is up.
            let mut report = AttemptReport::new(self, attempt_started);
            // This dial starts on the network as it is now; only a change
            // while it is in flight abandons it.
            network.borrow_and_update();
            let mut network_moved = false;
            // A raced round takes a network change as a wave ([`Self::race_redial`]).
            let waves = stagger.is_some() && redial_wave().is_some();
            let dial = tokio::time::timeout(attempt_timeout, async {
                match stagger {
                    Some(_) => {
                        self.race_redial(attempt_group, standby_bound, stagger, &resolved).await
                    }
                    None => self.reconnect_once(attempt_group).await,
                }
            });
            tokio::pin!(dial);
            let reconnect = loop {
                tokio::select! {
                    biased;
                    _ = close_state.changed() => return Err(ConnectionError::Closed),
                    reconnect = &mut dial => break reconnect,
                    // A dial on the network that just went away may hang until
                    // its timeout; drop it and dial on the new one.
                    _ = network.changed(), if !waves => {
                        network_moved = true;
                        break Ok(Err(ConnectionError::Link(LinkError::Transport(
                            "network changed during the redial".into(),
                        ))));
                    }
                    found = &mut behind, if raced.is_none() => raced = Some(found),
                }
            };
            // The last route a raced round was handed is the next round's first.
            if let Some(next) =
                resolved.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
            {
                raced = Some(Some(next));
            }
            let result = match reconnect {
                Ok(result) => result,
                Err(_) => Err(
                    if recovery_deadline
                        .is_some_and(|deadline| tokio::time::Instant::now() >= deadline)
                    {
                        ConnectionError::ReconnectDeadlineExceeded { attempts: attempt }
                    } else {
                        ConnectionError::ReconnectAttemptTimedOut { timeout: attempt_bound }
                    },
                ),
            };
            if self.closed.load(Ordering::Acquire) && result.is_ok() {
                return Err(ConnectionError::Closed);
            }
            report.ended(result.as_ref().map(|_| ()));
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
                    // A dead or slow standby is dropped with this attempt: the source took it
                    // out of its slot, so this was its last handle and QUIC closes it on drop.
                    // The pass already behind the standby is the next group; one not started
                    // yet is started now (below) instead of waiting out its stagger.
                    if let Some(standby) = &standby {
                        // Closed now, not when its last handle drops: until then its transport
                        // may keep the dead path selected for the peer.
                        standby.group.abandon();
                    }
                    let behind_started =
                        behind_at.is_some_and(|at| tokio::time::Instant::now() >= at);
                    if let Some(found) = raced.take() {
                        if let Some(next) = found {
                            group = next;
                        }
                    } else if let Some(source) = &self.reconnect_groups {
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
                                let discovery = async {
                                    if behind_started {
                                        (&mut behind).await
                                    } else {
                                        resolve_reconnect_group(
                                            source.as_ref(), policy.attempt_timeout,
                                        ).await
                                    }
                                };
                                match recovery_deadline {
                                    Some(deadline) => tokio::time::timeout_at(deadline, discovery).await.unwrap_or(None),
                                    None => tokio::time::timeout(policy.attempt_timeout, discovery).await.unwrap_or(None),
                                }
                            } => next,
                        };
                        if let Some(next) = next {
                            group = next;
                        }
                    }
                    if standby.is_some() && !network_moved {
                        // The standby try was not this burst's redial: the next one goes now.
                        in_burst = in_burst.saturating_sub(1);
                        continue;
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

/// One resume attempt's [`ResumeHooks::attempt_ended`] call, made once:
/// with the attempt's result, or, when the attempt is dropped before it
/// ends (its caller was cancelled), `Ok` if it had already published a new
/// generation and nothing otherwise.
struct AttemptReport<'a> {
    connection: &'a ClientConnection,
    started: tokio::time::Instant,
    generation: u64,
    done: bool,
}

impl<'a> AttemptReport<'a> {
    fn new(connection: &'a ClientConnection, started: tokio::time::Instant) -> Self {
        let generation = *connection.generation.borrow();
        Self { connection, started, generation, done: false }
    }

    fn ended(&mut self, result: Result<(), &ConnectionError>) {
        self.done = true;
        if let Some(hooks) = self.connection.resume_hooks() {
            hooks.attempt_ended(result, self.started.elapsed());
        }
    }
}

impl Drop for AttemptReport<'_> {
    fn drop(&mut self) {
        if !self.done && *self.connection.generation.borrow() != self.generation {
            self.ended(Ok(()));
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

/// What every handshake of one redial round carries ([`ClientConnection::begin_redial`]).
struct RedialRound {
    /// The session the round resumes.
    current: ReliableSession,
    /// The generation the round burns, shared by its racers.
    generation: u64,
    config: ClientConnectionConfig,
    takes_ik: bool,
    /// The Control lane's replay, for the lead racer's first message.
    early: Vec<Bytes>,
}

/// Routes dialed at once in a redial round, as `cmux_braid_path::RacePolicy::INTERNET` keeps.
const REDIAL_RACERS: usize = 3;
/// The longest a slow route holds the next one back in a redial round.
const REDIAL_STAGGER_CEILING: Duration = Duration::from_secs(2);
/// The stagger of a redial with no handshake time to go by (RFC 8305's default delay).
const REDIAL_STAGGER_UNKNOWN: Duration = Duration::from_millis(250);

/// How often a redial round with no winner dials afresh ([`ClientConnection::race_redial`]).
/// The source's pass staggers its own routes behind its first, so with three routes a fresh
/// dial leaves about every 250 ms.
const REDIAL_WAVE: Duration = Duration::from_millis(750);
/// Passes of the source a round keeps in flight for its waves: the oldest is 3 s old when it
/// makes room, longer than a route takes to open on any network that carries a terminal.
const REDIAL_WAVE_PASSES: usize = 4;
/// Handshakes a round keeps in flight once waves add to them.
const REDIAL_WAVE_RACERS: usize = 6;

/// The wave interval: [`REDIAL_WAVE`], or `CMUX_REMOTE_REDIAL_WAVE_MS` (0: no waves, and a
/// network change ends the round as before).
fn redial_wave() -> Option<Duration> {
    let wave = match std::env::var("CMUX_REMOTE_REDIAL_WAVE_MS").ok().map(|ms| ms.parse::<u64>()) {
        Some(Ok(ms)) => Duration::from_millis(ms),
        _ => REDIAL_WAVE,
    };
    (!wave.is_zero()).then_some(wave)
}

/// `CMUX_REMOTE_REDIAL_RACE=0` dials one route per redial again (the A/B for the race's
/// numbers, and the switch if it misbehaves).
fn redial_race_enabled() -> bool {
    std::env::var_os("CMUX_REMOTE_REDIAL_RACE").is_none_or(|value| value != "0")
}

/// Whether two groups are the same route: the same group, or one with the same label and
/// carrier facts (a source with one route hands back a new group for it each time).
fn same_route(a: &Arc<dyn LinkGroup>, b: &Arc<dyn LinkGroup>) -> bool {
    Arc::ptr_eq(a, b) || (a.description() == b.description() && a.evidence() == b.evidence())
}

/// Waits until `at`, or forever without one.
async fn sleep_until_or_never(at: Option<tokio::time::Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}
