//! `cmux ssh --bench`: the one harness behind RFD 0127's before and after numbers.
//!
//! Leo, 2026-11-22: "just improve all this shit." The RFD asks for one harness, so each cut's PR
//! posts its row from the same code: one JSON line per sample, appended to
//! `~/.cache/remote-bench/<unix-seconds>-<from>.jsonl`, with the fields
//! `{op, route, from, to, ms, ok, reason, ref}`.
//!
//! ```text
//! cmux ssh --bench MACHINE... [--bench-n 50] [--bench-ops connect,health,dial]
//!          [--bench-routes carrier,freestyle-proxy,tailnet]
//!          [--bench-target ROUTE:MACHINE=[USER@]HOST[:PORT]]... [--bench-out DIR]
//! ```
//!
//! - `carrier` needs only the machine name: it goes over this machine's acpmux
//!   (`_acpmux/remote.pipe`), the same dial `tools/carrier-pipe` makes.
//! - `freestyle-proxy` and `tailnet` run only for a machine given a `--bench-target` for that
//!   route (the ssh destination to reach it by); a route without one is left out, not guessed.
//! - `dial`: the route's byte stream opens (the carrier's pipe reply, or a TCP connect).
//!   `health`: a dial plus the far sshd's banner line, as `carrier-pipe health`.
//!   `connect`: `ssh -o ControlMaster=no ... true` over the route.
//!
//! `ref` is `CMUX_BENCH_REF`, else this checkout's `git rev-parse --short=12 HEAD`, else
//! `unknown`. Each sample has its own timeout; a failed sample is a row with `ok: false` and a
//! `reason`, never a skipped one.
//!
//! `cmux ssh --bench-pipe MACHINE [PORT]` is the carrier route's ssh `ProxyCommand`: stdin and
//! stdout to MACHINE's loopback port over the carrier.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{TcpStream, ToSocketAddrs as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow};
use cmux_process::{Command, Stdio};
use serde::Serialize;
use serde_json::{Value, json};

/// The carrier's pipe method on the acpmux socket (`cmux-remote` `machine_pipe.rs`).
const PIPE_METHOD: &str = "_acpmux/remote.pipe";
const DEFAULT_N: usize = 50;
/// Each sample's whole budget.
const SAMPLE_TIMEOUT: Duration = Duration::from_secs(30);
const REPLY_MAX: usize = 16 * 1024;

pub(super) const ROUTES: [&str; 3] = ["carrier", "freestyle-proxy", "tailnet"];
pub(super) const OPS: [&str; 3] = ["connect", "health", "dial"];

/// One sample, one JSON line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(super) struct Sample {
    pub op: String,
    pub route: String,
    pub from: String,
    pub to: String,
    pub ms: f64,
    pub ok: bool,
    pub reason: Option<String>,
    #[serde(rename = "ref")]
    pub reference: String,
}

impl Sample {
    pub(super) fn line(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// What a run measures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Plan {
    pub machines: Vec<String>,
    pub n: usize,
    pub ops: Vec<String>,
    pub routes: Vec<String>,
    /// `(route, machine, destination)`.
    pub targets: Vec<(String, String, String)>,
    pub out: Option<PathBuf>,
}

/// Whether `cmux ssh`'s arguments ask for the bench.
pub(super) fn wants(args: &[String]) -> bool {
    args.iter().any(|a| a == "--bench")
}

/// Whether they ask for the carrier ProxyCommand.
pub(super) fn wants_pipe(args: &[String]) -> bool {
    args.first().is_some_and(|a| a == "--bench-pipe")
}

pub(super) fn parse(args: &[String]) -> anyhow::Result<Plan> {
    let mut plan = Plan {
        machines: Vec::new(),
        n: DEFAULT_N,
        ops: OPS.iter().map(|s| (*s).to_owned()).collect(),
        routes: ROUTES.iter().map(|s| (*s).to_owned()).collect(),
        targets: Vec::new(),
        out: None,
    };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = |name: &str| {
            it.next().cloned().ok_or_else(|| anyhow!("cmux ssh --bench: {name} needs a value"))
        };
        match arg.as_str() {
            "--bench" => {}
            "--bench-n" => {
                plan.n =
                    value("--bench-n")?.parse::<usize>().ok().filter(|n| *n > 0).ok_or_else(
                        || anyhow!("cmux ssh --bench: --bench-n is a positive count"),
                    )?;
            }
            "--bench-ops" => plan.ops = choose("--bench-ops", &value("--bench-ops")?, &OPS)?,
            "--bench-routes" => {
                plan.routes = choose("--bench-routes", &value("--bench-routes")?, &ROUTES)?;
            }
            "--bench-target" => plan.targets.push(parse_target(&value("--bench-target")?)?),
            "--bench-out" => plan.out = Some(PathBuf::from(value("--bench-out")?)),
            other if other.starts_with('-') => {
                return Err(anyhow!("cmux ssh --bench: unknown option {other}"));
            }
            machine => plan.machines.push(machine.to_owned()),
        }
    }
    if plan.machines.is_empty() {
        return Err(anyhow!("cmux ssh --bench: name the machine(s) to measure"));
    }
    Ok(plan)
}

fn choose(flag: &str, list: &str, allowed: &[&str]) -> anyhow::Result<Vec<String>> {
    list.split(',')
        .map(|word| {
            allowed
                .contains(&word)
                .then(|| word.to_owned())
                .ok_or_else(|| anyhow!("cmux ssh --bench: {flag} takes {}", allowed.join(", ")))
        })
        .collect()
}

/// `ROUTE:MACHINE=DESTINATION`.
fn parse_target(spec: &str) -> anyhow::Result<(String, String, String)> {
    let bad = || anyhow!("cmux ssh --bench: --bench-target is ROUTE:MACHINE=[USER@]HOST[:PORT]");
    let (key, destination) = spec.split_once('=').ok_or_else(bad)?;
    let (route, machine) = key.split_once(':').ok_or_else(bad)?;
    if !ROUTES.contains(&route) || machine.is_empty() || destination.is_empty() {
        return Err(bad());
    }
    Ok((route.to_owned(), machine.to_owned(), destination.to_owned()))
}

/// `[USER@]HOST[:PORT]` as host and port (22 by default).
pub(super) fn host_port(destination: &str) -> (String, u16) {
    let host = destination.rsplit_once('@').map_or(destination, |(_, host)| host);
    match host.rsplit_once(':') {
        Some((name, port)) if !name.contains(':') => match port.parse() {
            Ok(port) => (name.to_owned(), port),
            Err(_) => (host.to_owned(), 22),
        },
        _ => (host.to_owned(), 22),
    }
}

/// The pipe request line for a machine and port.
pub(super) fn pipe_request(machine: &str, port: u16) -> String {
    let request = json!({"jsonrpc": "2.0", "id": 1, "method": PIPE_METHOD,
        "params": {"machine": machine, "port": port}});
    format!("{request}\n")
}

/// The reason out of acpmux's one reply line: Ok for an answer, else the refusal's reason.
pub(super) fn pipe_reply(line: &str) -> Result<(), String> {
    let answer: Value =
        serde_json::from_str(line.trim()).map_err(|_| "acpmux.bad_answer".to_owned())?;
    match answer.get("error") {
        None => Ok(()),
        Some(error) => Err(error
            .pointer("/data/reason")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned()),
    }
}

/// The `p`th percentile (0..=100) of `values`, nearest rank; None when empty.
pub(super) fn percentile(values: &[f64], p: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = ((p / 100.0) * sorted.len() as f64).ceil().max(1.0) as usize;
    sorted.get(rank.min(sorted.len()) - 1).copied()
}

fn round_ms(elapsed: Duration) -> f64 {
    (elapsed.as_secs_f64() * 10_000.0).round() / 10.0
}

fn acpmux_socket() -> anyhow::Result<PathBuf> {
    crate::acp::daemon_socket_path()
        .filter(|socket| socket.exists())
        .ok_or_else(|| anyhow!("no acpmux runs on this machine"))
}

/// One carrier dial: the stream (with any bytes that came behind the reply line) or the reason.
fn carrier_dial(machine: &str, port: u16) -> Result<(UnixStream, Vec<u8>), String> {
    let socket = acpmux_socket().map_err(|_| "dial-missing".to_owned())?;
    let mut stream = UnixStream::connect(&socket).map_err(|_| "dial-missing".to_owned())?;
    stream.set_read_timeout(Some(SAMPLE_TIMEOUT)).ok();
    stream.write_all(pipe_request(machine, port).as_bytes()).map_err(|_| "acpmux.io".to_owned())?;
    // Read exactly the reply line byte by byte, so the circuit's own bytes stay in the socket.
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) => return Err("acpmux.closed".to_owned()),
            Ok(_) => {
                if byte[0] == b'\n' {
                    break;
                }
                line.push(byte[0]);
                if line.len() > REPLY_MAX {
                    return Err("acpmux.bad_answer".to_owned());
                }
            }
            Err(_) => return Err("acpmux.slow".to_owned()),
        }
    }
    pipe_reply(&String::from_utf8_lossy(&line))?;
    Ok((stream, Vec::new()))
}

fn tcp_dial(destination: &str) -> Result<TcpStream, String> {
    let (host, port) = host_port(destination);
    let address = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|_| "dns".to_owned())?
        .next()
        .ok_or_else(|| "dns".to_owned())?;
    let stream = TcpStream::connect_timeout(&address, SAMPLE_TIMEOUT)
        .map_err(|e| format!("connect.{:?}", e.kind()).to_lowercase())?;
    stream.set_read_timeout(Some(SAMPLE_TIMEOUT)).ok();
    Ok(stream)
}

/// The first line from a stream, as sshd's banner.
fn banner(stream: impl std::io::Read) -> Result<(), String> {
    let mut line = String::new();
    BufReader::new(stream.take(512)).read_line(&mut line).map_err(|_| "no-banner".to_owned())?;
    if line.starts_with("SSH-") { Ok(()) } else { Err("no-banner".to_owned()) }
}

fn measure(op: &str, route: &str, machine: &str, destination: Option<&str>) -> Result<(), String> {
    match (op, route) {
        ("dial", "carrier") => carrier_dial(machine, 22).map(drop),
        ("health", "carrier") => carrier_dial(machine, 22).and_then(|(stream, _)| banner(stream)),
        ("dial", _) => tcp_dial(destination.ok_or("no-target")?).map(drop),
        ("health", _) => tcp_dial(destination.ok_or("no-target")?).and_then(banner),
        ("connect", _) => connect(route, machine, destination),
        _ => Err("unknown-op".to_owned()),
    }
}

fn connect(route: &str, machine: &str, destination: Option<&str>) -> Result<(), String> {
    let mut ssh = Command::new("ssh");
    ssh.args(["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "BatchMode=yes"]).args([
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=30",
    ]);
    if route == "carrier" {
        let exe = std::env::current_exe().map_err(|_| "no-exe".to_owned())?;
        ssh.arg("-o").arg(format!("ProxyCommand={} ssh --bench-pipe %h %p", exe.display()));
        ssh.arg(machine);
    } else {
        ssh.arg(destination.ok_or("no-target")?);
    }
    ssh.arg("true").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    let mut child = ssh.spawn().map_err(|_| "no-ssh".to_owned())?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => return Err(format!("ssh.exit.{}", status.code().unwrap_or(-1))),
            Ok(None) if started.elapsed() > SAMPLE_TIMEOUT => {
                // Only the ssh this sample started.
                child.kill().ok();
                child.wait().ok();
                return Err("timeout".to_owned());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(5)),
            Err(_) => return Err("ssh.wait".to_owned()),
        }
    }
}

fn from_name() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "unknown".to_owned())
}

fn reference() -> String {
    if let Ok(reference) = std::env::var("CMUX_BENCH_REF")
        && !reference.is_empty()
    {
        return reference;
    }
    Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|out| out.status.success())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .filter(|rev| !rev.is_empty())
        .unwrap_or_else(|| "unknown".to_owned())
}

fn out_dir(plan: &Plan) -> anyhow::Result<PathBuf> {
    if let Some(dir) = &plan.out {
        return Ok(dir.clone());
    }
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(Path::new(&home).join(".cache/remote-bench"))
}

/// `cmux ssh --bench ...`.
pub(super) fn run(args: &[String]) -> anyhow::Result<()> {
    let plan = parse(args)?;
    let dir = out_dir(&plan)?;
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let from = from_name();
    let reference = reference();
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let path = dir.join(format!("{stamp}-{from}.jsonl"));
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    for machine in &plan.machines {
        for route in &plan.routes {
            let destination = plan
                .targets
                .iter()
                .find(|(r, m, _)| r == route && m == machine)
                .map(|(_, _, d)| d.as_str());
            if route != "carrier" && destination.is_none() {
                continue;
            }
            for op in &plan.ops {
                let mut oks = Vec::new();
                for _ in 0..plan.n {
                    let started = Instant::now();
                    let outcome = measure(op, route, machine, destination);
                    let ms = round_ms(started.elapsed());
                    let sample = Sample {
                        op: op.clone(),
                        route: route.clone(),
                        from: from.clone(),
                        to: machine.clone(),
                        ms,
                        ok: outcome.is_ok(),
                        reason: outcome.err(),
                        reference: reference.clone(),
                    };
                    writeln!(file, "{}", sample.line())?;
                    if sample.ok {
                        oks.push(ms);
                    }
                }
                println!(
                    "{op} {route} {from}->{machine}: ok {}/{} p50 {} ms p95 {} ms",
                    oks.len(),
                    plan.n,
                    percentile(&oks, 50.0).map_or("-".into(), |v| v.to_string()),
                    percentile(&oks, 95.0).map_or("-".into(), |v| v.to_string()),
                );
            }
        }
    }
    println!("samples: {}", path.display());
    Ok(())
}

/// `cmux ssh --bench-pipe MACHINE [PORT]`: ssh's ProxyCommand over the carrier.
pub(super) fn pipe(args: &[String]) -> anyhow::Result<()> {
    let machine = args.get(1).ok_or_else(|| anyhow!("cmux ssh --bench-pipe MACHINE [PORT]"))?;
    let port = args.get(2).and_then(|p| p.parse().ok()).unwrap_or(22);
    let (stream, early) = carrier_dial(machine, port).map_err(|reason| anyhow!("{reason}"))?;
    stream.set_read_timeout(None).ok();
    let mut out = stream.try_clone()?;
    // A scoped thread: this call owns it and joins it. ssh closes the ProxyCommand's stdin when
    // its session ends, so the stdin half ends with the session.
    std::thread::scope(|scope| {
        scope.spawn(move || {
            let mut stdin = std::io::stdin().lock();
            std::io::copy(&mut stdin, &mut out).ok();
            out.shutdown(std::net::Shutdown::Write).ok();
        });
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(&early)?;
        let mut reader = stream;
        std::io::copy(&mut reader, &mut stdout).ok();
        stdout.flush().ok();
        Ok(())
    })
}

#[cfg(test)]
#[path = "ssh_bench_tests.rs"]
mod tests;
