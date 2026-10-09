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

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

/// Largest acpmux line the daemon reads: an attach or events page of
/// records with big tool outputs stays under it (the daemon then trims the
/// page to `MAX_PAGE_BYTES` for its client); a longer line ends the link.
pub(super) const MAX_LINE_BYTES: usize = 32 << 20;
/// Calls waiting for a reply on one link.
pub(super) const MAX_IN_FLIGHT: usize = 16;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// Why a call failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum LinkError {
    /// The socket is gone or never connected.
    Closed,
    Timeout,
    /// Too many calls wait already.
    Busy,
    /// acpmux answered with an error (its message, for the daemon log only).
    Rpc(String),
}

/// What the reader thread hands the link's owner.
pub(super) enum Inbound {
    /// A JSON-RPC notification: method and params.
    Notification(String, Value),
    /// The socket ended (EOF, an IO error, or an over-long line).
    Closed(&'static str),
}

type Pending = Mutex<HashMap<u64, SyncSender<Result<Value, LinkError>>>>;

pub(super) struct AcpmuxLink {
    stream: Mutex<UnixStream>,
    pending: Arc<Pending>,
    next_id: AtomicU64,
    closed: Arc<AtomicBool>,
}

impl AcpmuxLink {
    /// Connects and starts the reader thread, which calls `on_inbound` for
    /// every notification and once for the close.
    pub(super) fn connect(
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
        std::thread::Builder::new()
            .name("mux-acpmux-link".into())
            .stack_size(THREAD_STACK_BYTES)
            .spawn(move || read_loop(reader, pending, closed, on_inbound))?;
        Ok(link)
    }

    /// Sends a request and waits up to `timeout` for its result.
    pub(super) fn call(
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
        let result = receiver.recv_timeout(timeout).unwrap_or(Err(LinkError::Timeout));
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
    pub(super) fn close(&self) {
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
                Some(error) => Err(LinkError::Rpc(
                    error.get("message").and_then(Value::as_str).unwrap_or("error").to_string(),
                )),
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
        let content = if done { taken - 1 } else { taken };
        if line.len() + content > MAX_LINE_BYTES {
            return Ok(LineRead::TooLong);
        }
        line.extend_from_slice(&available[..content]);
        reader.consume(taken);
        if done {
            return Ok(LineRead::Line);
        }
    }
}
