//! What a connection's own line and key paths read about the session's connections: the client registry's
//! published projection (R-DAEMON-STATE stage S1), and the reads made from it.
use super::{ClientRegistry, ClientRegistryState, ClientTransport, DaemonHandoffReservation};
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
    /// The connection's base actor (`ConnectionOrigin::actor`).
    pub(in crate::server) actor: crate::workspace_registry::Actor,
    /// The surfaces the connection is attached to, each with whether it can type into it
    /// (`AttachedSurface::can_type`): its keys there are the person's (server/input_qos.rs).
    pub(in crate::server) attached: Vec<(SurfaceId, bool)>,
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
                    actor: record.origin.actor(),
                    attached,
                };
                (*client, facts)
            })
            .collect();
        Self { handoff, clients }
    }
}

impl ClientRegistry {
    /// Whether `client` is attached to `surface` and can type into it (`AttachedSurface::can_type`): its keys there
    /// are the person's. Reads the published facts, never the registry lock; only the input lane calls it.
    pub(in crate::server) fn types_into(&self, client: u64, surface: SurfaceId) -> bool {
        let facts = self.state.load().recover_poison();
        facts.clients.get(&client).is_some_and(|connection| {
            connection.attached.iter().any(|(attached, can_type)| *attached == surface && *can_type)
        })
    }
}
