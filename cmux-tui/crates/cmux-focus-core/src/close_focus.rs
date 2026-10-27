//! The pane successor rule when the focused pane closes
//! (plans/cmux-next/close-focus.md; formal model closefocus.tla).
//!
//! - C1 a focus that survives stays,
//! - C2 the successor is a surviving, shown pane,
//! - C3 the successor is none only when no shown pane survives,
//! - C4 deterministic: the result depends only on the arguments.

use crate::state::CloseFocusPolicy;
use std::collections::HashSet;

/// The item in `old` order to focus after `closed` left: the next surviving
/// one after it, else the previous one (`prefer_next`), or the reverse.
fn neighbor<'a>(
    closed: &str,
    old: &'a [String],
    prefer_next: bool,
    survives: impl Fn(&str) -> bool,
) -> Option<&'a String> {
    let index = old.iter().position(|id| id == closed)?;
    let after = old.iter().skip(index + 1).find(|id| survives(id));
    let before = old.iter().take(index).rev().find(|id| survives(id));
    if prefer_next { after.or(before) } else { before.or(after) }
}

fn first_pane(columns: &[Vec<String>], history: &[String]) -> Option<String> {
    let all: Vec<&String> = columns.iter().flatten().collect();
    history.iter().find(|id| all.contains(id)).or_else(|| all.first().copied()).cloned()
}

/// The pane to focus after `focused` closed. `before` holds the columns of
/// the screen that showed it, in visual order, each its panes in layout
/// order. `after[i]` holds the panes of that same column (by column
/// identity) after the change, empty when the column is gone. `history` is
/// this window's focus history for the workspace, newest first. Returns
/// `focused` when it survives.
pub fn pane(
    focused: Option<&str>,
    before: &[Vec<String>],
    after: &[Vec<String>],
    history: &[String],
    policy: CloseFocusPolicy,
) -> Option<String> {
    let surviving: HashSet<&str> = after.iter().flatten().map(String::as_str).collect();
    let Some(focused) = focused else { return first_pane(after, history) };
    if surviving.contains(focused) {
        return Some(focused.to_owned());
    }
    if policy == CloseFocusPolicy::MostRecent
        && let Some(recent) =
            history.iter().find(|id| id.as_str() != focused && surviving.contains(id.as_str()))
    {
        return Some(recent.clone());
    }
    let Some(column) = before.iter().position(|col| col.iter().any(|id| id == focused)) else {
        return first_pane(after, history);
    };
    let (Some(before_column), Some(after_column)) = (before.get(column), after.get(column)) else {
        return first_pane(after, history);
    };
    let stayed: HashSet<&str> = after_column.iter().map(String::as_str).collect();
    if let Some(in_column) = neighbor(focused, before_column, false, |id| stayed.contains(id)) {
        return Some(in_column.clone());
    }
    if let Some(added) =
        history.iter().find(|id| stayed.contains(id.as_str())).or_else(|| after_column.first())
    {
        return Some(added.clone());
    }
    // The column is empty or gone: the nearest non-empty column to the
    // left, else to the right.
    let alive = |index: usize| after.get(index).filter(|panes| !panes.is_empty());
    let left = (0..column).rev().find_map(alive);
    let right = (column + 1..before.len()).find_map(alive);
    let Some(next) = left.or(right) else { return first_pane(after, history) };
    history.iter().find(|id| next.contains(id)).or_else(|| next.first()).cloned()
}
