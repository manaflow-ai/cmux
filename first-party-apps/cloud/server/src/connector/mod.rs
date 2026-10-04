//! `cmux.terminal.connector/1` for kind `cloud-vm` (cloud-app.md 3.3): a
//! Cloud machine runs its own session host; the connector gives the daemon
//! one carrier to it. The link supervisor (`crate::link`) does the work.

pub mod iface;

use crate::api::{ControlPlane, Origin, codes};
use crate::link::ops::connect;
use crate::ops::Server;
use iface::{
    BackendError, BackendId, Carrier, CarrierEvent, ConnectRequest, HostLink, LocalId,
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
        todo!("C2 red commit: not implemented yet")
    }

    fn take_events(&mut self) -> Vec<CarrierEvent> {
        todo!("C2 red commit: not implemented yet")
    }
}
