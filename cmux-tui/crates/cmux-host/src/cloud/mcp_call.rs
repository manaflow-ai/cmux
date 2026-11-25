//! cmux Cloud's hosted MCP server (the platform's `/mcp`) for this machine's agent sessions,
//! through the agent socket, so the machine's `vm-self` bearer never leaves this agent. acpmux's
//! `hosted-mcp` bridge sends each JSON-RPC message it reads from the harness as one line:
//!
//! - `{"mcp.call": {"body": <JSON-RPC message>}}`: the agent checks the message (JSON-RPC 2.0,
//!   one of the methods below, at most 60 KiB, under the socket's 64 KiB line), POSTs it to the environment's platform `/mcp`
//!   as this machine's bound VM install and answers `{ok: true, status, body}`, or a refusal
//!   (`vm.unbound`, `request.invalid`, `integration.unreachable`).
//!
//! Known limit: the minter thread answers asks one at a time, each under the transport's 20 s
//! bound, so a tool call the platform takes longer than that to answer comes back as
//! `integration.unreachable`, and a long call delays the asks queued behind it.

use serde_json::{Value, json};

use super::github::refusal;
use super::sender::Answer;

/// The socket line key.
pub const CALL_KEY: &str = "mcp.call";
/// The platform route the call is sent to.
pub const MCP_PATH: &str = "/mcp";
/// The MCP protocol version the bridge speaks to the platform: its stateless JSON answers.
pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// The only methods sent.
pub const METHODS: [&str; 5] =
    ["initialize", "notifications/initialized", "ping", "tools/list", "tools/call"];
/// Under the agent socket's 64 KiB line, with room for the `mcp.call` wrapper.
pub const MAX_BODY: usize = 60 * 1024;

/// One checked `mcp.call`: the JSON-RPC message to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McpCall {
    pub body: Value,
}

/// The `mcp.call` object of a socket line, checked.
pub fn check_call(value: &Value) -> Result<McpCall, String> {
    let Some(body @ Value::Object(message)) = value.get("body") else {
        return Err("mcp.call body must be a JSON-RPC object".to_owned());
    };
    if message.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Err("mcp.call body must be JSON-RPC 2.0".to_owned());
    }
    let method = message.get("method").and_then(Value::as_str).unwrap_or_default();
    if !METHODS.contains(&method) {
        return Err(format!("mcp.call method must be one of {}", METHODS.join(", ")));
    }
    if body.to_string().len() > MAX_BODY {
        return Err("mcp.call body is over 60 KiB".to_owned());
    }
    Ok(McpCall { body: body.clone() })
}

/// The headers the platform's MCP route needs on every call.
pub fn headers() -> [(&'static str, &'static str); 2] {
    [("accept", "application/json, text/event-stream"), ("mcp-protocol-version", PROTOCOL_VERSION)]
}

/// The reply line for the platform's answer: its status and body, never the bearer.
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status, body } => json!({ "ok": true, "status": status, "body": body }),
        Answer::Transport => refusal(
            "integration.unreachable",
            "cmux Cloud's MCP server did not answer in time; check this machine's connection and retry.",
        ),
    }
}
