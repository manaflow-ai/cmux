use clap::ValueEnum;

/// Available ACP (Agent Client Protocol) providers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, ValueEnum)]
pub enum AcpProvider {
    /// OpenAI Codex CLI ACP - `codex-acp`
    #[default]
    Codex,
    /// OpenCode ACP - `opencode acp`
    Opencode,
    /// Claude Code ACP - `claude-code-acp`
    Claude,
    /// Gemini CLI ACP - `gemini --experimental-acp`
    Gemini,
}

impl AcpProvider {
    /// Get all available providers for display in the command palette
    pub fn all() -> &'static [AcpProvider] {
        &[
            AcpProvider::Codex,
            AcpProvider::Opencode,
            AcpProvider::Claude,
            AcpProvider::Gemini,
        ]
    }

    /// Get the display name for this provider
    pub fn display_name(&self) -> &'static str {
        match self {
            AcpProvider::Codex => "Codex CLI",
            AcpProvider::Opencode => "OpenCode",
            AcpProvider::Claude => "Claude Code",
            AcpProvider::Gemini => "Gemini CLI",
        }
    }

    /// Get the command to execute for this provider
    /// Commands are wrapped with stdbuf for unbuffered I/O
    pub fn command(&self) -> &'static str {
        match self {
            AcpProvider::Codex => {
                "/usr/bin/stdbuf -i0 -o0 -e0 /usr/local/bin/codex-acp -c approval_policy=\"never\" -c sandbox_mode=\"danger-full-access\" -c model=\"gpt-5.1-codex-max\""
            }
            AcpProvider::Opencode => "/usr/bin/stdbuf -i0 -o0 -e0 opencode acp",
            AcpProvider::Claude => "/usr/bin/stdbuf -i0 -o0 -e0 claude-code-acp",
            AcpProvider::Gemini => "/usr/bin/stdbuf -i0 -o0 -e0 gemini --experimental-acp",
        }
    }

    /// Get a short identifier for this provider
    pub fn short_name(&self) -> &'static str {
        match self {
            AcpProvider::Codex => "codex",
            AcpProvider::Opencode => "opencode",
            AcpProvider::Claude => "claude",
            AcpProvider::Gemini => "gemini",
        }
    }

    /// Parse a short name back to AcpProvider
    pub fn from_short_name(name: &str) -> Option<AcpProvider> {
        match name {
            "codex" => Some(AcpProvider::Codex),
            "opencode" => Some(AcpProvider::Opencode),
            "claude" => Some(AcpProvider::Claude),
            "gemini" => Some(AcpProvider::Gemini),
            _ => None,
        }
    }
}
