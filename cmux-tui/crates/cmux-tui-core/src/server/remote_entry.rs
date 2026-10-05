//! The session daemon's remote entry: the only way a `cmux link` peer stream
//! reaches the daemon (plans/cmux-next/transport.md 12a,
//! plans/cmux-next/server-remote-conversations.md).
//!
//! It is a separate Unix socket next to the session's local socket
//! (`cmux_link::entry_path`). A connection is served only when:
//!
//! 1. the [`LinkVerifier`] accepts the connecting process (the link: same
//!    user and, on macOS, signed as cmux; `cmux_link::caller::verify`);
//! 2. its first line is a valid peer stamp (`cmux_link::stamp`), read before
//!    anything else and only here, never on the local socket. A stamp with
//!    `check: link_token` (the host accepted a control-plane link token for
//!    this stream) records the install's good check before the stream binds,
//!    but only when the daemon started with a real token verifier
//!    ([`cmux_link::token::StampChecks`], from the daemon's own config). Under
//!    the default (`DenyAllTokens`) a stamp with any `check` is malformed:
//!    the entry closes the stream and records nothing;
//! 3. every later line passes the [`RemoteGate`] before anything parses or
//!    dispatches it. The default gate, [`DenyAllGate`], refuses everything
//!    with `error_code: remote_denied`; [`super::FsGate`] admits only the
//!    seven `fs-v1` ops, and lane 10's conversation gate will add its own
//!    explicit allowlist.
//!
//! A remote client is registered as [`ClientTransport::Remote`], so checks
//! for a trusted local connection (`is_unix`) refuse it, and its
//! conversation principal is `remote_<install>`, never `user_local`.

use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Instant;

use super::admission::LineAdmission;
use super::*;

pub use cmux_link::stamp::LinkPeer as RemotePeer;

/// How long the link has to send the whole stamp after it connects.
const STAMP_TIMEOUT: Duration = Duration::from_secs(5);

/// The error code of every refused remote frame. Refusals carry no detail,
/// so a peer cannot probe which objects or commands exist.
pub(super) const REMOTE_DENIED: &str = "remote_denied";

/// Decides, for every frame of a remote stream, whether it is dispatched.
pub trait RemoteGate: Send + Sync + 'static {
    /// True to dispatch `frame` (one JSON line, unparsed) for `peer`.
    fn admit(&self, peer: &RemotePeer, frame: &str) -> bool;
}

/// The default gate: every frame is refused.
pub struct DenyAllGate;

impl RemoteGate for DenyAllGate {
    fn admit(&self, _peer: &RemotePeer, _frame: &str) -> bool {
        false
    }
}

/// Accepts the process connected to the remote entry, or refuses it.
pub type LinkVerifier = Arc<dyn Fn(&UnixStream) -> std::io::Result<()> + Send + Sync>;

/// A running remote entry. Dropping it stops accepts and removes the socket.
pub struct RemoteEntryServer {
    path: PathBuf,
    /// The socket file's (device, inode), so drop never removes a socket
    /// that another daemon bound at the same path later.
    identity: (u64, u64),
    shutdown: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    mux: Arc<Mux>,
}

impl RemoteEntryServer {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for RemoteEntryServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        // Wake the blocking accept so the thread sees the flag. When the
        // socket is already gone nothing can wake it; the thread then ends
        // with the process instead of blocking this drop.
        let woke = UnixStream::connect(&self.path).is_ok();
        if let Some(thread) = self.thread.take()
            && woke
        {
            let _ = thread.join();
        }
        if file_identity(&self.path).is_some_and(|identity| identity == self.identity) {
            let _ = std::fs::remove_file(&self.path);
        }
        // Daemon shutdown: running link dials (byte streams included) end
        // now, not at their idle timeout.
        fs_wire::close_remote_clients(&self.mux);
    }
}

fn file_identity(path: &Path) -> Option<(u64, u64)> {
    std::fs::symlink_metadata(path).ok().map(|metadata| (metadata.dev(), metadata.ino()))
}

/// Listen on `path` (mode 0600, in a 0700 directory it creates) and serve
/// link streams for `mux`. `checks` is fixed at daemon start from the
/// daemon's own config; nothing a stream sends changes it.
pub fn serve_remote_entry(
    mux: Arc<Mux>,
    path: &Path,
    verifier: LinkVerifier,
    gate: Arc<dyn RemoteGate>,
    checks: cmux_link::token::StampChecks,
) -> anyhow::Result<RemoteEntryServer> {
    let entry_fs = fs_wire::EntryFs::installed();
    serve_remote_entry_with(mux, path, verifier, gate, entry_fs, checks.records())
}

/// [`serve_remote_entry`] with an explicit `fs-v1` owner and first-line
/// deadline. `record_checks` is [`cmux_link::token::StampChecks::records`]
/// (tests set it directly; the startup guards are tested in `cmux-link`).
pub(super) fn serve_remote_entry_with(
    mux: Arc<Mux>,
    path: &Path,
    verifier: LinkVerifier,
    gate: Arc<dyn RemoteGate>,
    entry_fs: fs_wire::EntryFs,
    record_checks: bool,
) -> anyhow::Result<RemoteEntryServer> {
    if let Some(directory) = path.parent() {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new().mode(0o700).recursive(true).create(directory)?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    if path.exists() {
        match UnixStream::connect(path) {
            Ok(_) => anyhow::bail!("remote entry {} is already in use", path.display()),
            Err(_) => std::fs::remove_file(path)?,
        }
    }
    let listener = cmux_unix_socket::bind(path)?;
    if let Err(error) = platform::restrict_file(path) {
        let _ = std::fs::remove_file(path);
        return Err(error.into());
    }
    let identity = file_identity(path)
        .ok_or_else(|| anyhow::anyhow!("remote entry {} vanished after bind", path.display()))?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let thread_shutdown = shutdown.clone();
    let thread_mux = mux.clone();
    let thread = std::thread::Builder::new().name("mux-remote-entry".into()).spawn(move || {
        let config = EntryConfig { entry_fs, record_checks };
        accept_loop(&thread_mux, &listener, &thread_shutdown, &verifier, &gate, config);
    })?;
    Ok(RemoteEntryServer {
        path: path.to_path_buf(),
        identity,
        shutdown,
        thread: Some(thread),
        mux,
    })
}

fn accept_loop(
    mux: &Arc<Mux>,
    listener: &UnixListener,
    shutdown: &AtomicBool,
    verifier: &LinkVerifier,
    gate: &Arc<dyn RemoteGate>,
    config: EntryConfig,
) {
    let connections = mux.connection_stats().clone();
    let render_service = Arc::new(RenderService::new());
    let mut backoff = crate::backoff::Backoff::new(ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX);
    loop {
        let stream = match listener.accept() {
            Ok((stream, _)) => {
                backoff.reset();
                stream
            }
            Err(error) => {
                if shutdown.load(Ordering::Acquire) {
                    return;
                }
                if crate::backoff::accept_error_needs_backoff(&error) {
                    backoff.sleep();
                }
                continue;
            }
        };
        if shutdown.load(Ordering::Acquire) {
            return;
        }
        let Some(permit) = claim_connection(&connections) else { continue };
        let (mux, verifier, gate, render_service) =
            (mux.clone(), verifier.clone(), gate.clone(), render_service.clone());
        let _ = std::thread::Builder::new().name("mux-remote-conn".into()).spawn(move || {
            serve_remote_connection(mux, stream, &verifier, gate, render_service, permit, config);
        });
    }
}

fn serve_remote_connection(
    mux: Arc<Mux>,
    stream: UnixStream,
    verifier: &LinkVerifier,
    gate: Arc<dyn RemoteGate>,
    render_service: Arc<RenderService>,
    permit: ConnectionPermit,
    config: EntryConfig,
) {
    if verifier(&stream).is_err() {
        let _ = stream.shutdown(Shutdown::Both);
        return;
    }
    if greet(&stream).is_err() {
        let _ = stream.shutdown(Shutdown::Both);
        return;
    }
    let Some(cmux_link::stamp::Stamp { peer, check }) = read_stamp(&stream) else {
        let _ = stream.shutdown(Shutdown::Both);
        return;
    };
    // The link accepted a control-plane link token for this stream: the
    // install's good check, recorded before the stream binds. Only a daemon
    // that started with a real verifier records it; otherwise any `check` is
    // malformed (on Linux any same-user process passes the caller check and
    // can write one). A poisoned relay lock records nothing and closes the
    // stream (fail closed).
    let refused = match check {
        None => false,
        Some(cmux_link::stamp::StampCheck::LinkToken) => {
            !config.record_checks || mux.record_remote_check(&peer.install).is_err()
        }
    };
    if refused {
        let _ = stream.shutdown(Shutdown::Both);
        return;
    }
    // A dial whose first line asks for an `fs.*` byte stream is served raw
    // (fs_wire.rs); any other dial reaches the line connection unchanged.
    let entry_fs = config.entry_fs;
    let Some(stream) = fs_wire::route_first_line(&mux, stream, &*gate, &peer, entry_fs) else {
        return;
    };
    let admission = RemoteAdmission { peer, gate };
    serve_line_connection(
        mux,
        stream,
        render_service,
        Some(permit),
        ClientTransport::Remote,
        &admission,
    );
}

/// The per-entry settings every connection of one remote entry shares.
#[derive(Clone, Copy)]
struct EntryConfig {
    entry_fs: fs_wire::EntryFs,
    /// [`cmux_link::token::StampChecks::records`] at daemon start.
    record_checks: bool,
}

/// Tell the link it reached a remote entry (it splices only after this).
fn greet(stream: &UnixStream) -> std::io::Result<()> {
    let mut writer = stream;
    writer.set_write_timeout(Some(STAMP_TIMEOUT))?;
    writer.write_all(cmux_link::entry_path::ENTRY_BANNER.as_bytes())?;
    writer.write_all(b"\n")
}

/// Read the stamp one byte at a time, so no byte after it is consumed
/// here, under one deadline for the whole line.
fn read_stamp(stream: &UnixStream) -> Option<cmux_link::stamp::Stamp> {
    let deadline = Instant::now() + STAMP_TIMEOUT;
    let mut line = Vec::with_capacity(256);
    let mut reader = stream;
    let mut byte = [0u8; 1];
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        stream.set_read_timeout(Some(remaining.max(Duration::from_millis(1)))).ok()?;
        match reader.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' => break,
            Ok(1) if line.len() < cmux_link::stamp::MAX_STAMP_BYTES => line.push(byte[0]),
            _ => return None,
        }
    }
    stream.set_read_timeout(None).ok()?;
    cmux_link::stamp::parse(std::str::from_utf8(&line).ok()?).ok()
}

struct RemoteAdmission {
    peer: RemotePeer,
    gate: Arc<dyn RemoteGate>,
}

impl LineAdmission for RemoteAdmission {
    fn registered(&self, mux: &Arc<Mux>, client: u64) -> bool {
        mux.bind_remote_peer(client, &self.peer).is_ok()
    }

    fn refusal(&self, line: &str) -> Option<Value> {
        if self.gate.admit(&self.peer, line) {
            return None;
        }
        Some(denied(line))
    }
}

/// The refusal of `line`: its `id` when it has one, and no detail.
pub(super) fn denied(line: &str) -> Value {
    let id = serde_json::from_str::<Value>(line).ok().and_then(|frame| frame.get("id").cloned());
    let mut response = json!({"ok": false, "error": REMOTE_DENIED, "error_code": REMOTE_DENIED});
    if let Some(id) = id {
        response["id"] = id;
    }
    response
}

#[cfg(test)]
#[path = "remote_entry_tests.rs"]
mod tests;
