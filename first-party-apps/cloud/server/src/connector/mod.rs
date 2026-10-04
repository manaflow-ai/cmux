//! `cmux.terminal.connector/1` for kind `cloud-vm` (cloud-app.md 3.3): a
//! Cloud machine runs its own session host; the connector gives the daemon
//! one carrier to it. The link supervisor (`crate::link`) does the work.

pub mod iface;

use crate::api::{ControlPlane, Origin, codes};
use crate::link::ops::connect;
use crate::ops::Server;
use iface::{
    BackendError, BackendId, Carrier, ConnectRequest, ConnectorEvent, HostLink, LocalId,
    TerminalConnector, allow_kind,
};

/// The connector, borrowed from the server for one call (the server is the
/// only writer of link state; the connector is its interface view).
pub struct CloudConnector<'a, C> {
    server: &'a mut Server<C>,
}

impl<'a, C> CloudConnector<'a, C> {
    pub(crate) fn new(server: &'a mut Server<C>) -> Self {
        Self { server }
    }
}

impl<C> Server<C> {
    /// The `cmux.terminal.connector/1` view of this server.
    pub fn connector(&mut self) -> CloudConnector<'_, C> {
        CloudConnector::new(self)
    }
}

struct CloudHostLink {
    carrier: Carrier,
}

impl HostLink for CloudHostLink {
    fn channel(&self) -> &str {
        ""
    }

    fn window_bytes(&self) -> u32 {
        0
    }

    fn carrier(&self) -> &Carrier {
        &self.carrier
    }
}

impl<C: ControlPlane> TerminalConnector for CloudConnector<'_, C> {
    fn id(&self) -> &BackendId {
        &self.server.attach().connector_id
    }

    fn kinds(&self) -> &[LocalId] {
        &self.server.attach().connector_kinds
    }

    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError> {
        allow_kind(self.kinds(), &request.kind)?;
        // A daemon connect is not a person's gesture: origin `remote`
        // (it never changes focus; start needs no person).
        let carrier = connect(self.server, &request.target, Origin::Remote, None).map_err(|e| {
            match e.code {
                crate::link::ops::LINK_REVOKED => BackendError::Revoked { reason: e.message },
                codes::UNSUPPORTED => BackendError::Unsupported(e.message),
                codes::INVALID_ARGS => BackendError::Invalid(e.message),
                _ => BackendError::Unavailable { reason: e.message, retryable: e.retryable },
            }
        })?;
        Ok(Box::new(CloudHostLink { carrier }))
    }

    fn close(&mut self, _channel: &str) -> Result<(), BackendError> {
        Err(BackendError::Unsupported("red stub".into()))
    }

    fn take_events(&mut self) -> Vec<ConnectorEvent> {
        Vec::new()
    }
}
