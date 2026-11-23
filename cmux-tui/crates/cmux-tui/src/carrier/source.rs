//! The carrier's routes, as `remote_runtime`'s route runner takes them: the
//! candidates one dial attempt tries in order ([`carrier_routes`]), and
//! [`CarrierRoutes`], the [`ReconnectGroupSource`] an established session
//! resumes through.
//!
//! An answer names the machine's relay slot, and, when the ssh backup
//! carrier is up for it ([`super::ssh::ssh_route`]), its sshd on the team
//! mesh after it: `[relay+do://…, ssh://cmux@<mesh ip>]`. A dial attempt
//! tries them in that order on the same runner ([`select_initial_route`] in
//! [`super::client`]); a resume rotates from the route after the one that
//! failed ([`next_reconnect_route`]), so a session on the relay fails over
//! to ssh, and back, on the same session, resumed by sequence. Each route
//! resumes on the group it last connected while that group is open (the
//! relay's opens fetch a fresh ticket each; each ssh link is its own `ssh`
//! run), and connects a new one once the connection retired it
//! ([`CachedGroup`]).
//!
//! The probe's fault drill kills one route inside a running session
//! ([`CarrierRoutes::kill`]): that route's group goes dead the way a cut
//! carrier does (its links fail, [`CachedGroup::kill`]) and the session's
//! own reconnect leaves the route out from then on, so it resumes on the
//! next one. Nothing else calls it, and only the drill's gates reach it
//! (`carrier::fault`). Only a drill's dial makes killable groups
//! ([`CachedGroup::killable`]): every other dial's links are the route's own,
//! with nothing between them and the session.
//!
//! [`select_initial_route`]: crate::remote_runtime::select_initial_route

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::connection::ReconnectGroupSource;
use cmux_remote::crypto::AuthKind;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::observability::TransportSnapshot;
use cmux_remote::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    RelayProvider, TransportProvider,
};
use cmux_remote_protocol::{LanePolicy, SessionId};

use super::answer::CarrierAnswer;
use super::fault::Route;
use super::ssh::SshRoute;
use crate::remote_runtime::{ReconnectRouteAttempt, ResolvedRouteCandidate, next_reconnect_route};

/// How a carrier session authenticates: the platform's grant, on every route.
pub(super) const CARRIER_AUTH: AuthKind = AuthKind::Grant;
/// The lanes a carrier session asks for, on every route.
pub(super) const CARRIER_LANES: LanePolicy = LanePolicy::Auto;

/// What dials one route.
#[derive(Clone)]
pub(super) enum RouteDialer {
    /// The machine's relay slot, with this attempt's tickets.
    Relay(Arc<RelayProvider>),
    /// The machine's sshd through the team mesh tunnel.
    Ssh(Arc<SshRoute>),
}

impl RouteDialer {
    /// The carrier's name in the connect log: `relay:0` or `ssh:0`.
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::Relay(_) => "relay:0",
            Self::Ssh(_) => "ssh:0",
        }
    }

    pub(super) fn is_ssh(&self) -> bool {
        matches!(self, Self::Ssh(_))
    }

    /// The kind of carrier this route is.
    pub(super) fn route(&self) -> Route {
        if self.is_ssh() { Route::Ssh } else { Route::Relay }
    }

    /// Why the platform refused this route for the rest of the dial (an ssh
    /// route only, [`super::ssh::SshRefusal`]).
    pub(super) fn refused(&self) -> Option<&str> {
        match self {
            Self::Relay(_) => None,
            Self::Ssh(route) => route.refused(),
        }
    }

    /// A group on this route.
    pub(super) async fn connect(
        &self,
        request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        match self {
            Self::Relay(provider) => provider.connect(request).await,
            Self::Ssh(route) => route.group(request).await,
        }
    }
}

/// One answer's routes in the order a dial attempt tries them, with what
/// dials each.
pub(super) struct RouteSet {
    pub routes: Vec<ResolvedRouteCandidate>,
    pub dialers: Vec<RouteDialer>,
}

/// The routes one answer names: the relay slot, dialed by `relay`, then
/// the ssh route when there is one.
pub(super) fn carrier_routes(
    answer: &CarrierAnswer,
    relay: Arc<RelayProvider>,
    ssh: Option<Arc<SshRoute>>,
) -> RouteSet {
    let mut routes = vec![ResolvedRouteCandidate::for_provider(answer.relay.clone(), &*relay)];
    let mut dialers = vec![RouteDialer::Relay(relay)];
    if let Some(ssh) = ssh {
        routes.push(ssh.candidate());
        dialers.push(RouteDialer::Ssh(ssh));
    }
    RouteSet { routes, dialers }
}

/// The carrier a session is on now, for the resume's log line.
#[derive(Default)]
pub(super) struct CurrentRoute(Mutex<&'static str>);

impl CurrentRoute {
    pub(super) fn set(&self, name: &'static str) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = name;
    }

    /// `relay:0`, `ssh:0`, or `none` before any route connected.
    pub(super) fn get(&self) -> &'static str {
        let name = *self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if name.is_empty() { "none" } else { name }
    }
}

/// A group the route cache holds. Closing it (the connection retires the
/// group it moved off, `reconnect_once`) takes it out of the cache for
/// good, so no route resumes on a closed group, whatever kind it is.
/// Killing a killable one ([`Self::kill`]) closes it and fails every link
/// it opened.
pub(super) struct CachedGroup {
    inner: Arc<dyn LinkGroup>,
    closed: AtomicBool,
    /// The fault drill's kill switch, on a drill dial's groups only: their
    /// links are [`GroupLink`]s. `None`: links are the route's own.
    killed: Option<tokio::sync::watch::Sender<bool>>,
}

impl CachedGroup {
    pub(super) fn new(inner: Arc<dyn LinkGroup>) -> Arc<Self> {
        Arc::new(Self { inner, closed: AtomicBool::new(false), killed: None })
    }

    /// A group the fault drill can kill ([`Self::kill`]); `killable: false`
    /// is [`Self::new`].
    pub(super) fn killable(inner: Arc<dyn LinkGroup>, killable: bool) -> Arc<Self> {
        if !killable {
            return Self::new(inner);
        }
        let killed = Some(tokio::sync::watch::channel(false).0);
        Arc::new(Self { inner, closed: AtomicBool::new(false), killed })
    }

    fn is_killable(&self) -> bool {
        self.killed.is_some()
    }

    fn is_open(&self) -> bool {
        !self.closed.load(Ordering::Acquire)
    }

    /// The fault drill's cut: the group opens nothing more, and every link
    /// it opened fails its sends and receives from now on, a pending one
    /// included, as a carrier that died under them would.
    pub(super) async fn kill(&self) {
        self.closed.store(true, Ordering::Release);
        if let Some(killed) = &self.killed {
            killed.send_replace(true);
        }
        let _ = self.inner.close().await;
    }
}

/// A link of a [`CachedGroup`]: the route's own link until the group is
/// killed, then a dead one.
struct GroupLink {
    inner: Box<dyn FrameLink>,
    killed: tokio::sync::watch::Receiver<bool>,
}

fn killed_link() -> LinkError {
    LinkError::Transport("the carrier route was killed".into())
}

impl GroupLink {
    /// Resolves once the group is killed (never, for a group that is not).
    async fn killed(&self) {
        let mut killed = self.killed.clone();
        if killed.wait_for(|killed| *killed).await.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

#[async_trait]
impl FrameLink for GroupLink {
    fn description(&self) -> &str {
        self.inner.description()
    }
    fn maximum_frame_bytes(&self) -> usize {
        self.inner.maximum_frame_bytes()
    }
    fn terminal_control_drain_active(&self) -> bool {
        self.inner.terminal_control_drain_active()
    }
    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        tokio::select! {
            biased;
            () = self.killed() => Err(killed_link()),
            sent = self.inner.send(frame) => sent,
        }
    }
    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        tokio::select! {
            biased;
            () = self.killed() => Err(killed_link()),
            received = self.inner.receive() => received,
        }
    }
    async fn close(&self) -> Result<(), LinkError> {
        self.inner.close().await
    }
}

#[async_trait]
impl LinkGroup for CachedGroup {
    fn description(&self) -> &str {
        self.inner.description()
    }
    fn capabilities(&self) -> ProviderCapabilities {
        self.inner.capabilities()
    }
    fn evidence(&self) -> &CarrierEvidence {
        self.inner.evidence()
    }
    async fn transport_snapshot(&self) -> TransportSnapshot {
        self.inner.transport_snapshot().await
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if !self.is_open() {
            return Err(ProviderError::Link(LinkError::Closed));
        }
        let inner = self.inner.open(request).await?;
        Ok(match &self.killed {
            Some(killed) => Box::new(GroupLink { inner, killed: killed.subscribe() }),
            None => inner,
        })
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        self.inner.close().await
    }
}

/// An established carrier session's next route after its current one
/// failed.
pub(super) struct CarrierRoutes {
    routes: Vec<ResolvedRouteCandidate>,
    dialers: Vec<RouteDialer>,
    /// Each route's last connected group, by index (`None`: none yet).
    groups: Mutex<Vec<Option<Arc<CachedGroup>>>>,
    /// The routes the fault drill killed, by index: left out from then on.
    killed: Mutex<Vec<bool>>,
    /// The session's groups are killable (a drill's dial): new ones are too.
    killable: bool,
    session: SessionId,
    next: AtomicUsize,
    current: Arc<CurrentRoute>,
    /// A reconnect connected a route of this session ([`Self::connect`]): from then on the session's carrier is
    /// what the reconnect set, never the first dial's ([`Self::first_route`]). Held while `current` is set.
    moved: Mutex<bool>,
}

impl CarrierRoutes {
    /// The routes of a session that connected route `selected` on `group`,
    /// the very group the connection holds, so its retirement is seen here.
    pub(super) fn new(
        set: RouteSet,
        selected: usize,
        group: Arc<CachedGroup>,
        session: SessionId,
        current: Arc<CurrentRoute>,
    ) -> Self {
        let RouteSet { routes, dialers } = set;
        let groups =
            (0..routes.len()).map(|index| (index == selected).then(|| group.clone())).collect();
        let killed = vec![false; routes.len()];
        let killable = group.is_killable();
        Self {
            routes,
            dialers,
            groups: Mutex::new(groups),
            killed: Mutex::new(killed),
            killable,
            session,
            next: AtomicUsize::new(selected.saturating_add(1)),
            current,
            moved: Mutex::new(false),
        }
    }

    /// The first dial's route `name`, once its session opened: the session's carrier, unless a reconnect already
    /// moved the session off it (the first route failed while the first mux stream opened), whose route stays.
    pub(super) fn first_route(&self, name: &'static str) {
        let moved = self.moved.lock().unwrap_or_else(PoisonError::into_inner);
        if !*moved {
            self.current.set(name);
        }
    }

    /// Route `index`'s group while it is open.
    fn cached(&self, index: usize) -> Option<Arc<CachedGroup>> {
        let groups = self.groups.lock().unwrap_or_else(PoisonError::into_inner);
        groups.get(index).cloned().flatten().filter(|group| group.is_open())
    }

    /// The fault drill's kill of every `route` carrier of this session: its
    /// group dies under the session ([`CachedGroup::kill`]), which resumes
    /// through [`ReconnectGroupSource::next_group`] on another route, and
    /// the session never connects it again. Answers how many routes it
    /// killed (0: the session has no such route, or is not a drill's).
    pub(super) async fn kill(&self, route: Route) -> usize {
        if !self.killable {
            return 0;
        }
        let indexes: Vec<usize> = (0..self.dialers.len())
            .filter(|index| self.dialers.get(*index).is_some_and(|d| d.route() == route))
            .collect();
        let groups: Vec<Arc<CachedGroup>> = {
            let mut killed = self.killed.lock().unwrap_or_else(PoisonError::into_inner);
            let mut groups = self.groups.lock().unwrap_or_else(PoisonError::into_inner);
            indexes
                .iter()
                .filter_map(|index| {
                    if let Some(slot) = killed.get_mut(*index) {
                        *slot = true;
                    }
                    groups.get_mut(*index).and_then(Option::take)
                })
                .collect()
        };
        for group in groups {
            group.kill().await;
        }
        indexes.len()
    }

    fn was_killed(&self, index: usize) -> bool {
        let killed = self.killed.lock().unwrap_or_else(PoisonError::into_inner);
        killed.get(index).copied().unwrap_or(false)
    }
}

#[async_trait]
impl ReconnectGroupSource for CarrierRoutes {
    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        next_reconnect_route(
            &self.next,
            &self.routes,
            self.session,
            CARRIER_LANES,
            CARRIER_AUTH,
            self,
        )
        .await
    }
}

#[async_trait]
impl ReconnectRouteAttempt<Arc<dyn LinkGroup>> for CarrierRoutes {
    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let dialer = self
            .dialers
            .get(index)
            .ok_or_else(|| ProviderError::Configuration("the carrier has no such route".into()))?;
        if let Some(reason) = dialer.refused() {
            return Err(ProviderError::Link(LinkError::Transport(format!(
                "carrier ssh route dropped: {reason}"
            ))));
        }
        if self.was_killed(index) {
            return Err(ProviderError::Link(killed_link()));
        }
        let group = match self.cached(index) {
            Some(group) => group,
            None => {
                let group = CachedGroup::killable(dialer.connect(request).await?, self.killable);
                // The kill's flag and the cache under one lock: a route killed
                // while this group was connecting never carries the session.
                let killed = {
                    let killed = self.killed.lock().unwrap_or_else(PoisonError::into_inner);
                    let killed = killed.get(index).copied().unwrap_or(false);
                    if !killed
                        && let Some(slot) = self
                            .groups
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .get_mut(index)
                    {
                        *slot = Some(group.clone());
                    }
                    killed
                };
                if killed {
                    group.kill().await;
                    return Err(ProviderError::Link(killed_link()));
                }
                group
            }
        };
        let mut moved = self.moved.lock().unwrap_or_else(PoisonError::into_inner);
        *moved = true;
        self.current.set(dialer.name());
        drop(moved);
        Ok(group)
    }
}
