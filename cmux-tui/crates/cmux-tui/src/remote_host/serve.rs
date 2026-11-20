//! `cmux host serve`: the listener on this machine's tailnet addresses
//! (remote-hosts.md 6-8). Accept and splice block in threads; nothing polls.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow, bail};
use serde_json::{Value, json};

use super::admit::{self, Decision};
use super::audit;
use super::config::{self, Config};
use super::grant::{self, Scope};
use super::preface::{self, Op};
use super::tailnet::{self, Tailnet};
use cmux_json::JsonSet as _;

/// How long a peer has to send its preface.
const PREFACE_BOUND: Duration = Duration::from_secs(5);
/// Bound on `daemon ensure` (a restoring daemon can take a while).
const ENSURE_BOUND: Duration = Duration::from_secs(60);
/// Connections not yet admitted and answered, in total and per peer
/// address. Excess connections are closed at once, so no peer can hold
/// every thread (or start a `tailscale whois` per byte it trickles).
const MAX_PENDING: usize = 32;
const MAX_PENDING_PER_PEER: usize = 4;

pub(crate) struct Host {
    tailnet: Tailnet,
    self_ips: Vec<IpAddr>,
    name: String,
    exe: PathBuf,
    socket: Mutex<Option<PathBuf>>,
    pending: Mutex<HashMap<IpAddr, usize>>,
    /// Open teammate (guest) connections, mirrored to `active.json` for
    /// `cmux host status` and the app's indicator.
    guests: Mutex<Vec<(u64, Value)>>,
}

/// `<host dir>/active.json`: the open teammate connections.
pub(crate) const ACTIVE_FILE: &str = "active.json";

static NEXT_GUEST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

impl Host {
    fn write_guests(&self, guests: &[(u64, Value)]) {
        let list: Vec<&Value> = guests.iter().map(|(_, v)| v).collect();
        let result = config::ensure_dir().and_then(|dir| {
            let path = dir.join(ACTIVE_FILE);
            let tmp = dir.join(format!(".{ACTIVE_FILE}.{}", std::process::id()));
            std::fs::write(&tmp, serde_json::to_vec(&list)?)?;
            cmux_tui_core::platform::restrict_file(&tmp)?;
            std::fs::rename(&tmp, &path)?;
            Ok(())
        });
        if let Err(e) = result {
            eprintln!("cmux host: cannot record teammate connections: {e:#}");
        }
    }

    fn guest_opened(&self, entry: Value) -> u64 {
        let id = NEXT_GUEST.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if let Ok(mut guests) = self.guests.lock() {
            guests.push((id, entry));
            self.write_guests(&guests);
        }
        id
    }

    fn guest_closed(&self, id: u64) {
        if let Ok(mut guests) = self.guests.lock() {
            guests.retain(|(g, _)| *g != id);
            self.write_guests(&guests);
        }
    }
}

/// One pending connection; released when the connection is answered.
struct Pending {
    host: Arc<Host>,
    peer: IpAddr,
}

impl Pending {
    fn enter(host: &Arc<Host>, peer: IpAddr) -> Option<Self> {
        let mut pending = host.pending.lock().ok()?;
        let total: usize = pending.values().sum();
        let mine = pending.entry(peer).or_insert(0);
        if total >= MAX_PENDING || *mine >= MAX_PENDING_PER_PEER {
            return None;
        }
        *mine += 1;
        drop(pending);
        Some(Self { host: Arc::clone(host), peer })
    }
}

impl Drop for Pending {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.host.pending.lock()
            && let Some(count) = pending.get_mut(&self.peer)
        {
            *count -= 1;
            if *count == 0 {
                pending.remove(&self.peer);
            }
        }
    }
}

fn plain_ip(addr: SocketAddr) -> IpAddr {
    match addr.ip() {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    }
}

pub(crate) fn run(exe: PathBuf) -> anyhow::Result<()> {
    // Before any setup: an update during it is still seen (`launchd_refresh.rs`).
    let watch = super::service::agent_watch();
    let ready = super::service::take_ready_signal();
    // One listener per state directory; the OS drops the lock with the
    // process, so `status` and `stop` never act on a stale pid. Taken before
    // the config is read: a `config::commit` that saved before this sees the
    // new config here, and one that saves after finds the lock held and
    // restarts this listener, so none serves access a write already removed.
    let _lock = super::service::acquire()?;
    let config = config::load()?;
    if !config.enabled {
        eprintln!("cmux host: remote hosting is disabled (run `cmux host enable`)");
        ready("disabled");
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
            // Not this user's listener (that one holds the lock): another
            // program or OS user has the port. Fail, so nothing that answers
            // there looks like this host.
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => {
                bail!("{addr} is in use by another program; pass --port to `cmux host enable`")
            }
            // An IPv6 tailnet address can be missing from the OS when the
            // node runs without IPv6; IPv4 alone is enough.
            Err(e) if ip.is_ipv6() => eprintln!("cmux host: not listening on {addr}: {e}"),
            Err(e) => return Err(e).with_context(|| format!("cannot listen on {addr}")),
        }
    }
    let host = Arc::new(Host {
        tailnet,
        self_ips,
        name: status.this.short_name(),
        exe,
        socket: Mutex::new(None),
        pending: Mutex::new(HashMap::new()),
        guests: Mutex::new(Vec::new()),
    });
    // A listener that died left no one connected.
    host.write_guests(&[]);
    let owner = config.owner.as_deref().unwrap_or("(none)");
    for listener in &listeners {
        eprintln!(
            "cmux host: serving {} on {} for owner {owner}",
            host.name,
            listener.local_addr().map(|a| a.to_string()).unwrap_or_default()
        );
    }
    ready("ready");
    // `None` when a listener stopped; the launchd agent's outcome otherwise.
    let (done, events) = std::sync::mpsc::channel();
    super::service::follow_app_updates(watch, done.clone());
    let mut running = listeners.len();
    for listener in listeners {
        let host = Arc::clone(&host);
        // Sent when the thread ends, a panic included: a listener that is gone always counts.
        let stopped = ListenerStopped(done.clone());
        std::thread::spawn(move || {
            let _stopped = stopped;
            accept_loop(&host, &listener);
        });
    }
    drop(done);
    while running > 0 {
        match events.recv() {
            Ok(None) => running -= 1,
            // KeepAlive restarts only an unsuccessful exit: launchd starts the new build.
            Ok(Some(super::service::AgentExit::Replaced)) => {
                bail!("an update replaced this cmux; launchd starts the new build")
            }
            Ok(Some(super::service::AgentExit::Removed)) => return Ok(()),
            Err(_) => break,
        }
    }
    Err(anyhow!("every listener stopped"))
}

/// Tells `run` that a listener stopped, when its thread ends for any reason.
struct ListenerStopped(std::sync::mpsc::Sender<Option<super::service::AgentExit>>);

impl Drop for ListenerStopped {
    fn drop(&mut self) {
        let _ = self.0.send(None);
    }
}

fn accept_loop(host: &Arc<Host>, listener: &TcpListener) {
    let mut incoming = listener.incoming();
    accept_each(|| incoming.next(), std::thread::sleep, |stream| accept_one(host, stream));
}

/// First and longest wait after an accept error that can persist, as the
/// daemon's own accept loops (cmux-tui-core server.rs `ACCEPT_RETRY_*`).
const ACCEPT_RETRY_INITIAL: Duration = Duration::from_millis(10);
const ACCEPT_RETRY_MAX: Duration = Duration::from_secs(1);

/// Hand every accepted connection to `serve` until `accept` answers `None`.
/// Resource exhaustion (EMFILE, ENFILE, ENOBUFS) persists across accepts,
/// and an immediate retry ran the listener thread at 100% CPU until
/// descriptors freed up: `wait` spaces those retries with a growing delay.
/// A per-connection error needs none, because the next accept blocks.
fn accept_each<S>(
    mut accept: impl FnMut() -> Option<io::Result<S>>,
    mut wait: impl FnMut(Duration),
    mut serve: impl FnMut(S),
) {
    let mut backoff = cmux_tui_core::backoff::Backoff::new(ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX);
    while let Some(accepted) = accept() {
        match accepted {
            Ok(stream) => {
                backoff.reset();
                serve(stream);
            }
            Err(e) => {
                eprintln!("cmux host: accept failed: {e}");
                if cmux_tui_core::backoff::accept_error_needs_backoff(&e) {
                    wait(backoff.next_delay());
                }
            }
        }
    }
}

fn accept_one(host: &Arc<Host>, stream: TcpStream) {
    let Ok(peer) = stream.peer_addr().map(plain_ip) else { return };
    let Some(pending) = Pending::enter(host, peer) else {
        eprintln!("cmux host: refused {peer}: too many pending connections");
        return;
    };
    let host = Arc::clone(host);
    // A thread the OS refuses drops this connection, never the listener.
    let spawned = std::thread::Builder::new().spawn(move || {
        if let Err(e) = serve_one(&host, stream, peer, pending) {
            eprintln!("cmux host: {peer}: {e:#}");
        }
    });
    if let Err(e) = spawned {
        eprintln!("cmux host: refused {peer}: cannot start its thread: {e}");
    }
}

fn serve_one(
    host: &Host,
    mut stream: TcpStream,
    peer: IpAddr,
    pending: Pending,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + PREFACE_BOUND;
    stream.set_write_timeout(Some(PREFACE_BOUND))?;
    // Admission first, from the address alone: a refused peer learns only
    // `not_allowed`, never whether its preface was well formed. The config
    // is reread for every connection, so allow/deny/disable apply at once.
    let config = config::load()?;
    let whois = host.tailnet.whois(peer);
    let seen = whois.as_ref().ok().cloned();
    let decision = admit::decide(&config, &host.self_ips, peer, whois);
    let record = |op: &str, outcome: &str, reason: Option<&str>| {
        let scopes: Vec<&str> = match &decision {
            Decision::Guest(_, scopes) => scopes.iter().map(|s| s.name()).collect(),
            _ => Vec::new(),
        };
        audit::append(&json!({
            "peer": peer.to_string(),
            "login": seen.as_ref().and_then(|i| i.login.clone()),
            "node": seen.as_ref().map(|i| i.node.clone()),
            "decision": decision.access().unwrap_or("refused"),
            "op": op,
            "outcome": outcome,
            "reason": reason,
            "scopes": scopes,
        }));
    };
    let (identity, scopes) = match &decision {
        Decision::Owner(identity) | Decision::Allowed(identity) => (identity.clone(), None),
        Decision::Guest(identity, scopes) => (identity.clone(), Some(scopes.clone())),
        Decision::Refused(reason) => {
            eprintln!("cmux host: refused {peer}: {reason}");
            record("admit", "refused", Some(*reason));
            preface::write_value(&mut stream, &preface::refusal("not_allowed"))?;
            return Ok(());
        }
    };
    let Some(line) = preface::read_line(&mut stream, deadline)? else { return Ok(()) };
    let Some(op) = preface::parse_request(&line) else {
        record("preface", "refused", Some("bad preface"));
        preface::write_value(&mut stream, &preface::refusal("bad_preface"))?;
        return Ok(());
    };
    let access = decision.access().unwrap_or_default();
    let who = format!("{} ({})", identity.login.as_deref().unwrap_or_default(), identity.node);
    // A teammate grant opens only what its scopes name (design 4).
    if let Some(scopes) = &scopes {
        let allowed = match op {
            Op::Probe => scopes.contains(&Scope::Status),
            Op::Connect => grant::may_connect(scopes),
        };
        if !allowed {
            let op_name = if op == Op::Probe { "probe" } else { "connect" };
            eprintln!("cmux host: refused {who} {op_name}: scope not granted");
            record(op_name, "refused", Some("scope not granted"));
            preface::write_value(&mut stream, &preface::refusal("scope_not_granted"))?;
            return Ok(());
        }
    }
    match op {
        Op::Probe => {
            record("probe", "ok", None);
            let mut reply = probe_reply(host, &config, access);
            if let Some(scopes) = &scopes {
                reply.set_path(
                    &["host", "scopes"],
                    json!(scopes.iter().map(|s| s.name()).collect::<Vec<_>>()),
                );
            }
            preface::write_value(&mut stream, &reply)?;
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
            drop(pending);
            stream.set_read_timeout(None)?;
            stream.set_write_timeout(None)?;
            keepalive(&stream);
            eprintln!("cmux host: connected {who} as {access}");
            record("connect", "connected", None);
            let guest = scopes.as_ref().map(|scopes| {
                host.guest_opened(json!({
                    "login": identity.login,
                    "node": identity.node,
                    "peer": peer.to_string(),
                    "scopes": scopes.iter().map(|s| s.name()).collect::<Vec<_>>(),
                    "since": grant::now_rfc3339(),
                    "listener_pid": std::process::id(),
                }))
            });
            let result = if proxied(&config, identity.login.as_deref(), scopes.as_deref()) {
                super::agent_proxy::run(stream, daemon, identity, peer)
            } else {
                splice(stream, daemon)
            };
            if let Some(id) = guest {
                host.guest_closed(id);
            }
            record("connect", "closed", None);
            eprintln!("cmux host: closed {who}");
            result.map_err(Into::into)
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

/// Whether a teammate connection takes the filtered agent proxy instead of a raw
/// splice: a grant without `shell`, and any login with a shared chat even with
/// `shell` (a share never comes with a raw daemon connection; chat-multiplayer
/// design section 2). The owner and full-access logins (no scopes) splice.
pub(super) fn proxied(config: &Config, login: Option<&str>, scopes: Option<&[Scope]>) -> bool {
    let Some(scopes) = scopes else { return false };
    let shared = login.is_some_and(|login| {
        config.shares.iter().any(|share| config::same_login(&share.login, login))
    });
    shared || !scopes.contains(&Scope::Shell)
}

pub(super) type DaemonStream = Box<dyn cmux_tui_core::platform::transport::Stream>;

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
    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        bail!("`daemon ensure` started without its output pipe");
    };
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

/// TCP keepalive on a spliced connection, so a client that vanished (a
/// laptop that slept, a network change) frees its threads and daemon client
/// within about a minute.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn keepalive(stream: &TcpStream) {
    use std::os::fd::AsRawFd as _;
    #[cfg(target_os = "linux")]
    const IDLE: libc::c_int = libc::TCP_KEEPIDLE;
    #[cfg(target_os = "macos")]
    const IDLE: libc::c_int = libc::TCP_KEEPALIVE;
    let fd = stream.as_raw_fd();
    let set = |level: libc::c_int, name: libc::c_int, value: libc::c_int| {
        // SAFETY: setsockopt on a live socket fd with an int option value.
        unsafe {
            libc::setsockopt(
                fd,
                level,
                name,
                (&raw const value).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1);
    set(libc::IPPROTO_TCP, IDLE, 30);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3);
}

/// Windows: no keepalive without a socket crate; a vanished client is
/// noticed when the next write fails.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn keepalive(_stream: &TcpStream) {}

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

#[cfg(test)]
mod tests {
    use std::io;
    use std::time::Duration;

    use super::{ListenerStopped, accept_each};

    /// Runs `accept_each` over `results` and returns the waits it asked for
    /// and the connections it served.
    fn run(results: Vec<io::Result<u32>>) -> (Vec<Duration>, Vec<u32>) {
        let mut results = results.into_iter();
        let (mut waits, mut served) = (Vec::new(), Vec::new());
        accept_each(|| results.next(), |wait| waits.push(wait), |stream| served.push(stream));
        (waits, served)
    }

    fn emfile() -> io::Result<u32> {
        Err(io::Error::from_raw_os_error(libc::EMFILE))
    }

    /// An accept that fails with EMFILE fails again at once until a
    /// descriptor frees up: before, the listener thread retried with no
    /// wait and ran at 100% CPU. Each such failure waits, longer each time;
    /// a connection accepted in between starts the spacing over.
    #[test]
    fn a_persistent_accept_error_waits_longer_each_time() {
        let (waits, served) = run(vec![emfile(), emfile(), emfile(), emfile(), emfile()]);
        assert!(served.is_empty());
        assert_eq!(waits.len(), 5, "every EMFILE waits before the next accept: {waits:?}");
        assert!(waits[0] > Duration::ZERO, "{waits:?}");
        assert!(waits.windows(2).all(|pair| pair[1] > pair[0]), "{waits:?}");
        assert!(waits.iter().all(|wait| *wait <= Duration::from_secs(1)), "{waits:?}");

        let (waits, served) = run(vec![emfile(), emfile(), emfile(), Ok(7), emfile()]);
        assert_eq!(served, vec![7]);
        assert_eq!(waits.len(), 4, "{waits:?}");
        assert!(waits[3] < waits[2], "a served connection resets the spacing: {waits:?}");
    }

    /// A per-connection error ends with that connection, and the next
    /// accept blocks: no wait.
    #[test]
    fn a_per_connection_accept_error_does_not_wait() {
        let aborted = || Err(io::Error::from(io::ErrorKind::ConnectionAborted));
        let (waits, served) = run(vec![aborted(), Ok(1), aborted()]);
        assert_eq!(served, vec![1]);
        assert!(waits.is_empty(), "{waits:?}");
    }

    #[test]
    fn a_listener_that_panics_still_counts_as_stopped() {
        let (done, events) = std::sync::mpsc::channel();
        let stopped = ListenerStopped(done.clone());
        let thread = std::thread::spawn(move || {
            let _stopped = stopped;
            panic!("the OS refused a thread");
        });
        assert!(thread.join().is_err());
        assert_eq!(events.try_recv(), Ok(None));
        drop(done);
    }
}
