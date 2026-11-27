//! The network seam (plans/cmux-next/add-device-DESIGN.md 3): the overlay
//! that finds and reaches devices. Tailscale today; Weft (a527,
//! plans/cmux-next/mesh-DESIGN.md) plugs in behind the same trait, so the
//! add flow, the list and the remove never name a vendor.

use std::net::IpAddr;

use acpmux::tailnet::{Node, Status};
use serde::Serialize;

/// Which overlay a [`DeviceNetwork`] is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum NetworkKind {
    Tailscale,
    Weft,
    /// No overlay here: only ssh hosts and codes can add devices.
    None,
}

impl NetworkKind {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Tailscale => "tailscale",
            Self::Weft => "weft",
            Self::None => "none",
        }
    }
}

/// The overlay as this device sees it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct NetworkStatus {
    pub kind: NetworkKind,
    /// Signed in and running.
    pub up: bool,
    /// This device's name on the network.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub this: Option<String>,
    /// Why the network is not up, as a sentence a person can act on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl NetworkStatus {
    pub(crate) fn none(detail: impl Into<String>) -> Self {
        Self { kind: NetworkKind::None, up: false, this: None, detail: Some(detail.into()) }
    }
}

/// One node the network knows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct NetworkNode {
    /// The short name (first DNS label, else the host name).
    pub name: String,
    /// The full DNS name, empty without one.
    pub dns_name: String,
    pub ips: Vec<IpAddr>,
    pub os: String,
    pub online: bool,
    /// The same person as this device: same login, not tagged, not shared in.
    pub mine: bool,
}

impl NetworkNode {
    /// What a client dials: the DNS name, else the first IPv4, else any address.
    pub(crate) fn address(&self) -> String {
        if !self.dns_name.is_empty() {
            return self.dns_name.clone();
        }
        let ip = self.ips.iter().find(|ip| ip.is_ipv4()).or(self.ips.first());
        ip.map(ToString::to_string).unwrap_or_else(|| self.name.clone())
    }

    /// Whether `host` (a URL's host, a name or an address) names this node.
    pub(crate) fn answers_to(&self, host: &str) -> bool {
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        if host.is_empty() {
            return false;
        }
        let dns = self.dns_name.trim_end_matches('.').to_ascii_lowercase();
        host == dns
            || host == self.name.to_ascii_lowercase()
            || (!dns.is_empty() && dns.split('.').next() == Some(host.as_str()))
            || host.parse::<IpAddr>().is_ok_and(|ip| self.ips.contains(&ip))
    }
}

/// An overlay network that finds and reaches devices.
pub(crate) trait DeviceNetwork {
    fn status(&self) -> NetworkStatus;
    /// Every other node, online or not.
    fn nodes(&self) -> Vec<NetworkNode>;
}

/// Tailscale through the one wrapper cmux has (`acpmux::tailnet`).
pub(crate) struct TailscaleNetwork {
    status: Result<Status, String>,
}

impl TailscaleNetwork {
    /// Reads `tailscale status --json` once.
    pub(crate) fn read() -> Self {
        let status = acpmux::tailnet::Tailnet::locate()
            .and_then(|t| t.status())
            .map_err(|e| format!("{e:#}"));
        Self { status }
    }

    /// A network from a status already read (tests).
    #[cfg(test)]
    pub(crate) fn from_status(status: Result<Status, String>) -> Self {
        Self { status }
    }
}

fn node(this: &Node, n: &Node) -> NetworkNode {
    let mine = !n.tagged() && !n.shared && n.login.is_some() && n.login == this.login;
    NetworkNode {
        name: n.short_name(),
        dns_name: n.dns_name.clone(),
        ips: n.ips.clone(),
        os: n.os.clone(),
        online: n.online,
        mine,
    }
}

impl DeviceNetwork for TailscaleNetwork {
    fn status(&self) -> NetworkStatus {
        match &self.status {
            Ok(s) if s.backend_state == "Running" => NetworkStatus {
                kind: NetworkKind::Tailscale,
                up: true,
                this: Some(s.this.short_name()),
                detail: None,
            },
            Ok(s) => NetworkStatus {
                kind: NetworkKind::Tailscale,
                up: false,
                this: None,
                detail: Some(format!(
                    "Tailscale is {} on this computer. Open Tailscale and sign in.",
                    s.backend_state
                )),
            },
            Err(e) => NetworkStatus::none(e.clone()),
        }
    }

    fn nodes(&self) -> Vec<NetworkNode> {
        match &self.status {
            Ok(s) => s.peers.iter().map(|n| node(&s.this, n)).collect(),
            Err(_) => Vec::new(),
        }
    }
}

/// Weft (a527). Its client library is not in this tree yet, so it reports
/// that it is not set up; the flow then uses Tailscale or ssh.
pub(crate) struct WeftNetwork;

impl DeviceNetwork for WeftNetwork {
    fn status(&self) -> NetworkStatus {
        NetworkStatus {
            kind: NetworkKind::Weft,
            up: false,
            this: None,
            detail: Some("This computer is not on the cmux network (Weft) yet.".to_owned()),
        }
    }

    fn nodes(&self) -> Vec<NetworkNode> {
        Vec::new()
    }
}

/// The `devices.network` choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Choice {
    /// Weft when this device is on it, else Tailscale.
    Auto,
    Tailscale,
    Weft,
}

impl Choice {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        match text.trim().to_ascii_lowercase().as_str() {
            "" | "auto" => Some(Self::Auto),
            "tailscale" => Some(Self::Tailscale),
            "weft" => Some(Self::Weft),
            _ => None,
        }
    }
}

/// The network `choice` names, given the ones that exist here.
pub(crate) fn pick(
    choice: Choice,
    weft: Box<dyn DeviceNetwork>,
    tailscale: impl FnOnce() -> Box<dyn DeviceNetwork>,
) -> Box<dyn DeviceNetwork> {
    match choice {
        Choice::Weft => weft,
        Choice::Tailscale => tailscale(),
        Choice::Auto if weft.status().up => weft,
        Choice::Auto => tailscale(),
    }
}
