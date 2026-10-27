//! One newline-delimited JSON-RPC connection from the daemon to this
//! machine's acpmux unix socket, for one attached agent tab
//! (`agent_session_attach.rs`). The daemon is a local (unix socket) acpmux
//! client; it sends only the typed calls the attach verbs make and never a
//! frame from its own client.
//!
//! Bounds: a line from acpmux is at most [`MAX_LINE_BYTES`] (a longer one
//! ends the link), at most [`MAX_IN_FLIGHT`] calls wait for a reply, and
//! every call has a deadline. The link holds no thread (p05-ipc-147): the
//! daemon's descriptor readers (`fd_readers.rs`) read every link's socket,
//! and its notifications go to one handler there, which never blocks (it
//! queues on the attachment's stream, whose overflow ends it).

use crate::server::FdReader;
use crate::server::FdReaders;
use crate::server::request_hang_watch::ipc_reply;
use cmux_threads::checked::sync as waits;
use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::io::Write;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::time::Duration;

use serde_json::{Value, json};

#[path = "agent_message_acpmux.rs"]
mod agent_message_acpmux;

/// Largest acpmux line the daemon reads: an attach or events page of
/// records with big tool outputs stays under it (the daemon then trims the
/// page to `MAX_PAGE_BYTES` for its client); a longer line ends the link.
pub(super) const MAX_LINE_BYTES: usize = 32 << 20;
/// Calls waiting for a reply on one link.
pub(super) const MAX_IN_FLIGHT: usize = 16;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
/// Bytes one read takes from a link's socket.
const READ_CHUNK_BYTES: usize = 16 * 1024;
/// Reads one turn of the descriptor readers takes from a link before the
/// other links get theirs; what is left stays readable for the next turn.
const READS_PER_TURN: usize = 64;

/// Why a call failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LinkError {
    /// The socket is gone or never connected.
    Closed,
    Timeout,
    /// Too many calls wait already.
    Busy,
    /// acpmux answered with an error: its message (for the daemon log
    /// only) and its `data` (`Null` without one).
    Rpc(String, Value),
    /// acpmux does not know the method (JSON-RPC -32601, an acpmux from
    /// before it): its message.
    MethodNotFound(String),
}

/// JSON-RPC's method-not-found code (acpmux `RpcError::method_not_found`).
const METHOD_NOT_FOUND: i64 = -32601;

/// What the link's reader hands its owner.
pub(crate) enum Inbound {
    /// A JSON-RPC notification: method and params.
    Notification(String, Value),
    /// The socket ended (EOF, an IO error, or an over-long line).
    Closed(&'static str),
}

type Pending = Mutex<HashMap<u64, SyncSender<Result<Value, LinkError>>>>;

pub(crate) struct AcpmuxLink {
    stream: Mutex<UnixStream>,
    pending: Arc<Pending>,
    next_id: AtomicU64,
    closed: Arc<AtomicBool>,
}

impl AcpmuxLink {
    /// Connects and hands the socket to `readers`, which call `on_inbound`
    /// for every notification and once for the close. `on_inbound` runs on
    /// the readers' thread: it never waits.
    pub(crate) fn connect(
        readers: &FdReaders,
        socket: &Path,
        on_inbound: impl FnMut(Inbound) + Send + 'static,
    ) -> std::io::Result<Arc<Self>> {
        let stream = UnixStream::connect(socket)?;
        stream.set_write_timeout(Some(CONNECT_TIMEOUT))?;
        let reader = stream.try_clone()?;
        let link = Arc::new(Self {
            stream: Mutex::new(stream),
            pending: Arc::default(),
            next_id: AtomicU64::new(1),
            closed: Arc::new(AtomicBool::new(false)),
        });
        readers.watch(Box::new(LinkReader {
            stream: reader,
            line: Vec::new(),
            pending: link.pending.clone(),
            closed: link.closed.clone(),
            on_inbound,
            ended: false,
        }))?;
        Ok(link)
    }

    /// Sends a request and waits up to `timeout` for its result.
    pub(crate) fn call(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = sync_channel(1);
        {
            let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            if pending.len() >= MAX_IN_FLIGHT {
                return Err(LinkError::Busy);
            }
            pending.insert(id, sender);
        }
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if self.write(&frame).is_err() {
            self.forget(id);
            return Err(LinkError::Closed);
        }
        let result = ipc_reply(|| waits::recv_timeout(&receiver, timeout))
            .unwrap_or(Err(LinkError::Timeout));
        self.forget(id);
        result
    }

    /// Sends a request whose reply is not waited for (it is read and
    /// dropped), so it holds no in-flight slot.
    pub(super) fn send_ignoring_reply(&self, method: &str, params: Value) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.write(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .map_err(|_| LinkError::Closed)
    }

    /// Sends a notification (no reply).
    pub(super) fn notify(&self, method: &str, params: Value) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        self.write(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .map_err(|_| LinkError::Closed)
    }

    /// Ends the socket; its reader reports the close.
    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let stream = self.stream.lock().unwrap_or_else(|e| e.into_inner());
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }

    fn write(&self, frame: &Value) -> std::io::Result<()> {
        let mut line = serde_json::to_vec(frame)?;
        line.push(b'\n');
        let mut stream = self.stream.lock().unwrap_or_else(|e| e.into_inner());
        stream.write_all(&line)?;
        stream.flush()
    }

    fn forget(&self, id: u64) {
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    }
}

impl Drop for AcpmuxLink {
    fn drop(&mut self) {
        self.close();
    }
}

/// One link's socket on the descriptor readers: it cuts lines, answers
/// calls and hands notifications to the link's owner.
struct LinkReader<F: FnMut(Inbound)> {
    /// The socket's read side. Its writer shares the descriptor and blocks
    /// with a timeout, so reads ask for no waiting per call (`MSG_DONTWAIT`)
    /// instead of making the descriptor non-blocking.
    stream: UnixStream,
    /// The line read so far, without its newline.
    line: Vec<u8>,
    pending: Arc<Pending>,
    closed: Arc<AtomicBool>,
    on_inbound: F,
    ended: bool,
}

impl<F: FnMut(Inbound) + Send + 'static> FdReader for LinkReader<F> {
    fn fd(&self) -> RawFd {
        self.stream.as_raw_fd()
    }

    fn readable(&mut self) -> bool {
        let mut chunk = [0_u8; READ_CHUNK_BYTES];
        for _ in 0..READS_PER_TURN {
            // SAFETY: `chunk` is valid for writes of its length, and the
            // socket stays open while `self.stream` lives.
            let read = unsafe {
                libc::recv(
                    self.stream.as_raw_fd(),
                    chunk.as_mut_ptr().cast(),
                    chunk.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            let Ok(read) = usize::try_from(read) else {
                match std::io::Error::last_os_error().kind() {
                    std::io::ErrorKind::WouldBlock => return true,
                    std::io::ErrorKind::Interrupted => continue,
                    _ => return self.end("acpmux_closed"),
                }
            };
            if read == 0 {
                return self.end("acpmux_closed");
            }
            if !self.take(chunk.get(..read).unwrap_or_default()) {
                return self.end("too_large");
            }
        }
        true
    }
}

impl<F: FnMut(Inbound)> LinkReader<F> {
    /// Handles every line `bytes` completes. False when a line grows past
    /// [`MAX_LINE_BYTES`].
    fn take(&mut self, mut bytes: &[u8]) -> bool {
        while let Some(end) = bytes.iter().position(|byte| *byte == b'\n') {
            let (content, rest) = bytes.split_at(end);
            if self.line.len().saturating_add(content.len()) > MAX_LINE_BYTES {
                return false;
            }
            self.line.extend_from_slice(content);
            handle_line(&self.line, &self.pending, &mut self.on_inbound);
            self.line.clear();
            bytes = rest.get(1..).unwrap_or_default();
        }
        if self.line.len().saturating_add(bytes.len()) > MAX_LINE_BYTES {
            return false;
        }
        self.line.extend_from_slice(bytes);
        true
    }

    /// The socket ended: every waiting call fails and the owner hears the
    /// close once. Always false: the watch ends.
    fn end(&mut self, reason: &'static str) -> bool {
        self.fail_pending();
        (self.on_inbound)(Inbound::Closed(reason));
        false
    }
}

impl<F: FnMut(Inbound)> LinkReader<F> {
    fn fail_pending(&mut self) {
        self.ended = true;
        self.closed.store(true, Ordering::Release);
        for (_, sender) in self.pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
            let _ = sender.try_send(Err(LinkError::Closed));
        }
    }
}

impl<F: FnMut(Inbound)> Drop for LinkReader<F> {
    fn drop(&mut self) {
        // The watch ended before the socket did (the readers stopped, or
        // this reader panicked): no call waits for a reply that cannot
        // come, and the owner still hears the close once.
        if !self.ended {
            self.end("acpmux_closed");
        }
    }
}

/// One line from acpmux: a reply goes to the call that waits for it, a
/// notification to the owner; anything else is skipped.
fn handle_line(line: &[u8], pending: &Pending, on_inbound: &mut impl FnMut(Inbound)) {
    let Ok(Value::Object(mut message)) = serde_json::from_slice::<Value>(line) else {
        return;
    };
    if let Some(id) = message.get("id").and_then(Value::as_u64)
        && !message.contains_key("method")
    {
        let outcome = match message.remove("error") {
            Some(error) => {
                let text = error.get("message").and_then(Value::as_str).unwrap_or("error");
                Err(if error.get("code").and_then(Value::as_i64) == Some(METHOD_NOT_FOUND) {
                    LinkError::MethodNotFound(text.to_string())
                } else {
                    LinkError::Rpc(
                        text.to_string(),
                        error.get("data").cloned().unwrap_or(Value::Null),
                    )
                })
            }
            None => Ok(message.remove("result").unwrap_or(Value::Null)),
        };
        let sender = pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        if let Some(sender) = sender {
            let _ = sender.try_send(outcome);
        }
        return;
    }
    if let Some(Value::String(method)) = message.remove("method") {
        on_inbound(Inbound::Notification(method, message.remove("params").unwrap_or_default()));
    }
}

/// How long a send waits for acpmux to name one session's workspace, and
/// for all of them.
const WORKSPACE_LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);
const WORKSPACE_LOOKUP_BUDGET: Duration = Duration::from_secs(5);

impl crate::mux::Mux {
    /// The workspace key each acpmux session runs in, for agent message
    /// policy: `_acpmux/info`'s `sessionEnv.CMUX_WORKSPACE_ID`, which acpmux
    /// gives a local unix-socket client only. Keys are lowercase hex without
    /// dashes. A session acpmux does not know, one without the variable, and
    /// every session while acpmux is not running map to `None`; acpmux is
    /// never started for this.
    pub(crate) fn acp_session_workspace_keys(
        &self,
        sessions: &[String],
    ) -> HashMap<String, Option<String>> {
        let mut keys: HashMap<String, Option<String>> =
            sessions.iter().map(|session| (session.clone(), None)).collect();
        let Some(socket) = self.control_clients.agent_sessions.socket() else { return keys };
        if sessions.is_empty() {
            return keys;
        }
        let Ok(link) = AcpmuxLink::connect(&self.fd_readers, &socket, |_| {}) else { return keys };
        let deadline = std::time::Instant::now() + WORKSPACE_LOOKUP_BUDGET;
        for session in sessions {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                break;
            }
            // The session env is in the session list: no wait for the chat logs.
            let info = link.call(
                "_acpmux/info",
                agent_message_acpmux::info_params(session),
                left.min(WORKSPACE_LOOKUP_TIMEOUT),
            );
            let key = info.ok().and_then(|info| {
                let key = info.get("sessionEnv")?.get("CMUX_WORKSPACE_ID")?.as_str()?;
                Some(crate::state::agent_message_policy::workspace_key(key))
            });
            keys.insert(session.clone(), key);
        }
        link.close();
        keys
    }
}

#[cfg(test)]
#[path = "agent_session_link_tests.rs"]
mod tests;
