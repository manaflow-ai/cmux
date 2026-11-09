//! The carrier's routes, as `remote_runtime`'s route runner takes them: the
//! candidates one dial attempt tries in order ([`carrier_routes`]), and
//! [`CarrierRoutes`], the [`ReconnectGroupSource`] an established session
//! resumes through.
//!
//! Today the answer names one route, the machine's relay slot, so a resume
//! always reattaches to the relay group the dial connected on (its opens
//! fetch a fresh ticket each, so it needs nothing else). A second carrier
//! (ssh, a second relay) becomes one more candidate here; the runner then
//! fails over to it on the same session, resumed by sequence.

use std::sync::Arc;
use std::sync::atomic::AtomicUsize;

use async_trait::async_trait;
use cmux_remote::connection::ReconnectGroupSource;
use cmux_remote::crypto::AuthKind;
use cmux_remote::provider::{ConnectRequest, LinkGroup, ProviderError, TransportProvider};
use cmux_remote_protocol::{LanePolicy, SessionId};

use super::answer::CarrierAnswer;
use crate::remote_runtime::{ReconnectRouteAttempt, ResolvedRouteCandidate, next_reconnect_route};

/// How a carrier session authenticates: the platform's grant, on every route.
pub(super) const CARRIER_AUTH: AuthKind = AuthKind::Grant;
/// The lanes a carrier session asks for, on every route.
pub(super) const CARRIER_LANES: LanePolicy = LanePolicy::Auto;

/// The routes one answer names, in the order a dial attempt tries them:
/// the relay slot, dialed by `relay`.
pub(super) fn carrier_routes(
    answer: &CarrierAnswer,
    relay: &dyn TransportProvider,
) -> Vec<ResolvedRouteCandidate> {
    vec![ResolvedRouteCandidate::for_provider(answer.relay.clone(), relay)]
}

/// An established carrier session's next route after its current one
/// failed. Each route resumes on the group the dial connected it on.
pub(super) struct CarrierRoutes {
    routes: Vec<ResolvedRouteCandidate>,
    /// The connected group of each route, by index (`None`: not dialed).
    groups: Vec<Option<Arc<dyn LinkGroup>>>,
    session: SessionId,
    next: AtomicUsize,
}

impl CarrierRoutes {
    /// The routes of a session that connected route `selected` on `group`.
    pub(super) fn new(
        routes: Vec<ResolvedRouteCandidate>,
        selected: usize,
        group: Arc<dyn LinkGroup>,
        session: SessionId,
    ) -> Self {
        let groups =
            (0..routes.len()).map(|index| (index == selected).then(|| group.clone())).collect();
        Self { routes, groups, session, next: AtomicUsize::new(selected.saturating_add(1)) }
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
        _request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        self.groups.get(index).cloned().flatten().ok_or_else(|| {
            ProviderError::Configuration("the carrier route was never dialed".into())
        })
    }
}
