//! What the person configured for Claude Code and Codex, read and edited in those agents' own
//! files, so cmux can show it and change it without the agent's own CLI (Settings > MCP Servers
//! "Claude Code & Codex", behind Labs `labs.agentCustomization`; `cmux agent-config`).
//!
//! Leo, 2026-11-19: "when I say Claude Code, when I say Codex [...] I need you guys to be, like,
//! doing the thing. Like, actually looking at the fucking functionality".
//!
//! One module per part of an agent's setup ([`mcp`] first); [`paths`] names every file each agent
//! reads, so the modules agree on where things live. Every edit round-trips: unknown keys,
//! comments and key order stay as they were ([`ojson`] for JSON, `toml_edit` for TOML), the write
//! is atomic and keeps the file before it beside it ([`fsio`]), and nothing a server holds as a
//! secret (an env value, a header) leaves this crate unmasked.

pub mod fsio;
pub mod mcp;
pub mod ojson;
pub mod paths;

/// The two agents whose own setup cmux reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub const ALL: [Agent; 2] = [Agent::Claude, Agent::Codex];

    /// The name the CLI and the page use: `claude` or `codex`.
    pub fn id(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "claude" | "claude-code" | "claudecode" => Some(Agent::Claude),
            "codex" => Some(Agent::Codex),
            _ => None,
        }
    }
}
