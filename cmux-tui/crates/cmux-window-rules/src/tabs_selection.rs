//! Chrome's tab multi-selection for one strip (`ui::ListSelectionModel`,
//! Leo 2026-10-19: "we need to be able to multi select those tabs") and its
//! moves (`TabStripModel::MoveSelectedTabsTo`). Cmd-click adds a tab or takes
//! it out, Shift-click selects the range from the anchor to the clicked tab,
//! and a plain click or Esc goes back to the one active tab. The active tab is
//! always one of the selected tabs; `ids` is empty while only the active tab
//! is selected, which is the usual state.
//!
//! The Mac app's `TabMultiSelection` and `TabSelectionMove` ask here (app FFI
//! ops `tab_selection*`); schemas/tab-selection/vectors.json pins the Swift
//! rules' answers from before the move.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// The strip's selection beyond its active tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MultiSelection {
    /// Every selected tab, the active one included. Never a single tab: empty instead.
    pub ids: BTreeSet<String>,
    /// Where a Shift-click range starts: the last tab clicked without Shift
    /// (Chrome's anchor). None reads as the active tab.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anchor: Option<String>,
}

/// The click's kind, from its modifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Click {
    /// No modifier: the clicked tab alone.
    Plain,
    /// Cmd: the clicked tab joins the selection or leaves it.
    Toggle,
    /// Shift: the range from the anchor to the clicked tab, instead of the selection.
    Range,
    /// Cmd-Shift: the range from the anchor to the clicked tab, added to the selection.
    AddRange,
}

impl MultiSelection {
    /// More than one tab is selected.
    pub fn is_multiple(&self) -> bool {
        self.ids.len() > 1
    }

    /// Applies a click on `id` in `order` (display order) while `active` is
    /// the active tab. Returns the tab to make active, None to leave the
    /// active tab as it is.
    pub fn click(
        &mut self,
        id: &str,
        click: Click,
        order: &[String],
        active: Option<&str>,
    ) -> Option<String> {
        let current: BTreeSet<String> = if self.is_multiple() {
            self.ids.clone()
        } else {
            active.map(str::to_owned).into_iter().collect()
        };
        match click {
            Click::Plain => {
                self.ids.clear();
                self.anchor = Some(id.to_owned());
                Some(id.to_owned())
            }
            Click::Toggle => {
                self.anchor = Some(id.to_owned());
                if !current.contains(id) {
                    let mut joined = current;
                    joined.insert(id.to_owned());
                    self.set(joined);
                    return Some(id.to_owned());
                }
                // The last selected tab stays selected (Chrome).
                if current.len() <= 1 {
                    return None;
                }
                let mut rest = current;
                rest.remove(id);
                let next = if Some(id) == active {
                    // The active tab left: the nearest selected tab after it
                    // becomes active, else the one before.
                    let index = position(order, id).unwrap_or(order.len());
                    let after = &order[(index + 1).min(order.len())..];
                    let before = &order[..index.min(order.len())];
                    after
                        .iter()
                        .find(|tab| rest.contains(*tab))
                        .or_else(|| before.iter().rev().find(|tab| rest.contains(*tab)))
                        .cloned()
                } else {
                    None
                };
                self.set(rest);
                if Some(id) != active {
                    return None;
                }
                self.anchor = next.clone();
                next
            }
            Click::Range | Click::AddRange => {
                let start = match self.anchor.as_deref() {
                    Some(anchor) if position(order, anchor).is_some() => anchor.to_owned(),
                    _ => active.unwrap_or(id).to_owned(),
                };
                let (a, b) = (position(order, &start)?, position(order, id)?);
                let range: BTreeSet<String> = order[a.min(b)..=a.max(b)].iter().cloned().collect();
                self.set(if click == Click::Range { range } else { &current | &range });
                self.anchor = Some(start);
                Some(id.to_owned())
            }
        }
    }

    /// Back to the active tab alone.
    pub fn clear(&mut self) {
        self.ids.clear();
    }

    /// Tabs that left the strip leave the selection; fewer than two left is no selection.
    pub fn follow(&mut self, order: &[String]) {
        if self.ids.is_empty() && self.anchor.is_none() {
            return;
        }
        let present: BTreeSet<&str> = order.iter().map(String::as_str).collect();
        if self.anchor.as_deref().is_some_and(|anchor| !present.contains(anchor)) {
            self.anchor = None;
        }
        let kept = self.ids.iter().filter(|id| present.contains(id.as_str())).cloned().collect();
        self.set(kept);
    }

    /// The active tab changed (a click, a shortcut, the CLI, a close): a tab
    /// outside the selection ends it, as in Chrome; a selected tab keeps it.
    pub fn activated(&mut self, id: Option<&str>) {
        if id.is_some_and(|id| self.ids.contains(id)) {
            return;
        }
        self.ids.clear();
    }

    fn set(&mut self, selection: BTreeSet<String>) {
        self.ids = if selection.len() > 1 { selection } else { BTreeSet::new() };
    }
}

fn position(order: &[String], id: &str) -> Option<usize> {
    order.iter().position(|tab| tab == id)
}

/// Chrome's `TabStripModel::MoveSelectedTabsTo`: the order after moving
/// `selection` to `index`, where `index` counts the strip's tabs without the
/// selected ones. `order` is the display order, pinned tabs first. The
/// selected tabs keep their order and stay in their section: pinned ones go to
/// `index` among the pinned tabs (the end of them when `index` is past them),
/// unpinned ones to `index` among the unpinned tabs (their start when `index`
/// is among the pinned tabs).
pub fn moving(
    order: &[String],
    pinned: &BTreeSet<String>,
    selection: &BTreeSet<String>,
    index: i64,
) -> Vec<String> {
    let pick = |selected: bool, is_pinned: bool| -> Vec<String> {
        order
            .iter()
            .filter(|tab| {
                selection.contains(*tab) == selected && pinned.contains(*tab) == is_pinned
            })
            .cloned()
            .collect()
    };
    let (rest_pinned, rest_unpinned) = (pick(false, true), pick(false, false));
    let (moved_pinned, moved_unpinned) = (pick(true, true), pick(true, false));
    let clamp = |at: i64, len: usize| at.clamp(0, len as i64) as usize;
    let pinned_at = clamp(index, rest_pinned.len());
    let unpinned_at = clamp(index.saturating_sub(rest_pinned.len() as i64), rest_unpinned.len());
    let mut result = Vec::with_capacity(order.len());
    result.extend_from_slice(&rest_pinned[..pinned_at]);
    result.extend(moved_pinned);
    result.extend_from_slice(&rest_pinned[pinned_at..]);
    result.extend_from_slice(&rest_unpinned[..unpinned_at]);
    result.extend(moved_unpinned);
    result.extend_from_slice(&rest_unpinned[unpinned_at..]);
    result
}

/// One move of a multi-tab drop: the tab and its final display index.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Step {
    pub id: String,
    pub index: usize,
}

/// The next one-tab move that brings `current` closer to `target`, None once
/// they agree. The app moves a multi-tab drop one tab at a time (the daemon
/// moves one tab per command), reading the order each move left. Tabs only
/// one side has are left out.
pub fn next_step(current: &[String], target: &[String]) -> Option<Step> {
    let in_target: BTreeSet<&str> = target.iter().map(String::as_str).collect();
    let in_current: BTreeSet<&str> = current.iter().map(String::as_str).collect();
    let now: Vec<&str> =
        current.iter().map(String::as_str).filter(|tab| in_target.contains(tab)).collect();
    let goal: Vec<&str> =
        target.iter().map(String::as_str).filter(|tab| in_current.contains(tab)).collect();
    let index = (0..now.len().min(goal.len())).find(|&index| now[index] != goal[index])?;
    // Its index in `current`, which can hold tabs `target` does not.
    let id = goal[index];
    let at = index
        .checked_sub(1)
        .and_then(|before| position(current, now[before]))
        .map_or(0, |before| before + 1);
    let from = position(current, id).unwrap_or(0);
    Some(Step { id: id.to_owned(), index: if from < at { at - 1 } else { at } })
}

#[cfg(test)]
#[path = "tabs_selection_tests.rs"]
mod tests;
