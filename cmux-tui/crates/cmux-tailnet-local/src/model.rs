//! Sans-I/O model: the subset of tailscaled's LocalAPI JSON this crate reads
//! (`ipnstate.Status`, `ipn.Prefs`, `ipn.LoginProfile`) and the classified
//! [`TailnetView`] built from it. Unknown fields are ignored, missing ones
//! default, so a newer or older tailscaled only changes what is known.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};

use serde::Deserialize;

use crate::Error;

/// How the local node currently reaches one peer, read from magicsock's view
/// in `/localapi/v0/status`.
///
/// `Relay` in the status JSON is the peer's *home* DERP region and is set for
/// nearly every peer, so it alone never means "via DERP". The classification
/// is, in order: a `CurAddr` is a live direct UDP path; a `PeerRelay` is a
/// Tailscale peer relay; an active session with neither rides DERP; an online
/// peer with no session yet is idle (its first packets would go through its
/// home DERP region while disco tries for a direct path).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PeerPath {
    /// Direct UDP to `endpoint` (LAN, public mapping, or IPv6).
    Direct { endpoint: SocketAddr },
    /// Through a Tailscale peer relay (`ip:port:vni:N` as tailscaled prints it).
    PeerRelay { relay: String },
    /// An active session with no direct path: packets ride DERP `region`.
    Derp { region: String },
    /// Online, no recent traffic, so no path chosen yet; `home_region` is the
    /// peer's home DERP region if known.
    Idle { home_region: Option<String> },
    /// The control plane reports the peer offline.
    Offline,
    /// Not enough data to tell (old tailscaled, or the CLI's view lacks fields).
    Unknown,
}

impl PeerPath {
    /// A direct path is up right now: a tailnet address for this peer is
    /// worth racing (it costs one WireGuard hop, no relay).
    pub fn is_direct(&self) -> bool {
        matches!(self, Self::Direct { .. })
    }

    /// Traffic would go through some relay (DERP or a peer relay) right now.
    pub fn is_relayed(&self) -> bool {
        matches!(self, Self::Derp { .. } | Self::PeerRelay { .. })
    }

    /// A short stable name for logs and metrics.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Direct { .. } => "direct",
            Self::PeerRelay { .. } => "peer-relay",
            Self::Derp { .. } => "derp",
            Self::Idle { .. } => "idle",
            Self::Offline => "offline",
            Self::Unknown => "unknown",
        }
    }
}

/// Which control server the node is signed in to (`Prefs.ControlURL`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlKind {
    /// Tailscale's own coordination server.
    TailscaleSaas,
    /// Any other server: headscale or another self-hosted control plane.
    SelfHosted { url: String },
    /// Prefs were not readable (permission, the CLI fallback, an old daemon).
    Unknown,
}

impl ControlKind {
    pub fn from_url(url: &str) -> Self {
        let url = url.trim();
        if url.is_empty() {
            return Self::Unknown;
        }
        let host = url
            .split_once("://")
            .map_or(url, |(_, rest)| rest)
            .split(['/', ':', '?'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        if host == "tailscale.com" || host.ends_with(".tailscale.com") {
            Self::TailscaleSaas
        } else {
            Self::SelfHosted { url: url.to_owned() }
        }
    }
}

/// One peer, as classified from the status JSON.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    /// tailscaled's node id (`ID`).
    pub id: String,
    /// MagicDNS name without the trailing dot, or empty.
    pub dns_name: String,
    pub host_name: String,
    pub os: String,
    pub ips: Vec<IpAddr>,
    pub online: bool,
    /// Traffic in the last few minutes (`Active`).
    pub active: bool,
    pub cur_addr: Option<SocketAddr>,
    /// Home DERP region code (`Relay`), e.g. `sfo`.
    pub home_region: Option<String>,
    pub peer_relay: Option<String>,
    /// RFC 3339, `None` when tailscaled reports Go's zero time.
    pub last_handshake: Option<String>,
    /// This peer is the current exit node.
    pub exit_node: bool,
    /// This peer offers itself as an exit node.
    pub exit_node_option: bool,
    /// Subnet routes this peer is the primary router for (`PrimaryRoutes`).
    pub primary_routes: Vec<String>,
    pub allowed_ips: Vec<String>,
    pub tags: Vec<String>,
    pub user_id: i64,
    /// Shared into this tailnet from another one (`ShareeNode`).
    pub sharee_node: bool,
    pub path: PeerPath,
}

impl Peer {
    /// The address a client dials: IPv4 first.
    pub fn dial_ip(&self) -> Option<IpAddr> {
        self.ips.iter().find(|ip| ip.is_ipv4()).or_else(|| self.ips.first()).copied()
    }

    /// Advertises subnet routes beyond its own addresses.
    pub fn is_subnet_router(&self) -> bool {
        !self.primary_routes.is_empty()
    }
}

/// This node.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SelfNode {
    pub id: String,
    pub dns_name: String,
    pub host_name: String,
    pub ips: Vec<IpAddr>,
    pub user_id: i64,
    pub tags: Vec<String>,
}

/// The tailnet this node is in (`CurrentTailnet`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TailnetName {
    pub name: String,
    pub magic_dns_suffix: String,
    pub magic_dns_enabled: bool,
}

/// The exit node in use (`ExitNodeStatus`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExitNode {
    pub id: String,
    pub online: bool,
    pub ips: Vec<String>,
}

/// The current login profile (`/localapi/v0/profiles/current`). tailscaled
/// can hold several; only the current one is reported.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub control_url: String,
    pub tailnet: String,
}

/// Where a view came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    UnixSocket,
    /// The macOS GUI app's loopback port with its same-user token.
    LoopbackTcp,
    NamedPipe,
    /// `tailscale status --json`, when no LocalAPI endpoint answered.
    Cli,
    /// Built from JSON handed in by the caller (tests, a host-supplied hint).
    Supplied,
}

/// One read of the local tailnet, classified.
#[derive(Clone, Debug)]
pub struct TailnetView {
    /// `ipn.State` name: `Running`, `Stopped`, `NeedsLogin`, ...
    pub backend_state: String,
    pub version: String,
    pub this: SelfNode,
    pub tailnet: Option<TailnetName>,
    pub control: ControlKind,
    pub exit_node: Option<ExitNode>,
    pub profile: Option<Profile>,
    pub peers: Vec<Peer>,
    pub source: Source,
    by_ip: HashMap<IpAddr, usize>,
}

impl TailnetView {
    pub fn running(&self) -> bool {
        self.backend_state == "Running"
    }

    /// The peer that owns `ip` (one of its Tailscale addresses).
    pub fn peer(&self, ip: IpAddr) -> Option<&Peer> {
        self.by_ip.get(&ip).and_then(|&i| self.peers.get(i))
    }

    /// How a connection to `ip` would travel now. `None` when `ip` is not a
    /// peer's Tailscale address (or is this node's own).
    pub fn path_hint(&self, ip: IpAddr) -> Option<PeerPath> {
        if !self.running() {
            return None;
        }
        self.peer(ip).map(|peer| peer.path.clone())
    }

    /// The peer whose MagicDNS name (full or first label) or host name is `name`.
    pub fn peer_by_name(&self, name: &str) -> Option<&Peer> {
        let name = name.trim_end_matches('.');
        self.peers.iter().find(|p| {
            p.dns_name.eq_ignore_ascii_case(name)
                || p.dns_name.split('.').next().is_some_and(|l| l.eq_ignore_ascii_case(name))
                || p.host_name.eq_ignore_ascii_case(name)
        })
    }

    /// The status key that, when it changes, makes prefs and profile worth
    /// reading again (they cost two more LocalAPI calls otherwise).
    pub(crate) fn identity_key(&self) -> (String, String, String) {
        (
            self.backend_state.clone(),
            self.this.id.clone(),
            self.tailnet.as_ref().map(|t| t.name.clone()).unwrap_or_default(),
        )
    }
}

/// True for an address in Tailscale's ranges: 100.64.0.0/10 (CGNAT) or
/// fd7a:115c:a1e0::/48.
pub fn is_tailnet_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, _, _] = v4.octets();
            a == 100 && (b & 0xc0) == 64
        }
        IpAddr::V6(v6) => {
            matches!(v6.segments(), [0xfd7a, 0x115c, 0xa1e0, ..])
        }
    }
}

// ---- raw JSON ----

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawStatus {
    version: String,
    backend_state: String,
    #[serde(rename = "Self")]
    self_status: Option<RawPeer>,
    #[serde(rename = "MagicDNSSuffix")]
    magic_dns_suffix: String,
    current_tailnet: Option<RawTailnet>,
    exit_node_status: Option<RawExitNode>,
    peer: Option<HashMap<String, RawPeer>>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawTailnet {
    name: String,
    #[serde(rename = "MagicDNSSuffix")]
    magic_dns_suffix: String,
    #[serde(rename = "MagicDNSEnabled")]
    magic_dns_enabled: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawExitNode {
    #[serde(rename = "ID")]
    id: String,
    online: bool,
    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawPeer {
    #[serde(rename = "ID")]
    id: String,
    host_name: String,
    #[serde(rename = "DNSName")]
    dns_name: String,
    #[serde(rename = "OS")]
    os: String,
    #[serde(rename = "UserID")]
    user_id: i64,
    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
    tags: Option<Vec<String>>,
    primary_routes: Option<Vec<String>>,
    #[serde(rename = "AllowedIPs")]
    allowed_ips: Option<Vec<String>>,
    cur_addr: String,
    relay: String,
    peer_relay: String,
    online: Option<bool>,
    active: bool,
    last_handshake: String,
    exit_node: bool,
    exit_node_option: bool,
    sharee_node: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawPrefs {
    #[serde(rename = "ControlURL")]
    control_url: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawProfile {
    #[serde(rename = "ID")]
    id: String,
    name: String,
    #[serde(rename = "ControlURL")]
    control_url: String,
    network_profile: Option<RawNetworkProfile>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct RawNetworkProfile {
    domain_name: String,
}

fn ips(raw: Option<Vec<String>>) -> Vec<IpAddr> {
    raw.unwrap_or_default().iter().filter_map(|s| s.parse().ok()).collect()
}

fn nonempty(s: String) -> Option<String> {
    let s = s.trim().to_owned();
    (!s.is_empty()).then_some(s)
}

/// Go's zero `time.Time` marshals as `0001-01-01T00:00:00Z`.
fn handshake(s: String) -> Option<String> {
    nonempty(s).filter(|s| !s.starts_with("0001-01-01"))
}

/// Classifies one peer's path (see [`PeerPath`]).
fn classify(raw: &RawPeer) -> PeerPath {
    if let Ok(endpoint) = raw.cur_addr.trim().parse::<SocketAddr>() {
        return PeerPath::Direct { endpoint };
    }
    if let Some(relay) = nonempty(raw.peer_relay.clone()) {
        return PeerPath::PeerRelay { relay };
    }
    let home = nonempty(raw.relay.clone());
    match raw.online {
        Some(false) => PeerPath::Offline,
        _ if raw.active => match home {
            Some(region) => PeerPath::Derp { region },
            None => PeerPath::Unknown,
        },
        Some(true) => PeerPath::Idle { home_region: home },
        None => PeerPath::Unknown,
    }
}

fn peer(raw: RawPeer) -> Peer {
    let path = classify(&raw);
    Peer {
        path,
        id: raw.id,
        dns_name: raw.dns_name.trim_end_matches('.').to_owned(),
        host_name: raw.host_name,
        os: raw.os,
        ips: ips(raw.tailscale_ips),
        online: raw.online.unwrap_or(false),
        active: raw.active,
        cur_addr: raw.cur_addr.trim().parse().ok(),
        home_region: nonempty(raw.relay),
        peer_relay: nonempty(raw.peer_relay),
        last_handshake: handshake(raw.last_handshake),
        exit_node: raw.exit_node,
        exit_node_option: raw.exit_node_option,
        primary_routes: raw.primary_routes.unwrap_or_default(),
        allowed_ips: raw.allowed_ips.unwrap_or_default(),
        tags: raw.tags.unwrap_or_default(),
        user_id: raw.user_id,
        sharee_node: raw.sharee_node,
    }
}

/// Parses `/localapi/v0/status` (or `tailscale status --json`, the same
/// document) into a view. Prefs and profile are attached separately.
pub fn parse_status(json: &[u8], source: Source) -> Result<TailnetView, Error> {
    let raw: RawStatus =
        serde_json::from_slice(json).map_err(|e| Error::Parse(format!("status: {e}")))?;
    let this = raw.self_status.map(|me| SelfNode {
        id: me.id,
        dns_name: me.dns_name.trim_end_matches('.').to_owned(),
        host_name: me.host_name,
        ips: ips(me.tailscale_ips),
        user_id: me.user_id,
        tags: me.tags.unwrap_or_default(),
    });
    let tailnet = match raw.current_tailnet {
        Some(t) => Some(TailnetName {
            name: t.name,
            magic_dns_suffix: t.magic_dns_suffix,
            magic_dns_enabled: t.magic_dns_enabled,
        }),
        None if !raw.magic_dns_suffix.is_empty() => {
            Some(TailnetName { magic_dns_suffix: raw.magic_dns_suffix, ..TailnetName::default() })
        }
        None => None,
    };
    let exit_node = raw.exit_node_status.filter(|e| !e.id.is_empty()).map(|e| ExitNode {
        id: e.id,
        online: e.online,
        ips: e.tailscale_ips.unwrap_or_default(),
    });
    let mut peers: Vec<Peer> = raw.peer.unwrap_or_default().into_values().map(peer).collect();
    // HashMap order is random; a stable order keeps views diffable.
    peers.sort_by(|a, b| a.dns_name.cmp(&b.dns_name).then_with(|| a.id.cmp(&b.id)));
    let mut by_ip = HashMap::new();
    for (i, p) in peers.iter().enumerate() {
        for ip in &p.ips {
            by_ip.insert(*ip, i);
        }
    }
    Ok(TailnetView {
        backend_state: raw.backend_state,
        version: raw.version,
        this: this.unwrap_or_default(),
        tailnet,
        control: ControlKind::Unknown,
        exit_node,
        profile: None,
        peers,
        source,
        by_ip,
    })
}

/// Reads `ControlURL` out of `/localapi/v0/prefs`. Nothing else is kept:
/// prefs can carry node state the caller has no use for.
pub fn parse_prefs_control(json: &[u8]) -> Result<ControlKind, Error> {
    let raw: RawPrefs =
        serde_json::from_slice(json).map_err(|e| Error::Parse(format!("prefs: {e}")))?;
    Ok(ControlKind::from_url(&raw.control_url))
}

/// Parses `/localapi/v0/profiles/current`.
pub fn parse_profile(json: &[u8]) -> Result<Profile, Error> {
    let raw: RawProfile =
        serde_json::from_slice(json).map_err(|e| Error::Parse(format!("profile: {e}")))?;
    Ok(Profile {
        id: raw.id,
        name: raw.name,
        control_url: raw.control_url,
        tailnet: raw.network_profile.map(|n| n.domain_name).unwrap_or_default(),
    })
}

impl TailnetView {
    /// Attaches prefs' control kind and the current profile. When prefs were
    /// unreadable the profile's `ControlURL` still names the server.
    pub fn with_extras(mut self, control: ControlKind, profile: Option<Profile>) -> Self {
        self.control = match (&control, &profile) {
            (ControlKind::Unknown, Some(p)) => ControlKind::from_url(&p.control_url),
            _ => control,
        };
        self.profile = profile;
        self
    }
}
