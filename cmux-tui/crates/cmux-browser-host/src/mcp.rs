//! `cmux-browser-host mcp`: the browser REPL as a Model Context Protocol
//! server on stdio (tools: eval, snapshot, screenshot, tabs, reset), ported
//! from PR #15570's `cmux browser repl mcp` (CLI/CMUXCLI+BrowserRepl.swift,
//! head 3572e03e173). This type only speaks the protocol; tool calls go to a
//! callback, so it is testable without a host.

use serde_json::Value;

/// Tool content and whether it is an error result.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub content: Vec<Value>,
    pub is_error: bool,
}

pub struct McpServer<F> {
    pub version: String,
    pub call_tool: F,
}

impl<F: FnMut(&str, &Value) -> Result<ToolResult, String>> McpServer<F> {
    /// Handles one line; the reply line, or `None` for a notification.
    pub fn handle_line(&mut self, _line: &str) -> Option<String> {
        None
    }
}

#[cfg(test)]
#[path = "mcp_tests.rs"]
mod tests;
