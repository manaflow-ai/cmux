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
//!    anything else and only here, never on the local socket;
//! 3. every later line passes the [`RemoteGate`] before anything parses or
//!    dispatches it. The default gate, [`DenyAllGate`], refuses everything
//!    with `error_code: remote_denied`; lane 10's conversation gate replaces
//!    it with an explicit allowlist.
//!
//! A remote client is registered as [`ClientTransport::Remote`], so checks
//! for a trusted local connection (`is_unix`) refuse it, and its
//! conversation principal is the peer's user, never `user_local`.

use std::io::Read;
use std::os::unix::net::{UnixListener, UnixStream};

use super::admission::LineAdmission;
use super::*;

pub use cmux_link::stamp::LinkPeer as RemotePeer;

/// How long the link has to send the stamp after it connects.
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
        true // RED stub: no gate yet.
    }
}

/// Accepts the process connected to the remote entry, or refuses it.
pub type LinkVerifier = Arc<dyn Fn(&UnixStream) -> std::io::Result<()> + Send + Sync>;

/// A running remote entry. Dropping it stops accepts and removes the socket.
pub struct RemoteEntryServer {
    path: PathBuf,
    shutdown: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
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
        let _ = std::fs::remove_file(&self.path);
    }
}

/// The conversation principal of a remote peer (server-remote-conversations.md 2).
pub fn remote_principal(peer: &RemotePeer) -> String {
    format!("user_{}", peer.user)
}

/// Listen on `path` (mode 0600) and serve link streams for `mux`.
pub fn serve_remote_entry(
    mux: Arc<Mux>,
    path: &Path,
    verifier: LinkVerifier,
    gate: Arc<dyn RemoteGate>,
) -> anyhow::Result<RemoteEntryServer> {
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
    let shutdown = Arc::new(AtomicBool::new(false));
    let thread_shutdown = shutdown.clone();
    let thread = std::thread::Builder::new()
        .name("mux-remote-entry".into())
        .spawn(move || accept_loop(&mux, &listener, &thread_shutdown, &verifier, &gate))?;
    Ok(RemoteEntryServer { path: path.to_path_buf(), shutdown, thread: Some(thread) })
}

fn accept_loop(
    mux: &Arc<Mux>,
    listener: &UnixListener,
    shutdown: &AtomicBool,
    verifier: &LinkVerifier,
    gate: &Arc<dyn RemoteGate>,
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
            serve_remote_connection(mux, stream, &verifier, gate, render_service, permit);
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
) {
    let _ = verifier; // RED stub: the link is not verified yet.
    let Some(peer) = read_stamp(&stream) else {
        let _ = stream.shutdown(Shutdown::Both);
        return;
    };
    let admission = RemoteAdmission { peer, gate };
    serve_line_connection(
        mux,
        Box::new(stream),
        render_service,
        Some(permit),
        ClientTransport::Remote,
        &admission,
    );
}

/// Read the stamp one byte at a time, so no byte after it is consumed here.
fn read_stamp(stream: &UnixStream) -> Option<RemotePeer> {
    stream.set_read_timeout(Some(STAMP_TIMEOUT)).ok()?;
    let mut line = Vec::with_capacity(256);
    let mut reader = stream;
    let mut byte = [0u8; 1];
    loop {
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
    // RED stub: the peer is not bound as the principal yet.

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
