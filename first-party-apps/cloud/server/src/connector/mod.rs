//! `cmux.terminal.connector/1` for kind `cloud-vm` (cloud-app.md 3.3): a
//! Cloud machine runs its own session host; the connector gives the daemon
//! one channel to it. The link supervisor (`crate::link`) does the work.

pub mod iface;

use crate::api::{ControlPlane, Origin, codes};
use crate::link::CONNECTOR_KIND;
use crate::link::ops::connect;
use crate::ops::Server;
use iface::{
    BackendError, BackendId, Carrier, CarrierEvent, ConnectRequest, ConnectorEvent,
    DEFAULT_WINDOW_BYTES, HostLink, LocalId, Lost, TerminalConnector, allow_kind, channel_id,
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
        &self.carrier.id
    }

    fn window_bytes(&self) -> u32 {
        DEFAULT_WINDOW_BYTES
    }

    fn carrier(&self) -> &Carrier {
        &self.carrier
    }
}

/// The machine of `channel` (`cloud-vm/<machine>#<generation>`), if the
/// text has that form.
fn channel_machine(channel: &str) -> Option<&str> {
    let (link, _generation) = channel.rsplit_once('#')?;
    link.strip_prefix(CONNECTOR_KIND)?.strip_prefix('/')
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
        // The host issues the token after the user's gesture; this server
        // only checks that it is there (the host checks expiry and reuse)
        // and keeps it out of logs (`Debug` hides it).
        request.open_token.check()?;
        // A daemon connect is not a person's gesture: origin `remote`
        // (it never changes focus; start needs no person).
        let carrier = connect(self.server, &request.target, Origin::Remote, None).map_err(|e| {
            match e.code {
                crate::link::ops::LINK_REVOKED => BackendError::Denied { reason: e.message },
                codes::UNSUPPORTED => BackendError::Unsupported,
                codes::INVALID_ARGS => BackendError::Invalid { reason: e.message },
                _ => BackendError::Unavailable { reason: e.message, retryable: e.retryable },
            }
        })?;
        Ok(Box::new(CloudHostLink { carrier }))
    }

    fn close(&mut self, channel: &str) -> Result<(), BackendError> {
        let supervisor = self.server.attach_mut().supervisor_mut();
        supervisor.pump();
        let open = channel_machine(channel)
            .filter(|machine| supervisor.carrier(machine).is_some_and(|c| c.id == channel));
        match open {
            Some(machine) => {
                supervisor.disconnect(machine);
                Ok(())
            }
            None => Err(BackendError::invalid("the channel is not open")),
        }
    }

    fn take_events(&mut self) -> Vec<ConnectorEvent> {
        // The connector reads its own side of the one drain: the host lines
        // keep every event this takes (crate::link::Attach::drain_link_events).
        self.server.attach_mut().take_connector_events()
    }
}

/// The connector's `end` for a carrier event: only a channel a connect
/// answered gets its one `end` (`up` is the connect's answer, not an event).
pub(crate) fn end_event(event: &CarrierEvent) -> Option<ConnectorEvent> {
    match event {
        CarrierEvent::Up { .. } | CarrierEvent::Down { opened: false, .. } => None,
        CarrierEvent::Down { target, generation, retryable, reason, opened: true } => {
            Some(ConnectorEvent::End {
                channel: channel_id(CONNECTOR_KIND, target, *generation),
                lost: Lost { reason: reason.clone(), retryable: *retryable },
            })
        }
        CarrierEvent::Revoked { target, reason, generation: Some(generation) } => {
            Some(ConnectorEvent::End {
                channel: channel_id(CONNECTOR_KIND, target, *generation),
                lost: Lost { reason: reason.clone(), retryable: false },
            })
        }
        CarrierEvent::Revoked { generation: None, .. } => None,
    }
}
