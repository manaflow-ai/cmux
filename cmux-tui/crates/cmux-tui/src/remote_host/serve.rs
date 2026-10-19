//! `cmux host serve`: the listener on this machine's tailnet addresses
//! (remote-hosts.md 6-8). Accept and splice block in threads; nothing polls.

use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use serde_json::{Value, json};

use super::admit::{self, Decision};
use super::config::{self, Config};
use super::preface::{self, Op};
use super::tailnet::{self, Tailnet};

/// How long a peer has to send its preface.
const PREFACE_BOUND: Duration = Duration::from_secs(5);
/// Bound on `daemon ensure` (a restoring daemon can take a while).
const ENSURE_BOUND: Duration = Duration::from_secs(60);

pub(crate) struct Host {
    tailnet: Tailnet,
    self_ips: Vec<IpAddr>,
    name: String,
    exe: PathBuf,
    socket: Mutex<Option<PathBuf>>,
}

pub(crate) fn run(exe: PathBuf) -> anyhow::Result<()> {
    let config = config::load()?;
    if !config.enabled {
        eprintln!("cmux host: remote hosting is disabled (run `cmux host enable`)");
        return Ok(());
    }
    let tailnet = Tailnet::locate()?;
    let status = tailnet.status()?;
    if status.backend_state != "Running" {
        bail!("Tailscale is {} on this machine; sign in first", status.backend_state);
    }
    let self_ips: Vec<IpAddr> =
        status.this.ips.iter().copied().filter(|ip| tailnet::is_tailnet_ip(*ip)).collect();
    if self_ips.is_empty() {
        bail!("this machine has no tailnet address");
    }
    let mut listeners = Vec::new();
    for ip in &self_ips {
        let addr = SocketAddr::new(*ip, config.port);
        match TcpListener::bind(addr) {
            Ok(listener) => listeners.push(listener),
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => {
                eprintln!("cmux host: {addr} is already served (another `cmux host serve` runs)");
                return Ok(());
            }
            // An IPv6 tailnet address can be missing from the OS when the
            // node runs without IPv6; IPv4 alone is enough.
            Err(e) if ip.is_ipv6() => eprintln!("cmux host: not listening on {addr}: {e}"),
            Err(e) => return Err(e).with_context(|| format!("cannot listen on {addr}")),
        }
    }
    super::service::write_pid()?;
    let host = Arc::new(Host {
        tailnet,
        self_ips,
        name: status.this.short_name(),
        exe,
        socket: Mutex::new(None),
    });
    let owner = config.owner.as_deref().unwrap_or("(none)");
    for listener in &listeners {
        eprintln!(
            "cmux host: serving {} on {} for owner {owner}",
            host.name,
            listener.local_addr().map(|a| a.to_string()).unwrap_or_default()
        );
    }
    let mut threads = Vec::new();
    for listener in listeners {
        let host = Arc::clone(&host);
        threads.push(std::thread::spawn(move || accept_loop(&host, &listener)));
    }
    for thread in threads {
        let _ = thread.join();
    }
    Err(anyhow!("every listener stopped"))
}

fn accept_loop(host: &Arc<Host>, listener: &TcpListener) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let host = Arc::clone(host);
                std::thread::spawn(move || {
                    let peer = stream.peer_addr().ok();
                    if let Err(e) = serve_one(&host, stream) {
                        eprintln!(
                            "cmux host: {}: {e:#}",
                            peer.map(|p| p.to_string()).unwrap_or_default()
                        );
                    }
                });
            }
            Err(e) => eprintln!("cmux host: accept failed: {e}"),
        }
    }
}

fn serve_one(host: &Host, mut stream: TcpStream) -> anyhow::Result<()> {
    let peer = stream.peer_addr()?.ip();
    let peer = match peer {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    };
    stream.set_read_timeout(Some(PREFACE_BOUND))?;
    stream.set_write_timeout(Some(PREFACE_BOUND))?;
    let Some(line) = preface::read_line(&mut stream)? else { return Ok(()) };
    let Some(op) = preface::parse_request(&line) else {
        preface::write_value(&mut stream, &preface::refusal("bad_preface"))?;
        return Ok(());
    };
    // The config is reread for every connection: allow/deny/disable apply
    // at once, without a restart.
    let config = config::load()?;
    let decision = admit::decide(&config, &host.self_ips, peer, host.tailnet.whois(peer));
    let identity = match &decision {
        Decision::Owner(identity) | Decision::Allowed(identity) => identity.clone(),
        Decision::Refused(reason) => {
            eprintln!("cmux host: refused {peer}: {reason}");
            preface::write_value(&mut stream, &preface::refusal("not_allowed"))?;
            return Ok(());
        }
    };
    let access = decision.access().unwrap_or_default();
    let who = format!("{} ({})", identity.login.as_deref().unwrap_or_default(), identity.node);
    match op {
        Op::Probe => {
            preface::write_value(&mut stream, &probe_reply(host, &config, access))?;
            Ok(())
        }
        Op::Connect => {
            let daemon = match host.connect_daemon(&config) {
                Ok(daemon) => daemon,
                Err(e) => {
                    eprintln!("cmux host: {who}: session unavailable: {e:#}");
                    preface::write_value(&mut stream, &preface::refusal("session_down"))?;
                    return Ok(());
                }
            };
            preface::write_value(&mut stream, &json!({"ok": true, "access": access}))?;
            stream.set_read_timeout(None)?;
            stream.set_write_timeout(None)?;
            eprintln!("cmux host: connected {who} as {access}");
            splice(stream, daemon)?;
            eprintln!("cmux host: closed {who}");
            Ok(())
        }
    }
}

fn probe_reply(host: &Host, config: &Config, access: &str) -> Value {
    json!({
        "ok": true,
        "host": {
            "name": host.name,
            "os": std::env::consts::OS,
            "version": env!("CARGO_PKG_VERSION"),
            "session": config.session.clone().unwrap_or_else(|| "main".to_owned()),
            "owner": config.owner,
            "access": access,
        }
    })
}

type DaemonStream = Box<dyn cmux_tui_core::platform::transport::Stream>;

impl Host {
    fn connect_daemon(&self, config: &Config) -> anyhow::Result<DaemonStream> {
        let cached = self.socket.lock().map_err(|_| anyhow!("socket cache poisoned"))?.clone();
        if let Some(stream) = cached
            .and_then(|path| cmux_tui_core::platform::transport::connect_same_user(&path).ok())
        {
            return Ok(stream);
        }
        let path = self.resolve_socket(config)?;
        let stream = cmux_tui_core::platform::transport::connect_same_user(&path)
            .with_context(|| format!("cannot connect to {}", path.display()))?;
        *self.socket.lock().map_err(|_| anyhow!("socket cache poisoned"))? = Some(path);
        Ok(stream)
    }

    /// The session socket: `daemon ensure` (starts the daemon if needed),
    /// or with `spawn: false` only the session's socket path.
    fn resolve_socket(&self, config: &Config) -> anyhow::Result<PathBuf> {
        let session = config.session.clone().unwrap_or_else(|| "main".to_owned());
        if !config.spawn {
            return cmux_tui_core::server::try_default_socket_path(&session);
        }
        ensure_session(&self.exe, &session)
    }
}

pub(crate) fn ensure_session(exe: &Path, session: &str) -> anyhow::Result<PathBuf> {
    let mut child = Command::new(exe)
        .args(["--session", session, "--json", "daemon", "ensure"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("cannot run {}", exe.display()))?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = (&mut stdout).take(1024 * 1024).read_to_end(&mut buf);
        buf
    });
    use wait_timeout::ChildExt as _;
    let status = match child.wait_timeout(ENSURE_BOUND)? {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            bail!("`daemon ensure` did not finish within {}s", ENSURE_BOUND.as_secs());
        }
    };
    let out = reader.join().unwrap_or_default();
    if !status.success() {
        bail!("`daemon ensure` failed: {}", String::from_utf8_lossy(&out).trim());
    }
    let value: Value = serde_json::from_slice(&out).context("`daemon ensure` printed no JSON")?;
    let socket = value["socket"].as_str().or_else(|| value["result"]["socket"].as_str());
    socket.map(PathBuf::from).ok_or_else(|| anyhow!("`daemon ensure` named no socket"))
}

/// Copies both ways until either side ends, then closes both.
fn splice(tcp: TcpStream, daemon: DaemonStream) -> io::Result<()> {
    tcp.set_nodelay(true)?;
    let mut tcp_read = tcp.try_clone()?;
    let mut daemon_write = daemon.try_clone_box()?;
    let up = std::thread::spawn(move || {
        let _ = io::copy(&mut tcp_read, &mut daemon_write);
        let _ = daemon_write.shutdown(Shutdown::Write);
    });
    let mut daemon_read = daemon;
    let mut tcp_write = tcp;
    let _ = copy_flush(&mut daemon_read, &mut tcp_write);
    let _ = tcp_write.shutdown(Shutdown::Both);
    let _ = daemon_read.shutdown(Shutdown::Both);
    let _ = up.join();
    Ok(())
}

fn copy_flush(from: &mut impl Read, to: &mut impl Write) -> io::Result<u64> {
    let mut buf = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => return Ok(total),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        to.write_all(&buf[..n])?;
        to.flush()?;
        total += n as u64;
    }
}
