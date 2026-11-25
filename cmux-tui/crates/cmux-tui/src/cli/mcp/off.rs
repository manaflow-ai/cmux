//! `cmux mcp serve` while the settings file keeps the server off for this
//! client (`refusal`). It still completes the MCP handshake: a server that
//! exits before `initialize` shows in the agent as a bare "connection closed"
//! (Claude Code's `/mcp`: CONNECTION_CLOSED), which tells the person nothing.
//! Instead it answers `initialize` with the reason as its instructions, lists
//! one tool ([`TOOL`]) whose description is the reason, and answers every
//! tool call with the reason as an error.
//!
//! It holds no backend, no upstream and no watcher: no cmux tool can run
//! through it, whatever the client sends.

use std::io::{BufRead, Read as _};

use serde_json::{Value, json};

use super::watch::Output;
use super::{MAX_MESSAGE_BYTES, envelope, error_response, tool_error};

/// The one tool the off server lists. Calling it runs nothing.
pub(super) const TOOL: &str = "cmux_tools_off";

/// The server's answers while it is off, all carrying `message` (why it is
/// off and how the person turns it on).
pub(super) struct Off {
    message: String,
}

impl Off {
    pub(super) fn new(message: String) -> Self {
        Self { message }
    }

    /// Answers each line of `input` on `output` until stdin closes.
    pub(super) fn run(&self, mut input: impl BufRead, output: &Output) -> i32 {
        let mut line = Vec::new();
        loop {
            line.clear();
            match input.by_ref().take(MAX_MESSAGE_BYTES as u64 + 1).read_until(b'\n', &mut line) {
                Ok(0) => return 0,
                Ok(_) => {}
                Err(error) => {
                    eprintln!("cmux mcp: cannot read stdin: {error}");
                    return 1;
                }
            }
            if line.len() > MAX_MESSAGE_BYTES {
                let _ = output.send(&error_response(Value::Null, -32600, "message exceeds 8 MiB"));
                return 1;
            }
            let text = line.trim_ascii();
            if text.is_empty() {
                continue;
            }
            let response = match serde_json::from_slice::<Value>(text) {
                Ok(message) => self.handle(&message),
                Err(error) => Some(error_response(Value::Null, -32700, &format!("{error}"))),
            };
            if let Some(response) = response
                && output.send(&response).is_err()
            {
                return 0;
            }
        }
    }

    /// One JSON-RPC message; `None` for a notification or a client response.
    pub(super) fn handle(&self, message: &Value) -> Option<Value> {
        let Some(object) = message.as_object() else {
            return Some(error_response(Value::Null, -32600, "expected a JSON-RPC object"));
        };
        let id = object.get("id").cloned();
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            if object.contains_key("result") || object.contains_key("error") {
                return None;
            }
            return Some(error_response(id.unwrap_or(Value::Null), -32600, "missing method"));
        };
        let id = id?;
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        let result = match method {
            "initialize" => json!({
                "protocolVersion": acpmux::secret_mcp::protocol_version(&params),
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "cmux", "title": "cmux", "version": env!("CARGO_PKG_VERSION")},
                "instructions": self.message,
            }),
            "ping" => json!({}),
            "tools/list" => json!({"tools": [self.descriptor()]}),
            "tools/call" => self.refused(),
            _ => return Some(error_response(id, -32601, &format!("method not found: {method}"))),
        };
        Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
    }

    fn descriptor(&self) -> Value {
        json!({
            "name": TOOL,
            "title": "cmux tools are off",
            "description": self.message,
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
            "annotations": {"readOnlyHint": true, "openWorldHint": false},
        })
    }

    /// Every tool call, of any name: not run, and why.
    fn refused(&self) -> Value {
        let error = json!({
            "code": "mcp.disabled",
            "message": self.message,
            "details": {},
            "retryable": false,
        });
        let mut result = tool_error(envelope(error, "not_run", None));
        // The reason as plain text first, so a client that shows only the
        // first text block shows the sentence, not the JSON envelope.
        if let Some(content) = result.get_mut("content").and_then(Value::as_array_mut) {
            content.insert(0, json!({"type": "text", "text": self.message}));
        }
        result
    }
}
