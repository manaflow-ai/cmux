//! The person's answer to "should agents you start in cmux get cmux's
//! tools?" (`agents.cmuxMcp`, the onboarding step and Settings > Agents)
//! applied to the `claude` and `codex` shims: the MCP server they pass to an
//! agent started in a cmux terminal (agent_computer_use.rs) goes only once
//! the answer is `on`. Unanswered (`ask`) and `off` pass none (the app asks
//! at launch). The hooks are not MCP and are passed either way. Nothing
//! here writes the person's own agent configs: `cmux setup mcp` only names
//! the lines a person runs to add cmux's server to an agent started
//! elsewhere (cli/setup/mcp.rs).

use std::ffi::OsString;
use std::path::Path;

use cmux_tui_core::user_settings::AgentsCmuxMcp;

/// The answer an agent started in a cmux terminal carries for its own MCP
/// servers (`CMUX_AGENT_TOOLS_ANSWER`, `acpmux::agent_tools::TOOLS_ANSWER_ENV`):
/// `on` with the person's yes, else `off`. Claude Code passes its environment
/// to a stdio server, so a `cmux` entry of the person's own that a terminal
/// Claude starts gets it and its `cmux mcp serve` follows the answer, as in an
/// agent chat (cli/mcp.rs `refusal`); the `codex` shim gives it to such an
/// entry as an env override (codex_wrapper.rs).
pub(crate) fn tools_answer(choice: AgentsCmuxMcp) -> &'static str {
    if choice.injects() { "on" } else { "off" }
}

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

/// Codex `-c` overrides for this launch in `cwd`; none until the person said
/// yes to cmux's tools in agents started in cmux. `getenv` reads the pane's
/// environment.
pub(crate) fn codex_settings(
    choice: AgentsCmuxMcp,
    executable: &Path,
    socket: &Path,
    cwd: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Vec<OsString> {
    if !choice.injects() {
        return Vec::new();
    }
    crate::agent_computer_use::codex_settings(executable, socket, cwd, getenv).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/A/cmux";
    const SOCKET: &str = "/tmp/s.sock";

    const CWD: &str = "/w";

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
                codex_settings(unset, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env)
                    .is_empty(),
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
        // An empty pane environment: nothing of this machine is read.
        let codex = codex_settings(on, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env);
        assert!(!codex.is_empty());
        let prefix = format!("mcp_servers.{}.", crate::agent_computer_use::SERVER);
        assert!(codex.iter().all(|s| s.to_str().unwrap().starts_with(&prefix)), "{codex:?}");
    }

    /// The terminal shims and acpmux's sessions read the person's answer the same way, so the
    /// terminal and the agent pane never disagree on whether an agent gets cmux's tools.
    #[test]
    fn the_shims_and_acpmux_read_the_answer_alike() {
        for text in [
            "",
            "{}",
            "{",
            r#"{"agents": {"cmuxMcp": "on"}}"#,
            r#"{"agents.cmuxMcp": "on"}"#,
            r#"{"agents": {"cmuxMcp": "off"}}"#,
            r#"{"agents": {"cmuxMcp": "ask"}}"#,
            r#"{"agents": {"cmuxMcp": "maybe"}}"#,
            r#"{"agents": {"cmuxMcp": true}}"#,
            "{\n// mine\n\"agents.cmuxMcp\": \"on\",\n}",
        ] {
            assert_eq!(
                choice(text).injects(),
                acpmux::agent_tools::agents_get_cmux(Some(text)),
                "{text}"
            );
        }
        assert!(!acpmux::agent_tools::agents_get_cmux(None));
    }

    #[test]
    fn off_passes_no_server_to_either_agent() {
        for text in [r#"{"agents": {"cmuxMcp": "off"}}"#, r#"{"agents.cmuxMcp": "off"}"#] {
            let off = choice(text);
            assert_eq!(claude_mcp_config(off, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
            assert!(
                codex_settings(off, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env)
                    .is_empty(),
                "{text}"
            );
        }
    }
}
