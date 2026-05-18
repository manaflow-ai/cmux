//! Terminal/session abstractions for the Linux port.

use std::path::PathBuf;

/// Command and environment used to start a terminal session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCommand {
    pub program: String,
    pub args: Vec<String>,
    pub working_directory: Option<PathBuf>,
}

impl TerminalCommand {
    #[must_use]
    pub fn user_shell() -> Self {
        let program = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        Self { program, args: Vec::new(), working_directory: None }
    }
}

/// Backend-independent terminal session state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSession {
    pub id: String,
    pub title: String,
    pub command: TerminalCommand,
}

impl TerminalSession {
    #[must_use]
    pub fn new(id: impl Into<String>, title: impl Into<String>, command: TerminalCommand) -> Self {
        Self { id: id.into(), title: title.into(), command }
    }
}
