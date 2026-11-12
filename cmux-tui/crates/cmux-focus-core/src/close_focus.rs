//! The focus successor rules for every close kind
//! (plans/cmux-next/close-focus.md; formal model closefocus.tla): one pure
//! function per kind. The focus reducer runs the pane rule ([`pane`]); the
//! app's tab selection, the daemon's active tab and the cmux-tui client run
//! [`tab`], and window and sidebar selection run [`workspace`]. Nothing else
//! decides a successor. ([`live_openers`] keeps the browser's opener tree for
//! where a link's new tab goes; it no longer picks a close successor.)
//!
//! Shared contract (the model checks in this crate's tests):
//! - C1 a focus that survives stays (closing an unfocused item, or a close
//!   by another client or the daemon of an item this client did not focus,
//!   never moves focus),
//! - C2 the successor is a surviving, shown item,
//! - C3 the successor is none only when no shown item survives,
//! - C4 deterministic: the result depends only on the arguments.
//!
//! The rules compare ids only by identity, so they take any `Eq + Hash`
//! id: the app's string ids, or the small integers its C ABI maps them to.

use crate::state::CloseFocusPolicy;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;

/// The items of `old` after and before `closed` (nearest first), or none
/// when `closed` is not in `old`.
fn around<'a, T: PartialEq>(
    closed: &T,
    old: &'a [T],
) -> Option<(impl Iterator<Item = &'a T>, impl Iterator<Item = &'a T>)> {
    let index = old.iter().position(|id| id == closed)?;
    let (before, rest) = old.split_at_checked(index)?;
    Some((rest.iter().skip(1), before.iter().rev()))
}

/// The item in `old` order to focus after `closed` left: the next surviving
/// one after it, else the previous one (`prefer_next`), or the reverse.
/// None when `closed` was not in `old` or nothing survives.
pub fn neighbor<'a, T: PartialEq>(
    closed: &T,
    old: &'a [T],
    prefer_next: bool,
    survives: impl Fn(&T) -> bool,
) -> Option<&'a T> {
    let (mut after, mut before) = around(closed, old)?;
    let next = after.find(|id| survives(id));
    let previous = before.find(|id| survives(id));
    if prefer_next { next.or(previous) } else { previous.or(next) }
}

/// The newest pane of `history` in `panes`, else the first of `panes`.
fn entry<'a, T: PartialEq>(panes: &'a [T], history: &'a [T]) -> Option<&'a T> {
    history.iter().find(|id| panes.contains(id)).or_else(|| panes.first())
}

fn first_pane<T: PartialEq + Clone>(columns: &[Vec<T>], history: &[T]) -> Option<T> {
    let all: Vec<&T> = columns.iter().flatten().collect();
    history.iter().find(|id| all.contains(id)).or_else(|| all.first().copied()).cloned()
}

/// The pane to focus after `focused` closed. `before` holds the columns of
/// the screen that showed it, in visual order, each its panes in layout
/// order. `after[i]` holds the panes of that same column (by column
/// identity) after the change, empty when the column is gone. `history` is
/// this window's focus history for the workspace, newest first. Returns
/// `focused` when it survives.
pub fn pane<T: Eq + Hash + Clone>(
    focused: Option<&T>,
    before: &[Vec<T>],
    after: &[Vec<T>],
    history: &[T],
    policy: CloseFocusPolicy,
) -> Option<T> {
    let surviving: HashSet<&T> = after.iter().flatten().collect();
    let Some(focused) = focused else { return first_pane(after, history) };
    if surviving.contains(focused) {
        return Some(focused.clone());
    }
    if policy == CloseFocusPolicy::MostRecent
        && let Some(recent) = history.iter().find(|id| *id != focused && surviving.contains(id))
    {
        return Some(recent.clone());
    }
    let Some(column) = before.iter().position(|col| col.contains(focused)) else {
        return first_pane(after, history);
    };
    let (Some(old_column), Some(new_column)) = (before.get(column), after.get(column)) else {
        return first_pane(after, history);
    };
    let stayed: HashSet<&T> = new_column.iter().collect();
    if let Some(in_column) = neighbor(focused, old_column, false, |id| stayed.contains(id)) {
        return Some(in_column.clone());
    }
    if let Some(added) =
        history.iter().find(|id| stayed.contains(id)).or_else(|| new_column.first())
    {
        return Some(added.clone());
    }
    // The column is empty or gone: the nearest non-empty column to the
    // left, else to the right.
    let alive = |col: &&Vec<T>| !col.is_empty();
    let (left, right) = after.split_at_checked(column).unwrap_or((after, &[]));
    let next = left.iter().rev().find(alive).or_else(|| {
        right.iter().skip(1).take(before.len().saturating_sub(column).saturating_sub(1)).find(alive)
    });
    let Some(next) = next else { return first_pane(after, history) };
    entry(next, history).cloned()
}

/// [`pane`] with cmux classic's fallback (issue 38194): under `MostRecent`,
/// when no surviving pane of `history` other than `focused` is left (a tree
/// whose remaining panes were never focused, as after a relaunch), the
/// closed pane's `sibling`, the first pane of the subtree that takes its
/// space (Bonsplit's `closePaneRecursively`), when it survives. Otherwise
/// exactly [`pane`].
pub fn pane_or_sibling<T: Eq + Hash + Clone>(
    focused: Option<&T>,
    before: &[Vec<T>],
    after: &[Vec<T>],
    history: &[T],
    sibling: Option<&T>,
    policy: CloseFocusPolicy,
) -> Option<T> {
    if policy == CloseFocusPolicy::MostRecent
        && let Some(focused) = focused
        && let Some(sibling) = sibling
    {
        let surviving: HashSet<&T> = after.iter().flatten().collect();
        let recent = history.iter().any(|id| id != focused && surviving.contains(id));
        if !surviving.contains(focused) && !recent && surviving.contains(sibling) {
            return Some(sibling.clone());
        }
    }
    pane(focused, before, after, history, policy)
}

/// The tab a pane selects after `selected` closed: the shown tab before it
/// in strip order (left in a strip, above in a vertical list), else the
/// shown tab after it (Lawrence 2026-11-08: "it should always focus the tab
/// before it if it exists"). One rule for every tab kind and every way a tab
/// closes (Cmd-W, the close button, a middle click, the menus, the CLI, a
/// terminal that exits, a batch close): the app's tab selection, the
/// daemon's active tab and the cmux-tui client all call this. `old` is the
/// strip order before the close (pinned tabs first, so closing the first
/// unpinned tab selects the last pinned one), `surviving` the tabs left and
/// `shown` the surviving tabs that are not hidden (a collapsed group's
/// members are hidden and skipped). When no shown tab survives, the
/// surviving tab before it, else after it (its group then expands). A
/// surviving selection stays.
pub fn tab<T: Eq + Hash + Clone>(
    selected: Option<&T>,
    old: &[T],
    surviving: &[T],
    shown: &HashSet<T>,
) -> Option<T> {
    let live: HashSet<&T> = surviving.iter().collect();
    let Some(selected) = selected else {
        return surviving
            .iter()
            .find(|id| shown.contains(*id))
            .or_else(|| surviving.first())
            .cloned();
    };
    if live.contains(selected) {
        return Some(selected.clone());
    }
    let visible = |id: &T| live.contains(id) && shown.contains(id);
    neighbor(selected, old, false, visible)
        .or_else(|| surviving.iter().find(|id| shown.contains(*id)))
        .or_else(|| neighbor(selected, old, false, |id| live.contains(id)))
        .or_else(|| surviving.first())
        .cloned()
}

/// The opener relations among `order`, from `opener` (child to opener,
/// possibly naming tabs that are gone), for a link tab's slot. A tab whose opener is not in
/// `order` takes that opener's own opener, as Chrome's `FixOpeners` does
/// when a tab leaves the strip; a relation back to the tab itself is
/// dropped. Only tabs in `order` are keys.
pub fn live_openers<T: Eq + Hash + Clone>(opener: &HashMap<T, T>, order: &[T]) -> HashMap<T, T> {
    let present: HashSet<&T> = order.iter().collect();
    let mut result = HashMap::new();
    for tab in order {
        let mut seen: HashSet<&T> = HashSet::from([tab]);
        let mut parent = opener.get(tab);
        while let Some(current) = parent
            && !present.contains(current)
            && seen.insert(current)
        {
            parent = opener.get(current);
        }
        if let Some(parent) = parent
            && present.contains(parent)
            && parent != tab
        {
            result.insert(tab.clone(), parent.clone());
        }
    }
    result
}

/// The workspace a window shows after `shown` left it: the next one below
/// in the sidebar's visual order, else the one above. `old` is the order
/// before (a window's members, in the order they joined it, or the sidebar
/// model's), `surviving` the workspaces the window still lists. `orders`,
/// the sidebar's row orders before the close, most preferred first (the
/// rows as drawn, then the model's rows), are tried in turn: the first that
/// lists `shown` and has a surviving neighbor among `old` picks it. So a
/// drawn row hands off to a drawn row (folder sorting and a filter apply; a
/// collapsed group's members only when no drawn row is left), and a list
/// row never to a workspace no row lists (a pinned tile) while a row is
/// left. `old` decides last.
pub fn workspace<T: Eq + Hash + Clone>(
    shown: Option<&T>,
    old: &[T],
    surviving: &[T],
    orders: &[Vec<T>],
) -> Option<T> {
    let live: HashSet<&T> = surviving.iter().collect();
    let Some(shown) = shown else { return surviving.first().cloned() };
    if live.contains(shown) {
        return Some(shown.clone());
    }
    let members: HashSet<&T> = old.iter().collect();
    for order in orders.iter().filter(|order| order.contains(shown)) {
        let rows: Vec<T> =
            order.iter().filter(|id| *id == shown || members.contains(id)).cloned().collect();
        if let Some(next) = neighbor(shown, &rows, true, |id| live.contains(id)) {
            return Some(next.clone());
        }
    }
    neighbor(shown, old, true, |id| live.contains(id)).or_else(|| surviving.first()).cloned()
}
