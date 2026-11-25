//! A model race's record, kept on its parent chat (`SessionMeta::races`): the races themselves
//! run in `hub/races.rs`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub harness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// This candidate's own plan hint, put before the shared task so attempts of one model
    /// diverge on purpose (best-of-N diversity); none is the task alone. Never sent to the reviewer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub id: String,
    pub target: Target,
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Race {
    pub id: String,
    pub parent: String,
    pub prompt: String,
    pub state: String,
    pub candidates: Vec<Candidate>,
    pub reviewer: Target,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewer_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewer_turn_id: Option<String>,
    pub winner_id: Option<String>,
    pub reason: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
    /// A persisted origin restriction: resumption must not turn a Web request into a local one.
    #[serde(default)]
    pub local: bool,
    /// Worktree authorization from the owning person, persisted for race recovery.
    /// This is derived by the server from connection proof, never a request body field.
    #[serde(default)]
    pub owner_authorized: bool,
    /// Cleanup remains retryable after a crash until every owned child is stopped.
    #[serde(default)]
    pub cleanup_pending: bool,
    /// The reviewer session remains in the record for attribution after it is stopped.
    #[serde(default)]
    pub reviewer_cleanup_done: bool,
}

impl Race {
    pub(crate) fn active(&self) -> bool {
        matches!(self.state.as_str(), "running" | "reviewing")
    }
}
