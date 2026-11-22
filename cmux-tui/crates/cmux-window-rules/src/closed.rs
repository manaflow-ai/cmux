//! The daemon's closed history as the app reads it (reopen-closed.md): which
//! close a page row stands for, whose an entry is for Cmd-Shift-T, and the
//! undo toast's expected closes, a reducer the app feeds with each gesture it
//! announces and each closed item the daemon records. The app keeps the
//! state between calls, the toast's window and title, and the reopen.

use serde::{Deserialize, Serialize};

/// A closed item's kind.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    Tab,
    Screen,
    Workspace,
    Window,
    #[default]
    #[serde(other)]
    Other,
}

/// One tab of a closed item.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClosedTab {
    pub kind: String,
    pub empty: bool,
    /// An internal page tab (Settings, a diff).
    pub page: bool,
    pub url: Option<String>,
}

/// A closed item with the machine whose daemon recorded it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClosedItem {
    pub kind: ItemKind,
    /// The close of a workspace group, not of its own.
    pub grouped: bool,
    pub tabs: Vec<ClosedTab>,
    pub machine: String,
}

/// The page a closed item is only, by machine and address: a closed tab of
/// one browser on a real address, as the daemon keys it (`closed_page`, Leo
/// 2026-10-14). None for a terminal, chat, page tab, screen, workspace,
/// window, group or close of several tabs: nothing tells one close of those
/// from another (two shells in one folder).
pub fn page_key(item: &ClosedItem) -> Option<(&str, &str)> {
    let [tab] = item.tabs.as_slice() else { return None };
    let url = tab.url.as_deref().unwrap_or("");
    let page = item.kind == ItemKind::Tab
        && !item.grouped
        && tab.kind == "browser"
        && !tab.empty
        && !tab.page
        && !url.is_empty()
        && url != "about:blank";
    page.then_some((item.machine.as_str(), url))
}

/// The items (newest first) a list shows: a page closed again
/// ([`page_key`]) once, at its newest close (Recently Closed, Search Tabs).
pub fn newest_once(items: &[ClosedItem]) -> Vec<usize> {
    let mut seen = Vec::new();
    items
        .iter()
        .enumerate()
        .filter(|(_, item)| match page_key(item) {
            None => true,
            Some(key) if seen.contains(&key) => false,
            Some(key) => {
                seen.push(key);
                true
            }
        })
        .map(|(index, _)| index)
        .collect()
}

/// Every close the row of `target` stands for among `items`: for a page each
/// close of it, so removing the row leaves none to take its place; else the
/// target alone.
pub fn closes(target: usize, items: &[ClosedItem]) -> Vec<usize> {
    let Some(page) = items.get(target).and_then(page_key) else { return vec![target] };
    items
        .iter()
        .enumerate()
        .filter(|(_, item)| page_key(item) == Some(page))
        .map(|(index, _)| index)
        .collect()
}

/// Whose an entry is for Cmd-Shift-T (decision 1, reopen-closed.md 4).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Owner {
    /// It left a workspace this window lists, or this window's record.
    Window,
    /// No live window owns it (a closed workspace, a deleted group, a closed window).
    None,
    /// Another window (open or closed) owns it.
    OtherWindow,
}

/// What an entry's owner reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OwnerFacts {
    pub kind: ItemKind,
    /// On this Mac's daemon.
    pub local: bool,
    /// The window of this app the item's window record names, if it names one.
    pub recorded_window: Option<String>,
    /// That window as the registry knows it (whether it is open); None: unknown.
    pub recorded_open: Option<bool>,
    /// The window that lists the item's workspace, if any.
    pub workspace_window: Option<String>,
}

/// Who owns an entry seen from window `window`. The window record a close
/// left decides on this Mac's daemon for a window the registry has; a
/// window item of an unknown window is not reopenable here; else the
/// workspace's window decides.
pub fn owner(facts: &OwnerFacts, window: Option<&str>) -> Owner {
    if facts.local
        && let Some(recorded) = facts.recorded_window.as_deref()
        && let Some(open) = facts.recorded_open
    {
        return if Some(recorded) == window {
            Owner::Window
        } else if open {
            Owner::OtherWindow
        } else {
            Owner::None
        };
    }
    if facts.kind == ItemKind::Window {
        return Owner::OtherWindow;
    }
    match facts.workspace_window.as_deref() {
        None => Owner::None,
        Some(owner) if Some(owner) == window => Owner::Window,
        Some(_) => Owner::OtherWindow,
    }
}

/// Cmd-Shift-T's entry for window `window` among `entries` (newest first):
/// the newest that left this window, else the newest no live window owns;
/// never one of another live window.
pub fn newest(entries: &[OwnerFacts], window: Option<&str>) -> Option<usize> {
    let owned = |wanted: Owner| entries.iter().position(|facts| owner(facts, window) == wanted);
    owned(Owner::Window).or_else(|| owned(Owner::None))
}

// MARK: The undo toast's expected closes

/// The most gestures waiting for their records at once; the oldest goes.
pub const EXPECTED_LIMIT: usize = 16;

/// One closing tab of a gesture, with the place it held before the close.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExpectedTab {
    pub id: String,
    pub index: usize,
}

/// One announced gesture, waiting for the daemon's closed items.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Expected {
    /// The app's key for the gesture (its title and window).
    pub token: u64,
    /// Its tabs in their strip order.
    pub tabs: Vec<ExpectedTab>,
    /// The panes its closed items come from.
    pub panes: Vec<String>,
    /// Whether the close earns the toast (`close::toast`, read before it).
    pub costly: bool,
    /// The closed items recorded for it so far.
    pub items: Vec<String>,
    /// The tabs those items hold.
    pub recorded: usize,
}

/// The gestures waiting for their records.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UndoState {
    pub expected: Vec<Expected>,
}

/// What announcing a gesture did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum Announced {
    /// No closing tab was found: nothing waits.
    Empty,
    /// A tab of it is still waiting (a repeated Cmd-W): the same gesture.
    Repeated,
    /// It waits; `dropped` are the oldest gestures past [`EXPECTED_LIMIT`].
    Waiting { dropped: Vec<u64> },
}

/// A user's close of `tabs` from `panes` in one gesture (`token` names it).
pub fn expect(
    state: &mut UndoState,
    token: u64,
    mut tabs: Vec<ExpectedTab>,
    panes: Vec<String>,
    costly: bool,
) -> Announced {
    if tabs.is_empty() {
        return Announced::Empty;
    }
    let waiting =
        |id: &String| state.expected.iter().any(|close| close.tabs.iter().any(|tab| &tab.id == id));
    if tabs.iter().any(|tab| waiting(&tab.id)) {
        return Announced::Repeated;
    }
    tabs.sort_by_key(|tab| tab.index);
    state.expected.push(Expected { token, tabs, panes, costly, ..Expected::default() });
    let over = state.expected.len().saturating_sub(EXPECTED_LIMIT);
    let dropped = state.expected.drain(..over).map(|close| close.token).collect();
    Announced::Waiting { dropped }
}

/// A closed item the daemon recorded since the last call.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RecordedItem {
    pub id: String,
    pub kind: ItemKind,
    /// The pane its tabs left.
    pub pane: Option<String>,
    /// How many tabs it holds.
    pub tabs: usize,
}

/// A gesture whose every record is in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settled {
    pub token: u64,
    /// Its closed items, in the order recorded (reopen the last first).
    pub items: Vec<String>,
    /// How many tabs it closed.
    pub tabs: usize,
    /// It shows the toast; else it is dropped.
    pub shows: bool,
}

/// What a batch of recorded items did.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recorded {
    /// Whether a waiting gesture took each item.
    pub matched: Vec<bool>,
    pub settled: Vec<Settled>,
}

/// Files each tab item under the first waiting gesture of its pane; a
/// gesture settles once its items hold all its tabs.
pub fn record(state: &mut UndoState, items: &[RecordedItem]) -> Recorded {
    let mut out = Recorded::default();
    for item in items {
        let position = match (&item.kind, &item.pane) {
            (ItemKind::Tab, Some(pane)) => {
                state.expected.iter().position(|close| close.panes.contains(pane))
            }
            _ => None,
        };
        out.matched.push(position.is_some());
        let Some(position) = position else { continue };
        let Some(close) = state.expected.get_mut(position) else { continue };
        close.items.push(item.id.clone());
        close.recorded = close.recorded.saturating_add(item.tabs.max(1));
        if close.recorded < close.tabs.len() {
            continue;
        }
        let close = state.expected.remove(position);
        out.settled.push(Settled {
            token: close.token,
            items: close.items,
            tabs: close.tabs.len(),
            shows: close.costly,
        });
    }
    out
}

/// How a settled close's toast shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "show")]
pub enum ToastShow {
    /// A new toast, "Closed “title”" for one tab, "Closed N tabs" for several.
    New { tabs: usize },
    /// It joins the close toast its window shows: one toast, one Undo for all.
    Join { tabs: usize },
    /// Too soon after the last close toast: Reopen Closed and History still have it.
    Drop,
}

/// The toast for a close of `tabs`: `shown` is the tab count of the close
/// toast still showing in the same window, if any; `allowed` the rate limit's answer.
pub fn toast_show(tabs: usize, shown: Option<usize>, allowed: bool) -> ToastShow {
    match shown {
        Some(previous) => ToastShow::Join { tabs: tabs.saturating_add(previous) },
        None if allowed => ToastShow::New { tabs },
        None => ToastShow::Drop,
    }
}

#[cfg(test)]
#[path = "closed_tests.rs"]
mod tests;
