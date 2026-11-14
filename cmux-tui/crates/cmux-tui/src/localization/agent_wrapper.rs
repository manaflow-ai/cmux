//! `agent_wrapper` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AgentWrapperMessages {
    pub hooks_unavailable: &'static str,
    pub agent_not_found: &'static str,
    pub agent_start_failed: &'static str,
    /// Codex did not say which `cmux` MCP server it has set up for this launch.
    pub codex_mcp_unknown: &'static str,
    /// The person's own cmux server from Codex's settings stays on for this
    /// launch (a launch the probe does not describe, or an entry with a url).
    pub codex_mcp_kept: &'static str,
}

pub(super) const ENGLISH: AgentWrapperMessages = AgentWrapperMessages {
    hooks_unavailable: "cmux: starting the agent without cmux status updates",
    agent_not_found: "cmux: the agent executable was not found",
    agent_start_failed: "cmux: the agent could not be started",
    codex_mcp_unknown: "cmux: Codex did not say which cmux tools it already has, so any it has stay on beside this cmux's own",
    codex_mcp_kept: "cmux: a cmux server from your Codex settings, if there is one, stays on beside this cmux's own for this session",
};

pub(super) const JAPANESE: AgentWrapperMessages = AgentWrapperMessages {
    hooks_unavailable: "cmux: cmux のステータス更新なしでエージェントを起動します",
    agent_not_found: "cmux: エージェントの実行ファイルが見つかりません",
    agent_start_failed: "cmux: エージェントを起動できませんでした",
    codex_mcp_unknown: "cmux: Codex に設定済みの cmux ツールを確認できなかったため、設定済みのものもこの cmux のツールと並べてそのまま使います",
    codex_mcp_kept: "cmux: Codex の設定にある cmux サーバーは、このセッションではこの cmux のツールと並べてそのまま使います",
};
