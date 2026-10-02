//! Path identities and kinds.

/// A path the endpoint assigned to one peer. Ids are local to that peer's
/// selector and never reused while the selector lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PathId(pub u16);

/// How a path carries the session's datagrams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PathKind {
    /// UDP to an address on a shared local network.
    DirectLan,
    /// UDP to a global IPv6 address or a punched IPv4 mapping.
    DirectWan,
    /// UDP to the peer's VPC address through the device's Freestyle tunnel.
    ViaCloudRegion,
    /// Binary WebSocket frames through the target host's Durable Object.
    DoRelay,
}

/// The two ranks the selector compares first: any live direct path beats
/// every relay, whatever the RTTs say. Inside a class the RTT decides.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PathClass {
    Direct,
    Relayed,
}

impl PathKind {
    pub const ALL: [PathKind; 4] =
        [PathKind::DirectLan, PathKind::DirectWan, PathKind::ViaCloudRegion, PathKind::DoRelay];

    pub fn class(self) -> PathClass {
        match self {
            PathKind::DirectLan | PathKind::DirectWan => PathClass::Direct,
            PathKind::ViaCloudRegion | PathKind::DoRelay => PathClass::Relayed,
        }
    }

    /// The label clients show next to an interactive surface
    /// (sync-and-transport.md 6.5 path types).
    pub fn wire_name(self) -> &'static str {
        match self {
            PathKind::DirectLan => "direct_lan",
            PathKind::DirectWan => "direct_wan",
            PathKind::ViaCloudRegion => "via_cloud_region",
            PathKind::DoRelay => "do_relay",
        }
    }

    /// Whether a local network change invalidates the path's addresses.
    /// Relays are reached by name over a fresh connection, so they survive.
    pub fn depends_on_local_address(self) -> bool {
        matches!(self, PathKind::DirectLan | PathKind::DirectWan)
    }
}
