//! Whether ssh answers on each computer `cmux device list` offers to add, before the list
//! suggests `cmux device add HOST --yes` for it. A host whose ssh port never answers (a tailnet
//! ACL that drops tcp:22, a machine that runs no sshd) would make that command wait out ssh's
//! connect timeout and fail, so the list folds those hosts into one line instead.
//!
//! One bounded pass: every host at once, one thread each, and the pass returns at
//! [`BUDGET`] whatever is still pending, so its wall time does not grow with the host count.

use std::net::{SocketAddr, TcpStream, ToSocketAddrs as _};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::Serialize;

/// The whole pass's wall time.
pub(crate) const BUDGET: Duration = Duration::from_secs(2);

/// Hosts probed in one pass; past it a host is [`SshReach::Unprobed`] (and keeps its add command).
pub(crate) const MAX_HOSTS: usize = 256;

/// What the pass learned about one host's ssh port.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum SshReach {
    /// The ssh port accepted a TCP connection.
    Open,
    /// The port refused, the name did not resolve, or nothing answered within [`BUDGET`].
    NoAnswer,
    /// Not probed: ssh reaches it through a ProxyJump or ProxyCommand, or the pass was over its
    /// host cap. Its add command stays, since a direct dial says nothing about it.
    Unprobed,
}

/// Where ssh dials `host`, from `ssh -G HOST`: its HostName and Port, or `None` when ssh goes
/// through a proxy (a direct TCP dial would test the wrong path).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Dial {
    Direct { host: String, port: u16 },
    Proxied,
}

/// [`Dial`] from `ssh -G` output; a host with no `hostname` line is dialed by its own name.
pub(crate) fn dial_of(host: &str, ssh_g: &str) -> Dial {
    let mut host_name = None;
    let mut port = 22;
    for line in ssh_g.lines() {
        let Some((key, value)) = line.trim().split_once(' ') else { continue };
        let value = value.trim();
        match key.to_ascii_lowercase().as_str() {
            "hostname" if !value.is_empty() => host_name = Some(value.to_owned()),
            "port" => port = value.parse().unwrap_or(22),
            "proxyjump" | "proxycommand" if !value.is_empty() && value != "none" => {
                return Dial::Proxied;
            }
            _ => {}
        }
    }
    Dial::Direct { host: host_name.unwrap_or_else(|| bare(host).to_owned()), port }
}

/// `user@host` as `host`, `[v6]` as `v6`.
fn bare(host: &str) -> &str {
    host.rsplit('@').next().unwrap_or(host).trim_matches(['[', ']'])
}

/// `ssh -G HOST` (reads the config only, never the network); a host ssh cannot read, or no ssh,
/// is dialed directly by its name on port 22.
fn dial(host: &str) -> Dial {
    let out = Command::new("ssh")
        .args(["-G", "--", host])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    match out {
        Ok(o) if o.status.success() => dial_of(host, &String::from_utf8_lossy(&o.stdout)),
        _ => Dial::Direct { host: bare(host).to_owned(), port: 22 },
    }
}

/// One host: where ssh dials it, then [`dial_probe`].
fn probe_one(host: &str, deadline: Instant) -> SshReach {
    dial_probe(&dial(host), deadline)
}

/// A TCP connect to where ssh dials that ends by `deadline`; a proxied host is not dialed.
pub(crate) fn dial_probe(dial: &Dial, deadline: Instant) -> SshReach {
    let Dial::Direct { host, port } = dial else { return SshReach::Unprobed };
    let addrs: Vec<SocketAddr> = match (host.as_str(), *port).to_socket_addrs() {
        Ok(a) => a.collect(),
        Err(_) => return SshReach::NoAnswer,
    };
    for addr in addrs {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        if TcpStream::connect_timeout(&addr, left).is_ok() {
            return SshReach::Open;
        }
    }
    SshReach::NoAnswer
}

/// A probe of one host that answers by the deadline it is given (tests pass their own).
pub(crate) type Probe = Arc<dyn Fn(&str, Instant) -> SshReach + Send + Sync>;

/// The real probe: `ssh -G`, DNS, then a TCP connect.
pub(crate) fn tcp_probe() -> Probe {
    Arc::new(probe_one)
}

/// Every host at once, each on its own thread; the answer, in `hosts` order, is ready by
/// `budget` whatever the host count. A host still pending then is [`SshReach::NoAnswer`] (its
/// thread is left to end on its own: a slow DNS answer cannot hold the list).
pub(crate) fn probe_all(hosts: &[String], budget: Duration, probe: &Probe) -> Vec<SshReach> {
    let deadline = Instant::now() + budget;
    let mut out = vec![SshReach::Unprobed; hosts.len()];
    let (tx, rx) = mpsc::channel();
    let mut pending = 0;
    for (i, host) in hosts.iter().enumerate().take(MAX_HOSTS) {
        let (tx, probe, host) = (tx.clone(), Arc::clone(probe), host.clone());
        let spawned =
            std::thread::Builder::new().name("device-ssh-probe".into()).spawn(move || {
                let _ = tx.send((i, probe(&host, deadline)));
            });
        if spawned.is_ok() {
            out[i] = SshReach::NoAnswer;
            pending += 1;
        }
    }
    drop(tx);
    while pending > 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok((i, reach)) => {
                out[i] = reach;
                pending -= 1;
            }
            Err(_) => break,
        }
    }
    out
}
