//! Which sidebar rows are automatic sessions, folded by default
//! (`sidebar.showAutomaticSessions`, off).
//!
//! A workspace no person started and that is no chat's subagent (a script, an
//! automation, a launcher or a daemon opened it: the daemon records it at the
//! create, `extra.created_by.kind` `script`) leaves its list's working order
//! for one quiet "Automatic (N)" row at the list's end; the row opens them
//! below it. A person's workspace (no record, or `person`) and a subagent (an
//! agent session made it: `agent`, the chat it nests under) always show. So does an automatic row that is pinned or that needs the
//! person (a question or a permission prompt waits): the fold never hides a
//! row that asks for them. A row marked Done or archived belongs to those
//! folds. With the setting on, every row draws in place.
//!
//! Pure: the app sends one [`Candidate`] per drawn workspace row and folds the
//! answer (`sidebar_automatic_plan` through `cmux_layout_reducer_json`).

use serde::{Deserialize, Serialize};

/// Who made the row's workspace (`extra.created_by.kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Creator {
    Person,
    Agent,
    Script,
}

/// One drawn workspace row and the facts the rule reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    /// None: the workspace has no record (made by the person in the app, or
    /// before the daemon kept one).
    pub created_by: Option<Creator>,
    pub pinned: bool,
    /// A question or a permission prompt waits for the person.
    pub needs_input: bool,
    pub archived: bool,
    pub marked_done: bool,
}

/// Why a row shows, or that it folds as automatic.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Automatic,
    Person,
    Subagent,
    Pinned,
    NeedsInput,
    Archived,
    MarkedDone,
}

/// The rule for one row.
pub fn verdict(candidate: &Candidate) -> Verdict {
    match candidate.created_by {
        None | Some(Creator::Person) => return Verdict::Person,
        Some(Creator::Agent) => return Verdict::Subagent,
        Some(Creator::Script) => {}
    }
    // The other folds own these rows: they never draw twice.
    if candidate.archived {
        return Verdict::Archived;
    }
    if candidate.marked_done {
        return Verdict::MarkedDone;
    }
    if candidate.pinned {
        return Verdict::Pinned;
    }
    if candidate.needs_input {
        return Verdict::NeedsInput;
    }
    Verdict::Automatic
}

/// One plan request.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub candidates: Vec<Candidate>,
    /// `sidebar.showAutomaticSessions`: every row draws in place.
    pub show_automatic: bool,
}

/// The answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    /// Indices of the candidates that fold behind "Automatic (N)", in the
    /// request's order.
    pub automatic: Vec<usize>,
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    if request.show_automatic {
        return Plan::default();
    }
    let automatic = request
        .candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| verdict(candidate) == Verdict::Automatic)
        .map(|(index, _)| index)
        .collect();
    Plan { automatic }
}

#[cfg(test)]
#[path = "automatic_tests.rs"]
mod tests;
