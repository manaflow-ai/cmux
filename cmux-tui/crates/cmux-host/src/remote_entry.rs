//! The session host's remote WebSocket entry: bind and auth mode, from the
//! host config `/etc/cmux/host.json` (pure).
//!
//! The default is `127.0.0.1:1337` with enrolled auth: every connection must
//! present a device enrolled with the session host (cmux-remote device
//! enrollment), and revoking the device closes its live sessions. A loopback
//! or tailnet bind (100.64.0.0/10, fd7a:115c:a1e0::/48) keeps enrolled auth;
//! a tailnet bind adds `--remote-ws-insecure-bind` because the plaintext
//! WebSocket rides the WireGuard tunnel.
//!
//! The only other mode is the cmux Cloud edge carrier:
//! `{"remoteWs": {"bind": "0.0.0.0:1337", "carrier": "freestyle-edge"}}`.
//! It runs the exact Cloud command line (`--remote-ws-insecure-bind
//! --remote-ws-trusted-carrier`, equal to cmuxTuiDaemon.ts), which grants
//! carrier auth to every link without enrollment. It is accepted only with
//! the wildcard bind, on Linux, on a machine bound to a metadata instance id.
//! It ASSUMES that nothing reaches port 1337 except the Freestyle edge:
//! verifying that in the image (firewall or interface bind, public IPv6
//! included) and moving Cloud clients to enrolled auth are tracked in bead
//! cx-wx2.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use serde_json::{Map, Value};

/// The host config the bind agent reads (under the agent's root).
pub const HOST_CONFIG_FILE: &str = "/etc/cmux/host.json";
/// The default entry: loopback, enrolled auth.
pub const DEFAULT_BIND: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1337);
/// The bead that tracks the edge carrier's assumptions.
pub const EDGE_CARRIER_BEAD: &str = "cx-wx2";

/// Who admits peers in the trusted-carrier mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Carrier {
    /// The Freestyle edge in front of a cmux Cloud machine.
    FreestyleEdge,
}

impl Carrier {
    pub fn as_str(self) -> &'static str {
        match self {
            Carrier::FreestyleEdge => "freestyle-edge",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteEntry {
    /// Every connection presents an enrolled device.
    Enrolled { bind: SocketAddr },
    /// The network admits peers; carrier auth without enrollment.
    TrustedCarrier { bind: SocketAddr, carrier: Carrier },
}

/// What the loader needs to know about the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Facts {
    pub linux: bool,
    /// The agent bound this machine to a metadata service instance id.
    pub bound_instance: bool,
}

impl RemoteEntry {
    /// The session host's `--remote-ws …` arguments.
    pub fn args(&self) -> Vec<String> {
        match self {
            RemoteEntry::Enrolled { bind } => {
                let mut args = vec!["--remote-ws".to_owned(), bind.to_string()];
                if !bind.ip().is_loopback() {
                    args.push("--remote-ws-insecure-bind".to_owned());
                }
                args
            }
            RemoteEntry::TrustedCarrier { bind, .. } => vec![
                "--remote-ws".to_owned(),
                bind.to_string(),
                "--remote-ws-insecure-bind".to_owned(),
                "--remote-ws-trusted-carrier".to_owned(),
            ],
        }
    }

    /// The one warning line logged at start, for the trusted-carrier mode.
    pub fn warning(&self) -> Option<String> {
        match self {
            RemoteEntry::Enrolled { .. } => None,
            RemoteEntry::TrustedCarrier { bind, carrier } => Some(format!(
                "cmux-host: WARNING remote entry {bind} runs in trusted-carrier mode \
                 (carrier {}): links get carrier auth without enrollment; this assumes \
                 nothing reaches the port except the {} (bead {EDGE_CARRIER_BEAD})",
                carrier.as_str(),
                carrier.as_str(),
            )),
        }
    }
}

/// Whether the host config file may be trusted: owned by the agent's own
/// user (root in production) and not writable by group or others.
/// Otherwise any process that can write the file could turn on the
/// trusted carrier.
pub fn file_is_trusted(owner_uid: u32, mode: u32, agent_euid: u32) -> Result<(), String> {
    if owner_uid != agent_euid {
        return Err(format!(
            "host.json is owned by uid {owner_uid}, not by the agent's uid {agent_euid}"
        ));
    }
    if mode & 0o022 != 0 {
        return Err(format!("host.json mode {:o} is writable by group or others", mode & 0o7777));
    }
    Ok(())
}

/// The entry for `text` (the host config, `None` when absent), or why the
/// config is refused.
pub fn parse(text: Option<&str>, facts: Facts) -> Result<RemoteEntry, String> {
    let Some(text) = text else { return Ok(RemoteEntry::Enrolled { bind: DEFAULT_BIND }) };
    let root: Value =
        serde_json::from_str(text).map_err(|e| format!("host.json is not JSON: {e}"))?;
    let Value::Object(root) = root else { return Err("host.json is not an object".to_owned()) };
    let section = match root.get("remoteWs") {
        None => return Ok(RemoteEntry::Enrolled { bind: DEFAULT_BIND }),
        Some(Value::Object(section)) => section,
        Some(_) => return Err("`remoteWs` is not an object".to_owned()),
    };
    if let Some(key) = section.keys().find(|k| !matches!(k.as_str(), "bind" | "carrier")) {
        return Err(format!("`remoteWs` has an unknown key {key:?}"));
    }
    let bind = bind(section)?;
    match section.get("carrier") {
        None => enrolled(bind),
        Some(Value::String(name)) if name == Carrier::FreestyleEdge.as_str() => {
            edge(bind, facts, Carrier::FreestyleEdge)
        }
        Some(other) => Err(format!("`remoteWs.carrier` {other} is not \"freestyle-edge\"")),
    }
}

fn bind(section: &Map<String, Value>) -> Result<Option<SocketAddr>, String> {
    match section.get("bind") {
        None => Ok(None),
        Some(Value::String(raw)) => raw
            .parse()
            .map(Some)
            .map_err(|_| format!("`remoteWs.bind` {raw:?} is not an IP address and port")),
        Some(other) => Err(format!("`remoteWs.bind` {other} is not a string")),
    }
}

fn enrolled(bind: Option<SocketAddr>) -> Result<RemoteEntry, String> {
    let bind = bind.unwrap_or(DEFAULT_BIND);
    if bind.ip().is_loopback() || is_tailnet(bind.ip()) {
        Ok(RemoteEntry::Enrolled { bind })
    } else {
        Err(format!(
            "`remoteWs.bind` {bind} is neither loopback nor tailnet; a wider bind needs \
             `\"carrier\": \"freestyle-edge\"` on a cmux Cloud machine"
        ))
    }
}

fn edge(bind: Option<SocketAddr>, facts: Facts, carrier: Carrier) -> Result<RemoteEntry, String> {
    let Some(bind) = bind.filter(|b| b.ip().is_unspecified()) else {
        return Err(format!(
            "the {} carrier needs the wildcard bind (0.0.0.0 or [::])",
            carrier.as_str()
        ));
    };
    if !facts.linux {
        return Err(format!("the {} carrier runs only on Linux", carrier.as_str()));
    }
    if !facts.bound_instance {
        return Err(format!(
            "the {} carrier needs a machine bound to a metadata instance id",
            carrier.as_str()
        ));
    }
    Ok(RemoteEntry::TrustedCarrier { bind, carrier })
}

/// Tailscale's address ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
fn is_tailnet(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            a == 100 && (64..128).contains(&b)
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

#[cfg(test)]
#[path = "remote_entry_tests.rs"]
mod tests;
