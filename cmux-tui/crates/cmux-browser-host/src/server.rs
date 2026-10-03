//! The host listener: one Unix socket per user, JSON lines.
//!
//! Request `{"id", "method", "params", "origin"}`, reply `{"id", "result"}` or
//! `{"id", "error": {code, message}}`. The socket lives in a directory only
//! the user can open (0700) and is itself 0600. Callers are identified by the
//! connection (peer uid now; the session host's launch credential later),
//! never by the request body.

use crate::host::{Caller, Host};
use crate::protocol::DriverError;
use serde_json::{Value, json};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// `$XDG_RUNTIME_DIR/cmux/browser-host.sock`, else `$TMPDIR/cmux-<uid>/browser-host.sock`.
pub fn default_socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("CMUX_BROWSER_HOST_SOCKET").filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    let base = match std::env::var_os("XDG_RUNTIME_DIR").filter(|p| !p.is_empty()) {
        Some(dir) => PathBuf::from(dir).join("cmux"),
        // SAFETY: getuid(2) has no failure modes or memory effects.
        None => std::env::temp_dir().join(format!("cmux-{}", unsafe { libc::getuid() })),
    };
    base.join("browser-host.sock")
}

/// Binds the socket, replacing a stale one. One host per socket: a lock
/// file next to it is held for the process's life, so two hosts started at
/// once cannot unlink each other's socket. `owns_dir`: the directory is the
/// host's own (the default path) and is made private (0700).
pub fn bind(path: &Path, owns_dir: bool) -> io::Result<UnixListener> {
    use std::os::fd::AsRawFd;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
        if owns_dir {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path.with_extension("lock"))?;
    // SAFETY: flock(2) on an fd we own.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("a browser host already owns {}", path.display()),
        ));
    }
    if UnixStream::connect(path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("a browser host already listens on {}", path.display()),
        ));
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    // Held until the process exits.
    std::mem::forget(lock);
    Ok(listener)
}

/// Serves connections. A failed accept (for example EMFILE) is skipped.
pub fn serve(listener: UnixListener, host: Arc<Host>) -> io::Result<()> {
    // SAFETY: getuid(2) has no failure modes.
    let uid = unsafe { libc::getuid() };
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        // Only this user's processes (the socket is 0600 too).
        if peer_uid(&stream).is_some_and(|peer| peer != uid) {
            continue;
        }
        let host = host.clone();
        let _ =
            std::thread::Builder::new().name("cmux-browser-host-conn".into()).spawn(move || {
                let _ = handle(stream, &host);
            });
    }
    Ok(())
}

fn handle(stream: UnixStream, host: &Host) -> io::Result<()> {
    let actor = peer_actor(&stream);
    let mut writer = stream.try_clone()?;
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(request) => {
                let id = request.get("id").cloned().unwrap_or(Value::Null);
                let method = request.get("method").and_then(Value::as_str).unwrap_or("");
                let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
                let origin = match request.get("origin").and_then(Value::as_str) {
                    // `user` is reserved for the app's own connections (later: proven by the provider secret).
                    Some("mcp") => "mcp",
                    Some("script") => "script",
                    _ => "cli",
                };
                let caller =
                    Caller { actor: actor.clone(), on_behalf_of: None, origin: origin.into() };
                match host.dispatch(&caller, method, &params) {
                    Ok(result) => json!({"id": id, "result": result}),
                    Err(error) => json!({"id": id, "error": error.to_json()}),
                }
            }
            Err(error) => {
                json!({"id": null, "error": DriverError::invalid(format!("request is not JSON: {error}")).to_json()})
            }
        };
        writeln!(writer, "{reply}")?;
        writer.flush()?;
    }
    Ok(())
}

/// `uid:<n>` of the peer process.
fn peer_actor(stream: &UnixStream) -> String {
    match peer_uid(stream) {
        Some(uid) => format!("uid:{uid}"),
        None => "unknown".into(),
    }
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> Option<libc::uid_t> {
    use std::os::fd::AsRawFd;
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the fd is an open Unix socket; cred and len describe a valid buffer.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0).then_some(cred.uid)
}

#[cfg(not(target_os = "linux"))]
fn peer_uid(stream: &UnixStream) -> Option<libc::uid_t> {
    use std::os::fd::AsRawFd;
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: the fd is an open Unix socket; uid and gid are valid out pointers.
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (rc == 0).then_some(uid)
}
