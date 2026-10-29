//! One newline-delimited JSON-RPC connection from the daemon to this
//! machine's acpmux unix socket, for one attached agent tab
//! (`agent_session_attach.rs`). The daemon is a local (unix socket) acpmux
//! client; it sends only the typed calls the attach verbs make and never a
//! frame from its own client.
//!
//! Bounds: a line from acpmux is at most [`MAX_LINE_BYTES`] (a longer one
//! ends the link), at most [`MAX_IN_FLIGHT`] calls wait for a reply, and
//! every call has a deadline. Notifications go to one handler on the reader
//! thread, which may block (backpressure): acpmux then fills its own bounded
//! per-connection queue and reports `_acpmux/lagged`.

use crate::server::request_hang_watch::ipc_reply;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::sync as waits;
use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
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

/// What the reader thread hands the link's owner.
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
    /// Connects and starts the reader thread, which calls `on_inbound` for
    /// every notification and once for the close.
    pub(crate) fn connect(
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
        let pending = link.pending.clone();
        let closed = link.closed.clone();
        // Requests wait in `call` for the replies it reads: their class.
        supervised::spawn_at(
            "mux-acpmux-link",
            crate::thread_qos::ThreadType::Interactive.qos(),
            Fatal,
            ShutdownBehavior::Continue,
            move || read_loop(reader, pending, closed, on_inbound),
        )?;
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

    /// Ends the socket; the reader thread reports the close.
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

fn read_loop(
    stream: UnixStream,
    pending: Arc<Pending>,
    closed: Arc<AtomicBool>,
    mut on_inbound: impl FnMut(Inbound),
) {
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    let reason = loop {
        line.clear();
        match read_bounded_line(&mut reader, &mut line) {
            Ok(LineRead::Line) => {}
            Ok(LineRead::Eof) => break "acpmux_closed",
            Ok(LineRead::TooLong) => break "too_large",
            Err(_) => break "acpmux_closed",
        }
        let Ok(Value::Object(mut message)) = serde_json::from_slice::<Value>(&line) else {
            continue;
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
            continue;
        }
        if let Some(Value::String(method)) = message.remove("method") {
            on_inbound(Inbound::Notification(method, message.remove("params").unwrap_or_default()));
        }
    };
    closed.store(true, Ordering::Release);
    for (_, sender) in pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
        let _ = sender.try_send(Err(LinkError::Closed));
    }
    on_inbound(Inbound::Closed(reason));
}

enum LineRead {
    Line,
    Eof,
    TooLong,
}

/// One line without its newline, never more than [`MAX_LINE_BYTES`].
fn read_bounded_line(reader: &mut impl BufRead, line: &mut Vec<u8>) -> std::io::Result<LineRead> {
    loop {
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if available.is_empty() {
            return Ok(LineRead::Eof);
        }
        let (taken, done) = match available.iter().position(|byte| *byte == b'\n') {
            Some(end) => (end + 1, true),
            None => (available.len(), false),
        };
        let content = if done { taken.saturating_sub(1) } else { taken };
        if line.len().saturating_add(content) > MAX_LINE_BYTES {
            return Ok(LineRead::TooLong);
        }
        line.extend_from_slice(available.get(..content).unwrap_or_default());
        reader.consume(taken);
        if done {
            return Ok(LineRead::Line);
        }
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
        let Ok(link) = AcpmuxLink::connect(&socket, |_| {}) else { return keys };
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
