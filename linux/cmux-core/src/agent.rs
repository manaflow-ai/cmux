//! Agent command helpers for Linux sessions.

use crate::{
    session::AgentKind,
    terminal::{TerminalCommand, TerminalSession},
};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentCommand {
    pub kind: AgentKind,
    pub title: String,
    pub command: TerminalCommand,
}

impl AgentCommand {
    #[must_use]
    pub fn shell() -> Self {
        Self {
            kind: AgentKind::Shell,
            title: "Shell".to_string(),
            command: TerminalCommand::user_shell(),
        }
    }

    #[must_use]
    pub fn claude(working_directory: Option<PathBuf>) -> Self {
        Self {
            kind: AgentKind::Claude,
            title: "Claude".to_string(),
            command: TerminalCommand {
                program: "claude".to_string(),
                args: Vec::new(),
                working_directory,
            },
        }
    }

    #[must_use]
    pub fn codex(working_directory: Option<PathBuf>) -> Self {
        Self {
            kind: AgentKind::Codex,
            title: "Codex".to_string(),
            command: TerminalCommand {
                program: "codex".to_string(),
                args: Vec::new(),
                working_directory,
            },
        }
    }

    #[must_use]
    pub fn into_terminal_session(self, id: impl Into<String>) -> TerminalSession {
        TerminalSession::new(id, self.title, self.command)
    }
}

#[must_use]
pub fn known_agents() -> Vec<AgentCommand> {
    vec![
        AgentCommand::shell(),
        AgentCommand::claude(None),
        AgentCommand::codex(None),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_command_uses_claude_binary() {
        let command = AgentCommand::claude(None);
        assert_eq!(command.kind, AgentKind::Claude);
        assert_eq!(command.command.program, "claude");
    }

    #[test]
    fn known_agents_include_shell_claude_and_codex() {
        let agents = known_agents();
        assert_eq!(agents.len(), 3);
        assert!(agents.iter().any(|agent| agent.kind == AgentKind::Shell));
        assert!(agents.iter().any(|agent| agent.kind == AgentKind::Claude));
        assert!(agents.iter().any(|agent| agent.kind == AgentKind::Codex));
    }
}
