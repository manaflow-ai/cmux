//! Minimal JSON-RPC 2.0 framing over newline-delimited JSON.
//!
//! acpmux keeps every message as a `serde_json::Value` so that unknown
//! methods, `_meta` blocks, and vendor extensions pass through untouched.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// A request id. ACP peers use integers or strings.
pub type Id = Value;

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Request { id: Id, method: String, params: Option<Value> },
    Notification { method: String, params: Option<Value> },
    Response { id: Id, result: Option<Value>, error: Option<RpcError> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl RpcError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), data: None }
    }
    pub fn with_data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new(-32602, message)
    }
    pub fn method_not_found(method: &str) -> Self {
        Self::new(-32601, format!("Method not found: {method}"))
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(-32603, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(-32002, message)
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (code {})", self.message, self.code)
    }
}

impl std::error::Error for RpcError {}

impl Message {
    pub fn parse(line: &str) -> Result<Self, RpcError> {
        let value: Value = serde_json::from_str(line)
            .map_err(|e| RpcError::new(-32700, format!("Parse error: {e}")))?;
        Self::from_value(value)
    }

    pub fn from_value(value: Value) -> Result<Self, RpcError> {
        let obj = value
            .as_object()
            .ok_or_else(|| RpcError::new(-32600, "Invalid request: not an object"))?;
        let method = obj.get("method").and_then(Value::as_str).map(str::to_owned);
        let id = obj.get("id").cloned().filter(|v| !v.is_null());
        match (method, id) {
            (Some(method), Some(id)) => {
                Ok(Message::Request { id, method, params: obj.get("params").cloned() })
            }
            (Some(method), None) => {
                Ok(Message::Notification { method, params: obj.get("params").cloned() })
            }
            (None, Some(id)) => {
                let error = match obj.get("error") {
                    Some(e) if !e.is_null() => Some(
                        serde_json::from_value::<RpcError>(e.clone())
                            .unwrap_or_else(|_| RpcError::internal(e.to_string())),
                    ),
                    _ => None,
                };
                Ok(Message::Response { id, result: obj.get("result").cloned(), error })
            }
            (None, None) => Err(RpcError::new(-32600, "Invalid request: no method or id")),
        }
    }

    pub fn to_value(&self) -> Value {
        match self {
            Message::Request { id, method, params } => {
                let mut v = json!({"jsonrpc": "2.0", "id": id, "method": method});
                if let Some(p) = params {
                    v["params"] = p.clone();
                }
                v
            }
            Message::Notification { method, params } => {
                let mut v = json!({"jsonrpc": "2.0", "method": method});
                if let Some(p) = params {
                    v["params"] = p.clone();
                }
                v
            }
            Message::Response { id, result, error } => match error {
                Some(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
                None => {
                    json!({"jsonrpc": "2.0", "id": id, "result": result.clone().unwrap_or(Value::Null)})
                }
            },
        }
    }

    pub fn to_line(&self) -> String {
        let mut s = self.to_value().to_string();
        s.push('\n');
        s
    }

    pub fn request(id: impl Into<Id>, method: &str, params: Value) -> Self {
        Message::Request { id: id.into(), method: method.to_owned(), params: Some(params) }
    }

    pub fn notification(method: &str, params: Value) -> Self {
        Message::Notification { method: method.to_owned(), params: Some(params) }
    }

    pub fn ok(id: Id, result: Value) -> Self {
        Message::Response { id, result: Some(result), error: None }
    }

    pub fn err(id: Id, error: RpcError) -> Self {
        Message::Response { id, result: None, error: Some(error) }
    }

    pub fn method(&self) -> Option<&str> {
        match self {
            Message::Request { method, .. } | Message::Notification { method, .. } => Some(method),
            Message::Response { .. } => None,
        }
    }

    pub fn params(&self) -> Option<&Value> {
        match self {
            Message::Request { params, .. } | Message::Notification { params, .. } => {
                params.as_ref()
            }
            Message::Response { .. } => None,
        }
    }
}

/// ACP method names used by acpmux. Kept as constants so the wire is explicit.
pub mod method {
    pub const INITIALIZE: &str = "initialize";
    pub const AUTHENTICATE: &str = "authenticate";
    pub const SESSION_NEW: &str = "session/new";
    pub const SESSION_LOAD: &str = "session/load";
    pub const SESSION_RESUME: &str = "session/resume";
    pub const SESSION_LIST: &str = "session/list";
    pub const SESSION_FORK: &str = "session/fork";
    pub const SESSION_CLOSE: &str = "session/close";
    pub const SESSION_DELETE: &str = "session/delete";
    pub const SESSION_PROMPT: &str = "session/prompt";
    pub const SESSION_CANCEL: &str = "session/cancel";
    pub const SESSION_SET_MODE: &str = "session/set_mode";
    pub const SESSION_SET_MODEL: &str = "session/set_model";
    pub const SESSION_SET_CONFIG_OPTION: &str = "session/set_config_option";
    pub const SESSION_UPDATE: &str = "session/update";
    pub const SESSION_REQUEST_PERMISSION: &str = "session/request_permission";
    pub const CANCEL_REQUEST: &str = "$/cancel_request";

    // acpmux extension namespace. Everything a plain ACP client does not need.
    pub const MUX_STATUS: &str = "_acpmux/status";
    pub const MUX_SESSIONS: &str = "_acpmux/sessions";
    pub const MUX_HARNESSES: &str = "_acpmux/harnesses";
    /// Reload catalog configuration without touching existing sessions.
    pub const MUX_RELOAD_CONFIG: &str = "_acpmux/reload_config";
    pub const MUX_DEFAULTS: &str = "_acpmux/defaults";
    /// Client-side only: the reader puts this on the notification stream
    /// when the daemon closes the socket, so stream consumers notice.
    pub const MUX_DISCONNECTED: &str = "_acpmux/disconnected";
    pub const MUX_PRESETS: &str = "_acpmux/presets";
    pub const MUX_ATTACH: &str = "_acpmux/attach";
    pub const MUX_DETACH: &str = "_acpmux/detach";
    pub const MUX_WATCH: &str = "_acpmux/watch";
    pub const MUX_RENAME: &str = "_acpmux/rename";
    pub const MUX_KILL: &str = "_acpmux/kill";
    pub const MUX_INFO: &str = "_acpmux/info";
    pub const MUX_EVENTS: &str = "_acpmux/events";
    pub const MUX_PERMISSION_RESPOND: &str = "_acpmux/permission_respond";
    pub const MUX_SET_POLICY: &str = "_acpmux/set_policy";
    pub const MUX_SET_RULES: &str = "_acpmux/set_rules";
    pub const MUX_TAG: &str = "_acpmux/tag";
    pub const MUX_WAIT: &str = "_acpmux/wait";
    pub const MUX_HISTORY: &str = "_acpmux/history";
    pub const MUX_SCHEMA: &str = "_acpmux/schema";
    pub const MUX_EXPORT: &str = "_acpmux/export";
    pub const MUX_IMPORT: &str = "_acpmux/import";
    pub const MUX_SHUTDOWN: &str = "_acpmux/shutdown";
    // Notifications from acpmux to attached clients.
    pub const MUX_EVENT: &str = "_acpmux/event";
    pub const MUX_SESSION_CHANGED: &str = "_acpmux/session_changed";
    pub const MUX_PERMISSION_PENDING: &str = "_acpmux/permission_pending";
    /// Sent to the prompting connection as soon as a `session/prompt` is
    /// recorded, before the turn ends: `{sessionId, promptId, turnId, queued}`.
    pub const MUX_PROMPT_ACCEPTED: &str = "_acpmux/prompt_accepted";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_request() {
        let m = Message::request(1, "session/prompt", json!({"sessionId": "s"}));
        let back = Message::parse(&m.to_line()).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn parses_error_response() {
        let m = Message::parse(r#"{"jsonrpc":"2.0","id":3,"error":{"code":-1,"message":"x"}}"#)
            .unwrap();
        match m {
            Message::Response { error: Some(e), .. } => assert_eq!(e.code, -1),
            _ => panic!("expected error response"),
        }
    }

    #[test]
    fn notification_has_no_id() {
        let m =
            Message::parse(r#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#).unwrap();
        assert!(matches!(m, Message::Notification { .. }));
    }
}
