//! What a connection's own line and key paths read about the session's connections: the client registry's
//! published projection (R-DAEMON-STATE stage S1), and the reads made from it.
use super::{ClientRegistry, ClientRegistryState, ClientTransport, DaemonHandoffReservation};
use crate::diagnostics::request_log::Label;
use crate::{SurfaceId, panic_free::RecoverPoison};
use std::collections::HashMap;

/// What a connection's own line and key paths read about the session's connections, published after every change
/// of the client registry and read with one atomic load, never through its lock (R-DAEMON-STATE stage S1,
/// handoff/rewrites/R-DAEMON-STATE/DESIGN.md section 2.6). Every connect, disconnect, attach and detach of every
/// client holds the registry lock; a person's key must not wait for any of them.
pub(in crate::server) struct ClientFacts {
    /// The daemon handoff, when one is reserved: `true` once it was acknowledged (committed).
    pub(in crate::server) handoff: Option<bool>,
    pub(in crate::server) clients: HashMap<u64, ConnectionFacts>,
}

/// One connection's facts in [`ClientFacts`].
pub(in crate::server) struct ConnectionFacts {
    pub(in crate::server) transport: ClientTransport,
    /// `ClientRecord::remote_device`.
    pub(in crate::server) remote_device: bool,
    /// A unix connection that declared `cloud-mobile-chat-v1`: a phone's carrier channel
    /// (phone_carrier.rs), held to hostd's adapter commands on every line.
    #[cfg(unix)]
    pub(in crate::server) phone_carrier: bool,
    /// The connection's base actor (`ConnectionOrigin::actor`).
    pub(in crate::server) actor: crate::workspace_registry::Actor,
    /// The surfaces the connection is attached to, each with whether it can type into it
    /// (`AttachedSurface::can_type`): its keys there are the person's (server/input_qos.rs).
    pub(in crate::server) attached: Vec<(SurfaceId, bool)>,
    /// The connection's name and kind (`set-client-info`), as the slow request log writes them.
    pub(in crate::server) log_labels: (Option<Label>, Option<Label>),
}

impl ClientFacts {
    /// The projection of `state` (runs under the registry lock after each change).
    pub(super) fn of(state: &ClientRegistryState) -> Self {
        let handoff = state
            .daemon_handoff
            .map(|reservation| matches!(reservation, DaemonHandoffReservation::Committed(_)));
        let clients = state
            .clients
            .iter()
            .map(|(client, record)| {
                let attached = record
                    .attached
                    .iter()
                    .map(|(surface, attached)| (*surface, attached.can_type()))
                    .collect();
                let facts = ConnectionFacts {
                    transport: record.transport,
                    remote_device: record.remote_device,
                    #[cfg(unix)]
                    phone_carrier: matches!(record.transport, ClientTransport::Unix)
                        && record.capabilities.contains(
                            super::super::agent_session_attach::CLOUD_MOBILE_CHAT_CAPABILITY,
                        ),
                    actor: record.origin.actor(),
                    attached,
                    log_labels: (
                        record.name.as_deref().and_then(Label::client),
                        record.kind.as_deref().and_then(Label::client),
                    ),
                };
                (*client, facts)
            })
            .collect();
        Self { handoff, clients }
    }
}

impl ClientRegistry {
    /// `client`'s name and kind for the slow request log. Reads the published facts, never the
    /// registry lock: every request line asks. With the published facts off there are none to
    /// read, and the record has the client's number only.
    pub(in crate::server) fn log_labels(&self, client: u64) -> (Option<Label>, Option<Label>) {
        if !self.input_lane.on() {
            return (None, None);
        }
        let facts = self.state.load().recover_poison();
        facts.clients.get(&client).map_or((None, None), |connection| connection.log_labels)
    }

    /// Whether `client` is attached to `surface` and can type into it (`AttachedSurface::can_type`): its keys there
    /// are the person's. Reads the published facts, never the registry lock; only the input lane calls it.
    pub(in crate::server) fn types_into(&self, client: u64, surface: SurfaceId) -> bool {
        let facts = self.state.load().recover_poison();
        facts.clients.get(&client).is_some_and(|connection| {
            connection.attached.iter().any(|(attached, can_type)| *attached == surface && *can_type)
        })
    }
}
