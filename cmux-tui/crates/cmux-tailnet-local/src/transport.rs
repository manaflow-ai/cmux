//! Where tailscaled's LocalAPI listens on this machine, and one bounded GET
//! to it. Mirrors tailscale's `safesocket`:
//!
//! - `$TS_SOCKET` when set (a Unix socket path), and nothing else.
//! - macOS GUI app (App Store): a loopback port and token, named by the file
//!   `sameuserproof-PORT-TOKEN` the network extension writes in its group
//!   container (`~/Library/Group Containers/<team>.io.tailscale.ipn.macos`).
//! - macOS standalone app (System Extension): `/Library/Tailscale/ipnport`
//!   is a symlink whose target is the port; `sameuserproof-PORT` there holds
//!   the token (readable by the admin group).
//! - Unix `tailscaled`: `/var/run/tailscale/tailscaled.sock` (Linux) or
//!   `/var/run/tailscaled.socket` (open-source tailscaled on macOS).
//! - Windows: the named pipe `\\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled`.
//! - iOS: none. The Tailscale app's LocalAPI lives in its sandbox and no other
//!   app can reach it, so the host side has to supply path hints.

use std::fmt;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::Error;
use crate::http::{self, Endpoint, Progress, ResponseReader};
use crate::model::Source;

/// One way to reach the LocalAPI.
#[derive(Clone, PartialEq, Eq)]
pub enum Target {
    Unix(PathBuf),
    /// 127.0.0.1:port with the same-user token.
    Loopback {
        port: u16,
        token: String,
    },
    Pipe(PathBuf),
}

impl fmt::Debug for Target {
    // The token is a credential: never print it.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unix(p) => f.debug_tuple("Unix").field(p).finish(),
            Self::Loopback { port, .. } => f
                .debug_struct("Loopback")
                .field("port", port)
                .field("token", &"<redacted>")
                .finish(),
            Self::Pipe(p) => f.debug_tuple("Pipe").field(p).finish(),
        }
    }
}

impl Target {
    pub fn source(&self) -> Source {
        match self {
            Self::Unix(_) => Source::UnixSocket,
            Self::Loopback { .. } => Source::LoopbackTcp,
            Self::Pipe(_) => Source::NamedPipe,
        }
    }
}

/// Bounds for every call.
#[derive(Clone, Debug)]
pub struct Limits {
    /// Whole-call deadline: connect, write, read.
    pub timeout: Duration,
    /// Largest decoded body. A 2,000-peer status is about 4 MiB.
    pub max_body: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self { timeout: Duration::from_secs(2), max_body: 16 * 1024 * 1024 }
    }
}

/// The LocalAPI targets to try on this machine, best first. Cheap: a few
/// `stat`/`readdir` calls, no connection.
///
/// iOS: always empty (the Tailscale app's LocalAPI is sandboxed).
#[cfg(target_os = "ios")]
pub fn discover() -> Vec<Target> {
    Vec::new()
}

/// The LocalAPI targets to try on this machine, best first. Cheap: a few
/// `stat`/`readdir` calls, no connection.
#[cfg(not(target_os = "ios"))]
// The list is assembled per OS by cfg blocks; on Windows only the push remains.
#[allow(clippy::vec_init_then_push)]
pub fn discover() -> Vec<Target> {
    if let Some(sock) = std::env::var_os("TS_SOCKET").filter(|v| !v.is_empty()) {
        return vec![Target::Unix(PathBuf::from(sock))];
    }
    let mut out = Vec::new();
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            out.extend(app_store_targets(&Path::new(&home).join("Library/Group Containers")));
        }
        out.extend(macsys_target(Path::new("/Library/Tailscale")));
    }
    #[cfg(unix)]
    for path in ["/var/run/tailscale/tailscaled.sock", "/var/run/tailscaled.socket"] {
        if Path::new(path).exists() {
            out.push(Target::Unix(PathBuf::from(path)));
        }
    }
    #[cfg(windows)]
    out.push(Target::Pipe(PathBuf::from(
        r"\\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled",
    )));
    out
}

/// App Store variant: scans `<group containers>/*.tailscale.ipn.macos` for
/// `sameuserproof-PORT-TOKEN`. The extension deletes old proofs when it
/// starts, so a leftover is rare; a stale one fails to connect and the next
/// target is tried.
#[cfg(unix)]
pub fn app_store_targets(group_containers: &Path) -> Vec<Target> {
    let mut out = Vec::new();
    let Ok(dirs) = std::fs::read_dir(group_containers) else { return out };
    for dir in dirs.flatten() {
        let name = dir.file_name();
        if !name.to_string_lossy().ends_with("tailscale.ipn.macos") {
            continue;
        }
        let Ok(files) = std::fs::read_dir(dir.path()) else { continue };
        for file in files.flatten() {
            if let Some(t) = parse_app_store_proof(&file.file_name().to_string_lossy()) {
                out.push(t);
            }
        }
    }
    out
}

/// `sameuserproof-PORT-TOKEN` -> loopback target.
pub fn parse_app_store_proof(name: &str) -> Option<Target> {
    let rest = name.strip_prefix("sameuserproof-")?;
    let (port, token) = rest.split_once('-')?;
    let port: u16 = port.parse().ok().filter(|p| *p != 0)?;
    let token = token.trim();
    (!token.is_empty() && token.bytes().all(|b| b.is_ascii_alphanumeric()))
        .then(|| Target::Loopback { port, token: token.to_owned() })
}

/// Standalone (System Extension) variant: `ipnport` symlink and
/// `sameuserproof-PORT` token file.
#[cfg(unix)]
pub fn macsys_target(dir: &Path) -> Option<Target> {
    let port_text = std::fs::read_link(dir.join("ipnport")).ok()?;
    let port_text = port_text.to_str()?.to_owned();
    let port: u16 = port_text.parse().ok().filter(|p| *p != 0)?;
    let mut token = String::new();
    std::fs::File::open(dir.join(format!("sameuserproof-{port_text}")))
        .ok()?
        .take(256)
        .read_to_string(&mut token)
        .ok()?;
    let token = token.trim();
    (!token.is_empty()).then(|| Target::Loopback { port, token: token.to_owned() })
}

/// One bounded GET. Non-2xx answers are errors carrying only the status:
/// error bodies are not read into messages.
pub fn get(target: &Target, endpoint: &Endpoint, limits: &Limits) -> Result<Vec<u8>, Error> {
    let now = Instant::now();
    let deadline = now.checked_add(limits.timeout).unwrap_or(now);
    let (status, body) = match target {
        #[cfg(unix)]
        Target::Unix(path) => {
            let stream = std::os::unix::net::UnixStream::connect(path)
                .map_err(|e| Error::Io(format!("connect {}: {e}", path.display())))?;
            exchange(stream, &http::request(endpoint, None), deadline, limits.max_body)?
        }
        #[cfg(not(unix))]
        Target::Unix(_) => return Err(Error::Unavailable("Unix sockets need a Unix OS")),
        Target::Loopback { port, token } => {
            let addr = std::net::SocketAddr::from(([127, 0, 0, 1], *port));
            let stream = std::net::TcpStream::connect_timeout(&addr, remaining(deadline)?)
                .map_err(|e| Error::Io(format!("connect 127.0.0.1:{port}: {e}")))?;
            let _ = stream.set_nodelay(true);
            exchange(stream, &http::request(endpoint, Some(token)), deadline, limits.max_body)?
        }
        Target::Pipe(path) => pipe_get(path, endpoint, deadline, limits.max_body)?,
    };
    match status {
        200..=299 => Ok(body),
        403 => Err(Error::Denied),
        _ => Err(Error::Status(status)),
    }
}

fn remaining(deadline: Instant) -> Result<Duration, Error> {
    deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero()).ok_or(Error::Timeout)
}

/// A stream whose reads and writes can be bounded.
pub(crate) trait Timed: Read + Write {
    fn bound(&self, d: Duration) -> std::io::Result<()>;
}

#[cfg(unix)]
impl Timed for std::os::unix::net::UnixStream {
    fn bound(&self, d: Duration) -> std::io::Result<()> {
        self.set_read_timeout(Some(d))?;
        self.set_write_timeout(Some(d))
    }
}

impl Timed for std::net::TcpStream {
    fn bound(&self, d: Duration) -> std::io::Result<()> {
        self.set_read_timeout(Some(d))?;
        self.set_write_timeout(Some(d))
    }
}

/// Writes the request and reads one response, each syscall bounded by what
/// is left of `deadline`, so a server that trickles bytes still ends on time.
pub(crate) fn exchange<S: Timed>(
    mut stream: S,
    req: &[u8],
    deadline: Instant,
    max_body: usize,
) -> Result<(u16, Vec<u8>), Error> {
    stream.bound(remaining(deadline)?).map_err(io)?;
    stream.write_all(req).map_err(io)?;
    let mut reader = ResponseReader::new(max_body);
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        stream.bound(remaining(deadline)?).map_err(io)?;
        let n = match stream.read(&mut buf) {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(io(e)),
        };
        if let Progress::Done { status, body } =
            reader.feed(buf.get(..n).unwrap_or_default(), n == 0)?
        {
            return Ok((status, body));
        }
    }
}

fn io(e: std::io::Error) -> Error {
    match e.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => Error::Timeout,
        _ => Error::Io(e.to_string()),
    }
}

/// Windows named pipe. A pipe handle opened by `std::fs` has no read
/// timeout, so the exchange runs on a helper thread and the caller waits at
/// most until the deadline; a hung tailscaled leaves that one thread blocked
/// until the pipe closes.
#[cfg(windows)]
fn pipe_get(
    path: &Path,
    endpoint: &Endpoint,
    deadline: Instant,
    max_body: usize,
) -> Result<(u16, Vec<u8>), Error> {
    let path = path.to_path_buf();
    let req = http::request(endpoint, None);
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("tailnet-localapi-pipe".into())
        .spawn(move || {
            let result = (|| {
                let mut pipe = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&path)
                    .map_err(|e| Error::Io(format!("open pipe: {e}")))?;
                pipe.write_all(&req).map_err(io)?;
                let mut reader = ResponseReader::new(max_body);
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    let n = pipe.read(&mut buf).map_err(io)?;
                    if let Progress::Done { status, body } =
                        reader.feed(buf.get(..n).unwrap_or_default(), n == 0)?
                    {
                        return Ok((status, body));
                    }
                }
            })();
            let _ = tx.send(result);
        })
        .map_err(|e| Error::Io(format!("spawn: {e}")))?;
    rx.recv_timeout(remaining(deadline)?).map_err(|_| Error::Timeout)?
}

#[cfg(not(windows))]
fn pipe_get(_: &Path, _: &Endpoint, _: Instant, _: usize) -> Result<(u16, Vec<u8>), Error> {
    Err(Error::Unavailable("named pipes are Windows only"))
}
