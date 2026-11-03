use super::AttemptKey;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryStage {
    Watching,
    Nudged,
    Restarted,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitReason {
    Permission,
    UsageLimit { reset_at_ms: Option<u64> },
    Capacity,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryEvent {
    Progress,
    Stalled,
    RouteError,
    Waiting(WaitReason),
    Resumed,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    None,
    Nudge,
    Restart { key: AttemptKey },
    Wait(WaitReason),
    Fail,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecoveryState {
    pub key: AttemptKey,
    pub last_sequence: Option<u64>,
    pub stage: RecoveryStage,
    pub waiting: Option<WaitReason>,
}

impl RecoveryState {
    pub fn new(key: AttemptKey) -> Self {
        Self { key, last_sequence: None, stage: RecoveryStage::Watching, waiting: None }
    }

    pub fn observe(
        &mut self,
        _key: &AttemptKey,
        _sequence: u64,
        _event: RecoveryEvent,
    ) -> RecoveryAction {
        RecoveryAction::None
    }
}
