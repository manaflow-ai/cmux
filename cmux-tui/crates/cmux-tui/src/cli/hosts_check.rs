//! `cmux hosts check`: which declared hosts answer from here (CMUX-673).
//! Up to MAX_PROBES endpoints are tried concurrently. The collector stops
//! waiting at its deadline; parsing, allocation and output still scale with
//! the declarations, and blocking config/DNS work may outlive collection.
//!
//! One endpoint: `ssh -G` says where ssh dials it (config only, no network),
//! then a TCP connect and a bounded read of the server's identification. A complete SSH identification is
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

/// The real probe: `ssh -G`, DNS, a TCP connect, the server's identification.
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

/// A TCP connect to where ssh dials, then its identification, all by `deadline`.
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

/// Bound the complete pre-identification exchange, including informational lines.
const MAX_GREETING_BYTES: usize = 8192;

#[derive(Debug, PartialEq, Eq)]
enum GreetingError {
    Timeout,
    Invalid,
}

/// RFC 4253 permits informational lines before the SSH identification. Only a
/// complete identification line counts; a prefix or an unterminated line does not.
fn read_greeting(
    mut read: impl FnMut(&mut [u8]) -> std::io::Result<usize>,
) -> Result<String, GreetingError> {
    let mut line = Vec::new();
    let mut chunk = [0u8; 256];
    let mut total = 0;
    while total < MAX_GREETING_BYTES {
        let limit = chunk.len().min(MAX_GREETING_BYTES - total);
        let count = match read(&mut chunk[..limit]) {
            Ok(0) => return Err(GreetingError::Invalid),
            Ok(count) => count,
            Err(error) => match error.kind() {
                std::io::ErrorKind::Interrupted => continue,
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
                    return Err(GreetingError::Timeout);
                }
                _ => return Err(GreetingError::Invalid),
            },
        };
        total += count;
        for byte in &chunk[..count] {
            line.push(*byte);
            if *byte != b'\n' {
                continue;
            }
            if line.starts_with(b"SSH-") {
                return identification(&line).map(str::to_owned).ok_or(GreetingError::Invalid);
            }
            line.clear();
        }
    }
    Err(GreetingError::Invalid)
}

fn identification(line: &[u8]) -> Option<&str> {
    // RFC 4253's 255-byte identification limit includes CRLF. Accept LF too.
    if line.len() > 255 {
        return None;
    }
    let text = std::str::from_utf8(line).ok()?.strip_suffix('\n')?;
    let text = text.strip_suffix('\r').unwrap_or(text);
    if !text.bytes().all(|byte| (b' '..=b'~').contains(&byte)) {
        return None;
    }
    let (version, software) = text.strip_prefix("SSH-")?.split_once('-')?;
    let (major, minor) = version.split_once('.')?;
    if major.is_empty()
        || minor.is_empty()
        || !major.bytes().chain(minor.bytes()).all(|byte| byte.is_ascii_digit())
        || software.split(' ').next()?.is_empty()
    {
        return None;
    }
    Some(text)
}

/// A bounded SSH identification read. A read timeout has exactly the collector's
/// pending result, so a silent peer cannot race between `down` and `unreachable`.
fn first_line(
    endpoint: &str,
    mut stream: TcpStream,
    addr: SocketAddr,
    start: Instant,
    deadline: Instant,
) -> EndpointResult {
    let greeting = read_greeting(|buffer| {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        stream.set_read_timeout(Some(left))?;
        stream.read(buffer)
    });
    if greeting == Err(GreetingError::Timeout) {
        return result(endpoint, Status::Unreachable, "no answer by the timeout", None);
    }
    let ms = Some(u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX));
    match greeting {
        Ok(text) => result(endpoint, Status::Reachable, &text, ms),
        Err(_) => result(
            endpoint,
            Status::Down,
            &format!("{addr} answered without a valid ssh identification"),
            ms,
        ),
    }
}

/// Collect concurrent endpoint probes until the deadline, keeping host order.
/// The probe cap bounds concurrency; this does not bound configuration or output cost.
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
        let (tx, probe, endpoint) = (tx.clone(), Arc::clone(probe), endpoint.clone());
        let spawned = std::thread::Builder::new().name("hosts-check".into()).spawn(move || {
            let _ = tx.send((h, e, probe(&endpoint, start, deadline)));
        });
        if spawned.is_ok() {
            slots[h][e] = result(
                &hosts[h].endpoints[e],
                Status::Unreachable,
                "no answer by the timeout",
                None,
            );
            pending += 1;
        }
    }
    drop(tx);
    while pending > 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok((h, e, answer)) => {
                slots[h][e] = answer;
                pending -= 1;
            }
            Err(_) => break,
        }
    }
    hosts.iter().zip(slots).map(|(host, endpoints)| summarize(&host.label, endpoints)).collect()
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
