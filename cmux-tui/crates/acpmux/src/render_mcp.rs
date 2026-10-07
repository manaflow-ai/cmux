//! The render server acpmux gives every agent session it starts: `cmux mcp
//! serve --render-only`, whose one tool, `render`, shows the user a live HTML
//! page in the thread (the agent pane draws the call in a sandboxed frame with
//! no network). It owns nothing and reaches nothing, so it needs no setting;
//! the rest of `cmux mcp` stays behind `mcp.enabled` (plans/cmux-next/mcp.md).
//!
//! agent_tools.rs adds it with cmux's other tools, from the same `cmux` (the
//! app's `Contents/Resources/bin`), and leaves it out where it leaves them out:
//! remote-origin sessions, `ACPMUX_AGENT_TOOLS=0` and `--strict-mcp-config`.

/// The server's name in an agent's MCP list.
pub const SERVER_NAME: &str = "cmux-render";
/// The tool as Claude names it, for `--allowedTools`.
pub const CLAUDE_TOOL: &str = "mcp__cmux-render__render";
/// `cmux` arguments that start the server.
pub const ARGS: [&str; 3] = ["mcp", "serve", "--render-only"];
