//! Workspace/session domain model for the Linux port.

use crate::terminal::{TerminalCommand, TerminalSession};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum AgentKind {
    #[default]
    Shell,
    Claude,
    Codex,
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum SessionStatus {
    #[default]
    Running,
    WaitingForInput,
    Exited(i32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSession {
    pub terminal: TerminalSession,
    pub agent: AgentKind,
    pub status: SessionStatus,
}

impl WorkspaceSession {
    #[must_use]
    pub fn shell(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            terminal: TerminalSession::new(id, title, TerminalCommand::user_shell()),
            agent: AgentKind::Shell,
            status: SessionStatus::Running,
        }
    }

    #[must_use]
    pub fn with_command(
        id: impl Into<String>,
        title: impl Into<String>,
        agent: AgentKind,
        command: TerminalCommand,
    ) -> Self {
        Self {
            terminal: TerminalSession::new(id, title, command),
            agent,
            status: SessionStatus::Running,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SessionList {
    sessions: Vec<WorkspaceSession>,
    active_id: Option<String>,
}

impl SessionList {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, session: WorkspaceSession) {
        if self.active_id.is_none() {
            self.active_id = Some(session.terminal.id.clone());
        }
        self.sessions.push(session);
    }

    #[must_use]
    pub fn active(&self) -> Option<&WorkspaceSession> {
        let active_id = self.active_id.as_ref()?;
        self.sessions
            .iter()
            .find(|session| &session.terminal.id == active_id)
    }

    pub fn set_active(&mut self, id: &str) -> bool {
        if self
            .sessions
            .iter()
            .any(|session| session.terminal.id == id)
        {
            self.active_id = Some(id.to_string());
            true
        } else {
            false
        }
    }

    #[must_use]
    pub fn sessions(&self) -> &[WorkspaceSession] {
        &self.sessions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_pushed_session_becomes_active() {
        let mut list = SessionList::new();
        list.push(WorkspaceSession::shell("one", "One"));
        list.push(WorkspaceSession::shell("two", "Two"));

        assert_eq!(list.active().unwrap().terminal.id, "one");
    }

    #[test]
    fn active_session_can_be_changed() {
        let mut list = SessionList::new();
        list.push(WorkspaceSession::shell("one", "One"));
        list.push(WorkspaceSession::shell("two", "Two"));

        assert!(list.set_active("two"));
        assert_eq!(list.active().unwrap().terminal.title, "Two");
        assert!(!list.set_active("missing"));
    }
}
