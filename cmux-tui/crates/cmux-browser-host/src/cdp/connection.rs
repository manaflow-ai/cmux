//! One CDP connection over any wire (pipe, relay frames, test fake).
//!
//! The connection matches replies to calls by message id and hands events to
//! one handler. The transport owns the reader: it calls [`CdpConnection::receive`]
//! for every inbound message and [`CdpConnection::close`] when the stream ends.

use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::time::Duration;

/// Sends one serialized CDP message.
pub trait CdpWire: Send + Sync {
    fn send(&self, message: &str) -> io::Result<()>;
}

/// One CDP event (`method` + `params`) and the flat session it belongs to.
#[derive(Debug, Clone, PartialEq)]
pub struct CdpEvent {
    pub session_id: Option<String>,
    pub method: String,
    pub params: Value,
}

/// Receives events on the transport's reader thread. It must not make a
/// blocking [`CdpConnection::call`] there: the reply would never be read.
pub type CdpEventHandler = Arc<dyn Fn(CdpEvent) + Send + Sync>;

type Reply = Result<Value, DriverError>;

/// A sent call waiting for its reply.
struct Pending {
    id: u64,
    method: String,
    rx: mpsc::Receiver<Reply>,
}

pub struct CdpConnection {
    wire: Box<dyn CdpWire>,
    next_id: AtomicU64,
    pending: Mutex<HashMap<u64, mpsc::SyncSender<Reply>>>,
    handler: Mutex<Option<CdpEventHandler>>,
    on_close: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    closed: Mutex<Option<String>>,
    /// A page-rooted connection (one CEF tab's DevTools relay): the page's
    /// own messages carry no `sessionId` on the wire, and the driver sees
    /// them under this alias, as if the page were a flat session of a
    /// browser connection.
    root_alias: Option<String>,
}

impl CdpConnection {
    pub fn new(wire: Box<dyn CdpWire>) -> Arc<Self> {
        Self::build(wire, None)
    }

    /// A connection to one page target (`Target.getTargetInfo` with no
    /// argument names it). Calls on `alias` go out without `sessionId`;
    /// inbound messages without `sessionId` arrive tagged with `alias`.
    pub fn page_rooted(wire: Box<dyn CdpWire>, alias: impl Into<String>) -> Arc<Self> {
        Self::build(wire, Some(alias.into()))
    }

    fn build(wire: Box<dyn CdpWire>, root_alias: Option<String>) -> Arc<Self> {
        Arc::new(CdpConnection {
            wire,
            next_id: AtomicU64::new(1),
            pending: Mutex::new(HashMap::new()),
            handler: Mutex::new(None),
            on_close: Mutex::new(None),
            closed: Mutex::new(None),
            root_alias,
        })
    }

    /// The page alias of a page-rooted connection.
    pub fn root_alias(&self) -> Option<&str> {
        self.root_alias.as_deref()
    }

    pub fn set_event_handler(&self, handler: CdpEventHandler) {
        *self.handler.lock().unwrap_or_else(PoisonError::into_inner) = Some(handler);
    }

    /// Called once when the connection closes (drivers wake their waiters).
    pub fn set_close_handler(&self, handler: Arc<dyn Fn() + Send + Sync>) {
        *self.on_close.lock().unwrap_or_else(PoisonError::into_inner) = Some(handler);
    }

    /// Why the connection closed, if it did.
    pub fn closed_reason(&self) -> Option<String> {
        self.closed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Sends one method and waits for its reply.
    pub fn call(
        &self,
        session_id: Option<&str>,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, DriverError> {
        let pending = self.send(session_id, method, params)?;
        self.wait(pending, timeout)
    }

    /// Sends several methods back to back, then waits for every reply.
    /// A target paused at start (`waitForDebuggerOnStart`) may hold replies
    /// until `Runtime.runIfWaitingForDebugger`, so setup sends its domain
    /// enables and the resume in one batch, as Playwright and Puppeteer do.
    pub fn call_batch(
        &self,
        session_id: Option<&str>,
        calls: Vec<(&str, Value)>,
        timeout: Duration,
    ) -> Vec<Result<Value, DriverError>> {
        let sent: Vec<_> = calls
            .into_iter()
            .map(|(method, params)| self.send(session_id, method, params))
            .collect();
        let deadline = std::time::Instant::now() + timeout;
        sent.into_iter()
            .map(|pending| {
                let pending = pending?;
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                self.wait(pending, left)
            })
            .collect()
    }

    fn send(
        &self,
        session_id: Option<&str>,
        method: &str,
        params: Value,
    ) -> Result<Pending, DriverError> {
        if let Some(reason) = self.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::sync_channel(1);
        self.pending.lock().unwrap_or_else(PoisonError::into_inner).insert(id, tx);
        // A close that ran between the check above and the insert drained
        // `pending` before this waiter was in it.
        if let Some(reason) = self.closed_reason() {
            self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            return Err(DriverError::closed(reason));
        }
        let mut message = Map::new();
        message.insert("id".into(), json!(id));
        message.insert("method".into(), json!(method));
        message.insert("params".into(), if params.is_null() { json!({}) } else { params });
        match session_id {
            Some(session_id) if Some(session_id) == self.root_alias.as_deref() => {}
            Some(session_id) => {
                message.insert("sessionId".into(), json!(session_id));
            }
            // A page-rooted connection has no browser target: a browser-level
            // call would reach the page instead.
            None if self.root_alias.is_some() => {
                self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
                return Err(DriverError::new(
                    ErrorCode::Unsupported,
                    format!("{method}: not available on a relayed tab (no browser target)"),
                ));
            }
            None => {}
        }
        if let Err(error) = self.wire.send(&Value::Object(message).to_string()) {
            self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            return Err(DriverError::closed(format!("CDP connection write failed: {error}")));
        }
        Ok(Pending { id, method: method.to_owned(), rx })
    }

    fn wait(&self, pending: Pending, timeout: Duration) -> Result<Value, DriverError> {
        match pending.rx.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&pending.id);
                Err(DriverError::timeout(format!(
                    "{} timed out after {} ms",
                    pending.method,
                    timeout.as_millis()
                )))
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(DriverError::closed(
                self.closed_reason().unwrap_or_else(|| "CDP connection closed".into()),
            )),
        }
    }

    /// Handles one inbound message from the transport.
    pub fn receive(&self, message: &str) {
        let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
            return;
        };
        if let Some(id) = object.get("id").and_then(Value::as_u64) {
            let waiter = self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            if let Some(waiter) = waiter {
                let reply = match object.remove("error") {
                    Some(error) => Err(protocol_error(&error)),
                    None => Ok(object.remove("result").unwrap_or_else(|| json!({}))),
                };
                let _ = waiter.try_send(reply);
            }
            return;
        }
        let Some(Value::String(method)) = object.remove("method") else {
            return;
        };
        let event = CdpEvent {
            session_id: object
                .get("sessionId")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| self.root_alias.clone()),
            method,
            params: object.remove("params").unwrap_or_else(|| json!({})),
        };
        let handler = self.handler.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(handler) = handler {
            handler(event);
        }
    }

    /// Marks the connection closed and fails every pending call.
    pub fn close(&self, reason: &str) {
        {
            let mut closed = self.closed.lock().unwrap_or_else(PoisonError::into_inner);
            if closed.is_none() {
                *closed = Some(reason.to_owned());
            }
        }
        let waiters: Vec<_> =
            self.pending.lock().unwrap_or_else(PoisonError::into_inner).drain().collect();
        for (_, waiter) in waiters {
            let _ = waiter.try_send(Err(DriverError::closed(reason.to_owned())));
        }
        let hook = self.on_close.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(hook) = hook {
            hook();
        }
    }
}

/// Maps a CDP error object to a driver error code.
pub fn protocol_error(error: &Value) -> DriverError {
    let message = error.get("message").and_then(Value::as_str).unwrap_or("CDP error").to_owned();
    let detail = error.get("data").and_then(Value::as_str);
    let text = match detail {
        Some(detail) if !detail.is_empty() => format!("{message}: {detail}"),
        _ => message,
    };
    let lower = text.to_ascii_lowercase();
    let code = if lower.contains("target closed")
        || lower.contains("session closed")
        || lower.contains("session with given id not found")
    {
        ErrorCode::Closed
    } else if lower.contains("cannot find context")
        || lower.contains("no frame")
        || lower.contains("frame with the given id was not found")
        || lower.contains("no target with given id")
    {
        ErrorCode::NotFound
    } else if lower.contains("no node with given id") || lower.contains("node is detached") {
        ErrorCode::Stale
    } else {
        ErrorCode::Invalid
    };
    DriverError::new(code, text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[derive(Default)]
    struct RecordingWire {
        sent: Mutex<Vec<Value>>,
    }

    impl CdpWire for Arc<RecordingWire> {
        fn send(&self, message: &str) -> io::Result<()> {
            self.sent.lock().unwrap().push(serde_json::from_str(message).unwrap());
            Ok(())
        }
    }

    #[test]
    fn a_provider_relay_connection_maps_its_page_alias_to_no_session() {
        let wire = Arc::new(RecordingWire::default());
        let conn = CdpConnection::page_rooted(Box::new(wire.clone()), "root");
        let events = Arc::new(Mutex::new(Vec::new()));
        let seen = events.clone();
        conn.set_event_handler(Arc::new(move |event| seen.lock().unwrap().push(event)));
        let caller = conn.clone();
        let call = thread::spawn(move || {
            caller.call(Some("root"), "Page.enable", json!({}), Duration::from_secs(5))
        });
        let child = conn.clone();
        let child_call = thread::spawn(move || {
            child.call(Some("frame-1"), "Runtime.enable", json!({}), Duration::from_secs(5))
        });
        while wire.sent.lock().unwrap().len() < 2 {
            thread::yield_now();
        }
        let sent = wire.sent.lock().unwrap().clone();
        let page = sent.iter().find(|m| m["method"] == "Page.enable").unwrap();
        assert!(page.get("sessionId").is_none(), "{page}");
        let frame = sent.iter().find(|m| m["method"] == "Runtime.enable").unwrap();
        assert_eq!(frame["sessionId"], "frame-1");
        for message in &sent {
            let id = &message["id"];
            conn.receive(&json!({"id": id, "result": {}}).to_string());
        }
        call.join().unwrap().unwrap();
        child_call.join().unwrap().unwrap();
        // Page events come back under the alias; child events keep theirs.
        conn.receive(&json!({"method": "Page.loadEventFired", "params": {}}).to_string());
        conn.receive(
            &json!({"method": "Runtime.executionContextCreated", "sessionId": "frame-1", "params": {}})
                .to_string(),
        );
        let events = events.lock().unwrap();
        assert_eq!(events[0].session_id.as_deref(), Some("root"));
        assert_eq!(events[1].session_id.as_deref(), Some("frame-1"));
        // No browser target behind a relayed tab: browser-level calls fail at once.
        let error =
            conn.call(None, "Target.getTargets", json!({}), Duration::from_secs(5)).unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported, "{error}");
        assert_eq!(wire.sent.lock().unwrap().len(), 2, "nothing was sent for it");
    }

    fn connection() -> (Arc<CdpConnection>, Arc<RecordingWire>) {
        let wire = Arc::new(RecordingWire::default());
        (CdpConnection::new(Box::new(wire.clone())), wire)
    }

    fn wait_for_sent(wire: &RecordingWire, count: usize) -> Vec<Value> {
        for _ in 0..2000 {
            let sent = wire.sent.lock().unwrap().clone();
            if sent.len() >= count {
                return sent;
            }
            thread::yield_now();
            thread::sleep(Duration::from_millis(1));
        }
        panic!("expected {count} sent messages");
    }

    #[test]
    fn replies_match_calls_by_id_and_carry_session() {
        let (conn, wire) = connection();
        let caller = {
            let conn = conn.clone();
            thread::spawn(move || {
                conn.call(
                    Some("S1"),
                    "Page.navigate",
                    json!({"url": "about:blank"}),
                    Duration::from_secs(5),
                )
            })
        };
        let sent = wait_for_sent(&wire, 1);
        assert_eq!(sent[0]["method"], "Page.navigate");
        assert_eq!(sent[0]["sessionId"], "S1");
        let id = sent[0]["id"].as_u64().unwrap();
        conn.receive(&json!({"id": id + 100, "result": {"wrong": true}}).to_string());
        conn.receive(&json!({"id": id, "result": {"frameId": "F"}}).to_string());
        assert_eq!(caller.join().unwrap().unwrap(), json!({"frameId": "F"}));
    }

    #[test]
    fn protocol_errors_map_to_driver_codes() {
        let (conn, wire) = connection();
        let caller = {
            let conn = conn.clone();
            thread::spawn(move || {
                conn.call(None, "DOM.resolveNode", json!({}), Duration::from_secs(5))
            })
        };
        let id = wait_for_sent(&wire, 1)[0]["id"].as_u64().unwrap();
        conn.receive(
            &json!({"id": id, "error": {"code": -32000, "message": "No node with given id found"}})
                .to_string(),
        );
        assert_eq!(caller.join().unwrap().unwrap_err().code, ErrorCode::Stale);
        assert_eq!(protocol_error(&json!({"message": "Target closed"})).code, ErrorCode::Closed);
        assert_eq!(
            protocol_error(&json!({"message": "Cannot find context with specified id"})).code,
            ErrorCode::NotFound
        );
        assert_eq!(
            protocol_error(&json!({"message": "Invalid parameters", "data": "x"})).message,
            "Invalid parameters: x"
        );
    }

    #[test]
    fn events_reach_the_handler_with_their_session() {
        let (conn, _wire) = connection();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        conn.set_event_handler(Arc::new(move |event| sink.lock().unwrap().push(event)));
        conn.receive(
            &json!({"method": "Page.loadEventFired", "params": {"timestamp": 1}, "sessionId": "S"})
                .to_string(),
        );
        conn.receive("not json");
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].method, "Page.loadEventFired");
        assert_eq!(seen[0].session_id.as_deref(), Some("S"));
    }

    #[test]
    fn close_fails_pending_and_later_calls() {
        let (conn, wire) = connection();
        let caller = {
            let conn = conn.clone();
            thread::spawn(move || {
                conn.call(None, "Browser.getVersion", json!({}), Duration::from_secs(5))
            })
        };
        wait_for_sent(&wire, 1);
        conn.close("browser exited");
        let error = caller.join().unwrap().unwrap_err();
        assert_eq!(error.code, ErrorCode::Closed);
        assert_eq!(error.message, "browser exited");
        let later =
            conn.call(None, "Browser.getVersion", json!({}), Duration::from_secs(5)).unwrap_err();
        assert_eq!(later.code, ErrorCode::Closed);
    }

    #[test]
    fn calls_time_out_and_forget_the_waiter() {
        let (conn, _wire) = connection();
        let error =
            conn.call(None, "Page.enable", json!({}), Duration::from_millis(10)).unwrap_err();
        assert_eq!(error.code, ErrorCode::Timeout);
        assert!(conn.pending.lock().unwrap().is_empty());
    }
}
