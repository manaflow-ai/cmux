//! The versioned wire messages that update a [`crate::PlacementTable`]: "placement set",
//! "placement moved" and "placement removed".
//!
//! Lockstep rule: an old reader and a new reader both take each other's messages. So
//! - every message carries `v` (the version its writer speaks); a reader takes any `v`;
//! - unknown fields are ignored (no `deny_unknown_fields`), and every field added after v1 is
//!   `#[serde(default)]`;
//! - an unknown `kind` reads as [`PlacementMessage::Unknown`], which the table ignores, instead
//!   of failing the whole stream.
//!
//! The tests below hold an old reader's shape and a newer writer's shape and check both ways.

use serde::{Deserialize, Serialize};

use crate::placement::{Applied, Placement};

/// The acpmux request that carries one [`PlacementMessage`] (its params) from cmux to the daemon
/// that hosts the front; the answer is a [`PlacementReply`].
pub const PLACEMENT_METHOD: &str = "_acpmux/tailnet/placement";

/// The version this build writes.
pub const PLACEMENT_MESSAGE_VERSION: u32 = 1;

fn version() -> u32 {
    PLACEMENT_MESSAGE_VERSION
}

/// One placement update, as JSON: `{"kind":"moved","v":1,"workspace":"alpha","placement":{...}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PlacementMessage {
    /// A workspace now runs at `placement` (first placement, or a full replace).
    Set {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
        placement: Placement,
    },
    /// A workspace moved to `placement`. Open connections keep their old target; new ones go to
    /// the new one. With `from_generation`, the move applies only over that generation.
    Moved {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
        placement: Placement,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_generation: Option<u64>,
    },
    /// A workspace has no placement any more (stopped or deleted).
    Removed {
        #[serde(default = "version")]
        v: u32,
        workspace: String,
    },
    /// A kind this build does not know (a newer writer's). Ignored.
    #[serde(other)]
    Unknown,
}

impl PlacementMessage {
    pub fn set(workspace: impl Into<String>, placement: Placement) -> Self {
        Self::Set { v: PLACEMENT_MESSAGE_VERSION, workspace: workspace.into(), placement }
    }

    pub fn moved(
        workspace: impl Into<String>,
        placement: Placement,
        from_generation: Option<u64>,
    ) -> Self {
        Self::Moved {
            v: PLACEMENT_MESSAGE_VERSION,
            workspace: workspace.into(),
            placement,
            from_generation,
        }
    }

    pub fn removed(workspace: impl Into<String>) -> Self {
        Self::Removed { v: PLACEMENT_MESSAGE_VERSION, workspace: workspace.into() }
    }

    /// The workspace the message is about (none for [`PlacementMessage::Unknown`]).
    pub fn workspace(&self) -> Option<&str> {
        match self {
            Self::Set { workspace, .. }
            | Self::Moved { workspace, .. }
            | Self::Removed { workspace, .. } => Some(workspace),
            Self::Unknown => None,
        }
    }
}

/// What applying one [`PlacementMessage`] did, as the daemon answers it. Same lockstep rules:
/// `v`, unknown fields ignored, every later field defaulted, an unknown `result` read as
/// [`PlacementResult::Unknown`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlacementReply {
    #[serde(default = "version")]
    pub v: u32,
    pub result: PlacementResult,
    /// The workspace's generation after a set or move.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlacementResult {
    Placed,
    Removed,
    Ignored,
    #[serde(other)]
    Unknown,
}

impl From<&Applied> for PlacementReply {
    fn from(applied: &Applied) -> Self {
        let (result, generation) = match applied {
            Applied::Placed { generation } => (PlacementResult::Placed, Some(*generation)),
            Applied::Removed => (PlacementResult::Removed, None),
            Applied::Ignored => (PlacementResult::Ignored, None),
        };
        Self { v: PLACEMENT_MESSAGE_VERSION, result, generation }
    }
}

#[cfg(test)]
#[path = "messages_tests.rs"]
mod tests;
