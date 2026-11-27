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
    /// Wait for the existing consent/permission flow. No route or harness
    /// change may be used to avoid the pending decision.
    Permission,
    /// Resume this same activity after its account resets; do not switch
    /// accounts, models or harnesses to evade the limit.
    UsageLimit { reset_at_ms: Option<u64> },
    /// The router owns capacity recovery; it is not a workflow stall.
    Capacity,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecoveryEvent {
    /// The caller owns its one-shot inactivity deadline and rearms it from an
    /// actual agent event. Progress never resets this activity's escalation.
    Progress,
    Stalled,
    RouteError,
    Waiting(WaitReason),
    Resumed,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecoveryAction {
    None,
    Nudge,
    /// Ensure this new incarnation on a different permitted route/harness.
    /// Route selection remains with the caller and must respect the activity's
    /// policy ceiling; this action never authorizes a permissions bypass.
    Restart {
        key: AttemptKey,
    },
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

    /// `sequence` is the monotonically numbered activity-observation journal,
    /// which includes observations from a one-shot stall deadline. It is not
    /// the raw acpmux cursor: a deadline must receive its own durable sequence.
    /// Persist the resulting state and action before performing that action.
    pub fn observe(
        &mut self,
        key: &AttemptKey,
        sequence: u64,
        event: RecoveryEvent,
    ) -> RecoveryAction {
        if key != &self.key
            || matches!(self.stage, RecoveryStage::Completed | RecoveryStage::Failed)
            || self.last_sequence.is_some_and(|last| sequence <= last)
        {
            return RecoveryAction::None;
        }
        self.last_sequence = Some(sequence);
        match event {
            RecoveryEvent::Completed => {
                self.waiting = None;
                self.stage = RecoveryStage::Completed;
                RecoveryAction::None
            }
            RecoveryEvent::Failed => {
                self.waiting = None;
                self.stage = RecoveryStage::Failed;
                RecoveryAction::Fail
            }
            RecoveryEvent::Waiting(reason) => {
                if self.waiting.as_ref() == Some(&reason) {
                    return RecoveryAction::None;
                }
                self.waiting = Some(reason.clone());
                RecoveryAction::Wait(reason)
            }
            RecoveryEvent::Resumed => {
                self.waiting = None;
                RecoveryAction::None
            }
            RecoveryEvent::Progress => RecoveryAction::None,
            RecoveryEvent::Stalled | RecoveryEvent::RouteError if self.waiting.is_some() => {
                RecoveryAction::None
            }
            RecoveryEvent::Stalled | RecoveryEvent::RouteError => match self.stage {
                RecoveryStage::Watching => {
                    self.stage = RecoveryStage::Nudged;
                    RecoveryAction::Nudge
                }
                RecoveryStage::Nudged => {
                    let Some(generation) = self.key.generation.checked_add(1) else {
                        self.stage = RecoveryStage::Failed;
                        return RecoveryAction::Fail;
                    };
                    self.key.generation = generation;
                    self.last_sequence = None;
                    self.stage = RecoveryStage::Restarted;
                    RecoveryAction::Restart { key: self.key.clone() }
                }
                RecoveryStage::Restarted => {
                    self.stage = RecoveryStage::Failed;
                    RecoveryAction::Fail
                }
                RecoveryStage::Completed | RecoveryStage::Failed => RecoveryAction::None,
            },
        }
    }
}
