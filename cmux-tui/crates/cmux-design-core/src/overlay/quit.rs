//! The quit flow's pure rules (CmuxNextDesign/Quit/QuitUnsavedRegistry.swift): who still has
//! unsaved work, and how long each save may take.

use serde::{Deserialize, Serialize};

/// `QuitUnsavedRegistry.maxDeadline`: the longest a participant's save may take, in seconds.
pub const MAX_DEADLINE: f64 = 30.0;
/// The cap a non-interactive quit passes (`deadlineCap: .seconds(3)`).
pub const NONINTERACTIVE_CAP: f64 = 3.0;

/// `min(participant.quitFlushDeadline, deadlineCap ?? maxDeadline, maxDeadline)`, in seconds.
pub fn flush_deadline(participant: f64, cap: Option<f64>) -> f64 {
    participant.min(cap.unwrap_or(MAX_DEADLINE)).min(MAX_DEADLINE)
}

/// A registered participant, as the registry weighs it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Participant {
    pub id: String,
    pub has_unsaved_changes: bool,
}

/// `unsaved()`: the live participants (in registration order) with unsaved changes, one per id,
/// the first registered winning. Answers their ids.
pub fn unsaved(participants: &[Participant]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    participants
        .iter()
        .filter(|p| p.has_unsaved_changes && seen.insert(p.id.clone()))
        .map(|p| p.id.clone())
        .collect()
}
