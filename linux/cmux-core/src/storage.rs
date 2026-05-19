//! XDG-backed persistence for Linux cmux state.

use crate::{
    session::{AgentKind, SessionStatus, WorkspaceSession},
    terminal::{TerminalCommand, TerminalSession},
};
use serde::{Deserialize, Serialize};
use std::{fs, io, path::PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("could not resolve an XDG config directory")]
    MissingConfigDirectory,
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SavedState {
    pub sessions: Vec<SavedSession>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSession {
    pub id: String,
    pub title: String,
    pub program: String,
    pub args: Vec<String>,
    pub working_directory: Option<PathBuf>,
    #[serde(default)]
    pub agent: SavedAgentKind,
    #[serde(default)]
    pub status: SavedSessionStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum SavedAgentKind {
    #[default]
    Shell,
    Claude,
    Codex,
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", content = "code", rename_all = "snake_case")]
pub enum SavedSessionStatus {
    #[default]
    Running,
    WaitingForInput,
    Exited(i32),
}

impl From<&TerminalSession> for SavedSession {
    fn from(session: &TerminalSession) -> Self {
        Self {
            id: session.id.clone(),
            title: session.title.clone(),
            program: session.command.program.clone(),
            args: session.command.args.clone(),
            working_directory: session.command.working_directory.clone(),
            agent: SavedAgentKind::Shell,
            status: SavedSessionStatus::Running,
        }
    }
}

impl From<&WorkspaceSession> for SavedSession {
    fn from(session: &WorkspaceSession) -> Self {
        Self {
            id: session.terminal.id.clone(),
            title: session.terminal.title.clone(),
            program: session.terminal.command.program.clone(),
            args: session.terminal.command.args.clone(),
            working_directory: session.terminal.command.working_directory.clone(),
            agent: (&session.agent).into(),
            status: (&session.status).into(),
        }
    }
}

impl From<SavedSession> for WorkspaceSession {
    fn from(session: SavedSession) -> Self {
        let status = session.status.into();
        let mut workspace_session = WorkspaceSession::with_command(
            session.id,
            session.title,
            session.agent.into(),
            TerminalCommand {
                program: session.program,
                args: session.args,
                working_directory: session.working_directory,
            },
        );
        workspace_session.status = status;
        workspace_session
    }
}

impl From<&AgentKind> for SavedAgentKind {
    fn from(agent: &AgentKind) -> Self {
        match agent {
            AgentKind::Shell => Self::Shell,
            AgentKind::Claude => Self::Claude,
            AgentKind::Codex => Self::Codex,
            AgentKind::Custom(value) => Self::Custom(value.clone()),
        }
    }
}

impl From<SavedAgentKind> for AgentKind {
    fn from(agent: SavedAgentKind) -> Self {
        match agent {
            SavedAgentKind::Shell => Self::Shell,
            SavedAgentKind::Claude => Self::Claude,
            SavedAgentKind::Codex => Self::Codex,
            SavedAgentKind::Custom(value) => Self::Custom(value),
        }
    }
}

impl From<&SessionStatus> for SavedSessionStatus {
    fn from(status: &SessionStatus) -> Self {
        match status {
            SessionStatus::Running => Self::Running,
            SessionStatus::WaitingForInput => Self::WaitingForInput,
            SessionStatus::Exited(code) => Self::Exited(*code),
        }
    }
}

impl From<SavedSessionStatus> for SessionStatus {
    fn from(status: SavedSessionStatus) -> Self {
        match status {
            SavedSessionStatus::Running => Self::Running,
            SavedSessionStatus::WaitingForInput => Self::WaitingForInput,
            SavedSessionStatus::Exited(code) => Self::Exited(code),
        }
    }
}

#[derive(Debug, Clone)]
pub struct StateStore {
    path: PathBuf,
}

impl StateStore {
    /// Create a store using the current user's XDG config directory.
    ///
    /// # Errors
    ///
    /// Returns an error if the XDG config directory cannot be resolved.
    pub fn xdg() -> Result<Self, StorageError> {
        let config_dir = dirs::config_dir().ok_or(StorageError::MissingConfigDirectory)?;
        Ok(Self {
            path: config_dir.join("cmux").join("state.json"),
        })
    }

    #[must_use]
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// Load saved state from disk.
    ///
    /// # Errors
    ///
    /// Returns an error if the state file cannot be read or decoded.
    pub fn load(&self) -> Result<SavedState, StorageError> {
        if !self.path.exists() {
            return Ok(SavedState::default());
        }
        let bytes = fs::read(&self.path)?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    /// Save state to disk, creating parent directories as needed.
    ///
    /// # Errors
    ///
    /// Returns an error if the directory cannot be created, the state cannot be
    /// encoded, or the file cannot be written.
    pub fn save(&self, state: &SavedState) -> Result<(), StorageError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(state)?;
        fs::write(&self.path, bytes)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_state_defaults_empty() {
        let store = StateStore::at("/tmp/cmux-test-state-that-should-not-exist.json");
        assert_eq!(store.load().unwrap(), SavedState::default());
    }

    #[test]
    fn legacy_sessions_default_to_shell_running() {
        let json = r#"{
            "sessions": [{
                "id": "one",
                "title": "One",
                "program": "/bin/sh",
                "args": [],
                "working_directory": null
            }]
        }"#;

        let state: SavedState = serde_json::from_str(json).unwrap();
        assert_eq!(state.sessions[0].agent, SavedAgentKind::Shell);
        assert_eq!(state.sessions[0].status, SavedSessionStatus::Running);
    }

    #[test]
    fn workspace_session_round_trips_agent_metadata() {
        let session = WorkspaceSession::with_command(
            "one",
            "Claude",
            AgentKind::Claude,
            TerminalCommand {
                program: "claude".to_string(),
                args: vec!["--dangerously-skip-permissions".to_string()],
                working_directory: None,
            },
        );

        let saved = SavedSession::from(&session);
        let restored = WorkspaceSession::from(saved);
        assert_eq!(restored.agent, AgentKind::Claude);
        assert_eq!(restored.terminal.command.program, "claude");
    }
}
