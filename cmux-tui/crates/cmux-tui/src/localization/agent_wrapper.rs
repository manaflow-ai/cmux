//! `agent_wrapper` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AgentWrapperMessages {
    pub hooks_unavailable: &'static str,
    pub agent_not_found: &'static str,
    /// The line after `agent_not_found` for Claude Code: how to install it.
    pub claude_install_hint: &'static str,
    /// The line after `agent_not_found` for Codex: how to install it.
    pub codex_install_hint: &'static str,
    pub agent_start_failed: &'static str,
}

pub(super) const ENGLISH: AgentWrapperMessages = AgentWrapperMessages {
    hooks_unavailable: "cmux: starting the agent without cmux status updates",
    agent_not_found: "cmux: the agent executable was not found",
    claude_install_hint: "cmux: Claude Code is not installed. To install it, run: curl -fsSL https://claude.ai/install.sh | bash",
    codex_install_hint: "cmux: Codex is not installed. To install it, run: curl -fsSL https://chatgpt.com/codex/install.sh | sh",
    agent_start_failed: "cmux: the agent could not be started",
};

pub(super) const JAPANESE: AgentWrapperMessages = AgentWrapperMessages {
    hooks_unavailable: "cmux: cmux のステータス更新なしでエージェントを起動します",
    agent_not_found: "cmux: エージェントの実行ファイルが見つかりません",
    claude_install_hint: "cmux: Claude Code がインストールされていません。インストールするには次を実行してください: curl -fsSL https://claude.ai/install.sh | bash",
    codex_install_hint: "cmux: Codex がインストールされていません。インストールするには次を実行してください: curl -fsSL https://chatgpt.com/codex/install.sh | sh",
    agent_start_failed: "cmux: エージェントを起動できませんでした",
};
