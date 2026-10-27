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
    #[cfg(unix)]
    pub(in crate::server) machine_catalog: Option<super::machine_catalog::Publication>,
    /// What this connection's `subscribe` received and rendered (tests).
    #[cfg(test)]
    pub(in crate::server) subscribe_probe:
        std::sync::Arc<crate::server::cmd_subscribe::SubscribeProbe>,
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
