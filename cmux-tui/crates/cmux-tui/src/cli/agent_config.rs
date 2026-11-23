//! `cmux agent-config`: Claude Code's and Codex's own setup, read and changed in the agents' own
//! files (the `cmux-agent-customize` crate), one part per module: [`skills`] (skills and slash
//! commands), [`subagents`] (Claude Code's `.claude/agents`), [`commands`] (custom slash commands made from cmux), [`hooks`] (hooks by event, turned off and on), [`settings`] (model, permission or approval
//! mode, sandbox, env masked) and [`mcp`] (MCP servers, and the
//! usage for a bare `cmux agent-config`). Settings runs these verbs with `--json`, behind Labs
//! `labs.agentCustomization`. No verb needs the app or the daemon.
//!
//! Leo, 2026-11-19: "when I say Claude Code, when I say Codex [...] I need you guys to be, like,
//! doing the thing."

mod commands;
mod hooks;
mod mcp;
mod settings;
mod skills;
mod subagents;

/// `Some(exit code)` when `args` is `agent-config ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    skills::run_if_requested(args)
        .or_else(|| subagents::run_if_requested(args))
        .or_else(|| commands::run_if_requested(args))
        .or_else(|| hooks::run_if_requested(args))
        .or_else(|| settings::run_if_requested(args))
        .or_else(|| mcp::run_if_requested(args))
}
