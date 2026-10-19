//! Client side: `cmux host dial` (the stdio bridge the apps use, the same
//! contract as `cmux link dial`) and `cmux host list` (discovery).

use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use serde_json::{Value, json};

use super::config::DEFAULT_PORT;
use super::preface::{self, Op};
use super::tailnet::{Node, Status, Tailnet};

const CONNECT_BOUND: Duration = Duration::from_secs(5);
/// Discovery probes give up sooner: an ACL that drops the packets shows as
/// a connect that never answers.
const PROBE_CONNECT_BOUND: Duration = Duration::from_millis(1500);
const PROBE_REPLY_BOUND: Duration = Duration::from_secs(4);
/// The host may start its session daemon before it answers `connect`.
const CONNECT_REPLY_BOUND: Duration = Duration::from_secs(75);

/// Where a `<host>` argument points: an address, or a tailnet node.
#[derive(Clone, Debug)]
pub(crate) struct Target {
    pub name: String,
    pub addr: SocketAddr,
}

pub(crate) fn resolve(host: &str, port: u16, status: Option<&Status>) -> anyhow::Result<Target> {
    if let Ok(addr) = host.parse::<SocketAddr>() {
        return Ok(Target { name: host.to_owned(), addr });
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(Target { name: host.to_owned(), addr: SocketAddr::new(ip, port) });
    }
    let wanted = host.trim_end_matches('.').to_ascii_lowercase();
    if let Some(status) = status {
        let found = status.peers.iter().find(|node| {
            node.short_name().eq_ignore_ascii_case(&wanted)
                || node.dns_name.eq_ignore_ascii_case(&wanted)
                || node.host_name.eq_ignore_ascii_case(&wanted)
        });
        if let Some(node) = found {
            let ip = node.dial_ip().ok_or_else(|| anyhow!("{host} has no tailnet address"))?;
            return Ok(Target { name: node.short_name(), addr: SocketAddr::new(ip, port) });
        }
    }
    let addr = (wanted.as_str(), port)
        .to_socket_addrs()
        .with_context(|| format!("cannot find host {host} on the tailnet"))?
        .next()
        .ok_or_else(|| anyhow!("cannot find host {host} on the tailnet"))?;
    Ok(Target { name: host.to_owned(), addr })
}

/// Opens a connection and sends the preface; returns the stream and the
/// host's one-line answer.
fn open(
    addr: SocketAddr,
    op: Op,
    connect_bound: Duration,
    reply_bound: Duration,
) -> anyhow::Result<(TcpStream, Value)> {
    let mut stream = TcpStream::connect_timeout(&addr, connect_bound)
        .with_context(|| format!("cannot reach {addr}"))?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(reply_bound))?;
    stream.set_write_timeout(Some(reply_bound))?;
    stream.write_all(preface::request(op).as_bytes())?;
    let line = preface::read_line(&mut stream)?
        .ok_or_else(|| anyhow!("{addr} closed without an answer"))?;
    let reply: Value = serde_json::from_str(&line).context("the host's answer is not JSON")?;
    Ok((stream, reply))
}

/// `cmux host dial <host> [--port N]`: the stdio bridge. The dial result is
/// one JSON line on stderr first; then stdin and stdout carry the daemon
/// protocol until either side ends.
pub(crate) fn dial(host: &str, port: u16) -> i32 {
    let status = Tailnet::locate().and_then(|t| t.status()).ok();
    let target = match resolve(host, port, status.as_ref()) {
        Ok(target) => target,
        Err(e) => return dial_failed("unreachable", &format!("{e:#}")),
    };
    let (stream, reply) = match open(target.addr, Op::Connect, CONNECT_BOUND, CONNECT_REPLY_BOUND) {
        Ok(pair) => pair,
        Err(e) => return dial_failed("unreachable", &format!("{e:#}")),
    };
    if reply["ok"].as_bool() != Some(true) {
        let code = reply["error_code"].as_str().unwrap_or("refused").to_owned();
        return dial_failed(&code, "the host refused the connection");
    }
    let line = json!({"ok": true, "host": target.name, "address": target.addr.to_string(), "access": reply["access"]});
    eprintln!("{line}");
    let _ = io::stderr().flush();
    if stream.set_read_timeout(None).is_err() || stream.set_write_timeout(None).is_err() {
        return 1;
    }
    let Ok(mut tcp_write) = stream.try_clone() else { return 1 };
    std::thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        let _ = io::copy(&mut stdin, &mut tcp_write);
        let _ = tcp_write.shutdown(Shutdown::Write);
    });
    let mut tcp_read = stream;
    let mut stdout = io::stdout().lock();
    let mut buf = [0u8; 64 * 1024];
    loop {
        match tcp_read.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if stdout.write_all(&buf[..n]).and_then(|()| stdout.flush()).is_err() {
                    break;
                }
            }
        }
    }
    0
}

fn dial_failed(code: &str, message: &str) -> i32 {
    eprintln!("{}", json!({"ok": false, "error_code": code, "message": message}));
    1
}

/// One probed host.
#[derive(Debug)]
pub(crate) struct Found {
    pub node: Node,
    pub addr: SocketAddr,
    pub reply: anyhow::Result<Value>,
}

/// Peers worth a probe: online, not this node, a platform that can host,
/// and either owned by this node's login or tagged (servers are tagged).
pub(crate) fn candidates(status: &Status) -> Vec<Node> {
    let me = status.this.login.as_deref();
    status
        .peers
        .iter()
        .filter(|node| node.online)
        .filter(|node| matches!(node.os.as_str(), "linux" | "macOS" | "windows" | "freebsd"))
        .filter(|node| {
            node.tagged()
                || (me.is_some()
                    && node.login.as_deref().map(str::to_ascii_lowercase)
                        == me.map(str::to_ascii_lowercase))
        })
        .cloned()
        .collect()
}

/// Probes every candidate at once; each probe has its own bound, so the
/// whole list takes about one probe's time.
pub(crate) fn probe_all(nodes: Vec<Node>, port: u16) -> Vec<Found> {
    let (tx, rx) = mpsc::channel();
    let count = nodes.len();
    for node in nodes {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let Some(ip) = node.dial_ip() else { return };
            let addr = SocketAddr::new(ip, port);
            let reply = open(addr, Op::Probe, PROBE_CONNECT_BOUND, PROBE_REPLY_BOUND)
                .map(|(_, reply)| reply);
            let _ = tx.send(Found { node, addr, reply });
        });
    }
    drop(tx);
    let mut found: Vec<Found> = rx.iter().take(count).collect();
    found.sort_by(|a, b| a.node.dns_name.cmp(&b.node.dns_name));
    found
}

/// `cmux host list [--json] [--all]`: hosts that answered the probe (with
/// `--all`, also the candidates that did not, with the reason).
pub(crate) fn list(json_out: bool, all: bool, port: Option<u16>) -> anyhow::Result<()> {
    let tailnet = Tailnet::locate()?;
    let status = tailnet.status()?;
    if status.backend_state != "Running" {
        bail!("Tailscale is {} on this machine; sign in first", status.backend_state);
    }
    let port = port.unwrap_or(DEFAULT_PORT);
    let found = probe_all(candidates(&status), port);
    let mut hosts = Vec::new();
    let mut others = Vec::new();
    for item in &found {
        match &item.reply {
            Ok(reply) if reply["ok"].as_bool() == Some(true) => hosts.push(json!({
                "name": item.node.short_name(),
                "dns_name": item.node.dns_name,
                "address": item.addr.to_string(),
                "os": reply["host"]["os"],
                "version": reply["host"]["version"],
                "session": reply["host"]["session"],
                "access": reply["host"]["access"],
                "tags": item.node.tags,
            })),
            Ok(reply) => others.push(json!({
                "name": item.node.short_name(),
                "reason": reply["error_code"].as_str().unwrap_or("refused"),
            })),
            Err(e) => {
                others.push(json!({"name": item.node.short_name(), "reason": short_error(e)}));
            }
        }
    }
    if json_out {
        let mut out =
            json!({"hosts": hosts, "probed": found.len(), "self": status.this.short_name()});
        if all {
            out["not_hosts"] = Value::Array(others);
        }
        println!("{out}");
        return Ok(());
    }
    if hosts.is_empty() {
        println!("No cmux hosts found on the tailnet ({} machines checked).", found.len());
    }
    for host in &hosts {
        println!(
            "{}  {}  {}  session {}  ({})",
            host["name"].as_str().unwrap_or_default(),
            host["address"].as_str().unwrap_or_default(),
            host["os"].as_str().unwrap_or_default(),
            host["session"].as_str().unwrap_or_default(),
            host["access"].as_str().unwrap_or_default(),
        );
    }
    if all {
        for other in &others {
            println!(
                "  not a host for you: {}  {}",
                other["name"].as_str().unwrap_or_default(),
                other["reason"].as_str().unwrap_or_default()
            );
        }
    }
    Ok(())
}

fn short_error(error: &anyhow::Error) -> &'static str {
    let io = error.chain().find_map(|cause| cause.downcast_ref::<io::Error>());
    match io.map(io::Error::kind) {
        Some(io::ErrorKind::ConnectionRefused) => "not serving",
        Some(io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) => "no answer",
        _ => "unreachable",
    }
}
