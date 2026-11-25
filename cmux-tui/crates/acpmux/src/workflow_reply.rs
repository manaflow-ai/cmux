//! Pure structured-reply and recovery policies for native code-mode workflows.
//!
//! The daemon persists policy state and any returned action together in the
//! activity journal before performing it, then reconciles an unacknowledged
//! action using the activity/incarnation identity. This module owns no transport,
//! timers, credentials or engine.

mod recovery;
mod schema;

pub use recovery::{RecoveryAction, RecoveryEvent, RecoveryStage, RecoveryState, WaitReason};
pub use schema::{ReplyDecision, ReplyIssue, ReplyPolicy, ReplyState, SchemaError};

use serde::{Deserialize, Serialize};

/// A workflow activity and its current agent incarnation. Restarting increments
/// generation so events from the abandoned incarnation cannot affect the new one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttemptKey {
    pub activity_id: String,
    pub generation: u32,
}

impl AttemptKey {
    pub fn new(activity_id: impl Into<String>) -> Self {
        Self { activity_id: activity_id.into(), generation: 0 }
    }
}

#[cfg(test)]
mod tests;
