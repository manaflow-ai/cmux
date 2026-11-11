//! One carrier dial: a cmux-remote client session over the machine's relay
//! slot (`relay+do`), admitted by a carrier grant and pinned to the daemon
//! key the platform names, with every attempt inside one deadline.
//!
//! Each attempt fetches a fresh ticket and grant (a grant is single-use),
//! opens the relay's control socket, waits for the lane allocation (the
//! relay parks it until the machine's daemon registers) until the deadline,
//! then runs the Noise handshake. The attempts run on the first-dial state
//! machine ([`LinkCell::dial`]), whose jittered waits retry a failed attempt
//! while time is left; each attempt picks its route with
//! [`select_initial_route`] over the answer's routes ([`carrier_routes`]),
//! and the session resumes through [`CarrierRoutes`]. Once up, the session's own reconnect carries
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

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote::bridge::OpenedMuxControl;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectGroupSource,
    ReconnectPolicy, ResumeHooks,
};
use cmux_remote::crypto::{ClientAuthMode, CryptoError, StaticIdentity};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkGroup, LinkRequest, ProviderError, RelayClientConfig,
    RelayCredentialSource, RelayProvider, lane_bindings, ssh_stderr_of,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::answer::{CarrierAnswer, CarrierSource, Prefetched, SourceError, TicketCache};
use super::contract::{
    Failure, FreshSessions, Phase, PhaseTimes, PhasesOf, Step, phases_line, route_line, routes_line,
};
use super::source::{
    CARRIER_AUTH, CARRIER_LANES, CachedGroup, CarrierRoutes, CurrentRoute, RouteSet, carrier_routes,
};
use super::ssh::{SshRefusal, SshSetup, ssh_route};
use crate::remote_runtime::{
    InitialRouteAttempt, InitialRouteAttemptError, RouteFailure, select_initial_route,
};
use cmux_remote::first_dial::{DialOutcome, DialStop, LinkCell};
use cmux_remote::network_watch::NetworkWatch;
use url::Url;

/// The relay's frame bound for a carrier (the Mac's remote client uses the same).
const MAX_FRAME_BYTES: usize = 65_535;
/// Each relay control step other than the parked allocation.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
/// The Noise handshake of one attempt, at most.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
/// How long an established session tries to resume before it gives up.
/// After that its streams end, and the next stream (`held`) or the
/// caller's next dial opens a fresh session instead of resuming forever.
pub(super) const RESUME_DEADLINE: Duration = Duration::from_secs(10);

/// A connected carrier session.
pub(super) struct Dialed {
    pub connection: Arc<ClientConnection>,
    pub multiplexer: Arc<ServiceMultiplexer>,
    /// The daemon stream, opened before the dial reports success.
    pub mux: OpenedMuxControl,
    /// The grant's `vmk`, when it has one.
    pub vmk: Option<super::contract::Vmk>,
    /// The desktop datagram link's settings, when the platform turned it on.
    pub rd_link: Option<super::answer::RdLink>,
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
    /// The dial's fresh sessions, shared with the caller's own retries.
    pub fresh_sessions: FreshSessions,
    /// The dial's progress lines, when its caller asked for them
    /// ([`super::progress`]): each attempt's marks say its stage.
    pub progress: Option<Arc<super::progress::Reporter>>,
    /// Where the ssh backup carrier's pieces are ([`super::ssh`]).
    pub ssh: Arc<SshSetup>,
    /// The platform's refusal of the ssh carrier for good, once one came:
    /// every later attempt of this dial leaves the route out.
    pub ssh_refusal: SshRefusal,
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
        // The session host restarted and lost the session: a fresh one.
        ConnectionError::SessionUnavailable => {
            Failure::session_gone(step.max(Step::Handshake), detail)
        }
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
    Failure {
        step: Step::Ticket,
        detail: error.detail,
        retryable: error.retryable,
        fresh_session: false,
    }
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
    /// The ssh route's state once the attempt built its routes: `on`, or
    /// why it is left out ([`super::ssh::Absent::code`]).
    pub ssh: Option<&'static str>,
    /// The carrier the attempt connected on (`relay:0`, `ssh:0`).
    pub carrier: Option<&'static str>,
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

    /// The marks so far.
    pub(super) fn marks(&self) -> Marks {
        *self.marks.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
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
            marks.first_open.get_or_insert_with(Instant::now);
        });
        let link = self.inner.open(request).await?;
        self.step.advance(Step::Handshake);
        // A lane counts once the relay has allocated it, not on the ask.
        self.step.mark(|marks| {
            marks.lanes += 1;
            marks.first_allocated.get_or_insert_with(Instant::now);
        });
        Ok(link)
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

/// How long one attempt's link may stay parked before the dial opens a new one. A link opened
/// while a new machine's host was still binding stayed parked for the whole deadline (4 of 13
/// first dials on 2026-11-10: `parked_ms` 178 s, then `parked_timeout`), though the host
/// registered 13 s in and the next dial was allocated in 0.5 s. A machine that registers is
/// allocated in well under a second, so a longer park is a link the relay will not pair.
pub(super) const PARK_REDIAL: Duration = Duration::from_secs(10);

/// When an attempt begun at `now` stops waiting for its parked link: the dial's `deadline`.
pub(super) fn park_until(deadline: Instant, now: Instant) -> Instant {
    let _ = now;
    deadline
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
    .map(|provider| provider.with_allocation_deadline(park_until(deadline, Instant::now())))
    .map_err(|e| Failure::fatal(Step::Relay, e.to_string()))
}

fn random_session() -> Result<SessionId, Failure> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| Failure::fatal(Step::Handshake, e.to_string()))?;
    Ok(SessionId(bytes))
}

/// One attempt, recording its step in `step` as it goes (the caller reads
/// it when the deadline cuts the attempt off): the answer, then one pass
/// over its routes.
async fn attempt(
    plan: &DialPlan,
    step: &Arc<Progress>,
    resume: &Arc<Resume>,
    current: &Arc<CurrentRoute>,
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
    let provider = Arc::new(relay_provider(&answer, tickets, plan.deadline)?);
    let ssh = ssh_route(
        &plan.ssh,
        &answer,
        &plan.machine,
        plan.source.clone(),
        plan.deadline,
        &plan.ssh_refusal,
    );
    step.mark(|marks| marks.ssh = Some(ssh.as_ref().map_or_else(|absent| absent.code(), |_| "on")));
    let set = carrier_routes(&answer, provider, ssh.ok());
    let mut route = RouteAttempt {
        plan,
        step,
        resume,
        current,
        answer: &answer,
        grant,
        session,
        set: &set,
        first: None,
    };
    let selected =
        select_initial_route(&set.routes, session, CARRIER_LANES, CARRIER_AUTH, false, &mut route)
            .await;
    let first = route.first.take();
    selected.map_err(|selection| {
        // Every route failed: the first route's step names the attempt (the
        // relay's, which the route line's words describe), every route's
        // reason is in the detail, and the attempt is retried when any
        // route may pass later.
        let retryable = selection.retryable;
        let failure = selection.error;
        match first {
            Some(first) if set.routes.len() > 1 => {
                Failure { step: first.step, retryable, ..failure }
            }
            _ => failure,
        }
    })
}

/// One attempt's pass over its routes: the relay link, the daemon key, the
/// Noise handshake and the mux control stream on the route being tried.
struct RouteAttempt<'a> {
    plan: &'a DialPlan,
    step: &'a Arc<Progress>,
    resume: &'a Arc<Resume>,
    current: &'a Arc<CurrentRoute>,
    answer: &'a CarrierAnswer,
    grant: Zeroizing<String>,
    session: SessionId,
    set: &'a RouteSet,
    /// The first route's failure, when it failed.
    first: Option<Failure>,
}

/// A failed route. A relay failure past the park that no retry fixes (a
/// daemon that is not the pinned one, or that refused the grant) ends the
/// dial: every route reaches the same daemon. A carrier's own failure (the
/// ticket, the relay, the park) lets the next route try, and the dial retry
/// the round when `retryable`. An ssh route's failure never ends a dial
/// the relay may still make, and is retryable: a refused `:22` right after
/// a machine's create (the mesh ACL takes the machine at its next ensure)
/// passes later. One the platform refused for good is not: the route is
/// left out from then on ([`SshRefusal`]).
pub(super) fn route_error(failure: Failure, kind: RouteKind) -> InitialRouteAttemptError<Failure> {
    match kind {
        RouteKind::Ssh => {
            return InitialRouteAttemptError::Route {
                error: Failure { retryable: true, ..failure },
                retryable: true,
            };
        }
        RouteKind::SshRefused => {
            return InitialRouteAttemptError::Route {
                error: Failure { retryable: false, fresh_session: false, ..failure },
                retryable: false,
            };
        }
        RouteKind::Relay => {}
    }
    if failure.retryable || failure.step <= Step::Parked {
        let retryable = failure.retryable;
        InitialRouteAttemptError::Route { error: failure, retryable }
    } else {
        InitialRouteAttemptError::Fatal(failure)
    }
}

/// Which kind of route failed, for [`route_error`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RouteKind {
    Relay,
    Ssh,
    /// An ssh route the platform refused for good.
    SshRefused,
}

#[async_trait]
impl InitialRouteAttempt<Dialed, Failure> for RouteAttempt<'_> {
    async fn bootstrap_ssh(
        &mut self,
        _endpoint: &Url,
        _upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError<Failure>> {
        // A carrier's ssh key runs `remote-link` as its forced command
        // (`SshBootstrapOptions::forced_command`): nothing to probe or
        // install first.
        Ok(())
    }

    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<Dialed, InitialRouteAttemptError<Failure>> {
        let result = self.connect_route(index, request).await;
        if let Err(failure) = &result
            && index == 0
        {
            self.first = Some(failure.clone());
        }
        let dialer = self.set.dialers.get(index);
        let kind = match dialer {
            Some(dialer) if dialer.refused().is_some() => {
                // The connect log says why the route is gone.
                self.step.mark(|marks| marks.ssh = Some(super::ssh::Absent::Refused.code()));
                RouteKind::SshRefused
            }
            Some(dialer) if dialer.is_ssh() => RouteKind::Ssh,
            _ => RouteKind::Relay,
        };
        result.map_err(|failure| route_error(failure, kind))
    }
}

impl RouteAttempt<'_> {
    async fn connect_route(
        &self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<Dialed, Failure> {
        let (plan, step) = (self.plan, self.step);
        let dialer = self
            .set
            .dialers
            .get(index)
            .ok_or_else(|| Failure::fatal(Step::Relay, "the carrier has no such route"))?;
        // A machine whose software predates the relay Register parks this link until the
        // deadline: one that stays parked is looked at, and adopted when it needs it.
        let _adopt = (!dialer.is_ssh()).then(|| {
            super::adopt::watch(
                plan.source.clone(),
                plan.machine.clone(),
                step.clone(),
                plan.deadline,
                plan.phases.clone(),
            )
        });
        let group = dialer.connect(request).await.map_err(|e| {
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
        let (tracked, daemon) = match self.answer.daemon_key {
            Some(daemon) => (tracked, daemon),
            None => match pin_while_parked(plan, tracked, step).await {
                Ok(pinned) => pinned,
                Err(failure) => {
                    let _ = group.close().await;
                    return Err(failure);
                }
            },
        };
        // The connection and the routes hold the same cached group, so the
        // routes see it retired once the session moves off it.
        let cached = CachedGroup::new(tracked);
        let tracked: Arc<dyn LinkGroup> = cached.clone();
        let remaining = plan.deadline.saturating_duration_since(Instant::now());
        let config = ClientConnectionConfig {
            identity: plan.identity.clone(),
            expected_daemon: Some(daemon),
            auth: ClientAuthMode::Grant { token: self.grant.clone() },
            device_name: "cmux-carrier".into(),
            session: self.session,
            lane_policy: CARRIER_LANES,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy {
                attempt_timeout: HANDSHAKE_TIMEOUT.min(remaining.max(Duration::from_millis(1))),
                maximum_duration: Some(RESUME_DEADLINE),
                ..ReconnectPolicy::default()
            },
        };
        let routes: Arc<dyn ReconnectGroupSource> = Arc::new(CarrierRoutes::new(
            RouteSet { routes: self.set.routes.clone(), dialers: self.set.dialers.clone() },
            index,
            cached,
            self.session,
            self.current.clone(),
        ));
        let connection =
            match ClientConnection::connect_with_reconnect_groups(tracked, config, Some(routes))
                .await
            {
                Ok(connection) => connection,
                Err(error) => {
                    let _ = group.close().await;
                    return Err(classify(&error, step.get()));
                }
            };
        step.mark(|marks| marks.connected = Some(Instant::now()));
        connection.set_resume_hooks(self.resume.clone());
        let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
        // A grant that does not admit mux control is refused here, before the
        // reply line says ok.
        let mux = match OpenedMuxControl::open(&multiplexer).await {
            Ok(mux) => mux,
            Err(error) => {
                // The link dropped after the handshake and the resume reached a
                // session host that restarted meanwhile (the updater restarts
                // it at boot): it no longer has this session, so the next
                // attempt opens a fresh one.
                let gone = connection.session_unavailable();
                multiplexer.shutdown().await;
                let _ = connection.close().await;
                let detail = format!("the daemon did not open its mux control stream: {error}");
                return Err(if gone {
                    Failure::session_gone(Step::Handshake, detail)
                } else {
                    Failure::fatal(Step::Handshake, detail)
                });
            }
        };
        step.mark(|marks| {
            marks.mux_open = Some(Instant::now());
            marks.carrier = Some(dialer.name());
        });
        self.current.set(dialer.name());
        // On the relay with an ssh route behind it: authorize the carrier
        // key once now, so a failover inside its lifetime skips the ask.
        if !dialer.is_ssh()
            && let Some(super::source::RouteDialer::Ssh(ssh)) =
                self.set.dialers.iter().find(|d| d.is_ssh())
        {
            ssh.prewarm();
        }
        Ok(Dialed {
            connection,
            multiplexer,
            mux,
            vmk: self.answer.vmk,
            rd_link: self.answer.rd_link.clone(),
        })
    }
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

/// Route lines for an established session's resumes, and the carrier
/// each resume went to (the connect log only).
pub(super) struct Resume {
    machine: String,
    log: Arc<dyn Fn(String) + Send + Sync>,
    phases: Arc<dyn Fn(String) + Send + Sync>,
    current: Arc<CurrentRoute>,
}

impl ResumeHooks for Resume {
    fn attempt_ended(&self, result: Result<(), &ConnectionError>, elapsed: Duration) {
        let outcome = result.err().map(resume_outcome);
        let detail = result.err().map(ToString::to_string);
        (self.log)(route_line(&self.machine, Phase::Resume, outcome, detail.as_deref(), elapsed));
        let carrier = Some(self.current.get()).filter(|_| outcome.is_none());
        let said = detail.as_deref().and_then(ssh_stderr_of);
        (self.phases)(routes_line(&self.machine, Phase::Resume, None, carrier, outcome, said));
    }
}

/// The route runner's view of a carrier failure.
impl RouteFailure for Failure {
    fn terminal(message: String) -> Self {
        Failure::fatal(Step::Relay, message)
    }

    fn summary(&self) -> String {
        self.detail.clone()
    }

    /// One route: its own failure, unchanged. More: the last route's step,
    /// with every route's reason.
    fn all_failed(failures: Vec<String>, last: Option<Self>) -> Self {
        match last {
            Some(last) if failures.len() <= 1 => last,
            Some(last) => Failure { detail: failures.join("; "), ..last },
            None => Failure::fatal(Step::Relay, failures.join("; ")),
        }
    }
}

/// What ended a dial on [`LinkCell::dial`]: an attempt's own failure, or
/// the dial's deadline between or during attempts.
enum DialEnd {
    Failed(Failure),
    Stopped(DialStop),
}

impl From<DialStop> for DialEnd {
    fn from(stop: DialStop) -> Self {
        Self::Stopped(stop)
    }
}

impl std::fmt::Display for DialEnd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed(failure) => f.write_str(&failure.detail),
            Self::Stopped(stop) => stop.fmt(f),
        }
    }
}

/// The attempts of one dial so far, for the deadline's answer.
#[derive(Default)]
struct Attempts {
    count: u32,
    /// The attempt in flight: its steps and when it started.
    current: Option<(Arc<Progress>, Instant)>,
    /// The last attempt's retryable failure.
    last: Option<Failure>,
}

/// One attempt's route line and phases line.
fn log_attempt(
    plan: &DialPlan,
    number: u32,
    failure: Option<&Failure>,
    step: &Progress,
    elapsed: Duration,
) {
    let phase = Phase::of_attempt(number);
    let outcome = failure.map(|f| f.step);
    let detail = failure.map(|f| f.detail.as_str());
    (plan.log)(route_line(&plan.machine, phase, outcome, detail, elapsed));
    (plan.phases)(phases_line(
        &plan.machine,
        PhasesOf::Attempt(phase),
        outcome,
        step.times(),
        elapsed,
    ));
    // Only an attempt that got its answer built routes to name.
    let marks = step.marks();
    if let Some(ssh) = marks.ssh {
        let carrier = marks.carrier.filter(|_| outcome.is_none());
        let said = detail.and_then(ssh_stderr_of);
        (plan.phases)(routes_line(&plan.machine, phase, Some(ssh), carrier, outcome, said));
    }
}

/// Dial until connected, a failure no retry can fix, or the deadline, on
/// the one first-dial state machine `remote connect` uses
/// ([`LinkCell::dial`]): its bursts, budget and jittered waits, bounded by
/// the plan's deadline. A session the daemon lost is retried from the
/// dial's fresh-session budget. Every attempt writes one route line.
pub(super) async fn dial(plan: &DialPlan) -> Result<Dialed, Failure> {
    let current = Arc::new(CurrentRoute::default());
    let resume = Arc::new(Resume {
        machine: plan.machine.clone(),
        log: plan.log.clone(),
        phases: plan.phases.clone(),
        current: current.clone(),
    });
    let attempts = std::sync::Mutex::new(Attempts::default());
    let lock = || attempts.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let policy = ReconnectPolicy {
        maximum_duration: Some(plan.deadline.saturating_duration_since(Instant::now())),
        ..ReconnectPolicy::default()
    };
    // A carrier dial watches no network: the deadline bounds it.
    let network = NetworkWatch::manual();
    let dialed = LinkCell::new()
        .dial(policy, network.subscribe(), || {
            let (resume, lock, current) = (&resume, &lock, &current);
            async move {
                let step = Arc::new(Progress::default());
                let started = Instant::now();
                let number = {
                    let mut attempts = lock();
                    attempts.count = attempts.count.saturating_add(1);
                    attempts.current = Some((step.clone(), started));
                    attempts.count
                };
                if let Some(progress) = &plan.progress {
                    progress.attempt(step.clone());
                }
                let result = match tokio::time::timeout_at(
                    plan.deadline,
                    attempt(plan, &step, resume, current),
                )
                .await
                {
                    Ok(result) => result,
                    Err(_) => Err(Failure::deadline(step.get())),
                };
                lock().current = None;
                log_attempt(plan, number, result.as_ref().err(), &step, started.elapsed());
                if let (Err(_), Some(progress)) = (&result, &plan.progress) {
                    progress.retrying();
                }
                match result {
                    Ok(dialed) => DialOutcome::Ready(dialed),
                    Err(failure) if !failure.retryable => {
                        DialOutcome::Fatal(DialEnd::Failed(failure))
                    }
                    Err(failure) if failure.fresh_session && !plan.fresh_sessions.take() => {
                        DialOutcome::Fatal(DialEnd::Failed(Failure {
                            retryable: false,
                            fresh_session: false,
                            ..failure
                        }))
                    }
                    Err(failure) => {
                        lock().last = Some(failure.clone());
                        DialOutcome::Retry(DialEnd::Failed(failure))
                    }
                }
            }
        })
        .await;
    match dialed {
        Ok(dialed) => Ok(dialed),
        Err(DialEnd::Failed(failure)) => Err(failure),
        // The deadline passed: an attempt it cut off names its step; between
        // attempts, the last attempt's failure is the answer.
        Err(DialEnd::Stopped(_)) => {
            let mut attempts = lock();
            let cut = match (attempts.current.take(), attempts.last.take()) {
                (None, Some(last)) => {
                    return Err(Failure { retryable: false, fresh_session: false, ..last });
                }
                (Some(current), _) => current,
                (None, None) => {
                    attempts.count = attempts.count.saturating_add(1);
                    (Arc::new(Progress::default()), Instant::now())
                }
            };
            let (step, started) = cut;
            let failure = Failure::deadline(step.get());
            log_attempt(plan, attempts.count, Some(&failure), &step, started.elapsed());
            Err(failure)
        }
    }
}
