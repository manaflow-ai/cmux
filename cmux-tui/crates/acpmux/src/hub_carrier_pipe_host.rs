//! The pipe host: the far end of every held pipe (RFD 0127 cut 4) lives in a process of its own,
//! so an ssh session through the carrier lives through *this* machine's acpmux restarting too
//! (cmux#56113; design cmuxterm-hq `docs/design/carrier-circuit-host.md`).
//!
//! Leo, 2026-11-23: "we ought to have more graceful handoffs... similar to network drains".
//!
//! Before this, the daemon kept each held pipe's sshd connection and resume log in its own
//! memory (`hub_carrier_resume.rs` `PARKING`). The dialer's restart was covered: the far daemon
//! parked the pipe and the dialer resumed it. This machine's own restart was not: the parked
//! pipes died with the daemon, the dialer's resume got "no such pipe", and ssh ended with a
//! broken pipe. On a lane VM that self-updates every 30 min, that was every drop of the
//! broker's `ssh -R` hold.
//!
//! Now the daemon only carries bytes. `acpmux __pipe-host SOCKET` holds the [`Parking`] table,
//! each pipe's sshd connection and its resume log. For each held-pipe stream the daemon connects
//! to the host's unix socket, sends one header line (who owns the pipe, and the loopback target
//! the gate admitted), and copies bytes between the stream and that connection. When the daemon
//! goes, the connection ends as a broken circuit does: the host parks the pipe for
//! [`RESUME_GRACE`], the dialer's hold dials again through the new daemon, and the pipe resumes
//! with no byte lost or doubled ([`cmux_remote::resume_hold`]). The handshake is the same, so
//! the dialer needs no change.
//!
//! The host is started by the first daemon that needs it, in a session and a systemd scope of
//! its own (`agent_host/scope.rs`), so neither a `systemctl --user restart acpmux.service` nor
//! a self-update signals it. It ends once it has held no pipe for [`IDLE_EXIT`], so a new
//! binary takes over at the next idle moment. `ACPMUX_PIPE_HOST=0` keeps pipes in the daemon,
//! as before; so does a host that does not start.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use cmux_remote::resume_hold::{Parking, RESUME_GRACE};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpStream, UnixListener, UnixStream};

/// The argument that selects the pipe host mode of the acpmux binary.
pub const PIPE_HOST_ARG: &str = "__pipe-host";
/// The env switch: `0` keeps held pipes in the daemon.
pub const SWITCH_ENV: &str = "ACPMUX_PIPE_HOST";
/// The host's socket, in the acpmux home.
const SOCKET_NAME: &str = "pipe-host.sock";
/// How long a host with no pipe and no stream stays before it ends.
pub const IDLE_EXIT: Duration = Duration::from_secs(10 * 60);
/// The header line's bound, and how long a connection may take to send it.
const HEADER_BYTES: usize = 4096;
const HEADER_WAIT: Duration = Duration::from_secs(5);
/// How long a daemon waits for a host it started to listen.
const START_WAIT: Duration = Duration::from_secs(3);
/// The header's version: a host refuses one it does not know by closing the connection.
const VERSION: u32 = 1;

/// The one line a daemon sends before a held-pipe stream's bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Header {
    pub v: u32,
    /// The stream's Noise-proven `daemonId`: only it may resume the pipe.
    pub owner: String,
    /// The loopback address the daemon's gate admitted.
    pub target: std::net::SocketAddr,
}

/// The host's socket for the acpmux home `home`.
pub fn socket_path(home: &Path) -> PathBuf {
    home.join(SOCKET_NAME)
}

/// Whether the daemon hands held pipes to a pipe host (on unless `ACPMUX_PIPE_HOST=0`).
pub fn enabled() -> bool {
    std::env::var_os(SWITCH_ENV).is_none_or(|v| v != "0")
}

/// A connection to the pipe host at `socket`, its header sent; a host is started when none
/// listens. Err: no host could be reached, and the caller keeps the pipe itself.
pub async fn connect(socket: &Path, header: &Header) -> Result<UnixStream, String> {
    let mut conn = match UnixStream::connect(socket).await {
        Ok(conn) => conn,
        Err(_) => {
            start(socket).await?;
            reach(socket).await?
        }
    };
    let mut line = serde_json::to_vec(header).map_err(|e| e.to_string())?;
    line.push(b'\n');
    conn.write_all(&line).await.map_err(|e| format!("the pipe host's header: {e}"))?;
    Ok(conn)
}

/// Wait for a host just started to listen.
async fn reach(socket: &Path) -> Result<UnixStream, String> {
    let deadline = tokio::time::Instant::now() + START_WAIT;
    let mut wait = Duration::from_millis(10);
    loop {
        match UnixStream::connect(socket).await {
            Ok(conn) => return Ok(conn),
            Err(e) if tokio::time::Instant::now() >= deadline => {
                return Err(format!("the pipe host did not listen within {START_WAIT:?}: {e}"));
            }
            Err(_) => {
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(Duration::from_millis(200));
            }
        }
    }
}

/// The last host this daemon started: kept so it is reaped (`try_wait`) when the next one
/// starts, never left a zombie past that.
static STARTED: std::sync::Mutex<Option<cmux_process::Child>> = std::sync::Mutex::new(None);

/// Start `acpmux __pipe-host SOCKET` in a session and a scope of its own.
async fn start(socket: &Path) -> Result<(), String> {
    let me = crate::self_command::SelfCommand::current()
        .map_err(|e| format!("this binary's path: {e}"))?;
    let mut child = me
        .process_command(&[std::ffi::OsStr::new(PIPE_HOST_ARG), socket.as_os_str()])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .env_remove("RUST_LOG")
        // Its own session: it outlives the daemon and is in no harness's process group.
        .new_session()
        .spawn()
        .map_err(|e| format!("start the pipe host: {e}"))?;
    child.detach("the pipe host keeps held pipes through this daemon's restart");
    let pid = child.id();
    {
        let mut started = STARTED.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut last) = started.take() {
            let _ = last.try_wait();
        }
        *started = Some(child);
    }
    crate::agent_host::scope::place(pid).await;
    Ok(())
}

/// Entry point of `acpmux __pipe-host SOCKET`.
pub fn main(args: &[std::ffi::OsString]) -> anyhow::Result<()> {
    let socket = args
        .first()
        .map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("usage: acpmux {PIPE_HOST_ARG} SOCKET"))?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async move {
        let Some(listener) = bind(&socket)? else {
            // Another host serves this socket.
            return Ok(());
        };
        serve(listener, Parking::new(RESUME_GRACE), IDLE_EXIT).await;
        // Only the socket this host bound: a newer host may have bound it again since.
        let _ = std::fs::remove_file(&socket);
        Ok(())
    })
}

/// Bind `socket`, or None when a live host already serves it. A stale file is replaced.
pub fn bind(socket: &Path) -> std::io::Result<Option<UnixListener>> {
    use std::os::unix::fs::PermissionsExt as _;
    match UnixListener::bind(socket) {
        Ok(listener) => {
            std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;
            Ok(Some(listener))
        }
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            if std::os::unix::net::UnixStream::connect(socket).is_ok() {
                return Ok(None);
            }
            std::fs::remove_file(socket)?;
            let listener = UnixListener::bind(socket)?;
            std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;
            Ok(Some(listener))
        }
        Err(e) => Err(e),
    }
}

/// Serve held-pipe streams on `listener` into `parking` until no pipe and no stream was held
/// for `idle`.
pub async fn serve(listener: UnixListener, parking: Arc<Parking<TcpStream>>, idle: Duration) {
    let streams = Arc::new(AtomicUsize::new(0));
    // Each stream's task; dropped with the host when it ends.
    let tasks = cmux_scope::Scope::new("pipe host");
    loop {
        let accepted = tokio::time::timeout(idle, listener.accept()).await;
        match accepted {
            Ok(Ok((conn, _))) => {
                if !same_user(&conn) {
                    continue;
                }
                let parking = parking.clone();
                let streams = streams.clone();
                streams.fetch_add(1, Ordering::SeqCst);
                tasks.spawn_named("pipe host stream", async move {
                    let ran = carry(conn, &parking).await;
                    tracing::debug!("pipe host: a stream ended: {ran:?}");
                    streams.fetch_sub(1, Ordering::SeqCst);
                });
            }
            Ok(Err(e)) => {
                tracing::warn!("pipe host: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(_) => {
                if streams.load(Ordering::SeqCst) == 0 && parking.is_empty() {
                    return;
                }
            }
        }
    }
}

/// Only this user's processes may use the host (the socket is 0600 in a private home; this
/// checks it again by the peer's credentials).
fn same_user(conn: &UnixStream) -> bool {
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    conn.peer_cred().is_ok_and(|cred| cred.uid() == me)
}

/// One held-pipe stream: its header, then the pipe it opens or resumes.
async fn carry<T>(conn: T, parking: &Arc<Parking<TcpStream>>) -> Result<(), String>
where
    T: AsyncRead + AsyncWrite + Send + Unpin,
{
    let mut conn = BufReader::new(conn);
    let header = read_header(&mut conn).await?;
    if header.v != VERSION {
        return Err(format!("header version {} is not {VERSION}", header.v));
    }
    if !header.target.ip().is_loopback() {
        return Err(format!("{} is not a loopback target", header.target));
    }
    // The daemon bridges the dialer's resume handshake right behind the header, so the reader
    // may already hold its first bytes: the pipe is served from the reader, never its inner
    // stream, or those bytes are lost and the dialer reads EOF.
    let target = header.target;
    let connect = || async move {
        let local = TcpStream::connect(target).await?;
        let _ = local.set_nodelay(true);
        Ok::<_, std::io::Error>(local)
    };
    let ran = parking.serve(conn, &header.owner, connect).await;
    Err(format!("{ran:?}"))
}

async fn read_header<R: AsyncBufReadExt + Unpin>(conn: &mut R) -> Result<Header, String> {
    let mut line = Vec::new();
    let read = tokio::time::timeout(HEADER_WAIT, async {
        let mut limited = (&mut *conn).take(HEADER_BYTES as u64);
        limited.read_until(b'\n', &mut line).await
    })
    .await
    .map_err(|_| "no header in time".to_owned())?
    .map_err(|e| e.to_string())?;
    if read == 0 || line.last() != Some(&b'\n') {
        return Err("no header line".into());
    }
    serde_json::from_slice(&line).map_err(|e| format!("the header: {e}"))
}

/// The daemon's half of one held-pipe stream: carry `stream` to the host until either way ends.
/// The pipe frames its own end, so a way that ends is a break: the other way stops too, and the
/// host parks the pipe at once rather than when its grace is out.
pub async fn bridge<S>(stream: S, host: UnixStream)
where
    S: AsyncRead + AsyncWrite + Send + Unpin,
{
    let (mut stream_read, mut stream_write) = tokio::io::split(stream);
    let (mut host_read, mut host_write) = host.into_split();
    tokio::select! {
        _ = tokio::io::copy(&mut stream_read, &mut host_write) => {}
        _ = tokio::io::copy(&mut host_read, &mut stream_write) => {}
    }
}

/// A header for a pipe owned by `owner` to `target`.
pub fn header(owner: &str, target: std::net::SocketAddr) -> Header {
    Header { v: VERSION, owner: owner.to_owned(), target }
}

#[cfg(test)]
#[path = "hub_carrier_pipe_host_tests.rs"]
mod tests;
