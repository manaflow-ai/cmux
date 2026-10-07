//! The render server acpmux gives every agent session it starts: `cmux mcp
//! serve --render-only`, whose one tool, `render`, shows the user a live HTML
//! page in the thread (the agent pane draws the call in a sandboxed frame with
//! no network). It owns nothing and reaches nothing, so it needs no setting;
//! the rest of `cmux mcp` stays behind `mcp.enabled` (plans/cmux-next/mcp.md).
//!
//! The `cmux` it runs is the one beside acpmux (both ship in the app's
//! `Contents/Resources/bin`). Without one, sessions start with no server.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The server's name in an agent's MCP list.
pub const SERVER_NAME: &str = "cmux-render";
/// The tool as Claude names it, for `--allowedTools`.
pub const CLAUDE_TOOL: &str = "mcp__cmux-render__render";
const ARGS: [&str; 3] = ["mcp", "serve", "--render-only"];

/// The `cmux` beside the running acpmux, when there is one.
pub fn cmux_beside_acpmux() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    cmux_beside(&exe)
}

fn cmux_beside(exe: &Path) -> Option<PathBuf> {
    let cmux = exe.parent()?.join("cmux");
    cmux.is_file().then_some(cmux)
}

/// ACP `mcpServers` for `session/new`, `session/load` and `session/fork`.
pub fn acp_servers() -> Value {
    acp_servers_for(cmux_beside_acpmux().as_deref())
}

fn acp_servers_for(cmux: Option<&Path>) -> Value {
    match cmux {
        Some(cmux) => json!([{
            "name": SERVER_NAME,
            "command": cmux,
            "args": ARGS,
            "env": [],
        }]),
        None => json!([]),
    }
}

/// Claude's `--mcp-config` value, or nil when there is no `cmux`.
pub fn claude_config() -> Option<String> {
    claude_config_for(cmux_beside_acpmux().as_deref())
}

fn claude_config_for(cmux: Option<&Path>) -> Option<String> {
    let cmux = cmux?;
    Some(json!({"mcpServers": {SERVER_NAME: {"command": cmux, "args": ARGS}}}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_server_runs_the_cmux_beside_acpmux_and_none_without_one() {
        let dir = std::env::temp_dir().join(format!("acpmux-render-mcp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("acpmux");
        assert_eq!(cmux_beside(&exe), None);
        std::fs::write(dir.join("cmux"), b"").unwrap();
        let cmux = cmux_beside(&exe).expect("cmux beside acpmux");
        assert_eq!(cmux, dir.join("cmux"));
        assert_eq!(
            acp_servers_for(Some(&cmux)),
            json!([{"name": "cmux-render", "command": cmux, "args": ["mcp", "serve", "--render-only"], "env": []}])
        );
        let config: Value = serde_json::from_str(&claude_config_for(Some(&cmux)).unwrap()).unwrap();
        assert_eq!(config["mcpServers"]["cmux-render"]["args"], json!(["mcp", "serve", "--render-only"]));
        assert_eq!(acp_servers_for(None), json!([]));
        assert_eq!(claude_config_for(None), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
