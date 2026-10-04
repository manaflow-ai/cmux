//! Host-only ops on the server's JSON-lines channel: requests this server
//! sends to its host (the app supervisor) and the host's answers and
//! events. One frame shape for every host-only op (`cmux.host.link.get`,
//! `cmux.terminal.connector.open`; `cmux.credential.relay` later):
//!
//! - server -> host: `{"t":"host.request","id":n,"op":"...","params":{}}`
//! - host -> server: `{"t":"host.result","id":n,"value":{...}}` or
//!   `{"t":"host.error","id":n,"code":"...","message":"...","retryable":bool}`
//! - host -> server: `{"t":"host.event","op":"...","data":{...}}`
//!
//! Each op the server uses must be a server scope in the manifest
//! (`op:<name>` in `server.scopes`). At most one request per op waits at a
//! time, so the waiting set and the outbox are bounded by the number of
//! ops; the one exception, [`HostRequests::request_each`], is bounded by
//! its caller (frame link opens: crate::connector::frames::MAX_FRAME_LINKS). Host frames arrive through the serve loop's inbox; only the loop
//! thread reads or changes this state. No timer: an answer that never
//! comes leaves the op waiting, and the op's users report it unavailable.

use serde_json::{Value, json};
use std::collections::BTreeMap;

/// `cmux.host.link.get {}` -> `{binary, hub_socket, state_dir, socket_dir, device_name}`.
pub const LINK_GET: &str = "cmux.host.link.get";
/// `cmux.host.link.changed`: the same shape as the `link.get` answer.
pub const LINK_CHANGED: &str = "cmux.host.link.changed";

/// The code of a host answer that was not well formed.
pub const MALFORMED: &str = "cmux.cloud.host_answer_invalid";

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
    /// The answer to request `id` of `op`.
    Result { op: String, id: u64, value: Value },
    /// The error answer to request `id` of `op`.
    Error { op: String, id: u64, error: HostError },
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

    /// Queues one `host.request` for `op` even when others of `op` wait
    /// (one per target, such as `cmux.terminal.connector.open`); the caller
    /// bounds how many wait. Returns the request id.
    pub fn request_each(&mut self, op: &str, params: Value) -> u64 {
        self.next_id += 1;
        self.waiting.insert(self.next_id, op.to_owned());
        self.outbox
            .push(json!({ "t": "host.request", "id": self.next_id, "op": op, "params": params }));
        self.next_id
    }

    /// Whether a request of `op` waits for its answer.
    pub fn is_waiting(&self, op: &str) -> bool {
        self.waiting.values().any(|waiting| waiting == op)
    }

    /// Forgets the waiting request of `op` (a newer event replaced what its
    /// answer would say), so a late answer to it is dropped.
    pub fn cancel(&mut self, op: &str) {
        self.waiting.retain(|_, waiting| waiting != op);
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
                let Some(op) = self.waiting.remove(&id) else {
                    return Err(format!("a host answer to no waiting request ({id})"));
                };
                // A malformed answer still ends its request (no request
                // waits forever): it becomes a typed, final error.
                let malformed = |op: String, why: &str| HostFrame::Error {
                    op,
                    id,
                    error: HostError {
                        code: MALFORMED.to_owned(),
                        message: why.to_owned(),
                        retryable: false,
                    },
                };
                if kind == "host.result" {
                    return Ok(match line.get("value") {
                        Some(value) => HostFrame::Result { op, id, value: value.clone() },
                        None => malformed(op, "a host.result without a value"),
                    });
                }
                let code = line.get("code").and_then(Value::as_str).filter(|c| !c.is_empty());
                let Some(code) = code else {
                    return Ok(malformed(op, "a host.error without a code"));
                };
                let message = line.get("message").and_then(Value::as_str).unwrap_or_default();
                Ok(HostFrame::Error {
                    op,
                    id,
                    error: HostError {
                        code: cut(code, MAX_CODE),
                        message: cut(message, MAX_MESSAGE),
                        retryable: line.get("retryable").and_then(Value::as_bool).unwrap_or(false),
                    },
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
