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
//! to ssh, and back, on the same session, resumed by sequence. The relay
//! route resumes on the group the dial connected (its opens fetch a fresh
//! ticket each), or one it connects then; an ssh route makes a fresh group
//! each time (each link is its own `ssh` run).
//!
//! [`select_initial_route`]: crate::remote_runtime::select_initial_route

use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use cmux_remote::connection::ReconnectGroupSource;
use cmux_remote::crypto::AuthKind;
use cmux_remote::provider::{
    ConnectRequest, LinkGroup, ProviderError, RelayProvider, TransportProvider,
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

/// An established carrier session's next route after its current one
/// failed.
pub(super) struct CarrierRoutes {
    routes: Vec<ResolvedRouteCandidate>,
    dialers: Vec<RouteDialer>,
    /// The connected relay group of each route, by index (`None`: none yet).
    groups: Mutex<Vec<Option<Arc<dyn LinkGroup>>>>,
    session: SessionId,
    next: AtomicUsize,
    current: Arc<CurrentRoute>,
}

impl CarrierRoutes {
    /// The routes of a session that connected route `selected` on `group`.
    pub(super) fn new(
        set: RouteSet,
        selected: usize,
        group: Arc<dyn LinkGroup>,
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

    fn cached(&self, index: usize) -> Option<Arc<dyn LinkGroup>> {
        self.groups.lock().unwrap_or_else(PoisonError::into_inner).get(index).cloned().flatten()
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
        { use std::io::Write as _; if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open("/tmp/g4trace.log") { let _ = writeln!(f, "G4TRACE {:?} routes connect index={index} ssh={}", std::time::SystemTime::now(), dialer.is_ssh()); } };
        let group = match (dialer.is_ssh(), self.cached(index)) {
            (false, Some(group)) => group,
            _ => {
                let group = dialer.connect(request).await?;
                if !dialer.is_ssh()
                    && let Some(slot) =
                        self.groups.lock().unwrap_or_else(PoisonError::into_inner).get_mut(index)
                {
                    *slot = Some(group.clone());
                }
                group
            }
        };
        { use std::io::Write as _; if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open("/tmp/g4trace.log") { let _ = writeln!(f, "G4TRACE {:?} routes connect done index={index}", std::time::SystemTime::now()); } };
        self.current.set(dialer.name());
        Ok(group)
    }
}
