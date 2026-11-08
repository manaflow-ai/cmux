//! The history actions' table (which action walks the location trail which
//! way, and what it says when there is nowhere to go; which action shows which
//! palette page) and Undo Layout Change's confirmation.

use serde::Serialize;

/// A walk of the location trail.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Back,
    Forward,
    Last,
}

/// What a walk says when the trail has nowhere to go (refused quietly: R136).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Nowhere {
    NothingBack,
    NothingForward,
    NothingLast,
}

/// One trail walk action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Walk {
    pub action: &'static str,
    pub direction: Direction,
    pub nowhere: Nowhere,
}

/// A history palette page.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Page {
    Locations,
    Closed,
    Search,
    Commands,
}

/// One action that shows a history palette page.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageAction {
    pub action: &'static str,
    pub page: Page,
}

/// The history actions' table.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Actions {
    pub walks: Vec<Walk>,
    pub pages: Vec<PageAction>,
    /// The actions that open the History page.
    pub history_page: Vec<&'static str>,
}

/// The history actions' table.
pub fn actions() -> Actions {
    Actions {
        walks: vec![
            Walk {
                action: "focusHistoryBack",
                direction: Direction::Back,
                nowhere: Nowhere::NothingBack,
            },
            Walk {
                action: "focusHistoryForward",
                direction: Direction::Forward,
                nowhere: Nowhere::NothingForward,
            },
            Walk {
                action: "focusHistoryLast",
                direction: Direction::Last,
                nowhere: Nowhere::NothingLast,
            },
        ],
        pages: vec![
            PageAction { action: "recentlyFocused", page: Page::Locations },
            PageAction { action: "recentlyClosed", page: Page::Closed },
            PageAction { action: "history.search", page: Page::Search },
            PageAction { action: "history.commands", page: Page::Commands },
        ],
        history_page: vec!["history.show", "browserShowHistory"],
    }
}

/// What Undo Layout Change does after the daemon's answer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoReply {
    /// The screen revision the next Undo Layout Change confirms; none: nothing pending.
    pub pending: Option<u64>,
    /// The undo waits for a confirmation because it closes this many panes (the refusal says so).
    pub closes_panes: Option<usize>,
}

/// The daemon asked to confirm an undo that closes panes: the next Undo on the
/// same revision confirms it, and this run says how many panes it closes.
pub fn undo_reply(
    confirmation_required: bool,
    revision: Option<u64>,
    closes_panes: Option<usize>,
) -> UndoReply {
    if !confirmation_required {
        return UndoReply::default();
    }
    UndoReply { pending: revision, closes_panes: Some(closes_panes.unwrap_or(1)) }
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod tests;
