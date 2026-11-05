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

#[path = "agent_message_acpmux.rs"]
mod agent_message_acpmux;

#[cfg(test)]
#[path = "agent_session_link_tests.rs"]
mod tests;

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
    /// A session list read whole (`call_whole_list`) could not be: a bad or
    /// repeated cursor, a page with no `sessions`, or a page after the first
    /// that failed. Why.
    BadList(String),
}

/// acpmux's session list order (`hub::session_pages::sort_session_summaries`): newest
/// `updatedAt` first, ties by `sessionId`, then this machine's row before a peer's copy.
fn sort_newest_first(rows: &mut [Value]) {
    fn updated(row: &Value) -> u64 {
        row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
    }
    fn id(row: &Value) -> &str {
        row.get("sessionId").and_then(Value::as_str).unwrap_or("")
    }
    fn peer(row: &Value) -> Option<&str> {
        row.get("peer").and_then(Value::as_str)
    }
    rows.sort_by(|a, b| {
        updated(b)
            .cmp(&updated(a))
            .then_with(|| id(a).cmp(id(b)))
            .then_with(|| peer(a).cmp(&peer(b)))
    });
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
        std::thread::Builder::new()
            .name("mux-acpmux-link".into())
            .stack_size(THREAD_STACK_BYTES)
            .spawn(move || read_loop(reader, pending, closed, on_inbound))?;
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
            // Close publishes the flag before draining under this same lock. A waiter must
            // never be inserted after the reader's final drain.
            if self.closed.load(Ordering::Acquire) {
                return Err(LinkError::Closed);
            }
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

    /// A `_acpmux/sessions` or `_acpmux/watch` with no `limit`, its whole list: past
    /// acpmux's largest reply the list comes with a `nextCursor`, and the rest is read
    /// by `_acpmux/sessions` with the same params (no `enabled`) from that cursor
    /// (acpmux `Client::whole_list`). With a `limit` it is one plain call: the caller
    /// pages itself. A list that fits one reply has no cursor, so an older acpmux
    /// answers as before. `timeout` bounds each reply. The pages come in acpmux's
    /// byte-page order, so the joined rows are sorted newest first again; a cursor given
    /// twice or not a string, a page with no `sessions`, or a page after the first that
    /// fails, is [`LinkError::BadList`] instead of a loop or a list passing for whole.
    pub(crate) fn call_whole_list(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, LinkError> {
        if params.get("limit").is_some_and(|limit| !limit.is_null()) {
            return self.call(method, params, timeout);
        }
        let mut reply = self.call(method, params.clone(), timeout)?;
        let mut rest = params;
        if let Some(p) = rest.as_object_mut() {
            p.remove("enabled");
        }
        let bad = |why: String| LinkError::BadList(format!("{method}: {why}"));
        // Every acpmux answers `_acpmux/sessions` with its list; a watch from before
        // watches had one answers without.
        if method == "_acpmux/sessions" && !reply.get("sessions").is_some_and(Value::is_array) {
            return Err(bad("the reply lists no sessions".to_owned()));
        }
        let mut seen = std::collections::HashSet::new();
        while let Some(cursor) = reply.as_object_mut().and_then(|r| r.remove("nextCursor")) {
            let cursor = match cursor {
                Value::String(cursor) => cursor,
                Value::Null => break,
                other => return Err(bad(format!("acpmux gave the page cursor {other}"))),
            };
            if !seen.insert(cursor.clone()) {
                return Err(bad(format!("acpmux gave the page cursor {cursor:?} twice")));
            }
            let Some(p) = rest.as_object_mut() else {
                return Err(bad(format!(
                    "the params are not an object, so no page after {cursor:?}"
                )));
            };
            p.insert("cursor".into(), Value::String(cursor.clone()));
            // Past the first page the list is no whole one: a caller that took the
            // first page's error as it is would go on with the first page alone.
            let mut page = self
                .call("_acpmux/sessions", rest.clone(), timeout)
                .map_err(|e| bad(format!("the page after cursor {cursor:?} failed: {e:?}")))?;
            let (Some(Value::Array(rows)), Some(all)) = (
                page.get_mut("sessions").map(Value::take),
                reply.get_mut("sessions").and_then(Value::as_array_mut),
            ) else {
                return Err(bad(format!("the page after cursor {cursor:?} lists no sessions")));
            };
            all.extend(rows);
            if let Some((next, r)) =
                page.get_mut("nextCursor").map(Value::take).zip(reply.as_object_mut())
            {
                r.insert("nextCursor".into(), next);
            }
        }
        if !seen.is_empty()
            && let Some(rows) = reply.get_mut("sessions").and_then(Value::as_array_mut)
        {
            sort_newest_first(rows);
        }
        Ok(reply)
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
        for (_, sender) in self.pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
            let _ = sender.try_send(Err(LinkError::Closed));
        }
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
