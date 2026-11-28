//! `ServerReachPlan`: which paired servers the app shows and how it dials
//! each (`ServerReachService` runs the reads and applies the plan), with the
//! `ServerReach` rules the plan needs (id and socket checks, the DNS label of
//! a server name, the machine id).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet};

/// The machine id prefix of a paired server (`ServerReach.machineIDPrefix`).
pub const MACHINE_ID_PREFIX: &str = "server-";

/// One host of `team.hosts.list` (`PairedServer`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedServer {
    pub host: String,
    pub name: String,
    /// `server`, `device`, or nil from an older backend.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// Where a placed chief's brain runs (`CloudChief.BrainPlace`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainPlace {
    pub host: String,
    pub install: String,
}

/// One cloud chief (`CloudChief`), the fields the app reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudChief {
    pub id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_conversation: Option<String>,
    #[serde(default)]
    pub rev: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brain_place: Option<BrainPlace>,
}

impl CloudChief {
    /// `CloudChief.parse`: one `HomeChief` value (snake_case, as the API
    /// sends it); nil without an `id` or a numeric `rev`.
    pub fn parse(value: &Value) -> Option<CloudChief> {
        let object = value.as_object()?;
        let id = object.get("id")?.as_str()?.to_owned();
        let rev = number_int(object.get("rev")?)?;
        let brain_place = object.get("brain_place").and_then(Value::as_object).and_then(|raw| {
            Some(BrainPlace {
                host: raw.get("host")?.as_str()?.to_owned(),
                install: raw.get("install")?.as_str()?.to_owned(),
            })
        });
        Some(CloudChief {
            id,
            display_name: object
                .get("display_name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            is_default: object.get("is_default").and_then(Value::as_bool).unwrap_or(false),
            main_conversation: object
                .get("main_conversation")
                .and_then(Value::as_str)
                .map(str::to_owned),
            rev,
            brain_place,
        })
    }
}

/// `(value as? NSNumber)?.intValue`: any JSON number (a fraction truncates)
/// or a bool.
fn number_int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_u64().map(|u| i64::try_from(u).unwrap_or(i64::MAX)))
            .or_else(|| n.as_f64().map(|f| f as i64)),
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

/// This Mac when it may itself be the placed server (`LocalServer`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalServer {
    #[serde(default)]
    pub host_names: Vec<String>,
    pub brain_socket: String,
}

/// This Mac's `cmux link` (`LinkPeers`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct LinkPeers {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    #[serde(default)]
    pub installs: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peers_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub install: Option<String>,
}

impl LinkPeers {
    /// `registrationFile`: `link.json` in the parent of the pairing file's
    /// directory.
    pub fn registration_file(&self) -> Option<String> {
        let peers = self.peers_file.as_deref()?;
        let state_dir = parent(peers);
        Some(join(&parent(&state_dir), "link.json"))
    }

    /// `watchedFiles`: the pairing file and the registration, when known.
    pub fn watched_files(&self) -> Vec<String> {
        self.peers_file.iter().cloned().chain(self.registration_file()).collect()
    }
}

/// `URL(fileURLWithPath:).deletingLastPathComponent().path` for an absolute
/// path: trailing slashes are ignored, and the root stays the root.
fn parent(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".to_owned(),
        Some(at) => trimmed.get(..at).unwrap_or("/").to_owned(),
    }
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') { format!("{dir}{name}") } else { format!("{dir}/{name}") }
}

/// How the app dials a server (`ServerReach.Route`). The SSH route carries
/// only its destination: the session, binary and socket are the brain's
/// fixed layout, which Swift's `SSHHost` fills in.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Route {
    Ssh {
        destination: String,
    },
    Unix {
        socket: String,
    },
    #[serde(rename_all = "camelCase")]
    Overlay {
        link_socket: String,
    },
}

/// A paired server's session (`ServerReach`), validated.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reach {
    #[serde(rename = "hostID")]
    pub host_id: String,
    #[serde(rename = "installID")]
    pub install_id: String,
    pub name: String,
    pub route: Route,
}

impl Reach {
    /// `ServerReach.init`: the field that does not validate, or the reach
    /// (its name trimmed).
    pub fn new(
        host_id: &str,
        install_id: &str,
        name: &str,
        route: Route,
    ) -> Result<Reach, &'static str> {
        if !is_id(host_id, "host_") {
            return Err("host");
        }
        if !is_id(install_id, "inst_") {
            return Err("install");
        }
        let trimmed = name.trim();
        if trimmed.is_empty() || trimmed.chars().count() > 80 {
            return Err("name");
        }
        match &route {
            Route::Unix { socket } if !is_local_socket(socket) => return Err("socket"),
            Route::Overlay { link_socket } if !is_local_socket(link_socket) => {
                return Err("link_socket");
            }
            _ => {}
        }
        Ok(Reach {
            host_id: host_id.to_owned(),
            install_id: install_id.to_owned(),
            name: trimmed.to_owned(),
            route,
        })
    }

    /// `machineID`.
    pub fn machine_id(&self) -> String {
        format!("{MACHINE_ID_PREFIX}{}", self.host_id)
    }
}

/// `ServerReach.isID`: the prefix, then 8 to 64 ASCII letters or digits.
pub fn is_id(text: &str, prefix: &str) -> bool {
    let Some(rest) = text.strip_prefix(prefix) else {
        return false;
    };
    (8..=64).contains(&rest.chars().count()) && rest.chars().all(|c| c.is_ascii_alphanumeric())
}

/// `ServerReach.isLocalSocket`: an absolute path of plain path characters
/// with no `..` component.
pub fn is_local_socket(path: &str) -> bool {
    path.starts_with('/')
        && path.chars().count() <= 1024
        && !path.split('/').any(|part| part == "..")
        && path.chars().all(|c| c.is_ascii_alphanumeric() || "/._~+- ".contains(c))
}

/// `ServerReach.dnsLabel`: lowercase letters, digits, dots and dashes;
/// spaces and underscores become one dash; anything else is dropped; dashes
/// and dots at either end are trimmed.
pub fn dns_label(name: &str) -> Option<String> {
    let mut out = String::new();
    for c in name.to_lowercase().chars().filter(char::is_ascii) {
        if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
            out.push(c);
        } else if (c == ' ' || c == '_') && !out.ends_with('-') {
            out.push('-');
        }
    }
    let label = out.trim_matches(|c| c == '-' || c == '.');
    (!label.is_empty()).then(|| label.to_owned())
}

/// `ServerReach.brainRoute`: SSH to the server's name as a DNS label; nil
/// when nothing usable is left (or the label is longer than a host name).
pub fn brain_route(server_name: &str) -> Option<Route> {
    let host = dns_label(server_name)?;
    (host.chars().count() <= 253).then_some(Route::Ssh { destination: host })
}

/// `isThisMac`: by install id when this Mac's link names one, else by host
/// name.
pub fn is_this_mac(
    host: &PairedServer,
    install: Option<&str>,
    local: &LocalServer,
    link: Option<&LinkPeers>,
) -> bool {
    if let Some(mine) = link.and_then(|l| l.install.as_deref()) {
        return Some(mine) == install;
    }
    let Some(theirs) = dns_label(&host.name) else {
        return false;
    };
    local.host_names.iter().any(|name| dns_label(name).as_deref() == Some(theirs.as_str()))
}

/// `route(for:install:local:link:)`: this Mac's brain socket when the
/// server is this Mac; else the overlay when the link has the install as a
/// peer; else SSH to the server's name.
pub fn route(
    host: &PairedServer,
    install: Option<&str>,
    local: Option<&LocalServer>,
    link: Option<&LinkPeers>,
) -> Option<Route> {
    if let Some(local) = local
        && is_this_mac(host, install, local, link)
    {
        return Some(Route::Unix { socket: local.brain_socket.clone() });
    }
    if let Some(link) = link
        && let Some(socket) = &link.socket
        && let Some(install) = install
        && link.installs.contains(install)
    {
        return Some(Route::Overlay { link_socket: socket.clone() });
    }
    brain_route(&host.name)
}

/// A plan (`ServerReachPlan`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub desired: Vec<Reach>,
    pub unroutable: Vec<String>,
}

/// `ServerReachPlan.make`: one reach per placed, still-paired server (not a
/// `device`), first chief first; a server with no valid route is named in
/// `unroutable`.
pub fn make(
    chiefs: &[CloudChief],
    hosts: &[PairedServer],
    local: Option<&LocalServer>,
    link: Option<&LinkPeers>,
) -> Plan {
    let mut by_id: HashMap<&str, &PairedServer> = HashMap::new();
    for host in hosts {
        by_id.entry(host.host.as_str()).or_insert(host);
    }
    let mut seen: HashSet<&str> = HashSet::new();
    let mut plan = Plan { desired: Vec::new(), unroutable: Vec::new() };
    for chief in chiefs {
        let Some(place) = &chief.brain_place else {
            continue;
        };
        let Some(host) = by_id.get(place.host.as_str()) else {
            continue;
        };
        if host.kind.as_deref() == Some("device") || !seen.insert(place.host.as_str()) {
            continue;
        }
        let reach = route(host, Some(&place.install), local, link)
            .and_then(|r| Reach::new(&host.host, &place.install, &host.name, r).ok());
        match reach {
            Some(reach) => plan.desired.push(reach),
            None => plan.unroutable.push(host.name.clone()),
        }
    }
    plan
}

/// `ServerReachPlan.diff`'s reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diff {
    pub add: Vec<Reach>,
    /// Machine ids of the shown sessions to end.
    pub remove: Vec<String>,
    pub reroute: Vec<Reach>,
}

/// `ServerReachPlan.diff`: a session is reused only while its install and
/// route are unchanged.
pub fn diff(shown: &[Reach], desired: &[Reach]) -> Diff {
    let mut shown_by_host: HashMap<&str, &Reach> = HashMap::new();
    for reach in shown {
        shown_by_host.entry(reach.host_id.as_str()).or_insert(reach);
    }
    let desired_hosts: HashSet<&str> = desired.iter().map(|r| r.host_id.as_str()).collect();
    let add = desired
        .iter()
        .filter(|r| !shown_by_host.contains_key(r.host_id.as_str()))
        .cloned()
        .collect();
    let reroute = desired
        .iter()
        .filter(|r| {
            shown_by_host
                .get(r.host_id.as_str())
                .is_some_and(|old| old.install_id != r.install_id || old.route != r.route)
        })
        .cloned()
        .collect();
    let remove = shown
        .iter()
        .filter(|r| !desired_hosts.contains(r.host_id.as_str()))
        .map(Reach::machine_id)
        .collect();
    Diff { add, remove, reroute }
}

/// `parseLinkShow`: the live link's socket, or nil when it is not running.
pub fn parse_link_show(show: &Value) -> Option<String> {
    let object = show.as_object()?;
    if object.get("running").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let socket = object.get("socket")?.as_str()?;
    socket.starts_with('/').then(|| socket.to_owned())
}

/// `parseLinkPeersFile`: the link's pairing file, when absolute.
pub fn parse_link_peers_file(show: &Value) -> Option<String> {
    let file = show.get("peers_file")?.as_str()?;
    file.starts_with('/').then(|| file.to_owned())
}

/// `parsePeerList`: the paired installs.
pub fn parse_peer_list(peers: &Value) -> BTreeSet<String> {
    peers
        .get("peers")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| row.get("install").and_then(Value::as_str))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

/// `linkPeers(show:peers:)`: the link, running or not; nil when `show` is
/// not an object.
pub fn link_peers(show: &Value, peers: Option<&Value>) -> Option<LinkPeers> {
    let object = show.as_object()?;
    let install =
        object.get("install").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
    Some(LinkPeers {
        socket: parse_link_show(show),
        installs: peers.map(parse_peer_list).unwrap_or_default(),
        peers_file: parse_link_peers_file(show),
        install,
    })
}

/// `defaultLinkSetupFile`: `<CMUX_TUI_STATE_DIR or ~/Library/Application
/// Support/cmux-tui/sessions>/link/config.json`.
pub fn default_link_setup_file(environment: &HashMap<String, String>, home: &str) -> String {
    let state = environment
        .get("CMUX_TUI_STATE_DIR")
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| format!("{home}/Library/Application Support/cmux-tui/sessions"));
    join(state.trim_end_matches('/'), "link/config.json")
}

/// `parseChiefs`: the chiefs of a `chief.list` value; Err on a reply
/// without `chiefs` (never read as "no servers").
pub fn parse_chiefs(value: &Value) -> Result<Vec<CloudChief>, &'static str> {
    let chiefs = value.get("chiefs").and_then(Value::as_array).ok_or("chief.list")?;
    Ok(chiefs.iter().filter_map(CloudChief::parse).collect())
}

/// `parseHosts`'s reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostsPage {
    pub hosts: Vec<PairedServer>,
    #[serde(default)]
    pub next: Option<String>,
}

/// `parseHosts`: one `team.hosts.list` page; Err on a reply without
/// `hosts`.
pub fn parse_hosts(value: &Value) -> Result<HostsPage, &'static str> {
    let rows = value.get("hosts").and_then(Value::as_array).ok_or("team.hosts.list")?;
    let hosts = rows
        .iter()
        .filter_map(|row| {
            Some(PairedServer {
                host: row.get("id")?.as_str()?.to_owned(),
                name: row.get("name")?.as_str()?.to_owned(),
                kind: row.get("kind").and_then(Value::as_str).map(str::to_owned),
            })
        })
        .collect();
    let next = value.get("next_cursor").and_then(Value::as_str).map(str::to_owned);
    Ok(HostsPage { hosts, next })
}
