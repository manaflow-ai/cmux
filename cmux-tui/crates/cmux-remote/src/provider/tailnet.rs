//! Local, non-authoritative hints used to add a Tailscale address to a dial race.
//!
//! The LocalAPI reader lives in a separate crate (`cmux-tailnet-local`). The
//! race sees it through [`TailnetHints`]: [`LocalApiTailnetHints`] reads its
//! cached snapshot, [`NoTailnetHints`] is the setting turned off.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use cmux_tailnet_local::{TailnetLocal, TailnetView};

/// How a Tailscale address is reached right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PeerPath {
    /// A direct UDP path is worth racing.
    Direct {
        endpoint: SocketAddr,
    },
    /// DERP and peer-relay paths are slower than cmux's own carriers.
    Derp,
    PeerRelay,
    /// The local snapshot cannot classify the path.
    Unknown,
}

/// Controls whether Tailscale candidates participate in a race.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TailnetCarrierMode {
    /// Preserve the existing candidate list.
    #[default]
    Off,
    /// Add only candidates currently classified as direct.
    DirectOnly,
    /// Reserved for a future policy that may include relayed candidates.
    On,
}

impl TailnetCarrierMode {
    /// Parse the setting value. Unknown values remain safely disabled.
    pub fn parse(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "direct-only" | "direct_only" => Self::DirectOnly,
            "on" => Self::On,
            _ => Self::Off,
        }
    }

    /// Read the test override. The settings file remains the source of the
    /// user-facing default, while this variable makes race tests hermetic.
    pub fn from_env() -> Self {
        std::env::var("CMUX_TAILNET_CARRIER").ok().map_or(Self::Off, |value| Self::parse(&value))
    }
}

/// Read-only facts supplied by a tailscaled LocalAPI snapshot.
pub trait TailnetHints: Send + Sync {
    /// Classify a peer's tailnet address.
    fn path_hint(&self, ip: IpAddr) -> Option<PeerPath>;
    /// This node's tailnet addresses. An empty list means no usable tailnet.
    fn self_ips(&self) -> Vec<IpAddr>;
    /// Tailnet addresses known for a route host. A LocalAPI-backed adapter can
    /// implement this from its cached peer list without blocking a race.
    fn peer_ips(&self, _host: &str) -> Vec<IpAddr> {
        Vec::new()
    }
}

/// The default when no LocalAPI adapter is installed.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoTailnetHints;

impl TailnetHints for NoTailnetHints {
    fn path_hint(&self, _ip: IpAddr) -> Option<PeerPath> {
        None
    }

    fn self_ips(&self) -> Vec<IpAddr> {
        Vec::new()
    }
}

/// Reads the last tailscaled view without waiting (`TailnetLocal::snapshot`).
pub type TailnetViewReader = dyn Fn() -> Option<Arc<TailnetView>> + Send + Sync;

/// Hints from tailscaled's LocalAPI through the process-wide cached snapshot
/// (`cmux_tailnet_local::TailnetLocal`). Each call reads memory; a stale view
/// asks the snapshot's own thread to read tailscaled again. Nothing is read
/// until a race under a mode other than off asks.
pub struct LocalApiTailnetHints {
    read: Arc<TailnetViewReader>,
}

impl std::fmt::Debug for LocalApiTailnetHints {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("LocalApiTailnetHints").finish_non_exhaustive()
    }
}

impl LocalApiTailnetHints {
    /// The system tailscaled, through `TailnetLocal::global()`.
    pub fn system() -> Self {
        Self::with_reader(Arc::new(|| TailnetLocal::global().snapshot()))
    }

    /// Hints from `read` (tests, or a view the host supplied).
    pub fn with_reader(read: Arc<TailnetViewReader>) -> Self {
        Self { read }
    }

    fn view(&self) -> Option<Arc<TailnetView>> {
        (self.read)().filter(|view| view.running())
    }
}

impl TailnetHints for LocalApiTailnetHints {
    fn path_hint(&self, ip: IpAddr) -> Option<PeerPath> {
        self.view()?.path_hint(ip).map(PeerPath::from)
    }

    fn self_ips(&self) -> Vec<IpAddr> {
        self.view()
            .map(|view| view.this.ips.iter().copied().filter(|ip| tailnet_ip(*ip)).collect())
            .unwrap_or_default()
    }

    fn peer_ips(&self, host: &str) -> Vec<IpAddr> {
        let Some(view) = self.view() else { return Vec::new() };
        let host = host.trim().trim_start_matches('[').trim_end_matches(']').trim_end_matches('.');
        if host.is_empty() {
            return Vec::new();
        }
        let peer = match host.parse::<IpAddr>() {
            Ok(ip) => view.peer(ip),
            Err(_) => view.peer_by_name(host),
        };
        peer.map(|peer| peer.ips.clone()).unwrap_or_default()
    }
}

impl From<cmux_tailnet_local::PeerPath> for PeerPath {
    fn from(path: cmux_tailnet_local::PeerPath) -> Self {
        use cmux_tailnet_local::PeerPath as Local;
        match path {
            Local::Direct { endpoint } => Self::Direct { endpoint },
            Local::Derp { .. } => Self::Derp,
            Local::PeerRelay { .. } => Self::PeerRelay,
            // No path chosen yet, offline or unclassified: never a candidate.
            Local::Idle { .. } | Local::Offline | Local::Unknown => Self::Unknown,
        }
    }
}

/// The hint source for `mode`: off reads nothing (no LocalAPI call, no
/// snapshot thread); otherwise the system tailscaled, asked to read now so
/// the first race already has a view.
pub fn hints_for_mode(mode: TailnetCarrierMode) -> Arc<dyn TailnetHints> {
    if mode == TailnetCarrierMode::Off {
        return Arc::new(NoTailnetHints);
    }
    TailnetLocal::global().refresh();
    Arc::new(LocalApiTailnetHints::system())
}

fn tailnet_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, ..] = ip.octets();
            a == 100 && (b & 0xc0) == 64
        }
        IpAddr::V6(ip) => {
            let [a, b, c, ..] = ip.segments();
            a == 0xfd7a && b == 0x115c && c == 0xa1e0
        }
    }
}

/// Append direct tailnet candidates to a resolved address list.
///
/// Candidates are deduplicated and placed before ordinary addresses so the
/// existing hedge starts the direct tailnet path first. Relayed hints are
/// deliberately omitted even when the mode is `on`, keeping DERP below cmux's
/// own relay and direct paths until measured policy exists.
pub fn add_candidates(
    addresses: &[SocketAddr],
    host: &str,
    mode: TailnetCarrierMode,
    hints: &dyn TailnetHints,
) -> Vec<SocketAddr> {
    let port = addresses.first().map_or(0, SocketAddr::port);
    add_candidates_on_port(addresses, host, port, mode, hints)
}

/// Append direct tailnet candidates using the dialer's explicit port.
pub fn add_candidates_on_port(
    addresses: &[SocketAddr],
    host: &str,
    port: u16,
    mode: TailnetCarrierMode,
    hints: &dyn TailnetHints,
) -> Vec<SocketAddr> {
    let direct = direct_candidates(host, port, mode, hints);
    merge_direct_candidates(&direct, addresses)
}

pub(crate) fn merge_direct_candidates(
    direct: &[SocketAddr],
    addresses: &[SocketAddr],
) -> Vec<SocketAddr> {
    let mut out = Vec::with_capacity(direct.len() + addresses.len());
    out.extend_from_slice(direct);
    for address in addresses {
        if !out.contains(address) {
            out.push(*address);
        }
    }
    out
}

/// The direct candidates known before resolving the ordinary route.
pub fn direct_candidates(
    host: &str,
    port: u16,
    mode: TailnetCarrierMode,
    hints: &dyn TailnetHints,
) -> Vec<SocketAddr> {
    if mode == TailnetCarrierMode::Off {
        return Vec::new();
    }
    let self_ips = hints.self_ips();
    if self_ips.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for ip in hints.peer_ips(host) {
        if !tailnet_ip(ip)
            || !self_ips.iter().any(|own| own.is_ipv4() == ip.is_ipv4())
            || !matches!(hints.path_hint(ip), Some(PeerPath::Direct { .. }))
        {
            continue;
        }
        if port != 0 {
            let address = SocketAddr::new(ip, port);
            if !out.contains(&address) {
                out.push(address);
            }
        }
    }
    out
}

#[cfg(test)]
#[path = "tailnet_tests.rs"]
mod tests;
