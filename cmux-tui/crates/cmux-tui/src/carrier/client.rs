//! One carrier dial: a cmux-remote client session over the machine's relay
//! slot (`relay+do`), admitted by a carrier grant and pinned to the daemon
//! key the platform names, with every attempt inside one deadline.
//!
//! Each attempt fetches a fresh ticket and grant (a grant is single-use),
//! opens the relay's control socket, waits for the lane allocation (the
//! relay parks it until the machine's daemon registers) until the deadline,
//! then runs the Noise handshake. A failed attempt backs off with full
//! jitter while time is left. Once up, the session's own reconnect carries
//! it: a resume presents no grant (the daemon re-admits the Noise key a
//! grant admitted, into its own session), so it needs nothing from the
//! platform but relay tickets.
//!
//! The first attempt can start from a handed-over answer ([`Prefetched`]: a
//! create's or spare claim's `carrier`) instead of asking. When that answer
//! has no `daemon_key` (a fresh create: the bind stores the key later), the
//! attempt opens the relay link at once and asks the platform for the key
//! while the relay holds the link for the machine's daemon. If that ask comes
//! back before the bind and still has no key, it asks once more when the
//! link is allocated: the daemon registers only after its bind, so the key
//! is stored by then. The handshake always waits for the key: it never runs
//! unpinned.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote::bridge::OpenedMuxControl;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy, ResumeHooks,
};
use cmux_remote::crypto::{ClientAuthMode, CryptoError, StaticIdentity};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkGroup, LinkRequest, ProviderError, RelayClientConfig,
    RelayCredentialSource, RelayProvider, TransportProvider, lane_bindings,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::answer::{CarrierAnswer, CarrierSource, Prefetched, SourceError, TicketCache};
use super::contract::{
    Backoff, Failure, Phase, PhaseTimes, PhasesOf, Step, phases_line, route_line,
};

/// The relay's frame bound for a carrier (the Mac's remote client uses the same).
const MAX_FRAME_BYTES: usize = 65_535;
/// Each relay control step other than the parked allocation.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
/// The Noise handshake of one attempt, at most.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// A connected carrier session.
pub(super) struct Dialed {
    pub connection: Arc<ClientConnection>,
    pub multiplexer: Arc<ServiceMultiplexer>,
    /// The daemon stream, opened before the dial reports success.
    pub mux: OpenedMuxControl,
    /// The grant's `vmk`, when it has one.
    pub vmk: Option<super::contract::Vmk>,
}

/// What one dial needs.
pub(super) struct DialPlan {
    pub machine: String,
    pub source: Arc<dyn CarrierSource>,
    pub identity: StaticIdentity,
    pub deadline: Instant,
    /// A handed-over answer for the first attempt, if any.
    pub prefetched: Arc<Prefetched>,
    /// Where each attempt's route line goes (stderr in the CLI).
    pub log: Arc<dyn Fn(String) + Send + Sync>,
    /// Where each attempt's phases line goes: the connect log only, never
    /// stderr ([`phases_line`]).
    pub phases: Arc<dyn Fn(String) + Send + Sync>,
}

/// A failure of the connection step: a provider error is the relay's (or,
/// when the deadline ran out while it was parked, the park's); anything
/// else is the handshake's.
pub(super) fn classify(error: &ConnectionError, step: Step) -> Failure {
    let detail = error.to_string();
    match error {
        ConnectionError::Provider(provider) if step <= Step::Parked => {
            if detail.contains("allocation timed out") {
                Failure::retry(Step::Parked, detail)
            } else if provider.is_retryable_carrier_failure() {
                Failure::retry(Step::Relay, detail)
            } else {
                Failure::fatal(Step::Relay, detail)
            }
        }
        // A daemon that is not the pinned one, or that refused the grant: no
        // retry admits it.
        ConnectionError::Crypto(
            CryptoError::DaemonKeyMismatch { .. } | CryptoError::Unauthorized(_),
        ) => Failure::fatal(Step::Handshake, detail),
        _ if error.is_retryable_carrier_failure() => {
            Failure::retry(step.max(Step::Handshake), detail)
        }
        _ => Failure::fatal(step.max(Step::Handshake), detail),
    }
}

/// The daemon key a dial pins: required, never learned from the handshake.
pub(super) fn pinned_daemon(answer: &CarrierAnswer) -> Result<[u8; 32], Failure> {
    answer.daemon_key.ok_or_else(|| Failure::fatal(Step::Ticket, "the machine has no daemon key"))
}

fn source_failure(error: SourceError) -> Failure {
    Failure { step: Step::Ticket, detail: error.detail, retryable: error.retryable }
}

/// A [`LinkGroup`] that records how far an attempt got: the relay's
/// allocation (parked until the daemon registers) while a link opens, the
/// handshake once one is open.
struct Tracked {
    inner: Arc<dyn LinkGroup>,
    step: Arc<Progress>,
}

/// How far the current attempt got, shared with its [`Tracked`] group so a
/// deadline cut can name the step, and when it reached each step.
#[derive(Default)]
pub(super) struct Progress {
    step: AtomicU8,
    marks: std::sync::Mutex<Marks>,
}

/// When one attempt reached each of its steps (see [`PhaseTimes`]).
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct Marks {
    pub started: Option<Instant>,
    pub answered: Option<Instant>,
    pub relay_up: Option<Instant>,
    pub first_open: Option<Instant>,
    pub first_allocated: Option<Instant>,
    pub connected: Option<Instant>,
    pub mux_open: Option<Instant>,
    pub lanes: u32,
}

impl Marks {
    /// The steps' durations as of `now`: a step runs from the mark that
    /// starts it to the one that ends it, or to `now` when it has not ended.
    pub(super) fn times(&self, now: Instant) -> PhaseTimes {
        let span = |from: Option<Instant>, to: Option<Instant>| {
            from.map_or(Duration::ZERO, |from| to.unwrap_or(now).saturating_duration_since(from))
        };
        PhaseTimes {
            ticket: span(self.started, self.answered),
            relay: span(self.answered, self.relay_up),
            parked: span(self.first_open, self.first_allocated),
            handshake: span(self.first_allocated, self.connected),
            mux: span(self.connected, self.mux_open),
            lanes: self.lanes,
        }
    }
}

impl Progress {
    fn set(&self, step: Step) {
        self.step.store(step_code(step), Ordering::SeqCst);
    }

    fn advance(&self, step: Step) {
        self.step.fetch_max(step_code(step), Ordering::SeqCst);
    }

    pub(super) fn get(&self) -> Step {
        step_of(self.step.load(Ordering::SeqCst))
    }

    fn mark(&self, write: impl FnOnce(&mut Marks)) {
        write(&mut self.marks.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
    }

    /// Every step's duration so far.
    pub(super) fn times(&self) -> PhaseTimes {
        self.marks.lock().unwrap_or_else(std::sync::PoisonError::into_inner).times(Instant::now())
    }
}

fn step_code(step: Step) -> u8 {
    step as u8
}

fn step_of(code: u8) -> Step {
    [Step::Ticket, Step::Relay, Step::Parked, Step::Handshake]
        .into_iter()
        .find(|step| step_code(*step) == code)
        .unwrap_or(Step::Handshake)
}

#[async_trait]
impl LinkGroup for Tracked {
    fn description(&self) -> &str {
        self.inner.description()
    }
    fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
        self.inner.capabilities()
    }
    fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
        self.inner.evidence()
    }
    async fn transport_snapshot(&self) -> cmux_remote::observability::TransportSnapshot {
        self.inner.transport_snapshot().await
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        self.step.advance(Step::Parked);
        self.step.mark(|marks| {
            marks.lanes += 1;
            marks.first_open.get_or_insert_with(Instant::now);
        });
        let link = self.inner.open(request).await?;
        self.step.advance(Step::Handshake);
        self.step.mark(|marks| {
            marks.first_allocated.get_or_insert_with(Instant::now);
        });
        Ok(link)
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

fn relay_provider(
    answer: &CarrierAnswer,
    tickets: Arc<TicketCache>,
    deadline: Instant,
) -> Result<RelayProvider, Failure> {
    let credentials = RelayCredentialSource::callback(move || {
        let tickets = tickets.clone();
        async move { tickets.ticket().await }
    });
    RelayProvider::with_credentials(
        RelayClientConfig {
            slot: answer.slot.clone(),
            ticket: String::new(),
            maximum_frame_bytes: MAX_FRAME_BYTES,
            control_timeout: CONTROL_TIMEOUT,
        },
        credentials,
    )
    .map(|provider| provider.with_allocation_deadline(deadline))
    .map_err(|e| Failure::fatal(Step::Relay, e.to_string()))
}

fn random_session() -> Result<SessionId, Failure> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| Failure::fatal(Step::Handshake, e.to_string()))?;
    Ok(SessionId(bytes))
}

/// One attempt, recording its step in `step` as it goes (the caller reads
/// it when the deadline cuts the attempt off).
async fn attempt(
    plan: &DialPlan,
    step: &Arc<Progress>,
    resume: &Arc<Resume>,
) -> Result<Dialed, Failure> {
    step.set(Step::Ticket);
    step.mark(|marks| marks.started = Some(Instant::now()));
    let key = plan.identity.public_key();
    let answer = match plan.prefetched.take_now() {
        Some(answer) => answer,
        None => plan.source.fetch(&plan.machine, Some(&key)).await.map_err(source_failure)?,
    };
    step.mark(|marks| marks.answered = Some(Instant::now()));
    let grant = answer
        .grant
        .clone()
        .ok_or_else(|| Failure::fatal(Step::Ticket, "cmux-platform sent no carrier grant"))?;
    let tickets = TicketCache::new(plan.source.clone(), plan.machine.clone(), &answer);
    step.set(Step::Relay);
    let session = random_session()?;
    let provider = relay_provider(&answer, tickets, plan.deadline)?;
    let group = provider
        .connect(ConnectRequest {
            endpoint: answer.relay.clone(),
            session,
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .map_err(|e| {
            let detail = e.to_string();
            if e.is_retryable_carrier_failure() || matches!(e, ProviderError::Transport(_)) {
                Failure::retry(Step::Relay, detail)
            } else {
                Failure::fatal(Step::Relay, detail)
            }
        })?;
    step.mark(|marks| marks.relay_up = Some(Instant::now()));
    let tracked: Arc<dyn LinkGroup> =
        Arc::new(Tracked { inner: group.clone(), step: step.clone() });
    let (tracked, daemon) = match answer.daemon_key {
        Some(daemon) => (tracked, daemon),
        None => match pin_while_parked(plan, tracked, step).await {
            Ok(pinned) => pinned,
            Err(failure) => {
                let _ = group.close().await;
                return Err(failure);
            }
        },
    };
    let remaining = plan.deadline.saturating_duration_since(Instant::now());
    let config = ClientConnectionConfig {
        identity: plan.identity.clone(),
        expected_daemon: Some(daemon),
        auth: ClientAuthMode::Grant { token: Zeroizing::new(grant.to_string()) },
        device_name: "cmux-carrier".into(),
        session,
        lane_policy: LanePolicy::Auto,
        limits: SessionLimits::default(),
        reconnect: ReconnectPolicy {
            attempt_timeout: HANDSHAKE_TIMEOUT.min(remaining.max(Duration::from_millis(1))),
            ..ReconnectPolicy::default()
        },
    };
    let connection = match ClientConnection::connect(tracked, config).await {
        Ok(connection) => connection,
        Err(error) => {
            let _ = group.close().await;
            return Err(classify(&error, step.get()));
        }
    };
    step.mark(|marks| marks.connected = Some(Instant::now()));
    connection.set_resume_hooks(resume.clone());
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    // A grant that does not admit mux control is refused here, before the
    // reply line says ok.
    let mux = match OpenedMuxControl::open(&multiplexer).await {
        Ok(mux) => mux,
        Err(error) => {
            multiplexer.shutdown().await;
            let _ = connection.close().await;
            return Err(Failure::fatal(
                Step::Handshake,
                format!("the daemon did not open its mux control stream: {error}"),
            ));
        }
    };
    step.mark(|marks| marks.mux_open = Some(Instant::now()));
    Ok(Dialed { connection, multiplexer, mux, vmk: answer.vmk })
}

/// The daemon key of an answer that came without one: asked of the platform
/// (a ticket-only ask; a person's answer carries `daemon_key` whenever the
/// bind stored it) while the first link opens, which the relay holds until
/// the machine's daemon registers. An ask that came back without the key is
/// made once more when the link is allocated. Answers the group to connect
/// on, whose first open is that already allocated link, and the key to pin.
async fn pin_while_parked(
    plan: &DialPlan,
    tracked: Arc<dyn LinkGroup>,
    step: &Arc<Progress>,
) -> Result<(Arc<dyn LinkGroup>, [u8; 32]), Failure> {
    let first = first_request(tracked.as_ref());
    let ask = || async { plan.source.fetch(&plan.machine, None).await.map_err(source_failure) };
    let (opened, early) = tokio::join!(tracked.open(first), ask());
    let link = opened.map_err(|e| classify(&ConnectionError::Provider(e), step.get()))?;
    let daemon = match early.as_ref().map(|answer| answer.daemon_key) {
        Ok(Some(daemon)) => daemon,
        // Asked before the bind stored the key (or the ask failed): the
        // daemon has registered now, so its key is stored.
        Ok(None) | Err(_) => pinned_daemon(&ask().await?)?,
    };
    let group: Arc<dyn LinkGroup> =
        Arc::new(Opened { inner: tracked, first: std::sync::Mutex::new(Some((first, link))) });
    Ok((group, daemon))
}

/// The link request a connection on `group` opens first (cmux-remote's
/// `establish_physical_links`: the first lane binding's first lane, at
/// generation 0).
fn first_request(group: &dyn LinkGroup) -> LinkRequest {
    let lane = lane_bindings(LanePolicy::Auto, group.capabilities())
        .first()
        .and_then(|lanes| lanes.first().copied())
        .unwrap_or(Lane::Interactive);
    LinkRequest { lane, generation: 0 }
}

/// A [`LinkGroup`] whose first open of `first`'s request is a link opened
/// ahead of the connection (allocated while the daemon key was asked for).
/// Every other open, and any open after that one, goes to `inner`.
struct Opened {
    inner: Arc<dyn LinkGroup>,
    first: std::sync::Mutex<Option<(LinkRequest, Box<dyn FrameLink>)>>,
}

#[async_trait]
impl LinkGroup for Opened {
    fn description(&self) -> &str {
        self.inner.description()
    }
    fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
        self.inner.capabilities()
    }
    fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
        self.inner.evidence()
    }
    async fn transport_snapshot(&self) -> cmux_remote::observability::TransportSnapshot {
        self.inner.transport_snapshot().await
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        let held = {
            let mut first = self.first.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match first.as_ref() {
                Some((asked, _)) if *asked == request => first.take().map(|(_, link)| link),
                _ => None,
            }
        };
        match held {
            Some(link) => Ok(link),
            None => self.inner.open(request).await,
        }
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

/// The step a failed resume names: a provider error is the relay's (or the
/// park's), anything else the handshake's.
pub(super) fn resume_outcome(error: &ConnectionError) -> Step {
    classify(error, Step::Relay).step
}

/// Route lines for an established session's resumes.
pub(super) struct Resume {
    machine: String,
    log: Arc<dyn Fn(String) + Send + Sync>,
}

impl ResumeHooks for Resume {
    fn attempt_ended(&self, result: Result<(), &ConnectionError>, elapsed: Duration) {
        let outcome = result.err().map(resume_outcome);
        let detail = result.err().map(ToString::to_string);
        (self.log)(route_line(&self.machine, Phase::Resume, outcome, detail.as_deref(), elapsed));
    }
}

/// Dial until connected, a failure no retry can fix, or the deadline.
/// Every attempt writes one route line.
pub(super) async fn dial(
    plan: &DialPlan,
    jitter: impl Fn(Duration) -> Duration,
) -> Result<Dialed, Failure> {
    let resume = Arc::new(Resume { machine: plan.machine.clone(), log: plan.log.clone() });
    let mut backoff = Backoff::default();
    let mut attempts = 0_u32;
    loop {
        attempts += 1;
        let started = Instant::now();
        let step = Arc::new(Progress::default());
        let result =
            match tokio::time::timeout_at(plan.deadline, attempt(plan, &step, &resume)).await {
                Ok(result) => result,
                Err(_) => Err(Failure::deadline(step.get())),
            };
        let phase = Phase::of_attempt(attempts);
        let outcome = result.as_ref().err().map(|f| f.step);
        let elapsed = started.elapsed();
        let detail = result.as_ref().err().map(|f| f.detail.as_str());
        (plan.log)(route_line(&plan.machine, phase, outcome, detail, elapsed));
        (plan.phases)(phases_line(
            &plan.machine,
            PhasesOf::Attempt(phase),
            outcome,
            step.times(),
            elapsed,
        ));
        let failure = match result {
            Ok(dialed) => return Ok(dialed),
            Err(failure) => failure,
        };
        if !failure.retryable {
            return Err(failure);
        }
        let remaining = plan.deadline.saturating_duration_since(Instant::now());
        let Some(delay) = backoff.next(remaining, &jitter) else {
            return Err(Failure { retryable: false, ..failure });
        };
        tokio::time::sleep(delay).await;
    }
}
