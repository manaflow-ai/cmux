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

/// The app's provider socket, next to the agent socket.
pub fn provider_socket_path(agent_socket: &Path) -> PathBuf {
    agent_socket.with_file_name("browser-host-provider.sock")
}

/// Serves the app's provider connections (plans/cmux-next/browser-host.md
/// "Provider connection"): same uid, then `hello` with the per-launch
/// secret. One provider at a time: a second one is refused while the first
/// is connected, and replaces it after it disconnects.
pub fn serve_providers(
    listener: UnixListener,
    secret: crate::provider::ProviderSecret,
    slot: crate::engines::ProviderSlot,
    agent_bundle: Arc<str>,
) -> io::Result<()> {
    // SAFETY: getuid(2) has no failure modes.
    let uid = unsafe { libc::getuid() };
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if peer_uid(&stream) != Some(uid) {
            continue;
        }
        let (secret, slot, agent_bundle) = (secret.clone(), slot.clone(), agent_bundle.clone());
        let _ = std::thread::Builder::new().name("cmux-browser-host-provider-accept".into()).spawn(
            move || {
                let _ = accept_provider(stream, &secret, &slot, &agent_bundle);
            },
        );
    }
    Ok(())
}

fn accept_provider(
    stream: UnixStream,
    secret: &crate::provider::ProviderSecret,
    slot: &crate::engines::ProviderSlot,
    agent_bundle: &str,
) -> io::Result<()> {
    use crate::provider_link::{ProviderDriver, accept};
    let busy = || {
        slot.lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|provider| provider.closed_reason().is_none())
    };
    if busy() {
        return Ok(());
    }
    let mut reader = stream.try_clone()?;
    let mut writer = stream.try_clone()?;
    // A client that connects and never says hello does not keep a thread.
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    let Ok(info) = accept(&mut reader, &mut writer, secret, agent_bundle) else {
        return Ok(());
    };
    stream.set_read_timeout(None)?;
    let driver = ProviderDriver::start(reader, writer, crate::driver::discard_events(), info.tabs)?;
    let mut current = slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if current.as_ref().is_some_and(|provider| provider.closed_reason().is_none()) {
        // Another provider won the race: this one goes.
        let _ = stream.shutdown(std::net::Shutdown::Both);
        return Ok(());
    }
    *current = Some(driver);
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
                // The host's own 0600 socket: a local caller (CALLER-LOCALITY).
                let caller = Caller {
                    actor: actor.clone(),
                    on_behalf_of: None,
                    origin: origin.into(),
                    locality: crate::locality::CallerLocality::Local,
                };
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

#[cfg(test)]
mod provider_listener_tests {
    use super::*;
    use crate::provider::{Frame, PROVIDER_VERSION, ProviderSecret, read_frame, write_frame};

    fn hello(secret: &str) -> Frame {
        Frame::Hello {
            version: PROVIDER_VERSION,
            provider_id: "app".into(),
            install_id: "install".into(),
            secret: ProviderSecret::new(secret),
            engines: vec!["cef".into()],
            tabs: Vec::new(),
        }
    }

    /// Sends hello and returns the stream when the host answered hello.ack.
    fn dial(path: &Path, secret: &str) -> Option<UnixStream> {
        let mut stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
        write_frame(&mut stream, &hello(secret)).unwrap();
        match read_frame(&mut stream) {
            Ok(Some(Frame::HelloAck { .. })) => Some(stream),
            _ => None,
        }
    }

    #[test]
    fn the_provider_listener_needs_the_secret_and_takes_one_provider_at_a_time() {
        let dir = std::env::temp_dir().join(format!("cmux-bh-provider-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("browser-host-provider.sock");
        let listener = bind(&path, true).unwrap();
        let slot: crate::engines::ProviderSlot = Arc::default();
        let secret = "s".repeat(40);
        let (thread_slot, thread_secret) = (slot.clone(), ProviderSecret::new(secret.clone()));
        std::thread::spawn(move || {
            serve_providers(listener, thread_secret, thread_slot, Arc::from("agent"))
        });
        assert!(dial(&path, "wrong-secret-wrong-secret-wrong-secret").is_none());
        assert!(slot.lock().unwrap().is_none());
        let first = dial(&path, &secret).expect("the right secret is accepted");
        // The slot is set right after hello.ack; wait for it without sleeping.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while slot.lock().unwrap().is_none() && std::time::Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(slot.lock().unwrap().is_some());
        assert!(
            dial(&path, &secret).is_none(),
            "a second provider is refused while the first is live"
        );
        drop(first);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while slot.lock().unwrap().as_ref().is_some_and(|p| p.closed_reason().is_none())
            && std::time::Instant::now() < deadline
        {
            std::thread::yield_now();
        }
        assert!(dial(&path, &secret).is_some(), "a new provider replaces a closed one");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
