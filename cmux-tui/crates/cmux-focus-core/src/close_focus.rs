//! The focus successor rules for every close kind
//! (plans/cmux-next/close-focus.md; formal model closefocus.tla): one pure
//! function per kind. The focus reducer runs the pane rule ([`pane`]); the
//! app's tab selection runs [`tab`] (with [`live_openers`]), and window and
//! sidebar selection run [`workspace`]. Nothing else decides a successor.
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

/// The tab a pane selects after `selected` closed: the next shown tab after
/// it, else the previous shown one. `old` is the strip order before the
/// close, `shown` the tabs that survive and are not hidden (a collapsed
/// group's members are hidden). When no shown tab survives, the first
/// surviving tab (its group then expands).
///
/// `opener` maps a link tab to the tab that opened it (live relations only,
/// among `old`: [`live_openers`]). A closed tab in that tree goes back to
/// its family first, in Chrome's order (`DetermineNewSelectedIndex`): its
/// next child, else a sibling (the next tab with its opener), else its
/// opener. Only shown, surviving tabs count. Tabs without relations
/// (terminals, agents, a browser tab after an unrelated switch) keep
/// next-else-previous.
pub fn tab<T: Eq + Hash + Clone>(
    selected: Option<&T>,
    old: &[T],
    surviving: &[T],
    shown: &HashSet<T>,
    opener: &HashMap<T, T>,
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
    if let Some(family) = opener_family(selected, old, opener, visible) {
        return Some(family.clone());
    }
    neighbor(selected, old, true, visible)
        .or_else(|| surviving.iter().find(|id| shown.contains(*id)))
        .or_else(|| neighbor(selected, old, true, |id| live.contains(id)))
        .or_else(|| surviving.first())
        .cloned()
}

/// Chrome's opener step for a closed tab: the next child of `closed`, else
/// the next tab with the same opener, else the opener. "Next" is Chrome's
/// `GetIndexOfNextWebContentsOpenedBy`: the nearest after `closed`, else
/// the nearest before it. None when none qualifies.
pub fn opener_family<'a, T: Eq + Hash>(
    closed: &T,
    old: &'a [T],
    opener: &'a HashMap<T, T>,
    qualifies: impl Fn(&T) -> bool,
) -> Option<&'a T> {
    if opener.is_empty() {
        return None;
    }
    let opened_by = |parent: &T| -> Option<&'a T> {
        let (mut after, mut before) = around(closed, old)?;
        let child = |id: &&T| opener.get(*id) == Some(parent) && qualifies(id);
        after.find(child).or_else(|| before.find(child))
    };
    if !old.contains(closed) {
        return None;
    }
    if let Some(child) = opened_by(closed) {
        return Some(child);
    }
    let parent = opener.get(closed)?;
    if let Some(sibling) = opened_by(parent) {
        return Some(sibling);
    }
    qualifies(parent).then_some(parent)
}

/// The opener relations among `order`, from `opener` (child to opener,
/// possibly naming tabs that are gone). A tab whose opener is not in
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
