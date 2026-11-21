//! Which agent chats have settled, and what Archive Settled Chats archives
//! (`sidebar.settleFinished`; leo-workspace design/sidebar.md, "Agent
//! workspace identity and organization").
//!
//! A chat settles when its last turn finished and the person has seen it:
//! the row leaves its list's working order for a folded "Settled (N)" row at
//! the list's end, after the rows that still work or ask, and before the Done
//! and Archived folds. It rises back by itself: a new turn, a question, an
//! unread answer, a failure or a lost agent each make it unsettled again.
//!
//! The rule tells a finished lifecycle from an unread badge. A finished turn
//! nobody has seen is unread, not settled: it stays in place with its badge.
//! A chat the person marked Done or archived belongs to those folds, never
//! this one, and a pinned row keeps its place. The rule synthesizes no row:
//! it only names rows the list already draws.
//!
//! Pure: the app sends one [`Candidate`] per drawn workspace row and draws
//! the answer (`sidebar_settle_plan` through `cmux_layout_reducer_json`).

use serde::{Deserialize, Serialize};

/// What the row's agent chats are doing, the most urgent first.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    /// A turn runs.
    Working,
    /// A permission prompt or a question waits for the person.
    NeedsInput,
    /// The last turn answered (seen or not: `unread` tells).
    Finished,
    /// The last turn failed.
    Failed,
    /// The agent process or its machine is gone.
    Lost,
    /// A pull request of the chat's has failing checks.
    CiFailing,
    /// Nothing runs and nothing is reported. The default.
    #[default]
    Idle,
}

/// One drawn workspace row and the facts the rule reads.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    /// The row stands for an agent chat (a terminal or a page never settles).
    pub chat: bool,
    pub lifecycle: Lifecycle,
    /// The row carries an unread badge or notification.
    pub unread: bool,
    /// The chat has had a turn (any recorded activity); a new, empty chat
    /// has nothing to settle.
    pub has_activity: bool,
    pub pinned: bool,
    pub archived: bool,
    /// The person marked it Done: the Done fold holds it.
    pub marked_done: bool,
}

/// Why a row stays in the active list, or that it settled.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Settled,
    NotChat,
    Working,
    NeedsInput,
    Unread,
    Failed,
    Lost,
    CiFailing,
    NoTurnYet,
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
    if candidate.unread {
        return Verdict::Unread;
    }
    if !candidate.has_activity {
        return Verdict::NoTurnYet;
    }
    Verdict::Settled
}

/// What asks for the plan.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    /// The list's layout: which rows draw behind the Settled fold.
    #[default]
    Layout,
    /// Archive Settled Chats: which rows archive, and which stay and why.
    Archive,
}

/// One plan request.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub candidates: Vec<Candidate>,
    pub trigger: Trigger,
}

/// Chats Archive Settled Chats leaves where they are, by what keeps each.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Kept {
    /// A finished answer the person has not read: archiving it would hide news.
    pub unread: Vec<usize>,
    /// A failed turn: it asks for a look first.
    pub failed: Vec<usize>,
    /// A lost agent: it asks for a look (reattach or close) first.
    pub lost: Vec<usize>,
    /// Working, waiting for an answer, or red CI.
    pub busy: Vec<usize>,
}

/// The answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    /// Indices of the settled candidates, in the request's order. For the
    /// Archive trigger, the ones it archives (archiving keeps their history
    /// and their chats reattach).
    pub settled: Vec<usize>,
    /// Archive only: the chats that stay, by reason. Empty for Layout.
    pub kept: Kept,
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    let mut plan = Plan::default();
    for (index, candidate) in request.candidates.iter().enumerate() {
        let verdict = verdict(candidate);
        if verdict == Verdict::Settled {
            plan.settled.push(index);
            continue;
        }
        if request.trigger != Trigger::Archive {
            continue;
        }
        match verdict {
            Verdict::Unread => plan.kept.unread.push(index),
            Verdict::Failed => plan.kept.failed.push(index),
            Verdict::Lost => plan.kept.lost.push(index),
            Verdict::Working | Verdict::NeedsInput | Verdict::CiFailing => {
                plan.kept.busy.push(index);
            }
            _ => {}
        }
    }
    plan
}

#[cfg(test)]
#[path = "settle_tests.rs"]
mod tests;
