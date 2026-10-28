//! One connection's leases and identity. Dropping it expires its remote catalog.
use super::{
    AttachedSurface, BrowserPointerOwner, ClientIdentityWire, ClientTransport, MessageWriter,
    ResourceClientStream, ResourceClientWait, ResourceRequestId, SurfaceId,
};
use crate::server::connection_scheduler::connection_qos::{ConnectionClass, ConnectionClassCell};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::Instant;

use crate::request_origin::RequestOrigin;

pub(in crate::server) struct ClientRecord {
    pub(in crate::server) transport: ClientTransport,
    pub(in crate::server) connected_at: Instant,
    pub(in crate::server) name: Option<String>,
    pub(in crate::server) kind: Option<String>,
    /// Shared-sizing identity from `set-client-info`. `user_id` is asserted
    /// by the connection; this daemon has no Stack session to verify it.
    pub(in crate::server) identity: ClientIdentityWire,
    /// A remote device's spliced lane (`set-client-info remote:true`);
    /// sticky for the connection's life.
    pub(in crate::server) remote_device: bool,
    pub(in crate::server) capabilities: HashSet<String>,
    pub(in crate::server) browser_pointer_owner: Option<BrowserPointerOwner>,
    pub(in crate::server) attached: BTreeMap<SurfaceId, AttachedSurface>,
    pub(in crate::server) view_leases: HashMap<String, (SurfaceId, u64)>,
    pub(in crate::server) retired_view_leases: HashMap<String, SurfaceId>,
    pub(in crate::server) retired_view_lease_order: VecDeque<String>,
    pub(in crate::server) retired_surfaces: HashSet<SurfaceId>,
    pub(in crate::server) retired_surface_order: VecDeque<SurfaceId>,
    pub(in crate::server) resource_streams: HashMap<String, ResourceClientStream>,
    pub(in crate::server) resource_waits: HashMap<ResourceRequestId, ResourceClientWait>,
    pub(in crate::server) announced_attached: bool,
    pub(in crate::server) writer: MessageWriter,
    /// Hello role, peer and confirmations (request_origin.rs).
    pub(in crate::server) origin: crate::request_origin::ConnectionOrigin,
    /// A WebSocket connection that authenticated with a pairing-store
    /// credential (a human-approved pairing or the verified app's
    /// `page-credential`), not the static or file token: the person's own
    /// client for the Cloud lease (`ws-cloud-conversations-v1`).
    pub(in crate::server) person: bool,
    /// The connection's client class, which its reader and request threads
    /// rest at (connection_qos.rs); set by [`Self::classify`].
    pub(in crate::server) connection_class: Arc<ConnectionClassCell>,
    /// The surfaces this frontend shows and its subscriptions they scope
    /// (`frontend.visibility.set`, server/frontend_visibility.rs).
    pub(in crate::server) frontend_visibility: crate::server::frontend_visibility::ClientVisibility,
    #[cfg(unix)]
    pub(in crate::server) machine_catalog: Option<super::machine_catalog::Publication>,
    /// What this connection's `subscribe` received and rendered (tests).
    #[cfg(test)]
    pub(in crate::server) subscribe_probe: Arc<crate::server::cmd_subscribe::SubscribeProbe>,
}

/// What `server-threads` says of the connection a thread works for
/// (server/server_stats.rs): the facts its class comes from and the class.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::server) struct ConnectionFacts {
    pub(in crate::server) transport: &'static str,
    pub(in crate::server) remote_device: bool,
    /// The derived request origin (`user` is the verified app).
    pub(in crate::server) origin: &'static str,
    /// The socket peer's PID at accept, from its kernel peer key.
    pub(in crate::server) peer_pid: Option<u32>,
    pub(in crate::server) class: &'static str,
    /// The class its lines run at under `daemonRequestQos`
    /// (`ConnectionClass::qos` of a reader).
    pub(in crate::server) reader_qos: cmux_threads::ThreadQos,
}

impl super::ClientRegistry {
    /// The facts of each of `clients` the registry holds, read under one
    /// hold of its lock (server-threads, a diagnostics read).
    pub(in crate::server) fn connection_facts(
        &self,
        clients: impl IntoIterator<Item = u64>,
    ) -> HashMap<u64, ConnectionFacts> {
        use crate::panic_free::RecoverPoison;
        let state = self.state.lock().recover_poison();
        clients
            .into_iter()
            .filter_map(|client| {
                let record = state.clients.get(&client)?;
                let facts = ConnectionFacts {
                    transport: record.transport.as_str(),
                    remote_device: record.remote_device,
                    origin: record.origin.derive().wire_name(),
                    peer_pid: record
                        .origin
                        .peer_key
                        .as_deref()
                        .and_then(crate::server::origin_gate::peer_pid),
                    class: record.connection_class.get().as_str(),
                    reader_qos: record.connection_class.get().qos(
                        crate::server::connection_scheduler::connection_qos::ConnectionThread::Reader,
                    ),
                };
                Some((client, facts))
            })
            .collect()
    }
}

impl super::ClientRegistryState {
    /// Classes `client`'s connection from what the daemon knows of it: its
    /// transport, its derived origin, `set-client-info remote` and whether
    /// its peer is a verified app's process (connection_qos.rs).
    pub(in crate::server) fn classify(&self, client: u64) {
        if let Some(record) = self.clients.get(&client) {
            self.classify_record(record);
        }
    }

    /// Reclasses the connections already classed whose peer is `peer_key`,
    /// once a connection of that process became the verified app: the app's
    /// other connections may have been classed before it proved itself.
    /// A connection not classed yet is classed when its hello window closes.
    pub(in crate::server) fn reclassify_process(&self, peer_key: &str) {
        for record in self.clients.values() {
            if record.connection_class.get() != ConnectionClass::Unclassified
                && record.origin.peer_key.as_deref() == Some(peer_key)
            {
                self.classify_record(record);
            }
        }
    }

    fn classify_record(&self, record: &ClientRecord) {
        let app_process = record.origin.peer_key.as_deref().is_some_and(|key| {
            self.clients.values().any(|other| {
                matches!(other.transport, ClientTransport::Unix)
                    && other.origin.derive() == RequestOrigin::User
                    && other.origin.peer_key.as_deref() == Some(key)
            })
        });
        record.connection_class.set(ConnectionClass::of(
            record.transport,
            record.remote_device,
            record.origin.derive(),
            app_process,
        ));
    }
}
