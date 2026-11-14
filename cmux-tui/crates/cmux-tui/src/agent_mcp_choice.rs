//! The person's answer to "may cmux add its tools to your coding agents?"
//! (`agents.cmuxMcp`, the onboarding step and Settings > Agents) applied to
//! the `claude` and `codex` shims: the MCP server they pass to an agent
//! started in a cmux terminal (agent_computer_use.rs) goes only once the
//! answer is `on`. Unanswered (`ask`) and `off` pass none: cmux does not add
//! its tools to the person's agents until they approve (the app asks at
//! launch). The hooks are not MCP and are passed either way.

use std::ffi::OsString;
use std::path::Path;

use cmux_tui_core::user_settings::AgentsCmuxMcp;

/// Claude Code's `--mcp-config` value for this launch, or `None` until the
/// person said yes to cmux's tools in their agents.
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

/// Codex `-c` overrides for this launch; none until the person said yes to
/// cmux's tools in their agents.
pub(crate) fn codex_settings(
    choice: AgentsCmuxMcp,
    executable: &Path,
    socket: &Path,
    launch: crate::agent_computer_use::CodexLaunch<'_>,
) -> Vec<OsString> {
    if !choice.injects() {
        return Vec::new();
    }
    crate::agent_computer_use::codex_settings(executable, socket, launch).unwrap_or_default()
}

/// [`codex_settings`] with the environment `getenv` (tests: never the
/// machine's own `~/.codex`).
#[cfg(test)]
fn codex_settings_with(
    choice: AgentsCmuxMcp,
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Vec<OsString> {
    if !choice.injects() {
        return Vec::new();
    }
    crate::agent_computer_use::codex_settings_with(
        executable,
        socket,
        getenv,
        crate::agent_computer_use::CodexLaunch::default(),
    )
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/A/cmux";
    const SOCKET: &str = "/tmp/s.sock";

    /// An environment with nothing set.
    fn no_env(_: &str) -> Option<OsString> {
        None
    }

    fn choice(text: &str) -> AgentsCmuxMcp {
        AgentsCmuxMcp::from_config_text(text)
    }

    /// Unanswered (no file, no key, `ask`, an unknown value or a file that does
    /// not parse): neither agent gets the server.
    #[test]
    fn unanswered_passes_no_server_to_either_agent() {
        for text in
            ["", "{}", r#"{"agents": {"cmuxMcp": "ask"}}"#, r#"{"agents.cmuxMcp": "maybe"}"#, "{"]
        {
            let unset = choice(text);
            assert_eq!(claude_mcp_config(unset, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
            assert!(
                codex_settings_with(unset, Path::new(EXE), Path::new(SOCKET), &no_env).is_empty(),
                "{text}"
            );
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
        // No HOME and no CODEX_HOME: the machine's own Codex config is never read.
        let codex = codex_settings_with(on, Path::new(EXE), Path::new(SOCKET), &no_env);
        assert!(!codex.is_empty());
        let prefix = format!("mcp_servers.{}.", crate::agent_computer_use::SERVER);
        assert!(codex.iter().all(|s| s.to_str().unwrap().starts_with(&prefix)), "{codex:?}");
    }

    #[test]
    fn off_passes_no_server_to_either_agent() {
        for text in [r#"{"agents": {"cmuxMcp": "off"}}"#, r#"{"agents.cmuxMcp": "off"}"#] {
            let off = choice(text);
            assert_eq!(claude_mcp_config(off, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
            assert!(
                codex_settings_with(off, Path::new(EXE), Path::new(SOCKET), &no_env).is_empty(),
                "{text}"
            );
        }
    }
}
