//! One connection's leases and identity. Dropping it expires its remote catalog.
use super::{
    AttachedSurface, BrowserPointerOwner, ClientIdentityWire, ClientTransport, MessageWriter,
    ResourceClientStream, ResourceClientWait, ResourceRequestId, SurfaceId,
};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::time::Instant;

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
    /// The connection comes from this owner's own journal plugin (its
    /// process group, checked before it registers): the bundled screen detector
    /// connects back at start and stays. It is not a client a person
    /// reattaches through, so the orphan exit does not count it
    /// (orphan_shutdown.rs).
    pub(in crate::server) owner_plugin: bool,
    #[cfg(unix)]
    pub(in crate::server) machine_catalog: Option<super::machine_catalog::Publication>,
}
