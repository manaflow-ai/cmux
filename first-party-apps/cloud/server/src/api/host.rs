//! Host-only ops on the server's JSON-lines channel: requests this server
//! sends to its host (the app supervisor) and the host's answers and
//! events. One frame shape for every host-only op (`cmux.host.link.get`
//! now; `cmux.credential.relay` later):
//!
//! - server -> host: `{"t":"host.request","id":n,"op":"...","params":{}}`
//! - host -> server: `{"t":"host.result","id":n,"value":{...}}` or
//!   `{"t":"host.error","id":n,"code":"...","message":"...","retryable":bool}`
//! - host -> server: `{"t":"host.event","op":"...","data":{...}}`
//!
//! Each op the server uses must be a server scope in the manifest
//! (`op:<name>` in `server.scopes`). At most one request per op waits at a
//! time, so the waiting set and the outbox are bounded by the number of
//! ops. Host frames arrive through the serve loop's inbox; only the loop
//! thread reads or changes this state. No timer: an answer that never
//! comes leaves the op waiting, and the op's users report it unavailable.

use serde_json::{Value, json};
use std::collections::BTreeMap;

/// `cmux.host.link.get {}` -> `{binary, hub_socket, state_dir, socket_dir, device_name}`.
pub const LINK_GET: &str = "cmux.host.link.get";
/// `cmux.host.link.changed`: the same shape as the `link.get` answer.
pub const LINK_CHANGED: &str = "cmux.host.link.changed";

/// Longest host error code and message kept (display text only).
const MAX_CODE: usize = 128;
const MAX_MESSAGE: usize = 2048;

/// A `host.error` answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostError {
    pub code: String,
    pub message: String,
    /// A new request may work; the op's user decides when to send one.
    pub retryable: bool,
}

/// One decoded host frame.
#[derive(Debug, Clone, PartialEq)]
pub enum HostFrame {
    /// The answer to a request of `op`.
    Result { op: String, value: Value },
    /// The error answer to a request of `op`.
    Error { op: String, error: HostError },
    /// An event the host sends unasked.
    Event { op: String, data: Value },
}

/// Whether `line` is a host frame (`t` starts with `host.`).
pub fn is_host_frame(line: &Value) -> bool {
    line.get("t").and_then(Value::as_str).is_some_and(|t| t.starts_with("host."))
}

fn cut(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

/// The requests this server sent that wait for an answer, and the frames
/// to send.
#[derive(Debug, Default)]
pub struct HostRequests {
    next_id: u64,
    waiting: BTreeMap<u64, String>,
    outbox: Vec<Value>,
}

impl HostRequests {
    /// Queues one `host.request` for `op`, unless one already waits.
    /// Returns whether a request was queued.
    pub fn request(&mut self, op: &str, params: Value) -> bool {
        if self.is_waiting(op) {
            return false;
        }
        self.next_id += 1;
        self.waiting.insert(self.next_id, op.to_owned());
        self.outbox
            .push(json!({ "t": "host.request", "id": self.next_id, "op": op, "params": params }));
        true
    }

    /// Whether a request of `op` waits for its answer.
    pub fn is_waiting(&self, op: &str) -> bool {
        self.waiting.values().any(|waiting| waiting == op)
    }

    /// The frames to send, in order.
    pub fn take_outbox(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.outbox)
    }

    /// Decodes one host line. `Err` names why a line is dropped: it is
    /// malformed, or it answers no waiting request (late, unknown or
    /// repeated), so it can never be taken for another request's answer.
    pub fn accept(&mut self, line: &Value) -> Result<HostFrame, String> {
        let kind = line.get("t").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "host.result" | "host.error" => {
                let id = line
                    .get("id")
                    .and_then(Value::as_u64)
                    .ok_or("a host answer without a numeric id")?;
                if !self.waiting.contains_key(&id) {
                    return Err(format!("a host answer to no waiting request ({id})"));
                }
                let frame = if kind == "host.result" {
                    let value =
                        line.get("value").cloned().ok_or("a host.result without a value")?;
                    HostFrame::Result { op: String::new(), value }
                } else {
                    let code = line.get("code").and_then(Value::as_str).filter(|c| !c.is_empty());
                    let code = code.ok_or("a host.error without a code")?;
                    HostFrame::Error {
                        op: String::new(),
                        error: HostError {
                            code: cut(code, MAX_CODE),
                            message: cut(
                                line.get("message").and_then(Value::as_str).unwrap_or_default(),
                                MAX_MESSAGE,
                            ),
                            retryable: line
                                .get("retryable")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                        },
                    }
                };
                // The request is answered only by a well-formed frame.
                let op = self.waiting.remove(&id).unwrap_or_default();
                Ok(match frame {
                    HostFrame::Result { value, .. } => HostFrame::Result { op, value },
                    HostFrame::Error { error, .. } => HostFrame::Error { op, error },
                    event @ HostFrame::Event { .. } => event,
                })
            }
            "host.event" => {
                let op =
                    line.get("op").and_then(Value::as_str).ok_or("a host.event without an op")?;
                Ok(HostFrame::Event {
                    op: op.to_owned(),
                    data: line.get("data").cloned().unwrap_or(Value::Null),
                })
            }
            other => Err(format!("an unknown host frame {other:?}")),
        }
    }
}
