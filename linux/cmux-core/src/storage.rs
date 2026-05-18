//! XDG-backed persistence for Linux cmux state.

use crate::terminal::TerminalSession;
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
}

impl From<&TerminalSession> for SavedSession {
    fn from(session: &TerminalSession) -> Self {
        Self {
            id: session.id.clone(),
            title: session.title.clone(),
            program: session.command.program.clone(),
            args: session.command.args.clone(),
            working_directory: session.command.working_directory.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct StateStore {
    path: PathBuf,
}

impl StateStore {
    pub fn xdg() -> Result<Self, StorageError> {
        let config_dir = dirs::config_dir().ok_or(StorageError::MissingConfigDirectory)?;
        Ok(Self { path: config_dir.join("cmux").join("state.json") })
    }

    #[must_use]
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn load(&self) -> Result<SavedState, StorageError> {
        if !self.path.exists() {
            return Ok(SavedState::default());
        }
        let bytes = fs::read(&self.path)?;
        Ok(serde_json::from_slice(&bytes)?)
    }

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
}
