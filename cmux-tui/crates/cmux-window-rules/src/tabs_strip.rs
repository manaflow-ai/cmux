//! The tab strip's commands on its tabs, as Chrome has them: what Cmd-W does
//! to a tab that cannot close, which tabs Close Other Tabs and Close Tabs to
//! the Left or Right close and which tab they select, where Move Tab Left or
//! Right takes a tab, and which tab Next or Previous Tab reaches.
//!
//! Every rule reads the strip in display order (the Mac app's
//! `TabStripModel.orderedTabs`: pinned tabs first, then the rest with each
//! group's members together, no group on a pinned tab) and the collapsed
//! groups, whose members the strip hides. The Mac app's `TabStripModel` asks
//! here (app FFI ops `tab_strip_*`); schemas/tab-strip-commands/vectors.json
//! pins the Swift rules' answers from before the move.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// One tab of the strip, in display order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    pub id: String,
    pub pinned: bool,
    /// False for a tab that cannot close (Home's tab, `pinned-dock-v1`).
    pub closable: bool,
    pub group: Option<String>,
}

/// The strip: its tabs in display order and its collapsed groups.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Strip {
    pub tabs: Vec<Tab>,
    pub collapsed: BTreeSet<String>,
}

/// What the person's Cmd-W does to a tab.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum KeyboardClose {
    /// Close the tab, pinned or not, as Chrome's Cmd-W does (cmux-ad i8).
    Close,
    /// Keep a tab that cannot close (Home's tab) and select `tab` instead.
    Select { tab: String },
    /// Do nothing and say nothing: a tab that cannot close with nothing
    /// else to select. Cmd-W in the Home Chief pane is not an error.
    Ignore,
}

/// The tabs one of Chrome's close commands closes, each in strip order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct ClosedBy {
    /// Close Other Tabs.
    pub others: Vec<String>,
    /// Close Tabs to the Left.
    pub left: Vec<String>,
    /// Close Tabs to the Right.
    pub right: Vec<String>,
}

impl Strip {
    fn index(&self, id: &str) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == id)
    }

    /// Whether the strip shows `tab`: not a member of a collapsed group.
    pub fn shows(&self, tab: &Tab) -> bool {
        tab.group.as_ref().is_none_or(|group| !self.collapsed.contains(group))
    }

    /// What Cmd-W does to `id`: it closes it, pinned or not (Lawrence
    /// 2026-11-08, cmux-ad i8: "make it consistent, match chrome's
    /// behavior"). Only a tab that cannot close is kept: the next shown tab
    /// in strip order is selected (the previous one when it is last), else
    /// nothing.
    pub fn keyboard_close(&self, id: &str) -> KeyboardClose {
        let Some(index) =
            self.index(id).filter(|&index| self.tabs.get(index).is_some_and(|tab| !tab.closable))
        else {
            return KeyboardClose::Close;
        };
        let after = self.tabs.iter().skip(index.saturating_add(1)).find(|tab| self.shows(tab));
        let before = || self.tabs.iter().take(index).rev().find(|tab| self.shows(tab));
        match after.or_else(before) {
            Some(tab) => KeyboardClose::Select { tab: tab.id.clone() },
            None => KeyboardClose::Ignore,
        }
    }

    /// Chrome's close commands (`TabStripModel::GetTabsClosedByCommand`)
    /// from `id`: Close Other Tabs, Close Tabs to the Left and to the Right
    /// never close a pinned tab or one that cannot close. To the left or
    /// right of a tab not in the strip is nothing.
    pub fn closed_by(&self, id: &str) -> ClosedBy {
        let closes = |tab: &&Tab| !tab.pinned && tab.closable;
        let ids = |tabs: &mut dyn Iterator<Item = &Tab>| {
            tabs.filter(closes).map(|tab| tab.id.clone()).collect()
        };
        let others = self.tabs.iter().filter(|tab| tab.id != id).filter(closes);
        let (left, right) = match self.index(id) {
            Some(index) => (
                ids(&mut self.tabs.iter().take(index)),
                ids(&mut self.tabs.iter().skip(index.saturating_add(1))),
            ),
            None => (Vec::new(), Vec::new()),
        };
        ClosedBy { others: others.map(|tab| tab.id.clone()).collect(), left, right }
    }

    /// Where Move Tab Left (`offset` -1) or Right (+1) takes `id`, as a
    /// display index; None at the edge of its section. A pinned tab moves
    /// only among the pinned tabs and an unpinned one only among the rest. A
    /// group's members stay together, so a tab outside a group steps past the
    /// whole group, and a member moves only among its group's members.
    pub fn move_index(&self, id: &str, offset: i64) -> Option<usize> {
        let index = self.index(id)?;
        if offset == 0 {
            return None;
        }
        let pinned = self.tabs.iter().filter(|tab| tab.pinned).count();
        let tab = self.tabs.get(index)?;
        let mut section = if tab.pinned { 0..pinned } else { pinned..self.tabs.len() };
        let members = |group: &String| {
            let first = self.tabs.iter().position(|tab| tab.group.as_ref() == Some(group));
            let last = self.tabs.iter().rposition(|tab| tab.group.as_ref() == Some(group));
            first.zip(last)
        };
        if let Some((first, last)) = tab.group.as_ref().and_then(members) {
            section = first..last.saturating_add(1);
        }
        let target = i64::try_from(index)
            .ok()
            .and_then(|index| index.checked_add(offset))
            .and_then(|target| usize::try_from(target).ok())
            .filter(|t| section.contains(t))?;
        // Beside another group: past all of it (one step inside would be undone by the ordering).
        let beside = self.tabs.get(target)?.group.as_ref().and_then(members);
        match (&tab.group, beside) {
            (None, Some((first, last))) => Some(if offset < 0 { first } else { last }),
            _ => Some(target),
        }
    }

    /// The shown tab `offset` steps from `id` in strip order, wrapping (Next
    /// and Previous Tab). From a hidden tab it counts from its place; from no
    /// tab, from the end it steps away from.
    pub fn adjacent(&self, id: Option<&str>, offset: i64) -> Option<String> {
        if offset == 0 || !self.tabs.iter().any(|tab| self.shows(tab)) {
            return None;
        }
        let count = self.tabs.len();
        let mut index = id.and_then(|id| self.index(id)).unwrap_or(if offset > 0 {
            count.saturating_sub(1)
        } else {
            0
        });
        let mut remaining = offset.unsigned_abs();
        while remaining > 0 {
            // `count` is at least 1: some tab shows.
            index = if offset > 0 {
                index.saturating_add(1).checked_rem(count).unwrap_or(0)
            } else {
                index.checked_sub(1).unwrap_or(count.saturating_sub(1))
            };
            if self.tabs.get(index).is_some_and(|tab| self.shows(tab)) {
                remaining = remaining.saturating_sub(1);
            }
        }
        self.tabs.get(index).map(|tab| tab.id.clone())
    }
}

/// The tab Close Other Tabs or Close Tabs to the Left or Right started from
/// `acted_on` selects (cmux-ad i7): `acted_on`, which stays. None (the
/// selection does not change) when the selection is `acted_on` or one of
/// `kept`, the tabs the gesture keeps on purpose (a menu opened on one of
/// several selected tabs keeps them all).
pub fn selection_keeping(
    selected: Option<&str>,
    acted_on: &str,
    kept: &BTreeSet<String>,
) -> Option<String> {
    match selected {
        Some(selected) if selected == acted_on || kept.contains(selected) => None,
        _ => Some(acted_on.to_owned()),
    }
}

#[cfg(test)]
#[path = "tabs_strip_tests.rs"]
mod tests;
