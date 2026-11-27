//! The pane navigation hint chips (Swift `PaneNavigationHintPlan`): while
//! the pane-navigation modifier is held, each pane shows its Focus Pane
//! number and the move keys that reach it from the focused pane. Labels are
//! the window's resolved bindings: an unbound action shows nothing.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// The pane moves with a hint, in chip order: (action id, move).
pub const ACTIONS: [(&str, Move); 6] = [
    ("focusLeft", Move::Left),
    ("focusRight", Move::Right),
    ("focusUp", Move::Up),
    ("focusDown", Move::Down),
    ("focusPreviousPane", Move::Previous),
    ("focusNextPane", Move::Next),
];

/// The action that picks a pane by its number.
pub const FOCUS_PANE_BY_NUMBER: &str = "focusPaneByNumber";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Move {
    Left,
    Right,
    Up,
    Down,
    Previous,
    Next,
}

/// Whether a pressed action keeps the hints up (the moves and pane numbers).
pub fn keeps_hints_up(action: &str) -> bool {
    action == FOCUS_PANE_BY_NUMBER || ACTIONS.iter().any(|(id, _)| *id == action)
}

/// The directional neighbors of the focused pane.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Neighbors {
    pub left: Option<String>,
    pub right: Option<String>,
    pub up: Option<String>,
    pub down: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Plan {
    pub order: Vec<String>,
    pub focused: String,
    pub neighbors: Neighbors,
    /// Each bound move's label, by action id.
    pub labels: HashMap<String, String>,
    /// Each bound Focus Pane digit's label, by digit ("1" to "9").
    pub pane_number_labels: HashMap<String, String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chip {
    pub pane: String,
    pub text: String,
}

/// The chips, in pane order: each pane's number, then the moves that reach it.
pub fn chips(plan: &Plan) -> Vec<Chip> {
    let order = &plan.order;
    let count = order.len();
    let mut texts: HashMap<&str, Vec<&str>> = HashMap::new();
    for (index, pane) in order.iter().enumerate() {
        if !(index < 8 || index + 1 == count) {
            continue;
        }
        // 9 is always the last pane, as Focus Pane 1…9 picks it.
        let digit = if index + 1 == count && index >= 8 { 9 } else { index + 1 };
        if let Some(text) = plan.pane_number_labels.get(&digit.to_string()) {
            texts.entry(pane).or_default().push(text);
        }
    }
    let index = order.iter().position(|pane| *pane == plan.focused);
    for (id, step) in ACTIONS {
        let target = match step {
            Move::Previous | Move::Next => index.filter(|_| count > 1).and_then(|i| {
                let i = if step == Move::Next { (i + 1) % count } else { (i + count - 1) % count };
                order.get(i).map(String::as_str)
            }),
            Move::Left => plan.neighbors.left.as_deref(),
            Move::Right => plan.neighbors.right.as_deref(),
            Move::Up => plan.neighbors.up.as_deref(),
            Move::Down => plan.neighbors.down.as_deref(),
        };
        let Some(target) = target else { continue };
        if target == plan.focused {
            continue;
        }
        let Some(text) = plan.labels.get(id) else { continue };
        let pane = texts.entry(target).or_default();
        if !pane.contains(&text.as_str()) {
            pane.push(text);
        }
    }
    order
        .iter()
        .filter_map(|pane| {
            texts.get(pane.as_str()).map(|t| Chip { pane: pane.clone(), text: t.join(" ") })
        })
        .collect()
}

#[cfg(test)]
#[path = "pane_hints_tests.rs"]
mod tests;
