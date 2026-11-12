//! The person's answer to "may cmux add its tools to your coding agents?"
//! (`agents.cmuxMcp`, the onboarding step and Settings > Agents) applied to
//! the `claude` and `codex` shims: the MCP server they pass to an agent
//! started in a cmux terminal (agent_computer_use.rs) goes only while the
//! answer is not `off`. Unanswered (`ask`) keeps what cmux did before the
//! question existed. The hooks are not MCP and are passed either way.

use std::ffi::OsString;
use std::path::Path;

use cmux_tui_core::user_settings::AgentsCmuxMcp;

/// Claude Code's `--mcp-config` value for this launch, or `None` when the
/// person turned cmux's tools off for their agents.
pub(crate) fn claude_mcp_config(
    choice: AgentsCmuxMcp,
    executable: &Path,
    socket: &Path,
) -> Option<OsString> {
    if !choice.injects() {
        return None;
    }
    crate::agent_computer_use::claude_mcp_config(executable, socket)
}

/// Codex `-c` overrides for this launch; none when the person turned cmux's
/// tools off for their agents.
pub(crate) fn codex_settings(
    choice: AgentsCmuxMcp,
    executable: &Path,
    socket: &Path,
) -> Vec<OsString> {
    if !choice.injects() {
        return Vec::new();
    }
    crate::agent_computer_use::codex_settings(executable, socket).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/A/cmux";
    const SOCKET: &str = "/tmp/s.sock";

    fn choice(text: &str) -> AgentsCmuxMcp {
        AgentsCmuxMcp::from_config_text(text)
    }

    #[test]
    fn unset_keeps_passing_the_server_to_both_agents() {
        for text in ["", "{}", r#"{"agents": {"cmuxMcp": "ask"}}"#] {
            let unset = choice(text);
            assert!(
                claude_mcp_config(unset, Path::new(EXE), Path::new(SOCKET)).is_some(),
                "{text}"
            );
            assert!(!codex_settings(unset, Path::new(EXE), Path::new(SOCKET)).is_empty(), "{text}");
        }
    }

    #[test]
    fn on_passes_the_server_to_both_agents() {
        let on = choice(r#"{"agents": {"cmuxMcp": "on"}}"#);
        let config = claude_mcp_config(on, Path::new(EXE), Path::new(SOCKET)).unwrap();
        let value: serde_json::Value = serde_json::from_str(config.to_str().unwrap()).unwrap();
        let servers = value["mcpServers"].as_object().unwrap();
        assert_eq!(servers.len(), 1, "{value}");
        assert!(servers.contains_key(crate::agent_computer_use::SERVER), "{value}");
        let codex = codex_settings(on, Path::new(EXE), Path::new(SOCKET));
        assert!(!codex.is_empty());
        let prefix = format!("mcp_servers.{}.", crate::agent_computer_use::SERVER);
        assert!(codex.iter().all(|s| s.to_str().unwrap().starts_with(&prefix)), "{codex:?}");
    }

    #[test]
    fn off_passes_no_server_to_either_agent() {
        for text in [r#"{"agents": {"cmuxMcp": "off"}}"#, r#"{"agents.cmuxMcp": "off"}"#] {
            let off = choice(text);
            assert_eq!(claude_mcp_config(off, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
            assert!(codex_settings(off, Path::new(EXE), Path::new(SOCKET)).is_empty(), "{text}");
        }
    }
}
