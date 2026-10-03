//! `cmux-browser-host mcp`: the browser REPL as a Model Context Protocol
//! server on stdio (tools: eval, snapshot, screenshot, tabs, reset), ported
//! from PR #15570's `cmux browser repl mcp` (CLI/CMUXCLI+BrowserRepl.swift,
//! head 3572e03e173). This type only speaks the protocol; tool calls go to a
//! callback, so it is testable without a host.

use serde_json::{Value, json};

/// Newest first; `initialize` echoes the client's version when listed.
pub const PROTOCOL_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

/// Tool content and whether it is an error result.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn text(text: String, is_error: bool) -> ToolResult {
        ToolResult { content: vec![json!({"type": "text", "text": text})], is_error }
    }
}

pub struct McpServer<F> {
    pub version: String,
    pub call_tool: F,
}

/// The tool list (names, descriptions and schemas as in #15570).
pub fn tools() -> Value {
    json!([
        {
            "name": "eval",
            "description": "Run JavaScript in the cmux browser REPL session (Playwright API: page, tabs, snapshot, screenshot, locators; top-level await; const/let persist across calls). Returns what the code printed and the last expression's value. Run `session.guide()` for the full guide.",
            "inputSchema": {"type": "object", "properties": {"code": {"type": "string", "description": "JavaScript to evaluate"}}, "required": ["code"]},
        },
        {
            "name": "snapshot",
            "description": "Accessibility snapshot of the current tab with refs (e12, f1e3) usable as locators in eval. Prints the diff against the previous snapshot when that is shorter.",
            "inputSchema": {"type": "object", "properties": {
                "target": {"type": "string", "description": "A ref or selector to scope the snapshot to"},
                "interactive": {"type": "boolean", "description": "Only interactive elements and the page outline"},
                "viewport": {"type": "boolean", "description": "Only elements in the viewport"},
            }},
        },
        {
            "name": "screenshot",
            "description": "PNG of the current tab's viewport, the full page, or one element.",
            "inputSchema": {"type": "object", "properties": {
                "target": {"type": "string", "description": "A ref or selector to capture"},
                "fullPage": {"type": "boolean", "description": "Capture the whole page"},
            }},
        },
        {
            "name": "tabs",
            "description": "The session's tabs: id, title, URL and which one is current.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "reset",
            "description": "End the REPL session: close its tabs and forget its variables.",
            "inputSchema": {"type": "object", "properties": {}},
        },
    ])
}

fn literal(text: &str) -> String {
    Value::String(text.to_owned()).to_string()
}

/// REPL code for the tools that are one evaluation.
pub fn code_for_tool(name: &str, arguments: &Value) -> Option<String> {
    match name {
        "eval" => arguments.get("code").and_then(Value::as_str).map(str::to_owned),
        "snapshot" => {
            let target = arguments
                .get("target")
                .and_then(Value::as_str)
                .map(literal)
                .unwrap_or_else(|| "undefined".into());
            let interactive =
                arguments.get("interactive").and_then(Value::as_bool).unwrap_or(false);
            let viewport = arguments.get("viewport").and_then(Value::as_bool).unwrap_or(false);
            Some(format!(
                "await snapshot({target}, {{ interactive: {interactive}, viewport: {viewport} }})"
            ))
        }
        "tabs" => Some("await tabs.list()".into()),
        _ => None,
    }
}

/// REPL code that prints the screenshot as `marker` + base64 on one line.
pub fn screenshot_code(arguments: &Value, marker: &str) -> String {
    let capture = match arguments.get("target").and_then(Value::as_str).filter(|t| !t.is_empty()) {
        Some(target) => format!("await page.locator({}).screenshot()", literal(target)),
        None => {
            let full_page = arguments.get("fullPage").and_then(Value::as_bool).unwrap_or(false);
            format!("await page.screenshot({{ fullPage: {full_page} }})")
        }
    };
    format!("console.log({} + ({capture}).toString(\"base64\")); undefined", literal(marker))
}

fn output_lines(payload: &Value) -> Vec<String> {
    payload["output"].as_str().unwrap_or("").lines().map(str::to_owned).collect()
}

/// A `browser.repl.eval` result as tool content: the printed lines, then the
/// uncaught error, if any, as an error result, then the status line.
pub fn result_of_eval(payload: &Value) -> ToolResult {
    let mut lines = output_lines(payload);
    let duration = payload["durationMs"].as_u64().unwrap_or(0);
    match payload["error"].as_str() {
        Some(error) => {
            lines.push(error.to_owned());
            lines.push(format!("[error | {duration}ms]"));
            ToolResult::text(lines.join("\n"), true)
        }
        None => {
            lines.push(format!("[ok | {duration}ms]"));
            ToolResult::text(lines.join("\n"), false)
        }
    }
}

/// A screenshot evaluation as an image (the last line that starts with `marker`).
pub fn screenshot_result(payload: &Value, marker: &str) -> ToolResult {
    let lines = output_lines(payload);
    if let Some(error) = payload["error"].as_str() {
        let mut text = lines;
        text.push(error.to_owned());
        return ToolResult::text(text.join("\n").trim_start_matches('\n').to_owned(), true);
    }
    match lines.iter().rev().find(|line| line.starts_with(marker)) {
        Some(line) => ToolResult {
            content: vec![
                json!({"type": "image", "data": &line[marker.len()..], "mimeType": "image/png"}),
            ],
            is_error: false,
        },
        None => ToolResult::text(lines.join("\n"), true),
    }
}

fn reply(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

impl<F: FnMut(&str, &Value) -> Result<ToolResult, String>> McpServer<F> {
    /// Handles one line; the reply line, or `None` for a notification.
    pub fn handle_line(&mut self, line: &str) -> Option<String> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return None;
        }
        match serde_json::from_str::<Value>(trimmed) {
            Ok(message) if message.is_object() => {
                self.handle(&message).map(|reply| reply.to_string())
            }
            _ => Some(error(Value::Null, -32700, "Parse error").to_string()),
        }
    }

    /// Handles one message; `None` for a notification or a client response.
    pub fn handle(&mut self, message: &Value) -> Option<Value> {
        let id = message.get("id").cloned();
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            let id = id?;
            if message.get("result").is_some() || message.get("error").is_some() {
                return None;
            }
            return Some(error(id, -32600, "Invalid Request"));
        };
        let id = id.filter(|id| !id.is_null())?;
        let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
        Some(match method {
            "initialize" => {
                let requested = params.get("protocolVersion").and_then(Value::as_str).unwrap_or("");
                let version = PROTOCOL_VERSIONS
                    .iter()
                    .find(|v| **v == requested)
                    .copied()
                    .unwrap_or(PROTOCOL_VERSIONS[0]);
                reply(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": {"tools": {"listChanged": false}},
                        "serverInfo": {"name": "cmux-browser-repl", "version": self.version},
                        "instructions": "Drive cmux browser tabs with Playwright-style JavaScript through the eval tool; read pages with snapshot and act on its refs.",
                    }),
                )
            }
            "ping" => reply(id, json!({})),
            "tools/list" => reply(id, json!({"tools": tools()})),
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(error(id, -32602, "tools/call needs a tool name"));
                };
                let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                let known =
                    tools().as_array().is_some_and(|list| list.iter().any(|t| t["name"] == name));
                if !known {
                    return Some(error(id, -32602, &format!("Unknown tool: {name}")));
                }
                if name == "eval" && arguments.get("code").and_then(Value::as_str).is_none() {
                    return Some(error(id, -32602, "eval needs code, a string"));
                }
                let result = (self.call_tool)(name, &arguments)
                    .unwrap_or_else(|message| ToolResult::text(message, true));
                reply(id, json!({"content": result.content, "isError": result.is_error}))
            }
            other => error(id, -32601, &format!("Method not found: {other}")),
        })
    }
}

#[cfg(test)]
#[path = "mcp_tests.rs"]
mod tests;
