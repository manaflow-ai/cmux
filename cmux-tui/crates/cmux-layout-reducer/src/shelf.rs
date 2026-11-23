//! Which agent chats sit on the working shelf (`sidebar.workingShelf`, off by
//! default; Leo's feature map 2026-11-23, item 16: "Chats waiting on subagents,
//! checks or watches fold into one row and return when they need you").
//!
//! A chat is shelved when no turn runs and it waits on work that will wake it
//! by itself: a background task started with `notify` (`bg_start`,
//! `run_wait`), a watch that wakes it, a background subagent or a working
//! sub-session (acpmux's summary `backgroundWaits`). The row leaves its list's
//! working order for one "Working (N)" row at the list's end, before the
//! Settled, Done and Archived folds. It comes back by itself: the wait's end
//! starts a turn (acpmux sends the chat the end), a question, an unread answer,
//! a failure or a lost agent each take it off the shelf, since the rule reads
//! the row's live state every time.
//!
//! A running turn is working, not waiting: it stays in place with its
//! spinner. A chat the person marked Done or archived belongs to those folds,
//! a pinned row keeps its place, and the rule makes up no row.
//!
//! Pure: the app sends one [`Candidate`] per drawn workspace row and folds the
//! answer (`sidebar_shelf_plan` through `cmux_layout_reducer_json`).

use serde::{Deserialize, Serialize};

pub use crate::settle::Lifecycle;

/// One drawn workspace row and the facts the rule reads.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    /// The row stands for an agent chat (a terminal or a page never shelves).
    pub chat: bool,
    pub lifecycle: Lifecycle,
    /// The row carries an unread badge or notification.
    pub unread: bool,
    /// What the chat waits on that wakes it by itself (acpmux's summary
    /// `backgroundWaits`, summed over the row's chats).
    pub background_waits: u32,
    pub pinned: bool,
    pub archived: bool,
    /// The person marked it Done: the Done fold holds it.
    pub marked_done: bool,
}

/// Why a row stays in the active list, or that it is shelved.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Shelved,
    NotChat,
    NothingRunning,
    Working,
    NeedsInput,
    Unread,
    Failed,
    Lost,
    CiFailing,
    Pinned,
    Archived,
    MarkedDone,
}

/// The rule for one row.
pub fn verdict(candidate: &Candidate) -> Verdict {
    if !candidate.chat {
        return Verdict::NotChat;
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
    match candidate.lifecycle {
        Lifecycle::Working => return Verdict::Working,
        Lifecycle::NeedsInput => return Verdict::NeedsInput,
        Lifecycle::Failed => return Verdict::Failed,
        Lifecycle::Lost => return Verdict::Lost,
        Lifecycle::CiFailing => return Verdict::CiFailing,
        Lifecycle::Finished | Lifecycle::Idle => {}
    }
    // An answer the person has not read needs them: it stays with its badge.
    if candidate.unread {
        return Verdict::Unread;
    }
    if candidate.background_waits == 0 {
        return Verdict::NothingRunning;
    }
    Verdict::Shelved
}

/// One plan request.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub candidates: Vec<Candidate>,
}

/// The answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    /// Indices of the shelved candidates, in the request's order.
    pub shelved: Vec<usize>,
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    Plan {
        shelved: request
            .candidates
            .iter()
            .enumerate()
            .filter(|(_, candidate)| verdict(candidate) == Verdict::Shelved)
            .map(|(index, _)| index)
            .collect(),
    }
}

#[cfg(test)]
#[path = "shelf_tests.rs"]
mod tests;
