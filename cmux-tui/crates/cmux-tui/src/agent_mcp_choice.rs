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
#[path = "agent_mcp_choice_tests.rs"]
mod tests;
