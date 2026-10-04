//! `cmux.terminal.connector/1` for kind `cloud-vm` (cloud-app.md 3.3): a
//! Cloud machine runs its own session host; the connector gives the daemon
//! one channel to it. The link supervisor (`crate::link`) does the work.
//!
//! The interface types and traits are the shared `cmux-terminal-iface`
//! crate, with no local adapters: the link names its channel
//! ([`HostLink::channel`]), the connector closes by channel id and drains
//! [`ConnectorEvent`]s for callers that hold no link handle (the serve loop,
//! `cmux.terminal.connector.close`), and the link's bytes move on its
//! carrier socket ([`cmux_terminal_iface::DataPlane::Socket`]), which the
//! daemon dials, because the app host has no frame stream for this server.
//!
//! One handle per channel: a connect while a live handle holds the target's
//! channel is `invalid` ([`ALREADY_CONNECTED`]). A link close through the
//! handle applies at the server's next drain, so the handle's `end` frame
//! comes only after that drain ([`link::CloudHostLink`]).

mod link;

use crate::api::{ControlPlane, Origin, codes};
use crate::link::ops::connect;
use crate::link::{Attach, CONNECTOR_KIND, CarrierEvent, channel_id};
use crate::ops::Server;
use cmux_terminal_iface::{
    BackendError, BackendId, ConnectRequest, ConnectorEvent, HostLink, LocalId, Lost,
    TerminalConnector, allow_kind,
};
use link::CloudHostLink;
use std::collections::BTreeMap;

pub(crate) use link::LinkHandle;

/// The refusal of a second handle for a channel that has a live one.
pub const ALREADY_CONNECTED: &str = "already connected; use the open link";

/// The connector, borrowed from the server for one call (the server is the
/// only writer of link state; the connector is its interface view).
pub struct CloudConnector<'a, C> {
    server: &'a mut Server<C>,
}

impl<C> Server<C> {
    /// The `cmux.terminal.connector/1` view of this server.
    pub fn connector(&mut self) -> CloudConnector<'_, C> {
        CloudConnector { server: self }
    }
}

/// The machine of `channel` (`cloud-vm/<machine>#<generation>`), if the
/// text has that form.
fn channel_machine(channel: &str) -> Option<&str> {
    let (link, _generation) = channel.rsplit_once('#')?;
    link.strip_prefix(CONNECTOR_KIND)?.strip_prefix('/')
}

/// Ends the open link of `channel`; its `end` follows in the link events.
/// A channel that is not open is `invalid`.
fn close_channel(attach: &mut Attach, channel: &str) -> Result<(), BackendError> {
    let supervisor = attach.supervisor_mut();
    supervisor.pump();
    let open = channel_machine(channel)
        .filter(|machine| supervisor.carrier(machine).is_some_and(|c| c.id == channel));
    match open {
        Some(machine) => {
            supervisor.disconnect(machine);
            Ok(())
        }
        None => Err(BackendError::not_open()),
    }
}

impl<C: ControlPlane + Send> TerminalConnector for CloudConnector<'_, C> {
    fn id(&self) -> &BackendId {
        &self.server.attach().connector_id
    }

    fn kinds(&self) -> &[LocalId] {
        &self.server.attach().connector_kinds
    }

    /// At most one channel per target and one live handle per channel: a
    /// second call while a handle holds the channel is `invalid`
    /// ([`ALREADY_CONNECTED`]), and one while a close waits for the drain is
    /// `unavailable` (retryable). A kind not in `kinds` fails with `denied`.
    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError> {
        let attach = self.server.attach();
        allow_kind(&attach.connector_kinds, &request.kind)?;
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
        let handles = &mut self.server.attach_mut().link_handles;
        let handle = handles.entry(carrier.id.clone()).or_default();
        link::claim(handle)?;
        Ok(Box::new(CloudHostLink::new(carrier, handle.clone())))
    }

    /// Ends a channel by id; its `end` follows. A channel that is not open
    /// is `invalid`.
    fn close(&mut self, channel: &str) -> Result<(), BackendError> {
        close_channel(self.server.attach_mut(), channel)
    }

    /// `end` events since the last call, in order.
    fn take_events(&mut self) -> Vec<ConnectorEvent> {
        // The connector reads its own side of the one drain: the host lines
        // keep every event this takes (crate::link::Attach::drain_link_events).
        self.server.attach_mut().take_connector_events()
    }
}

/// Applies the closes that link handles asked for (part of the one drain).
pub(crate) fn apply_link_closes(attach: &mut Attach) {
    let asked: Vec<String> = attach
        .link_handles
        .iter()
        .filter(|(_, handle)| link::take_close(handle))
        .map(|(channel, _)| channel.clone())
        .collect();
    for channel in asked {
        // A link that ended meanwhile gets its `end` from the event anyway.
        let _gone = close_channel(attach, &channel);
    }
}

/// Gives a channel's `end` to its link handle, once; the handle leaves the table.
pub(crate) fn end_link_handle(handles: &mut BTreeMap<String, LinkHandle>, end: &ConnectorEvent) {
    let ConnectorEvent::End { channel, lost } = end;
    if let Some(handle) = handles.remove(channel) {
        link::end(&handle, lost.clone());
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
                lost: Lost::new(reason.clone(), *retryable),
            })
        }
        CarrierEvent::Revoked { target, reason, generation: Some(generation) } => {
            Some(ConnectorEvent::End {
                channel: channel_id(CONNECTOR_KIND, target, *generation),
                lost: Lost::new(reason.clone(), false),
            })
        }
        CarrierEvent::Revoked { generation: None, .. } => None,
    }
}
