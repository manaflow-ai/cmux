//! Variant B's submission ledger (`WorkspaceAutoNamer`): each shown workspace has at most one
//! rename in flight, for the current title of its current target. The app plans, reads its
//! models and sends; this decides what is sent, what is skipped and what is released.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// A workspace on a machine.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Slot {
    /// The machine.
    pub machine_id: String,
    /// The workspace.
    pub workspace_id: String,
}

/// The identity a rename is fenced by: the daemon run and the name revision.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Target {
    /// The daemon run (`DaemonGeneration`, opaque here).
    pub daemon_generation: Value,
    /// The name revision.
    pub name_revision: u64,
}

/// One rename the rule asks for.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Submission {
    /// Its target.
    #[serde(flatten)]
    pub target: Target,
    /// The focused front chat's tab.
    pub front_tab_id: String,
    /// That tab's agent session (opaque here).
    pub front_agent_session: Value,
    /// The name.
    pub name: String,
}

#[derive(Debug, Clone)]
struct Live {
    submission: Submission,
    attempt: u64,
}

/// What a deferred send does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct MaySend {
    /// Send now.
    pub send: bool,
    /// The send was skipped and released: wake the workspace's observation to plan again.
    pub retry: bool,
}

/// One namer's ledger.
#[derive(Debug, Default)]
pub struct Ledger {
    submitted: HashMap<Slot, Live>,
    next_attempt: u64,
}

impl Ledger {
    /// Keeps the submissions of the listed workspaces only.
    pub fn list(&mut self, slots: &[Slot]) {
        self.submitted.retain(|slot, _| slots.contains(slot));
    }

    /// A plan of `slot` read `target` and, when the rule asks for one, `candidate`. A live
    /// submission for another target is dropped; returns whether the candidate is new (the
    /// live one for an older title is dropped then, so its late completion cannot clear it).
    pub fn plan(&mut self, slot: &Slot, target: &Target, candidate: Option<&Submission>) -> bool {
        if self.submitted.get(slot).is_some_and(|live| &live.submission.target != target) {
            self.submitted.remove(slot);
        }
        let Some(candidate) = candidate else {
            return false;
        };
        if let Some(live) = self.submitted.get(slot) {
            if &live.submission == candidate {
                return false;
            }
            self.submitted.remove(slot);
        }
        true
    }

    /// Queues `submission` (the app checked its target is still current): its attempt, or
    /// `None` when that very submission is already live.
    pub fn begin(&mut self, slot: &Slot, submission: Submission) -> Option<u64> {
        if self.submitted.get(slot).is_some_and(|live| live.submission == submission) {
            return None;
        }
        let attempt = self.next_attempt;
        self.next_attempt = self.next_attempt.wrapping_add(1);
        self.submitted.insert(slot.clone(), Live { submission, attempt });
        Some(attempt)
    }

    /// Right before the daemon request: send when `attempt` is still live and its target still
    /// `current`; a stale target releases it and asks for a retry.
    pub fn may_send(&mut self, slot: &Slot, attempt: u64, current: bool) -> MaySend {
        if !self.is_live(slot, attempt) {
            return MaySend { send: false, retry: false };
        }
        if !current {
            self.submitted.remove(slot);
            return MaySend { send: false, retry: true };
        }
        MaySend { send: true, retry: false }
    }

    /// The queue refused `attempt` or its accepted send failed: release that exact attempt.
    pub fn release(&mut self, slot: &Slot, attempt: u64) {
        if self.is_live(slot, attempt) {
            self.submitted.remove(slot);
        }
    }

    fn is_live(&self, slot: &Slot, attempt: u64) -> bool {
        self.submitted.get(slot).is_some_and(|live| live.attempt == attempt)
    }
}
