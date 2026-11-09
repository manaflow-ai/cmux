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
//! [`select_initial_route`]: crate::remote_runtime::select_initial_route

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
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
pub(super) struct CachedGroup {
    inner: Arc<dyn LinkGroup>,
    closed: AtomicBool,
}

impl CachedGroup {
    pub(super) fn new(inner: Arc<dyn LinkGroup>) -> Arc<Self> {
        Arc::new(Self { inner, closed: AtomicBool::new(false) })
    }

    fn is_open(&self) -> bool {
        !self.closed.load(Ordering::Acquire)
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
        self.inner.open(request).await
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
    session: SessionId,
    next: AtomicUsize,
    current: Arc<CurrentRoute>,
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
        Self {
            routes,
            dialers,
            groups: Mutex::new(groups),
            session,
            next: AtomicUsize::new(selected.saturating_add(1)),
            current,
        }
    }

    /// Route `index`'s group while it is open.
    fn cached(&self, index: usize) -> Option<Arc<CachedGroup>> {
        let groups = self.groups.lock().unwrap_or_else(PoisonError::into_inner);
        groups.get(index).cloned().flatten().filter(|group| group.is_open())
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
        let group = match self.cached(index) {
            Some(group) => group,
            None => {
                let group = CachedGroup::new(dialer.connect(request).await?);
                if let Some(slot) =
                    self.groups.lock().unwrap_or_else(PoisonError::into_inner).get_mut(index)
                {
                    *slot = Some(group.clone());
                }
                group
            }
        };
        self.current.set(dialer.name());
        Ok(group)
    }
}
