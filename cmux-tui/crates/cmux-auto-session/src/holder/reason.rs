//! Why a chat is brought into a daemon.

use serde::{Deserialize, Serialize};

use crate::wire::AssignmentKind;

/// Why a chat is being brought into this daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportReason {
    /// A Cloud machine takes a chat over: the events and the newest snapshot into a fresh
    /// worktree, the open turn settled `outcome_unknown`, the `machine_takeover` continuation
    /// queued.
    Takeover,
    /// A laptop gets its chat back: the snapshot merged into the chat's folder.
    Handback,
    /// A chat started with no laptop: a worktree of the repository and branch, and the harness.
    Create,
    /// Inbox messages arrived for a chat this machine holds and may not have loaded.
    Deliver,
}

impl ImportReason {
    pub const ALL: [ImportReason; 4] = [
        ImportReason::Takeover,
        ImportReason::Handback,
        ImportReason::Create,
        ImportReason::Deliver,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            ImportReason::Takeover => "takeover",
            ImportReason::Handback => "handback",
            ImportReason::Create => "create",
            ImportReason::Deliver => "deliver",
        }
    }
}

impl From<AssignmentKind> for ImportReason {
    fn from(kind: AssignmentKind) -> ImportReason {
        match kind {
            AssignmentKind::Takeover => ImportReason::Takeover,
            AssignmentKind::Create => ImportReason::Create,
            AssignmentKind::Deliver => ImportReason::Deliver,
        }
    }
}
