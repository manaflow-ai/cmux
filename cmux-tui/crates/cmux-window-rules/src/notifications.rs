//! The notification verbs: which unread tabs a verb reads, acknowledges and
//! opens; Mute Workspace's muted list; Toggle Banners' next mode.
//!
//! The app sends only the tabs that hold an unread notification (its store
//! keeps unread counts per workspace, screen and pane, so it reads no tab of
//! a workspace with none), in tree order, and the prompted tabs it finds by
//! surface: a verb's cost follows the unread and prompted tabs, never the
//! workspace count (Leo, 2026-11-04: "It should just never, ever ... be
//! acceptable for there to be some sort of linear time growth degradation").

use serde::{Deserialize, Serialize};

/// One tab with an unread notification, in tree order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UnreadTab {
    /// When its notification was posted; none sorts as the oldest.
    pub created_at_ms: Option<u64>,
}

/// A verb over the unread tabs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Verb {
    /// Jump to Latest Unread (and a row verb with no row: open the latest).
    JumpToUnread,
    /// Mark the oldest read and open the next one.
    MarkOldestAndJumpNext,
    MarkAllRead,
    /// Toggle Read or Dismiss with no row: the latest is read.
    ReadLatest,
}

/// Why a verb did nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    NoUnread,
    NoPrompt,
}

/// What a verb does: indices into the unread tabs the app sent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    /// Acknowledged, in this order.
    pub acknowledge: Vec<usize>,
    /// Shown, and its notification opened.
    pub open: Option<usize>,
    pub refusal: Option<Refusal>,
}

/// The unread tabs oldest first: by notification time, then tree order.
pub fn order(unread: &[UnreadTab]) -> Vec<usize> {
    let mut keyed: Vec<(u64, usize)> = unread
        .iter()
        .enumerate()
        .map(|(index, tab)| (tab.created_at_ms.unwrap_or(0), index))
        .collect();
    keyed.sort_unstable();
    keyed.into_iter().map(|(_, index)| index).collect()
}

/// What `verb` does with `unread`.
pub fn plan(verb: Verb, unread: &[UnreadTab]) -> Plan {
    let order = order(unread);
    let (Some(&oldest), Some(&latest)) = (order.first(), order.last()) else {
        return Plan { refusal: Some(Refusal::NoUnread), ..Plan::default() };
    };
    match verb {
        Verb::JumpToUnread => Plan { open: Some(latest), ..Plan::default() },
        Verb::MarkOldestAndJumpNext => {
            Plan { acknowledge: vec![oldest], open: order.get(1).copied(), ..Plan::default() }
        }
        Verb::MarkAllRead => Plan { acknowledge: order, ..Plan::default() },
        Verb::ReadLatest => Plan { acknowledge: vec![latest], ..Plan::default() },
    }
}

/// The tab whose agent was prompted last (the first on a tie), from each live
/// prompted tab's last prompt time.
pub fn last_prompt(prompts: &[u64]) -> Result<usize, Refusal> {
    let mut best: Option<(usize, u64)> = None;
    for (index, &at) in prompts.iter().enumerate() {
        if best.is_none_or(|(_, top)| at > top) {
            best = Some((index, at));
        }
    }
    best.map(|(index, _)| index).ok_or(Refusal::NoPrompt)
}

/// Mute Workspace: the muted workspace keys after toggling `key`, sorted. A
/// remote mute saved before keys were qualified (`legacy`) unmutes, with `key`.
pub fn toggle_mute(muted: &[String], key: &str, legacy: Option<&str>) -> Vec<String> {
    let mut next: Vec<String> = muted.to_vec();
    next.sort();
    next.dedup();
    if let Some(legacy) = legacy {
        next.retain(|entry| entry != legacy && entry != key);
    } else if let Ok(found) = next.binary_search_by(|entry| entry.as_str().cmp(key)) {
        next.remove(found);
    } else {
        next.push(key.to_owned());
        next.sort();
    }
    next
}

/// Toggle Banners: `notifications.desktop` after the toggle (off turns on as
/// `unlessFocused`, any other mode turns off).
pub fn toggle_banners(desktop: &str) -> &'static str {
    if desktop == "never" { "unlessFocused" } else { "never" }
}

#[cfg(test)]
#[path = "notifications_tests.rs"]
mod tests;
