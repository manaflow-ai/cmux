//! The one rule for what opens on the right of a pane: transcript subagents
//! ([`subagent_panes`]), side chats, Session Info sessions and transcript
//! session cards, and links opened to the right (the app's `LinkOpener`).
//! leo-workspace design/pane-placement.md; Leo 2026-10-30: "subagent
//! stuff... or anything we expect to open on "the right"... if there's
//! already a thing on the right, there should be logic for just putting it on
//! the lower pane of the right. that kinda split."
//!
//! - Nothing on the right: a new split right of the source.
//! - A terminal or browser, with a pane on the right that already holds that
//!   kind: a tab in that pane (the lowest such one), never a split. Leo
//!   2026-10-31: "imo in this case, just open it on the existing. you only
//!   need the rightmost botom auto split when there's a terminal that gets
//!   opened when there's already a browser, and vice versa".
//! - A document (a diff): a tab in the pane on the right that already shows a
//!   diff, else in the lowest pane on the right, never a lower split; with
//!   nothing there a split right, whatever the width floors say. Leo
//!   2026-11-03: "just put it in a tab???"; Lawrence 2026-11-03: "clicking
//!   view changes needs to open diff in pane split right".
//! - One pane on the right: a new split below it, the right column's lower
//!   pane.
//! - Two or more: a tab in the lowest pane, never another split.
//!
//! No split leaves the source under [`MINIMUM_CHAT_WIDTH`] or the right column
//! under [`MINIMUM_RIGHT_COLUMN_WIDTH`]: that open is a tab in the pane on the
//! right, or in the source's own pane when there is none.
//!
//! The app's `RightColumnPlacement` reads the column; the CLI's own beside
//! rule (`cmux-tui` `cli/beside.rs`) is the daemon side of the same idea.
//!
//! [`subagent_panes`]: crate::subagent_panes

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

/// The narrowest the source (the chat) stays after a split.
pub const MINIMUM_CHAT_WIDTH: f64 = 480.0;
/// The narrowest the right column may be for a split in it.
pub const MINIMUM_RIGHT_COLUMN_WIDTH: f64 = 420.0;
/// The layout's gutter: how far right of the source a column may start.
pub const GAP: f64 = 24.0;

/// What an open shows, for the same-kind rule: only the two kinds Leo named,
/// and a document, which is a tab in any pane on the right. Anything else (a
/// chat, a subagent, a file page) opens with no kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Terminal,
    Browser,
    Document,
}

/// Where the item opens.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "to")]
pub enum Decision {
    /// A new split right of the source.
    SplitRight,
    /// A new split below this pane, the right column's one pane.
    SplitBelow { pane: String },
    /// A tab in this pane; `None`: the source's own pane.
    Tab { pane: Option<String> },
}

/// The source's width and the right column beside it, top to bottom, with
/// each pane's width and the kinds of tab each pane holds. An unknown width
/// sets no floor.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Column {
    pub source_width: Option<f64>,
    pub panes: Vec<String>,
    pub widths: HashMap<String, f64>,
    pub kinds: HashMap<String, Vec<Kind>>,
}

impl Column {
    fn holds(&self, pane: &str, kind: Kind) -> bool {
        self.kinds.get(pane).is_some_and(|kinds| kinds.contains(&kind))
    }
}

/// Decides an open of `kind` (`None`: no kind) for `column`.
pub fn decide(column: &Column, kind: Option<Kind>) -> Decision {
    let panes = &column.panes;
    // A document never stays in the source's pane, so the chat is never what it replaces. The
    // pane already showing a diff first, so diffs gather in one pane; else the lowest.
    if kind == Some(Kind::Document) {
        let pane =
            panes.iter().rev().find(|pane| column.holds(pane, Kind::Document)).or(panes.last());
        return match pane {
            Some(pane) => Decision::Tab { pane: Some(pane.clone()) },
            None => Decision::SplitRight,
        };
    }
    let Some(right) = panes.first() else {
        // A split right halves the source: both halves must stay wide enough.
        let fits = column
            .source_width
            .is_none_or(|width| width / 2.0 >= MINIMUM_CHAT_WIDTH.max(MINIMUM_RIGHT_COLUMN_WIDTH));
        return if fits { Decision::SplitRight } else { Decision::Tab { pane: None } };
    };
    if let Some(kind) = kind
        && let Some(same) = panes.iter().rev().find(|pane| column.holds(pane, kind))
    {
        return Decision::Tab { pane: Some(same.clone()) };
    }
    if panes.len() > 1 {
        return Decision::Tab { pane: panes.last().cloned() };
    }
    let fits = column.source_width.is_none_or(|width| width >= MINIMUM_CHAT_WIDTH)
        && column.widths.get(right).is_none_or(|width| *width >= MINIMUM_RIGHT_COLUMN_WIDTH);
    if fits {
        Decision::SplitBelow { pane: right.clone() }
    } else {
        Decision::Tab { pane: Some(right.clone()) }
    }
}

/// A pane's frame, in one top-down (flipped) space.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    fn max_x(&self) -> f64 {
        self.x + self.width
    }
    fn max_y(&self) -> f64 {
        self.y + self.height
    }
}

/// The right column beside `source`: the panes whose left edge is the nearest
/// one at or past the source's right edge (within `gap`, the layout's gutter)
/// and that overlap the source's height, top to bottom (panes level with each
/// other in key order). Geometry only, so a column of several panes reads the
/// same whichever of them was focused last.
pub fn beside(source: &str, frames: &BTreeMap<String, Rect>, gap: f64) -> Vec<String> {
    let Some(origin) = frames.get(source) else { return Vec::new() };
    let near: Vec<(&String, &Rect)> = frames
        .iter()
        .filter(|(pane, rect)| {
            pane.as_str() != source
                && rect.x >= origin.max_x() - 1.0
                && rect.y < origin.max_y()
                && rect.max_y() > origin.y
        })
        .collect();
    let Some(nearest) = near.iter().map(|(_, rect)| rect.x).reduce(f64::min) else {
        return Vec::new();
    };
    if nearest - origin.max_x() > gap {
        return Vec::new();
    }
    let mut column: Vec<(&String, &Rect)> =
        near.into_iter().filter(|(_, rect)| (rect.x - nearest).abs() <= 1.0).collect();
    column.sort_by(|a, b| a.1.y.total_cmp(&b.1.y));
    column.into_iter().map(|(pane, _)| pane.clone()).collect()
}

#[cfg(test)]
#[path = "right_column_tests.rs"]
mod tests;
