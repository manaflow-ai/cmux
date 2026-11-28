//! The undo toast's glue around cmux-window-rules' undo reducer (`CloseUndoToasts`): which
//! daemon items are new, what each new item tells the reducer, the recent items `debug.filepages`
//! lists, the rate limit (`UndoToastRateLimit`), a settled close's toast and message, the order
//! its Undo reopens, the entries a gesture announces and the waiting summary. The reducer
//! (`closed::expect`, `record`, `toast_show`) stays the one in cmux-window-rules.

use crate::item::ClosedItem;
use crate::listing::{self, Machine};
use cmux_window_rules::closed::{self, ExpectedTab, RecordedItem, ToastShow, UndoState};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// The close toast's id (`CloseUndoToasts.toastID`), which the rate limit counts by.
pub const TOAST_ID: &str = "tab-closed";
/// How many recent daemon items `debug.filepages` keeps.
pub const RECENT_LIMIT: usize = 8;
/// The default shortest time between two new toasts with one id, in ms (30 s).
pub const MINIMUM_GAP_MS: i64 = 30_000;

/// The ids of every serving machine's closed items, machine by machine (`daemonItemIDs`).
pub fn daemon_item_ids(machines: &[Machine]) -> Vec<String> {
    machines
        .iter()
        .filter(|machine| machine.serves)
        .flat_map(|machine| machine.items.iter().map(|item| item.id.clone()))
        .collect()
}

/// The ids among `ids` not yet seen, in their order (`daemonItemsChanged`'s `added`); `seen`
/// becomes `ids`.
pub fn added(seen: &mut BTreeSet<String>, ids: &[String]) -> Vec<String> {
    let added = ids.iter().filter(|id| !seen.contains(*id)).cloned().collect();
    *seen = ids.iter().cloned().collect();
    added
}

/// What the reducer reads of a new item: its kind, the pane its tabs left and how many tabs it
/// holds. An item no serving machine has any more is kindless, paneless and holds none.
pub fn recorded_item(id: &str, item: Option<&ClosedItem>) -> RecordedItem {
    RecordedItem {
        id: id.to_owned(),
        kind: item.map(|item| item.kind.rules_kind()).unwrap_or_default(),
        pane: item.and_then(|item| item.pane_id.clone()),
        tabs: item.map_or(0, ClosedItem::tab_count),
    }
}

/// [`recorded_item`] of each id, looked up among the machines (`DaemonClosedHistory.entry`).
pub fn recorded_items(machines: &[Machine], ids: &[String]) -> Vec<RecordedItem> {
    ids.iter()
        .map(|id| recorded_item(id, listing::entry(machines, id).map(|entry| entry.item)))
        .collect()
}

/// One recent daemon item (`recentDaemonItems`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RecentItem {
    pub id: String,
    pub pane: Option<String>,
    pub tabs: usize,
    /// A waiting gesture took it.
    pub matched: bool,
}

/// Appends `items` with whether the reducer matched each (a missing answer is false), keeping
/// the newest [`RECENT_LIMIT`].
pub fn push_recent(recent: &mut Vec<RecentItem>, items: &[RecordedItem], matched: &[bool]) {
    for (index, item) in items.iter().enumerate() {
        recent.push(RecentItem {
            id: item.id.clone(),
            pane: item.pane.clone(),
            tabs: item.tabs,
            matched: matched.get(index).copied().unwrap_or(false),
        });
    }
    if recent.len() > RECENT_LIMIT {
        recent.drain(..recent.len() - RECENT_LIMIT);
    }
}

/// At most one new toast per id in `minimum_gap_ms` (`UndoToastRateLimit`); zero turns it off.
/// Times are ms on one monotonic clock.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RateLimit {
    pub minimum_gap_ms: i64,
    pub last_shown: BTreeMap<String, i64>,
}

impl Default for RateLimit {
    fn default() -> Self {
        RateLimit { minimum_gap_ms: MINIMUM_GAP_MS, last_shown: BTreeMap::new() }
    }
}

impl RateLimit {
    /// A limit of `minimum_gap_ms`.
    pub fn new(minimum_gap_ms: i64) -> RateLimit {
        RateLimit { minimum_gap_ms, last_shown: BTreeMap::new() }
    }

    /// Whether a new toast `id` may show at `now_ms`; a true answer counts it as shown.
    pub fn allows(&mut self, id: &str, now_ms: i64) -> bool {
        if let Some(last) = self.last_shown.get(id)
            && now_ms.saturating_sub(*last) < self.minimum_gap_ms
        {
            return false;
        }
        self.last_shown.insert(id.to_owned(), now_ms);
        true
    }
}

/// The close toast a window shows, as far as a next close reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShownToast {
    /// The window it shows in.
    pub window: String,
    pub tabs: usize,
    /// The person dismissed it, or it timed out.
    pub dismissed: bool,
}

/// The toast a close joins (`show`'s `previous`): the one showing, not dismissed, in the same
/// window. Its tab count.
pub fn joinable(shown: Option<&ShownToast>, window: &str) -> Option<usize> {
    shown.filter(|shown| !shown.dismissed && shown.window == window).map(|shown| shown.tabs)
}

/// How a settled close of `tabs` in `window` shows: joins the toast it can, else a new one when
/// the rate limit allows it at `now_ms` (counted only then).
pub fn toast(
    limit: &mut RateLimit,
    tabs: usize,
    shown: Option<&ShownToast>,
    window: &str,
    now_ms: i64,
) -> ToastShow {
    let previous = joinable(shown, window);
    let allowed = previous.is_some() || limit.allows(TOAST_ID, now_ms);
    closed::toast_show(tabs, previous, allowed)
}

/// A toast's message, before the app localizes it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "message")]
pub enum Message {
    /// "Closed N tabs".
    Tabs { count: usize },
    /// "Closed “title”".
    Tab { title: String },
    /// "Closed “Untitled Tab”": one tab without a title.
    Untitled,
}

/// The message of a toast of `tabs`, `title` the one tab's.
pub fn message(tabs: usize, title: &str) -> Message {
    if tabs > 1 {
        Message::Tabs { count: tabs }
    } else if title.is_empty() {
        Message::Untitled
    } else {
        Message::Tab { title: title.to_owned() }
    }
}

/// The order a settled close's Undo reopens its items: each holds the place it had when it
/// closed, so the last closed comes back first.
pub fn reopen_order(items: &[String]) -> Vec<String> {
    items.iter().rev().cloned().collect()
}

/// The Undo of a toast that joined others: its own close first, then the ones it joined
/// (each a list of items, newest toast last).
pub fn joined_reopen_order(closes: &[Vec<String>]) -> Vec<String> {
    closes.iter().rev().flat_map(|items| reopen_order(items)).collect()
}

/// One closing tab and its pane's tabs, by id, as a gesture reads them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClosingPart {
    /// The closing tabs.
    pub tabs: Vec<String>,
    /// Every tab of their pane, in strip order.
    pub pane_tabs: Vec<String>,
    /// The pane's resource id, if it has one yet.
    pub pane: Option<String>,
}

/// What a gesture announces (`expectGroup`): each closing tab with its place in its pane (a
/// tab its pane no longer lists is left out), the panes with a resource id, and whether its
/// toast keeps the one tab's title.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Announce {
    pub tabs: Vec<ExpectedTab>,
    pub panes: Vec<String>,
    /// Exactly one tab closes: its toast reads its title. Else the title is empty.
    pub titled: bool,
}

/// The announcement of closing `parts` in one gesture.
pub fn announce(parts: &[ClosingPart]) -> Announce {
    let tabs = parts
        .iter()
        .flat_map(|part| {
            part.tabs.iter().filter_map(|tab| {
                part.pane_tabs
                    .iter()
                    .position(|other| other == tab)
                    .map(|index| ExpectedTab { id: tab.clone(), index })
            })
        })
        .collect();
    let count: usize = parts.iter().map(|part| part.tabs.len()).sum();
    Announce {
        tabs,
        panes: parts.iter().filter_map(|part| part.pane.clone()).collect(),
        titled: count == 1,
    }
}

/// One waiting gesture as `debug.filepages` lists it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Waiting {
    /// Its panes sorted, joined with `,`.
    pub pane: String,
    pub tabs: usize,
    /// The tabs its recorded items hold so far.
    pub daemon_tabs: usize,
}

/// The gestures still waiting for their history records (`waiting`).
pub fn waiting(state: &UndoState) -> Vec<Waiting> {
    state
        .expected
        .iter()
        .map(|close| {
            let mut panes = close.panes.clone();
            panes.sort();
            Waiting { pane: panes.join(","), tabs: close.tabs.len(), daemon_tabs: close.recorded }
        })
        .collect()
}
