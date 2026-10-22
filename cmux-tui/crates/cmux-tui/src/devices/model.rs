//! One device list (plans/cmux-next/add-device-DESIGN.md 2.4): every store
//! that lets another device in, merged into one row per device. Pure: the
//! inputs are the JSON the stores already print, so tests drive it with
//! fixtures and no daemon.

use serde::Serialize;
use serde_json::Value;

use super::network::{NetworkNode, NetworkStatus};

/// What the stores said, as their own `--json` printed it.
#[derive(Clone, Debug, Default)]
pub(crate) struct Sources {
    /// `acp host ls --json`: `{"peers": [...]}`.
    pub peers: Value,
    /// `acp host ticket ls --json`: `{"tickets": [...], "devices": [...]}`.
    pub pairing: Value,
    /// Remote hosting (`~/.cmux/host/remote.json`): the owner, `allow` and `grants`.
    pub remote: Value,
}

/// What a device is to a person.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum Kind {
    Computer,
    Phone,
}

/// What a device may do, in the words a row shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum Role {
    /// This machine runs agents on it (an acpmux peer, or a daemon-role pairing).
    RunsAgents,
    /// It may use this machine's agents and terminals.
    UsesThis,
    /// It may list and watch only.
    WatchOnly,
}

/// Where a device stands now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum State {
    Connected,
    Offline,
    /// Added, but waiting for a person to approve it.
    Pending,
    /// It is added but cannot work; `detail` says why.
    Error,
}

/// One store's record of a device: removing the device removes every one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "store", rename_all = "kebab-case")]
pub(crate) enum Via {
    /// An acpmux peer this machine dials.
    Peer { name: String },
    /// A credential in acpmux `pairing.json`.
    Paired { id: String },
    /// A remote-hosting teammate grant.
    Grant { login: String },
    /// A remote-hosting full-access login (`cmux host allow`).
    Allow { login: String },
}

/// Where the network reaches a device.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Reach {
    pub network: &'static str,
    pub address: String,
    /// Every network address of the device.
    pub ips: Vec<String>,
    pub online: bool,
}

/// One row of `cmux device list`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Device {
    /// Stable for one device across runs: `peer:NAME`, `paired:ID`, `grant:LOGIN`, `allow:LOGIN`.
    pub id: String,
    pub name: String,
    pub kind: Kind,
    pub roles: Vec<Role>,
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reach: Option<Reach>,
    pub via: Vec<Via>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub added_at: Option<String>,
    /// A sentence a person can act on (an error, what a pending device waits for).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// A computer the network knows that is not a device yet (Add Device, way 1).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Available {
    pub name: String,
    /// What enroll dials: the MagicDNS name, else the address.
    pub address: String,
    pub os: String,
    /// Same login as this machine, not tagged and not shared in.
    pub mine: bool,
}

/// An open invite (an acpmux ticket not yet used).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Invite {
    pub id: String,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub expires_at: String,
}

/// `cmux device list --json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Listing {
    pub network: NetworkStatus,
    pub devices: Vec<Device>,
    pub available: Vec<Available>,
    pub invites: Vec<Invite>,
}

/// Merges the stores and the network's nodes into one row per device.
pub(crate) fn merge(_sources: &Sources, network: NetworkStatus, _nodes: &[NetworkNode]) -> Listing {
    Listing { network, devices: Vec::new(), available: Vec::new(), invites: Vec::new() }
}

/// The device `key` names: its id, its name, or its network address, case-insensitive.
pub(crate) fn find<'a>(_listing: &'a Listing, _key: &str) -> Option<&'a Device> {
    None
}
