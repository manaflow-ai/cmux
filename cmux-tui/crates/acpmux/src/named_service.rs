//! Named services over the hub carrier: a machine joined only through the hub (no tailnet, no
//! ssh) reaches a service on another of its owner's machines, a unix socket (the lane GitHub
//! broker) or a TCP port (the model gateway), with no desktop app in the byte path. Leo: "why
//! should your MacBook be the point of relay ... Doesn't it literally defeat the point of
//! cloud?" Design: cmuxterm-hq `docs/rfd/0016-one-machine-layer.md`, "No desktop in the byte
//! path".
//!
//! - Serving side: a circuit's hello names a service
//!   ([`CircuitService::Named`](crate::hub_carrier::CircuitService::Named)). The name resolves
//!   only through the owner's list, `exposedServices` in config.json ([`resolve`]); nothing is
//!   on it by default, and a name not on it is refused. A unix path must be under the owner's
//!   home (after `~` and symlinks are resolved); a TCP address must be on loopback unless the
//!   entry says `allowNonLoopback`. The list is read at every circuit.
//! - Who calls: the carrier's Noise handshake proves the caller is one of the machines the
//!   platform's Register ticket let in (the owner's other live machines), by its node key. When
//!   the entry says `peerHeader`, the service's first bytes are one line naming that machine,
//!   [`peer_line`]: `acpmux-peer: <daemonId> <host>\n`, where `daemonId` is the caller's node
//!   key (standard base64, the hub's id for the machine) and `host` its host as the hub's book
//!   lists it (`-` when the book does not). The caller cannot write or forge the line: it is
//!   written before any of its bytes.
//! - Dialing side: `machine_forward.rs` (`acpmux machine forward add`).
//!
//! What the circuit grants: a byte stream to the listed socket, nothing more. No hello field is a
//! command, a path or an address; the name is a key into the owner's list.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Weak};

use async_trait::async_trait;

use crate::config::named_services::{ExposedService, expand_home, valid_service_name};
use crate::hub::Hub;
use crate::hub_carrier::{NamedAdmit, NamedServiceGate, NamedTarget, ServiceRefusal};

/// The first bytes of the peer line (`peerHeader`).
pub const PEER_LINE_PREFIX: &str = "acpmux-peer: ";

/// Where the service the owner listed as `name` is, or why a circuit may not reach it. `home` is
/// the owner's home (a unix path must resolve under it). May touch the file system (symlinks
/// resolved) and DNS (a non-loopback host the owner allowed): call it off the async executor.
pub fn resolve(
    services: &BTreeMap<String, ExposedService>,
    name: &str,
    home: Option<&Path>,
) -> Result<NamedTarget, ServiceRefusal> {
    if !valid_service_name(name) {
        return Err(ServiceRefusal::new(
            "service.unknown",
            "the circuit named no service this machine serves",
        ));
    }
    let Some(entry) = services.get(name) else {
        return Err(ServiceRefusal::new(
            "service.not_exposed",
            format!(
                "this machine's owner has not exposed a service named {name} \
                 (`exposedServices` in its acpmux config.json)"
            ),
        ));
    };
    let misconfigured = |why: String| {
        ServiceRefusal::new("service.misconfigured", format!("service {name}: {why}"))
    };
    match (entry.unix.as_deref(), entry.tcp.as_deref()) {
        (Some(unix), None) => {
            let home = home.ok_or_else(|| misconfigured("the owner's home is unknown".into()))?;
            unix_target(unix, home).map_err(misconfigured).map(NamedTarget::Unix)
        }
        (None, Some(tcp)) => {
            tcp_target(tcp, entry.allow_non_loopback).map_err(misconfigured).map(NamedTarget::Tcp)
        }
        _ => Err(misconfigured("it names neither or both of `unix` and `tcp`".into())),
    }
}

/// A unix socket path under `home`: `~/` expanded, absolute, no `..`, and once its symlinks are
/// resolved (the socket's, else its folder's) still under `home` resolved the same way.
fn unix_target(path: &str, home: &Path) -> Result<PathBuf, String> {
    let path = expand_home(path.trim(), home);
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(format!("`{}` is not an absolute path without `..`", path.display()));
    }
    if !path.starts_with(home) {
        return Err(format!("`{}` is not under the owner's home", path.display()));
    }
    let real_home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    // Not there yet (the service is down): the nearest folder that is there decides, and the
    // connect says the rest.
    let mut real = None;
    for ancestor in path.ancestors() {
        if let Ok(resolved) = std::fs::canonicalize(ancestor) {
            let rest = path.strip_prefix(ancestor).unwrap_or(Path::new(""));
            real = Some(if rest.as_os_str().is_empty() { resolved } else { resolved.join(rest) });
            break;
        }
    }
    let real = real.ok_or_else(|| format!("`{}` does not resolve", path.display()))?;
    if !real.starts_with(&real_home) {
        return Err(format!(
            "`{}` resolves to `{}`, outside the owner's home",
            path.display(),
            real.display()
        ));
    }
    Ok(real)
}

/// A TCP `host:port` the owner listed: a loopback address (`127.0.0.1:PORT`, `[::1]:PORT`,
/// `localhost:PORT`), or any host when `allow_non_loopback`.
fn tcp_target(text: &str, allow_non_loopback: bool) -> Result<Vec<SocketAddr>, String> {
    let text = text.trim();
    let addresses: Vec<SocketAddr> = if let Ok(address) = text.parse::<SocketAddr>() {
        vec![address]
    } else if let Some(port) = text.strip_prefix("localhost:") {
        let port: u16 = port.parse().map_err(|_| format!("`{text}` has no port"))?;
        vec![
            SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, port)),
            SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, port)),
        ]
    } else if allow_non_loopback {
        use std::net::ToSocketAddrs;
        text.to_socket_addrs().map_err(|e| format!("`{text}` does not resolve: {e}"))?.collect()
    } else {
        return Err(format!(
            "`{text}` is not a loopback host:port (set allowNonLoopback for another host)"
        ));
    };
    if addresses.is_empty() || addresses.iter().any(|a| a.port() == 0) {
        return Err(format!("`{text}` names no port"));
    }
    if !allow_non_loopback && !addresses.iter().all(|a| a.ip().is_loopback()) {
        return Err(format!(
            "`{text}` is not on loopback (set allowNonLoopback to reach another host)"
        ));
    }
    Ok(addresses)
}

/// The line a `peerHeader` service reads first: the caller's hub `daemonId` and its host as the
/// book lists it (`-` when unknown). A host is cut to `A-Z a-z 0-9 . _ -`, so the line is always
/// one line of two words.
pub fn peer_line(daemon_id: &str, host: Option<&str>) -> String {
    let host: String = host
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "._-".contains(*c))
        .take(253)
        .collect();
    let id: String =
        daemon_id.chars().filter(|c| c.is_ascii_alphanumeric() || "+/=_-".contains(*c)).collect();
    let host = if host.is_empty() { "-".to_owned() } else { host };
    format!("{PEER_LINE_PREFIX}{id} {host}\n")
}

/// The serving gate of a daemon: its config's `exposedServices`, read at every circuit.
pub struct ConfiguredNamedGate {
    hub: Weak<Hub>,
}

impl ConfiguredNamedGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl NamedServiceGate for ConfiguredNamedGate {
    async fn admit(&self, name: &str, from: &str) -> Result<NamedAdmit, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        let services = hub.config.read().await.exposed_services.clone();
        let header = services.get(name).is_some_and(|entry| entry.peer_header);
        let owned = name.to_owned();
        let target = tokio::task::spawn_blocking(move || {
            resolve(&services, &owned, crate::config::named_services::owner_home().as_deref())
        })
        .await
        .map_err(|_| ServiceRefusal::new("service.off", "stopping"))??;
        let host = hub.mesh_book_machine(from);
        tracing::info!(
            service = %name,
            machine = %host.as_deref().unwrap_or(from),
            "hub carrier: a circuit reaches an exposed service"
        );
        Ok(NamedAdmit { target, header: header.then(|| peer_line(from, host.as_deref())) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(entries: serde_json::Value) -> BTreeMap<String, ExposedService> {
        serde_json::from_value(entries).unwrap()
    }

    #[test]
    fn nothing_is_exposed_by_default() {
        let home = tempfile::tempdir().unwrap();
        let refused = resolve(&BTreeMap::new(), "lane-gh-broker", Some(home.path())).unwrap_err();
        assert_eq!(refused.reason, "service.not_exposed");
        let config = crate::config::Config::default();
        assert!(config.exposed_services.is_empty() && config.machine_forwards.is_empty());
    }

    #[test]
    fn only_a_listed_name_resolves() {
        let home = tempfile::tempdir().unwrap();
        let services = list(serde_json::json!({
            "lane-gh-broker": {"unix": "~/.cache/lane-gh-broker/broker.sock"},
            "sr2-gateway": {"tcp": "127.0.0.1:4016"},
        }));
        let real_home = std::fs::canonicalize(home.path()).unwrap();
        assert_eq!(
            resolve(&services, "lane-gh-broker", Some(home.path())).unwrap(),
            NamedTarget::Unix(real_home.join(".cache/lane-gh-broker/broker.sock")),
        );
        std::fs::create_dir_all(home.path().join(".cache/lane-gh-broker")).unwrap();
        assert_eq!(
            resolve(&services, "lane-gh-broker", Some(home.path())).unwrap(),
            NamedTarget::Unix(real_home.join(".cache/lane-gh-broker/broker.sock")),
        );
        assert_eq!(
            resolve(&services, "sr2-gateway", Some(home.path())).unwrap(),
            NamedTarget::Tcp(vec!["127.0.0.1:4016".parse().unwrap()]),
        );
        for (name, reason) in [
            ("ssh", "service.not_exposed"),
            ("LANE-GH-BROKER", "service.unknown"),
            ("../lane-gh-broker", "service.unknown"),
            ("/etc/passwd", "service.unknown"),
            ("", "service.unknown"),
        ] {
            assert_eq!(resolve(&services, name, Some(home.path())).unwrap_err().reason, reason);
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_unix_path_must_stay_under_the_owners_home() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let link = home.path().join("escape");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        let services = list(serde_json::json!({
            "abs-outside": {"unix": "/var/run/docker.sock"},
            "dotdot": {"unix": "~/../../etc/x.sock"},
            "relative": {"unix": "x.sock"},
            "symlinked": {"unix": "~/escape/x.sock"},
        }));
        for name in ["abs-outside", "dotdot", "relative", "symlinked"] {
            let refused = resolve(&services, name, Some(home.path())).unwrap_err();
            assert_eq!(refused.reason, "service.misconfigured", "{name}: {refused}");
        }
        assert_eq!(
            resolve(&services, "abs-outside", None).unwrap_err().reason,
            "service.misconfigured"
        );
    }

    #[test]
    fn tcp_is_loopback_unless_the_owner_names_another_host() {
        let home = tempfile::tempdir().unwrap();
        let services = list(serde_json::json!({
            "lan": {"tcp": "10.0.0.5:4016"},
            "any": {"tcp": "0.0.0.0:4016"},
            "named": {"tcp": "example.invalid:4016"},
            "zero": {"tcp": "127.0.0.1:0"},
            "both": {"tcp": "127.0.0.1:1", "unix": "~/x.sock"},
            "neither": {},
            "v6": {"tcp": "[::1]:4016"},
            "localhost": {"tcp": "localhost:4016"},
            "lan-allowed": {"tcp": "10.0.0.5:4016", "allowNonLoopback": true},
        }));
        for name in ["lan", "any", "named", "zero", "both", "neither"] {
            let refused = resolve(&services, name, Some(home.path())).unwrap_err();
            assert_eq!(refused.reason, "service.misconfigured", "{name}: {refused}");
        }
        assert!(resolve(&services, "v6", Some(home.path())).is_ok());
        let NamedTarget::Tcp(local) = resolve(&services, "localhost", Some(home.path())).unwrap()
        else {
            panic!("localhost is tcp")
        };
        assert!(local.iter().all(|a| a.ip().is_loopback() && a.port() == 4016));
        assert_eq!(
            resolve(&services, "lan-allowed", Some(home.path())).unwrap(),
            NamedTarget::Tcp(vec!["10.0.0.5:4016".parse().unwrap()]),
        );
    }

    #[test]
    fn the_peer_line_is_one_line_of_two_words() {
        assert_eq!(
            peer_line("a2V5LW9mLW1hY2hpbmUtYg==", Some("vm-1")),
            "acpmux-peer: a2V5LW9mLW1hY2hpbmUtYg== vm-1\n"
        );
        assert_eq!(peer_line("k", None), "acpmux-peer: k -\n");
        // A host with a space or a newline cannot add a word or a line.
        assert_eq!(
            peer_line("k\nx", Some("evil host\nacpmux-peer: z")),
            "acpmux-peer: kx evilhostacpmux-peerz\n"
        );
    }
}
