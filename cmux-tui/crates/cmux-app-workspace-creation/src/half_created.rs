//! What a failed create does to its workspace (`EmptyWorkspaceRepair.withTerminal`, `populating`,
//! `WorkspaceCreation.closeHalfCreated`): a create never leaves a workspace half made, except after
//! a refused `create-workspace`, which made nothing (its key may name a live workspace).

use serde::{Deserialize, Serialize};

/// The step of a create that failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailedStep {
    /// `create-workspace` (with one request: nothing, it is skipped).
    CreateWorkspace,
    /// The first terminal or tab.
    FirstTab,
}

/// The kind of error a step threw, as far as the rule reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailureKind {
    /// The daemon answered with a command error (`DaemonError.command`): a refusal.
    Command,
    /// Anything else: not connected, a late reply, a decode error, a cancel.
    Other,
}

/// What `withTerminal` does after a failed step.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailurePlan {
    /// The create was refused: nothing was made.
    pub refused: bool,
    /// The app closes the workspace (`close-workspace` with `ifEmpty`, reason session end).
    pub closes: bool,
}

/// A failed `step` with `kind`: only a refused `create-workspace` made nothing and closes nothing;
/// every other failure closes the key.
pub fn failure_plan(step: FailedStep, kind: FailureKind) -> FailurePlan {
    let refused = step == FailedStep::CreateWorkspace && kind == FailureKind::Command;
    FailurePlan { refused, closes: !refused }
}

/// The end of a failed create after its close.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailureEnd {
    /// The repair marks the key kept after a failed close (`closeFailed`), so it repairs the
    /// workspace when its populate ends.
    pub kept_after_failed_close: bool,
    /// The error thrown is the step's own (a close error is logged, never thrown).
    pub throws_step_error: bool,
}

/// The end of a failed create: `close_failed` (the close threw) marks the key kept after a failed
/// close; the step's error stays the one thrown.
pub fn failure_end(plan: FailurePlan, close_failed: bool) -> FailureEnd {
    FailureEnd { kept_after_failed_close: plan.closes && close_failed, throws_step_error: true }
}

/// The repair's state of a key while this app populates it (`EmptyWorkspaceRepair.State`, the part
/// a create moves).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum RepairState {
    /// No state.
    None,
    /// `count` creates are populating it.
    Populating {
        /// How many.
        count: u32,
    },
    /// A create answered; waiting for the store to show a pane.
    AwaitingPane,
    /// Empty on purpose (its creator closed it): never repaired.
    Closing,
    /// Another state the create does not move (`repairing`, `failed`, ...).
    Other,
}

/// The state when a populate begins: one more create.
pub fn begin_populating(state: RepairState) -> RepairState {
    match state {
        RepairState::Populating { count } => RepairState::Populating { count: count + 1 },
        _ => RepairState::Populating { count: 1 },
    }
}

/// The end of one populate (`finishPopulating`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PopulateEnd {
    /// The key's next state.
    pub state: RepairState,
    /// The key leaves the kept-after-failed-close set.
    pub clears_kept: bool,
    /// The failure is recorded for the repair to show.
    pub records_failure: bool,
}

/// One populate of `state` ending: another populate keeps going; a failed one whose close failed
/// (`kept`) clears the state and records the failure (the repair may fill it); else a success awaits
/// its pane and a failure is closing. A key not populating is left as it is.
pub fn finish_populating(state: RepairState, succeeded: bool, kept: bool) -> PopulateEnd {
    let unchanged = PopulateEnd { state, clears_kept: false, records_failure: false };
    let RepairState::Populating { count } = state else { return unchanged };
    if count > 1 {
        return PopulateEnd { state: RepairState::Populating { count: count - 1 }, ..unchanged };
    }
    if !succeeded && kept {
        return PopulateEnd { state: RepairState::None, clears_kept: true, records_failure: true };
    }
    let state = if succeeded { RepairState::AwaitingPane } else { RepairState::Closing };
    PopulateEnd { state, clears_kept: false, records_failure: false }
}
