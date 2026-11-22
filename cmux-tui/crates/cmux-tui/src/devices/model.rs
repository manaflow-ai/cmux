//! One device list (plans/cmux-next/add-device-DESIGN.md 2.4): every store
//! that lets another device in, merged into one row per device. Pure: the
//! inputs are the JSON the stores already print, so tests drive it with
//! fixtures and no daemon.

use serde::Serialize;
use serde_json::Value;

use super::network::{NetworkNode, NetworkStatus};
use cmux_device_kind::DeviceKind;
use cmux_device_kind::screen::{self, NoScreen, Screen};

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
    /// The team's joined machines as `machine list` rows (`kind: "joined"`):
    /// `[{"id","name","state","platform","createdAt",…}]`.
    pub joined: Value,
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
    /// A machine that joined the team with a pasted line (`cmux machine add`).
    Joined { machine_id: String },
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
    /// Stable for one device across runs: `peer:NAME`, `paired:ID`, `grant:LOGIN`, `allow:LOGIN`,
    /// `joined:MACHINE_ID`.
    pub id: String,
    pub name: String,
    pub kind: Kind,
    /// What the device is (`mac-mini`, `linux-server`, `iphone`): what it reports of itself
    /// (`host_health` `device`), else what its record's source or OS tells.
    pub device: DeviceKind,
    /// The glyph every view of this device draws: [`DeviceKind::symbol`], an SF Symbol name.
    pub symbol: &'static str,
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
    /// What the Screen Sharing page offers for it (`cmux_device_kind::screen::offer`): View, or
    /// nothing with the reason. None for a row that is not a machine (a person's login).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen: Option<Screen>,
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
    /// What enroll dials (`cmux device add ADDRESS --yes`): the person's ssh
    /// config alias for the computer when one names it, since that alias
    /// carries their user, key and HostKeyAlias pin (hq#11835: the MagicDNS
    /// name failed `Host key verification failed` where the alias reached
    /// it); else the MagicDNS name, else the address; an ssh config host's
    /// own name.
    pub address: String,
    /// Empty for an ssh config host: nothing says what it runs until enroll reaches it.
    pub os: String,
    /// Same login as this machine, not tagged and not shared in; true for
    /// a host the person's own ssh config names.
    pub mine: bool,
    pub found: Found,
    /// Whether ssh answers on it from here (`reach.rs`): set before `cmux device list` prints,
    /// and with `--json --probe`; absent when nothing probed it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssh: Option<super::reach::SshReach>,
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

/// Short-lived machines of one autoscaled pool (`ci-linux-pool-1114-162023-3fa17bde`):
/// one line, never one row each, since each lives minutes and none is a computer to add.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Pool {
    /// The name before the generated part (`ci-linux-pool`).
    pub stem: String,
    pub count: usize,
}

/// `cmux device list --json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Listing {
    pub network: NetworkStatus,
    pub devices: Vec<Device>,
    pub available: Vec<Available>,
    /// Network computers left out of `available` as members of a short-lived pool.
    pub pools: Vec<Pool>,
    pub invites: Vec<Invite>,
}

/// The pool stem of a machine name that ends in a generated id: a last part of 6 or more hex
/// characters with both a digit and a letter (`3fa17bde`), with any all-digit parts before it
/// (a timestamp) dropped too. `swarm-01` and `release-20261114` have no generated id.
pub(crate) fn pool_stem(name: &str) -> Option<&str> {
    let (rest, last) = name.rsplit_once('-')?;
    let generated = last.len() >= 6
        && last.chars().all(|c| c.is_ascii_hexdigit())
        && last.chars().any(|c| c.is_ascii_digit())
        && last.chars().any(|c| c.is_ascii_alphabetic());
    if !generated {
        return None;
    }
    let mut stem = rest;
    while let Some((head, part)) = stem.rsplit_once('-') {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_digit()) {
            break;
        }
        stem = head;
    }
    (!stem.is_empty()).then_some(stem)
}

/// Splits `available` network computers into the ones to list and pools: a stem two or more
/// machines share is a pool.
fn fold_pools(available: Vec<(bool, Available)>) -> (Vec<(bool, Available)>, Vec<Pool>) {
    let mut counts: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for (_, a) in &available {
        if let Some(stem) = pool_stem(&a.name) {
            *counts.entry(stem.to_owned()).or_default() += 1;
        }
    }
    counts.retain(|_, n| *n >= 2);
    let kept = available
        .into_iter()
        .filter(|(_, a)| !pool_stem(&a.name).is_some_and(|s| counts.contains_key(s)))
        .collect();
    (kept, counts.into_iter().map(|(stem, count)| Pool { stem, count }).collect())
}

/// What a peer down for over a day says: it is not failing now, it is gone.
fn parked_detail(name: &str) -> String {
    format!(
        "Not reachable for over a day; tried again hourly. If it is gone for good: cmux device remove {name}"
    )
}

/// The person's ssh config alias for network computer `node`: one whose
/// HostName is the node (its MagicDNS name, short name or address) first, else
/// one named as the node is. ssh dials such an alias with the person's own
/// user, key and known-hosts pin, which the bare MagicDNS name lacks.
fn ssh_alias(
    hosts: &[crate::machine_runtime::SshConfigHost],
    node: &NetworkNode,
) -> Option<String> {
    let by_host_name =
        hosts.iter().find(|h| h.host_name.as_deref().is_some_and(|name| node.answers_to(name)));
    by_host_name
        .or_else(|| {
            // An alias with its own HostName goes elsewhere, whatever its name says.
            hosts.iter().find(|h| h.host_name.is_none() && node.answers_to(&h.alias))
        })
        .map(|h| h.alias.clone())
}

/// Merges the stores and the network's nodes into one row per device.
///
/// - an acpmux peer is a computer that runs your agents; its URL's host is
///   matched to a network node for its OS and address (a peer with no URL,
///   a joined machine and a paired computer by their name), so the node is
///   never offered again as "Not added yet";
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
        // A peer joined over the mesh has no URL: its name is the only key to its node.
        let node = match url_host(&url) {
            Some(host) => nodes.iter().find(|n| n.answers_to(&host)),
            None => node_named(nodes, &name),
        };
        let error = text(peer, "error").filter(|e| !e.is_empty());
        let connected = peer["connected"].as_bool().unwrap_or(false);
        // acpmux's `parked`: down a day or more. Gone quiet, not a failure a person can act
        // on now, so it never sits at the top as "not working".
        let parked = !connected && peer["parked"].as_bool() == Some(true);
        let state = if connected {
            State::Connected
        } else if parked {
            State::Offline
        } else if error.is_some() {
            State::Error
        } else {
            State::Offline
        };
        let hub = hub_screen(peer);
        let device = peer_device(peer, &url, node, hub.as_ref());
        let os = node
            .map(|n| n.os.clone())
            .filter(|os| !os.is_empty())
            .or_else(|| hub.as_ref().and_then(HubScreen::platform).map(str::to_owned));
        let screen = hub_refusal(hub.as_ref(), device).map(|reason| Screen::None {
            reason: if connected { reason } else { NoScreen::Offline },
        });
        devices.push(Device {
            id: format!("peer:{name}"),
            name: name.clone(),
            kind: kind_of(node.map(|n| n.os.as_str())),
            device,
            symbol: device.symbol(),
            roles: vec![Role::RunsAgents],
            state,
            os,
            reach: node.map(|n| reach_of(n, net_name)),
            via: vec![Via::Peer { name: name.clone() }],
            added_at: None,
            detail: if parked {
                Some(parked_detail(&name))
            } else if state == State::Error {
                error
            } else {
                None
            },
            full_access: None,
            screen,
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
        let device = paired_device(paired, &role);
        // A paired computer has no address of its own: a network node of its name is it.
        let node = if role == "phone" { None } else { node_named(nodes, &name) };
        devices.push(Device {
            id: format!("paired:{id}"),
            name,
            // A phone's own record (acpmux role `phone`): the Mac app lists the phone and joins
            // this row to it for its Full-access setting.
            kind: if role == "phone" { Kind::Phone } else { Kind::Computer },
            device,
            symbol: device.symbol(),
            roles: vec![match role.as_str() {
                "read-only" => Role::WatchOnly,
                "daemon" => Role::RunsAgents,
                _ => Role::UsesThis,
            }],
            state: if open { State::Connected } else { State::Offline },
            os: node.map(|n| n.os.clone()).filter(|os| !os.is_empty()),
            reach: node.map(|n| reach_of(n, net_name)),
            via: vec![Via::Paired { id }],
            added_at,
            detail: None,
            full_access: matches!(role.as_str(), "client" | "phone")
                .then(|| paired["full_access"] == true),
            screen: None,
        });
    }
    for row in sources.joined.as_array().map(Vec::as_slice).unwrap_or_default() {
        let Some(id) = text(row, "id") else { continue };
        let state = text(row, "state").unwrap_or_default();
        // A revoked machine lets nothing in any more.
        if state == "revoked" {
            continue;
        }
        let device = reported(row)
            .unwrap_or_else(|| DeviceKind::from_os(&text(row, "platform").unwrap_or_default()));
        let name = text(row, "name").unwrap_or_else(|| id.clone());
        let node = node_named(nodes, &name);
        devices.push(Device {
            id: format!("joined:{id}"),
            name,
            kind: Kind::Computer,
            device,
            symbol: device.symbol(),
            roles: vec![Role::RunsAgents],
            state: if state == "online" { State::Connected } else { State::Offline },
            os: text(row, "platform"),
            reach: node.map(|n| reach_of(n, net_name)),
            via: vec![Via::Joined { machine_id: id }],
            added_at: text(row, "createdAt"),
            detail: None,
            full_access: None,
            screen: None,
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
    for d in devices.iter_mut().filter(|d| d.screen.is_none()) {
        d.screen = screen_of(d);
    }
    devices.sort_by(|a, b| {
        rank(a.state)
            .cmp(&rank(b.state))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    let taken = |n: &NetworkNode| {
        devices.iter().any(|d| d.reach.as_ref().is_some_and(|r| r.address == n.address()))
    };
    let available: Vec<(bool, Available)> = nodes
        .iter()
        .filter(|n| n.online && kind_of(Some(&n.os)) == Kind::Computer && !taken(n))
        .map(|n| {
            (
                n.mine,
                Available {
                    name: n.name.clone(),
                    address: ssh_alias(&sources.ssh_hosts, n).unwrap_or_else(|| n.address()),
                    os: n.os.clone(),
                    mine: n.mine,
                    found: Found::Network,
                    ssh: None,
                },
            )
        })
        .collect();
    let (mut available, pools) = fold_pools(available);
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
            ssh: None,
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
        pools,
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
        device: DeviceKind::Generic,
        symbol: DeviceKind::Generic.symbol(),
        roles: vec![role],
        state,
        os: None,
        reach: None,
        via: vec![via],
        added_at,
        detail,
        full_access: None,
        screen: None,
    }
}

/// What the Screen Sharing page offers for a row: none for a person's login (not a machine), else
/// what its kind (or, when it reported none, its OS) can do there.
fn screen_of(d: &Device) -> Option<Screen> {
    if d.via.iter().all(|v| matches!(v, Via::Grant { .. } | Via::Allow { .. })) {
        return None;
    }
    let os = if d.kind == Kind::Phone { Some("ios") } else { d.os.as_deref() };
    Some(screen::offer(d.device, os, d.state == State::Connected))
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

/// The kind a record says its device reported (`device`), when it names one.
fn reported(record: &Value) -> Option<DeviceKind> {
    record["device"].as_str().map(DeviceKind::parse)
}

/// An acpmux peer's kind: a Cloud machine (a `ws://`/`wss://` peer, as the app's location picker
/// tells them apart) by its source; else what the peer reported in its health; else, for a
/// machine only the mesh hub reaches (no health), what the device hub says of it (a Linux one
/// sharing its screen is a Linux desktop); else its OS.
fn peer_device(
    peer: &Value,
    url: &str,
    node: Option<&NetworkNode>,
    hub: Option<&HubScreen>,
) -> DeviceKind {
    if url.starts_with("ws://") || url.starts_with("wss://") {
        return DeviceKind::Cloud;
    }
    reported(&peer["health"])
        .or_else(|| reported(peer))
        .or_else(|| match hub {
            Some(HubScreen::Listed { platform, shared: true })
                if platform.eq_ignore_ascii_case("linux") =>
            {
                Some(DeviceKind::LinuxDesktop)
            }
            _ => None,
        })
        .unwrap_or_else(|| node.map_or(DeviceKind::Generic, |n| DeviceKind::from_os(&n.os)))
}

/// What the device hub says of the screen of a machine only the mesh hub reaches: acpmux's
/// `deviceHub` on its `peers` row, read from the hub's device list (`GET /v1/devices`) by the
/// share host. Absent when nothing read that list (no share host runs here).
#[derive(Clone, Debug, PartialEq, Eq)]
enum HubScreen {
    /// No device hub record has its name: no screen host signed in for it.
    Absent,
    /// Its record: the platform it registered as, and whether it shares its screen.
    Listed { platform: String, shared: bool },
}

impl HubScreen {
    fn platform(&self) -> Option<&str> {
        match self {
            HubScreen::Listed { platform, .. } if !platform.is_empty() => Some(platform),
            _ => None,
        }
    }
}

/// A `via: "hub"` peer row's [`HubScreen`]; None for any other row or one with no `deviceHub`.
fn hub_screen(peer: &Value) -> Option<HubScreen> {
    if peer["via"].as_str() != Some("hub") {
        return None;
    }
    let hub = &peer["deviceHub"];
    match hub["listed"].as_bool()? {
        false => Some(HubScreen::Absent),
        true => Some(HubScreen::Listed {
            platform: text(hub, "platform").unwrap_or_default(),
            shared: hub["screenShared"].as_bool() == Some(true),
        }),
    }
}

/// Why a hub-only machine whose kind says nothing has no screen to view, when the device hub
/// tells: no screen host signed in, or a Linux one with sharing off. None leaves it to its kind
/// and OS (`screen::offer`).
fn hub_refusal(hub: Option<&HubScreen>, device: DeviceKind) -> Option<NoScreen> {
    if device != DeviceKind::Generic {
        return None;
    }
    match hub? {
        HubScreen::Absent => Some(NoScreen::NoScreenHost),
        HubScreen::Listed { platform, shared: false } if platform.eq_ignore_ascii_case("linux") => {
            Some(NoScreen::SharingOff)
        }
        HubScreen::Listed { .. } => None,
    }
}

/// A pairing's kind: what the device reported, else its OS, else an iPhone for a phone pairing.
fn paired_device(paired: &Value, role: &str) -> DeviceKind {
    reported(paired)
        .or_else(|| text(paired, "os").map(|os| DeviceKind::from_os(&os)))
        .filter(|k| *k != DeviceKind::Generic)
        .unwrap_or(if role == "phone" { DeviceKind::IPhone } else { DeviceKind::Generic })
}

/// The network node a record with no address of its own names: the node's name, or the
/// first label of its DNS name. Mesh-joined peers, joined machines and paired computers
/// have no URL; without this their node is listed again under "Not added yet".
fn node_named<'a>(nodes: &'a [NetworkNode], name: &str) -> Option<&'a NetworkNode> {
    nodes.iter().find(|n| n.answers_to(name))
}

fn reach_of(n: &NetworkNode, network: &'static str) -> Reach {
    Reach {
        network,
        address: n.address(),
        ips: n.ips.iter().map(ToString::to_string).collect(),
        online: n.online,
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
