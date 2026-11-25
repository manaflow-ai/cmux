//! `cmux hosts check`: which declared hosts answer from here (CMUX-673).
//! Every endpoint of every host is tried at once, each on
//! its own thread, and the pass ends at its timeout whatever is still
//! pending, so its wall time stays the timeout or less at any host count.
//!
//! One endpoint: `ssh -G` says where ssh dials it (config only, no network),
//! then a TCP connect and a read of the server's first line. `SSH-…` is
//! [`Status::Reachable`]; a port that answers with something else is
//! [`Status::Down`] (a machine, but no ssh server); no answer is
//! [`Status::Unreachable`]. An endpoint ssh reaches through a ProxyJump or
//! ProxyCommand is [`Status::Unchecked`]: a direct dial would test another
//! path. A host takes the first endpoint, in its own order, that is
//! reachable; else down, else unchecked, else unreachable.

use std::io::Read as _;
use std::net::{SocketAddr, TcpStream, ToSocketAddrs as _};
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_config::hosts::{HostDecl, SshEndpoint, ssh_endpoint};
use cmux_process::{Command, Stdio};
use serde::Serialize;

use crate::devices::reach::{Dial, dial_of};

/// The check's default timeout.
pub(super) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(3);

/// The longest timeout `--timeout` takes.
pub(super) const MAX_TIMEOUT: Duration = Duration::from_secs(30);

/// Endpoints probed in one pass; past it an endpoint is unchecked.
const MAX_PROBES: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, PartialOrd, Ord)]
#[serde(rename_all = "kebab-case")]
pub(super) enum Status {
    /// An ssh server answered.
    Reachable,
    /// A machine answered on the ssh port, but not an ssh server.
    Down,
    /// Not dialed: ssh goes through a proxy, or the pass was over its cap.
    Unchecked,
    /// Nothing answered by the timeout; the host may work from another network.
    Unreachable,
}

/// What one endpoint answered.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct EndpointResult {
    pub endpoint: String,
    pub status: Status,
    /// Why it was not reachable, or the server's banner when it was.
    pub detail: String,
    /// Milliseconds from the pass's start to the answer (none when unanswered).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ms: Option<u64>,
}

/// One host's answer: its best endpoint, then every endpoint in its order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct HostResult {
    pub label: String,
    pub status: Status,
    /// The endpoint the status came from (the first reachable one, in order).
    pub endpoint: String,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ms: Option<u64>,
    pub endpoints: Vec<EndpointResult>,
}

/// A probe of one endpoint that answers by the deadline it is given (tests pass their own).
pub(super) type Probe = Arc<dyn Fn(&str, Instant, Instant) -> EndpointResult + Send + Sync>;

/// The real probe: `ssh -G`, DNS, a TCP connect, the server's first line.
pub(super) fn ssh_probe() -> Probe {
    Arc::new(|endpoint: &str, start: Instant, deadline: Instant| {
        let Some(target) = ssh_endpoint(endpoint) else {
            return result(endpoint, Status::Unreachable, "not an ssh address", None);
        };
        probe_dial(endpoint, &dial(&target), start, deadline)
    })
}

fn result(endpoint: &str, status: Status, detail: &str, ms: Option<u64>) -> EndpointResult {
    EndpointResult { endpoint: endpoint.to_owned(), status, detail: detail.to_owned(), ms }
}

/// `ssh -G [-p PORT] -- DEST`; no ssh, or a destination ssh cannot read, is
/// dialed directly by its own name.
fn dial(target: &SshEndpoint) -> Dial {
    let mut command = Command::new("ssh");
    command.arg("-G");
    if let Some(port) = target.port {
        command.args(["-p", &port.to_string()]);
    }
    let out = command
        .args(["--", &target.destination])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    match out {
        Ok(o) if o.status.success() => {
            dial_of(&target.destination, &String::from_utf8_lossy(&o.stdout))
        }
        _ => {
            let host = target.destination.rsplit('@').next().unwrap_or(&target.destination);
            Dial::Direct { host: host.to_owned(), port: target.port.unwrap_or(22) }
        }
    }
}

/// A TCP connect to where ssh dials, then the first line, all by `deadline`.
pub(super) fn probe_dial(
    endpoint: &str,
    dial: &Dial,
    start: Instant,
    deadline: Instant,
) -> EndpointResult {
    let Dial::Direct { host, port } = dial else {
        return result(endpoint, Status::Unchecked, "ssh reaches it through a proxy", None);
    };
    let addrs: Vec<SocketAddr> = match (host.as_str(), *port).to_socket_addrs() {
        Ok(addrs) => addrs.collect(),
        Err(_) => {
            return result(
                endpoint,
                Status::Unreachable,
                &format!("{host} does not resolve"),
                None,
            );
        }
    };
    let mut last = format!("nothing answered on {host}:{port}");
    for addr in addrs {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match TcpStream::connect_timeout(&addr, left) {
            Ok(stream) => return first_line(endpoint, stream, addr, start, deadline),
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                last = format!("{addr} refused the connection");
            }
            Err(error) if error.kind() == std::io::ErrorKind::TimedOut => {
                last = format!("{addr} did not answer in time");
            }
            Err(error) => last = format!("{addr}: {error}"),
        }
    }
    result(endpoint, Status::Unreachable, &last, None)
}

/// The server's first line: an ssh banner is reachable, anything else down.
fn first_line(
    endpoint: &str,
    mut stream: TcpStream,
    addr: SocketAddr,
    start: Instant,
    deadline: Instant,
) -> EndpointResult {
    let mut line = Vec::new();
    let mut chunk = [0u8; 256];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || stream.set_read_timeout(Some(left)).is_err() {
            break;
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(read) => {
                line.extend_from_slice(chunk.get(..read).unwrap_or_default());
                if line.contains(&b'\n') || line.len() >= 255 {
                    break;
                }
            }
        }
    }
    let ms = Some(u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX));
    let text = String::from_utf8_lossy(&line);
    let text = text.lines().next().unwrap_or("").trim();
    if text.starts_with("SSH-") {
        return result(endpoint, Status::Reachable, text, ms);
    }
    let detail = if text.is_empty() {
        format!("{addr} accepted the connection but sent no ssh greeting")
    } else {
        format!("{addr} answered, but not as an ssh server")
    };
    result(endpoint, Status::Down, &detail, ms)
}

/// Every endpoint of every host at once; the answer, in host order, is ready
/// by `timeout` whatever the count.
pub(super) fn check_all(hosts: &[HostDecl], timeout: Duration, probe: &Probe) -> Vec<HostResult> {
    let start = Instant::now();
    let deadline = start + timeout;
    let mut slots: Vec<Vec<EndpointResult>> = hosts
        .iter()
        .map(|host| {
            host.endpoints
                .iter()
                .map(|endpoint| {
                    result(endpoint, Status::Unchecked, "not checked: too many endpoints", None)
                })
                .collect()
        })
        .collect();
    let (tx, rx) = mpsc::channel();
    let mut pending = 0usize;
    let jobs = hosts
        .iter()
        .enumerate()
        .flat_map(|(h, host)| {
            host.endpoints.iter().enumerate().map(move |(e, endpoint)| (h, e, endpoint))
        })
        .take(MAX_PROBES);
    for (h, e, endpoint) in jobs {
        let (tx, probe, dial) = (tx.clone(), Arc::clone(probe), endpoint.clone());
        let spawned = std::thread::Builder::new().name("hosts-check".into()).spawn(move || {
            let _ = tx.send((h, e, probe(&dial, start, deadline)));
        });
        if spawned.is_ok() {
            if let Some(slot) = slot_at(&mut slots, h, e) {
                *slot = result(endpoint, Status::Unreachable, "no answer by the timeout", None);
            }
            pending += 1;
        }
    }
    drop(tx);
    while pending > 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok((h, e, answer)) => {
                if let Some(slot) = slot_at(&mut slots, h, e) {
                    *slot = answer;
                }
                pending -= 1;
            }
            Err(_) => break,
        }
    }
    hosts.iter().zip(slots).map(|(host, endpoints)| summarize(&host.label, endpoints)).collect()
}

/// Endpoint `e` of host `h` (every job's indices come from `slots`' own shape).
fn slot_at(slots: &mut [Vec<EndpointResult>], h: usize, e: usize) -> Option<&mut EndpointResult> {
    slots.get_mut(h).and_then(|host| host.get_mut(e))
}

/// The host's status: the first endpoint, in order, with the best status.
fn summarize(label: &str, endpoints: Vec<EndpointResult>) -> HostResult {
    let best = endpoints.iter().min_by_key(|answer| answer.status).cloned();
    let best = best.unwrap_or_else(|| result("", Status::Unreachable, "no endpoints", None));
    HostResult {
        label: label.to_owned(),
        status: best.status,
        endpoint: best.endpoint,
        detail: best.detail,
        ms: best.ms,
        endpoints,
    }
}

#[cfg(test)]
#[path = "hosts_check_tests.rs"]
mod tests;
