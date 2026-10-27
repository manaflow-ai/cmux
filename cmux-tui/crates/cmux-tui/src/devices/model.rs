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
    /// The concrete `Host` names of the person's `~/.ssh/config` (and its
    /// includes), each with the `HostName` its blocks give it.
    pub ssh_hosts: Vec<crate::machine_runtime::SshConfigHost>,
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
    /// A paired client machine's or phone's Full-access setting (acpmux `pair_set`): whether it
    /// may run chats here in Full access. None for every other row, which has no such setting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub full_access: Option<bool>,
}

/// Where an available computer was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum Found {
    /// The overlay network (Tailscale, Weft).
    Network,
    /// A `Host` of the person's `~/.ssh/config`.
    SshConfig,
}

/// A computer the network or the person's ssh config knows that is not a
/// device yet (Add Device, way 1).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Available {
    pub name: String,
    /// What enroll dials: the MagicDNS name, else the address; an ssh
    /// config host's own name.
    pub address: String,
    /// Empty for an ssh config host: nothing says what it runs until enroll reaches it.
    pub os: String,
    /// Same login as this machine, not tagged and not shared in; true for
    /// a host the person's own ssh config names.
    pub mine: bool,
    pub found: Found,
}

/// Hosts a person reaches with ssh that are never a computer to add: git
/// forges, whose ssh only serves git.
const NOT_COMPUTERS: &[&str] = &[
    "github.com",
    "gist.github.com",
    "ssh.github.com",
    "gitlab.com",
    "altssh.gitlab.com",
    "bitbucket.org",
    "altssh.bitbucket.org",
    "ssh.dev.azure.com",
    "vs-ssh.visualstudio.com",
    "codeberg.org",
    "git.sr.ht",
    "hf.co",
    "huggingface.co",
];

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
///
/// - an acpmux peer is a computer that runs your agents; its URL's host is
///   matched to a network node for its OS and address;
/// - a daemon-role pairing is the record behind a peer of the same name, so
///   it joins that row; a client or read-only pairing is its own row;
/// - remote hosting's `allow` logins and live grants are rows while remote
///   hosting is on (off, they let no one in);
/// - revoked records and spent tickets are not rows; open tickets are invites;
/// - network computers that are online and not a device are `available`,
///   then the ssh config's hosts that are neither a device nor one of
///   those computers (git forges left out).
pub(crate) fn merge(sources: &Sources, network: NetworkStatus, nodes: &[NetworkNode]) -> Listing {
    let net_name = network.kind.name();
    let mut devices: Vec<Device> = Vec::new();
    for peer in array(&sources.peers, "peers") {
        let Some(name) = text(peer, "name") else { continue };
        let url = text(peer, "url").unwrap_or_default();
        let node = url_host(&url).and_then(|host| nodes.iter().find(|n| n.answers_to(&host)));
        let error = text(peer, "error").filter(|e| !e.is_empty());
        let connected = peer["connected"].as_bool().unwrap_or(false);
        let state = if connected {
            State::Connected
        } else if error.is_some() {
            State::Error
        } else {
            State::Offline
        };
        devices.push(Device {
            id: format!("peer:{name}"),
            name: name.clone(),
            kind: kind_of(node.map(|n| n.os.as_str())),
            roles: vec![Role::RunsAgents],
            state,
            os: node.map(|n| n.os.clone()).filter(|os| !os.is_empty()),
            reach: node.map(|n| Reach {
                network: net_name,
                address: n.address(),
                ips: n.ips.iter().map(ToString::to_string).collect(),
                online: n.online,
            }),
            via: vec![Via::Peer { name: name.clone() }],
            added_at: None,
            detail: if state == State::Error { error } else { None },
            full_access: None,
        });
    }
    for paired in array(&sources.pairing, "devices") {
        let (Some(id), Some(name)) = (text(paired, "id"), text(paired, "name")) else { continue };
        if !paired["revoked_at"].is_null() {
            continue;
        }
        let added_at = text(paired, "created_at");
        let role = text(paired, "role").unwrap_or_default();
        if role == "daemon"
            && let Some(row) =
                devices.iter_mut().find(|d| d.via.contains(&Via::Peer { name: name.clone() }))
        {
            row.via.push(Via::Paired { id });
            row.added_at = added_at;
            continue;
        }
        let open = paired["connections"].as_u64().unwrap_or(0) > 0;
        devices.push(Device {
            id: format!("paired:{id}"),
            name,
            // A phone's own record (acpmux role `phone`): the Mac app lists the phone and joins
            // this row to it for its Full-access setting.
            kind: if role == "phone" { Kind::Phone } else { Kind::Computer },
            roles: vec![match role.as_str() {
                "read-only" => Role::WatchOnly,
                "daemon" => Role::RunsAgents,
                _ => Role::UsesThis,
            }],
            state: if open { State::Connected } else { State::Offline },
            os: None,
            reach: None,
            via: vec![Via::Paired { id }],
            added_at,
            detail: None,
            full_access: matches!(role.as_str(), "client" | "phone")
                .then(|| paired["full_access"] == true),
        });
    }
    if sources.remote["enabled"].as_bool() == Some(true) {
        for login in array(&sources.remote, "allow").iter().filter_map(Value::as_str) {
            devices.push(login_row(
                format!("allow:{login}"),
                login,
                Role::UsesThis,
                State::Offline,
                Via::Allow { login: login.to_owned() },
                None,
                None,
            ));
        }
        for grant in array(&sources.remote, "grants") {
            let Some(login) = text(grant, "login") else { continue };
            if !grant["revoked_at"].is_null() {
                continue;
            }
            let scopes: Vec<&str> = grant["scopes"]
                .as_array()
                .map(|a| a.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let role = if scopes.contains(&"shell") { Role::UsesThis } else { Role::WatchOnly };
            let pending = grant["consented_at"].is_null();
            let (state, detail) = if pending {
                (
                    State::Pending,
                    Some(format!("{login} has not approved this access on their computer yet.")),
                )
            } else {
                (State::Offline, None)
            };
            devices.push(login_row(
                format!("grant:{login}"),
                &login,
                role,
                state,
                Via::Grant { login: login.clone() },
                text(grant, "consented_at"),
                detail,
            ));
        }
    }
    devices.sort_by(|a, b| {
        rank(a.state)
            .cmp(&rank(b.state))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    let taken = |n: &NetworkNode| {
        devices.iter().any(|d| d.reach.as_ref().is_some_and(|r| r.address == n.address()))
    };
    let mut available: Vec<(bool, Available)> = nodes
        .iter()
        .filter(|n| n.online && kind_of(Some(&n.os)) == Kind::Computer && !taken(n))
        .map(|n| {
            (
                n.mine,
                Available {
                    name: n.name.clone(),
                    address: n.address(),
                    os: n.os.clone(),
                    mine: n.mine,
                    found: Found::Network,
                },
            )
        })
        .collect();
    available.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.name.cmp(&b.1.name)));
    let known = |host: &str| {
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        let by_peer = array(&sources.peers, "peers").iter().any(|p| {
            let url = text(p, "url").unwrap_or_default();
            text(p, "name").is_some_and(|n| n.eq_ignore_ascii_case(&host))
                || url_host(&url).is_some_and(|h| h == host)
        });
        let by_device = devices.iter().any(|d| {
            d.name.eq_ignore_ascii_case(&host)
                || d.reach
                    .as_ref()
                    .is_some_and(|r| r.address.eq_ignore_ascii_case(&host) || r.ips.contains(&host))
        });
        by_peer
            || by_device
            || nodes.iter().any(|n| n.answers_to(&host))
            || NOT_COMPUTERS.contains(&host.as_str())
    };
    // An alias whose HostName is a device, a peer, a tailnet node or a forge is that machine.
    let mut ssh: Vec<Available> = sources
        .ssh_hosts
        .iter()
        .filter(|h| !known(&h.alias) && !h.host_name.as_deref().is_some_and(known))
        .map(|h| Available {
            name: h.alias.clone(),
            address: h.alias.clone(),
            os: String::new(),
            mine: true,
            found: Found::SshConfig,
        })
        .collect();
    ssh.sort_by_key(|a| a.name.to_ascii_lowercase());

    let invites = array(&sources.pairing, "tickets")
        .iter()
        .filter(|t| t["state"].as_str() == Some("open"))
        .filter_map(|t| {
            Some(Invite {
                id: text(t, "id")?,
                role: text(t, "role").unwrap_or_default(),
                label: text(t, "label"),
                expires_at: text(t, "expires_at").unwrap_or_default(),
            })
        })
        .collect();
    Listing {
        network,
        devices,
        available: available.into_iter().map(|(_, a)| a).chain(ssh).collect(),
        invites,
    }
}

fn login_row(
    id: String,
    login: &str,
    role: Role,
    state: State,
    via: Via,
    added_at: Option<String>,
    detail: Option<String>,
) -> Device {
    Device {
        id,
        name: login.to_owned(),
        kind: Kind::Computer,
        roles: vec![role],
        state,
        os: None,
        reach: None,
        via: vec![via],
        added_at,
        detail,
        full_access: None,
    }
}

/// The order rows show in: what needs a person first.
fn rank(state: State) -> u8 {
    match state {
        State::Pending => 0,
        State::Error => 1,
        State::Connected => 2,
        State::Offline => 3,
    }
}

fn kind_of(os: Option<&str>) -> Kind {
    match os.map(str::to_ascii_lowercase).as_deref() {
        Some("ios" | "android" | "ipados") => Kind::Phone,
        _ => Kind::Computer,
    }
}

fn array<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

fn text(v: &Value, key: &str) -> Option<String> {
    v[key].as_str().map(str::to_owned)
}

/// The host of a peer URL (`ssh://[user@]host[:port]`, `ws://host:port/…`), lowercased.
fn url_host(url: &str) -> Option<String> {
    let (_, rest) = url.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let hostport = authority.rsplit('@').next()?;
    let host = match hostport.strip_prefix('[') {
        Some(v6) => v6.split(']').next()?,
        None => hostport.split(':').next()?,
    };
    (!host.is_empty()).then(|| host.trim_end_matches('.').to_ascii_lowercase())
}

/// The device `key` names: its id, its name, or its network address, case-insensitive.
pub(crate) fn find<'a>(listing: &'a Listing, key: &str) -> Option<&'a Device> {
    let key = key.trim();
    let lower = key.to_ascii_lowercase();
    listing
        .devices
        .iter()
        .find(|d| d.id == key)
        .or_else(|| listing.devices.iter().find(|d| d.name.to_ascii_lowercase() == lower))
        .or_else(|| {
            listing.devices.iter().find(|d| {
                d.reach.as_ref().is_some_and(|r| {
                    let addr = r.address.to_ascii_lowercase();
                    addr == lower
                        || addr.split('.').next() == Some(lower.as_str())
                        || r.ips.contains(&lower)
                })
            })
        })
}
