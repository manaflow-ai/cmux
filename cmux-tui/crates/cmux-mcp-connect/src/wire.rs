//! The MCP Streamable HTTP messages a connect needs (`initialize`, `tools/list`) and the
//! reading of their replies, which come as JSON or as a `text/event-stream`. Pure: the daemon
//! sends and receives; this module builds the bodies and reads what came back.

use crate::Refusal;
use crate::classify::{Policy, ToolKind, classify, default_policy};
use crate::screen::{Flag, screen_tool};
use serde_json::{Value, json};

/// The MCP protocol version cmux asks for.
pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// The most tools one server may list; more is refused (a list that big is not a tool set).
pub const MAX_TOOLS: usize = 500;
/// The most `tools/list` pages read.
pub const MAX_PAGES: usize = 20;
/// The largest reply body read, in bytes.
pub const MAX_REPLY_BYTES: usize = 4 * 1024 * 1024;

/// The `initialize` request.
pub fn initialize_body(id: u64) -> Value {
    json!({
        "jsonrpc": "2.0", "id": id, "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "cmux", "version": "1"},
        },
    })
}

/// The `notifications/initialized` notice sent after `initialize`.
pub fn initialized_note() -> Value {
    json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
}

/// One `tools/list` page.
pub fn tools_list_body(id: u64, cursor: Option<&str>) -> Value {
    match cursor {
        Some(c) => {
            json!({"jsonrpc": "2.0", "id": id, "method": "tools/list", "params": {"cursor": c}})
        }
        None => json!({"jsonrpc": "2.0", "id": id, "method": "tools/list", "params": {}}),
    }
}

/// A `tools/call` request for the server's own tool `name`.
pub fn tools_call_body(id: u64, name: &str, arguments: &Value) -> Value {
    let arguments = if arguments.is_object() { arguments.clone() } else { json!({}) };
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
}

/// The `result` of the reply with `id`, from a JSON body or an event stream. A JSON-RPC error,
/// a missing reply or a body too large is refused.
pub fn reply_result(content_type: &str, body: &str, id: u64) -> Result<Value, Refusal> {
    if body.len() > MAX_REPLY_BYTES {
        return Err(Refusal::new("the server's reply is too large"));
    }
    let messages: Vec<Value> = if content_type.to_ascii_lowercase().starts_with("text/event-stream")
    {
        sse_messages(body)
    } else {
        match serde_json::from_str::<Value>(body) {
            Ok(Value::Array(items)) => items,
            Ok(one) => vec![one],
            Err(_) => return Err(Refusal::new("the server's reply is not JSON")),
        }
    };
    let reply = messages
        .into_iter()
        .find(|m| m.get("id").and_then(Value::as_u64) == Some(id))
        .ok_or_else(|| Refusal::new("the server sent no reply to the request"))?;
    if let Some(err) = reply.get("error") {
        let text = err.get("message").and_then(Value::as_str).unwrap_or("error");
        let text: String = text.chars().take(200).collect();
        return Err(Refusal(format!("the server answered with an error: {text}")));
    }
    reply.get("result").cloned().ok_or_else(|| Refusal::new("the server's reply has no result"))
}

/// The JSON messages of an event stream: each event's `data:` lines joined.
fn sse_messages(body: &str) -> Vec<Value> {
    let mut out = Vec::new();
    let mut data = String::new();
    for line in body.lines().chain(std::iter::once("")) {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.is_empty() {
            if !data.is_empty() {
                if let Ok(v) = serde_json::from_str::<Value>(&data) {
                    out.push(v);
                }
                data.clear();
            }
        } else if let Some(rest) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(rest.strip_prefix(' ').unwrap_or(rest));
        }
    }
    out
}

/// The tools of one `tools/list` result and its next cursor.
pub fn tools_page(result: &Value) -> Result<(Vec<Value>, Option<String>), Refusal> {
    let tools = result
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| Refusal::new("the tool list has no tools array"))?;
    if tools.iter().any(|t| t.get("name").and_then(Value::as_str).is_none()) {
        return Err(Refusal::new("a listed tool has no name"));
    }
    let next = result.get("nextCursor").and_then(Value::as_str).map(str::to_owned);
    Ok((tools.clone(), next))
}

fn kind_word(kind: ToolKind) -> &'static str {
    match kind {
        ToolKind::Read => "read",
        ToolKind::Write => "write",
        ToolKind::Destructive => "destructive",
    }
}

fn policy_word(policy: Policy) -> &'static str {
    match policy {
        Policy::Always => "always",
        Policy::Ask => "ask",
        Policy::Never => "never",
    }
}

/// The rule a flag broke, by name only: the matched words are the server's text and stay out of
/// the card and the agent's context (T9).
fn flag_word(flag: &Flag) -> &'static str {
    match flag {
        Flag::Instruction(_) => "instruction",
        Flag::SecretPath(_) => "secretPath",
        Flag::HiddenCharacters => "hiddenCharacters",
        Flag::TooLong(_) => "tooLong",
    }
}

/// What the card shows for each tool: name, kind, starting policy and screen flags. The tool's
/// own description is not echoed (it is the server's text, T9).
pub fn tool_report(tools: &[Value]) -> Vec<Value> {
    tools
        .iter()
        .map(|t| {
            let flags = screen_tool(t);
            let kind = classify(t);
            json!({
                "name": t.get("name").and_then(Value::as_str).unwrap_or_default(),
                "kind": kind_word(kind),
                "policy": policy_word(default_policy(kind, !flags.is_empty())),
                "flags": flags.iter().map(flag_word).collect::<Vec<_>>(),
            })
        })
        .collect()
}
