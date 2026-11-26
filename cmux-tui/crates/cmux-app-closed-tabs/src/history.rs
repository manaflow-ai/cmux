//! The History page's closed rows (`HistoryService.closedEntries`, `daemonClosedText`) and the
//! ids a history list gives a daemon-recorded item (`DaemonClosedHistory.historyID`,
//! `daemonID(fromHistoryID:)`). The app names a row's page tab and localizes the fixed words;
//! it passes them in [`Words`].

use crate::item::ClosedItem;
use crate::listing::{self, EntryRef, Machine};
use crate::reading::{self, HistoryAgentSession, HistoryKind};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The prefix a history list puts before a daemon item id.
pub const HISTORY_PREFIX: &str = "daemon:";
/// The prefix of a closed row's History entry id, before the daemon item id.
pub const ENTRY_PREFIX: &str = "closed:daemon:";
/// This Mac's machine id (`MachineRegistry.localID`).
pub const LOCAL_MACHINE: &str = "local";

/// The id a history list gives a daemon-recorded item (`historyID`).
pub fn history_id(id: &str) -> String {
    format!("{HISTORY_PREFIX}{id}")
}

/// The daemon item id of a history list id, None for the app's trackers (`daemonID(fromHistoryID:)`).
pub fn daemon_id(history_id: &str) -> Option<&str> {
    history_id.strip_prefix(HISTORY_PREFIX)
}

/// The History entry id of a closed row.
pub fn entry_id(id: &str) -> String {
    format!("{ENTRY_PREFIX}{id}")
}

/// The words the app localizes for a closed row, and its pages' titles.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Words {
    /// A deleted group's title, `%@` standing for its name (`workspaceGroup.closedHistoryTitle`).
    pub group_title: String,
    /// A group without a name (`ConfirmationStrings.unnamedGroup`).
    pub unnamed_group: String,
    /// An agent chat tab's title (`AgentPaneModel.tabTitle`).
    pub agent_title: String,
    /// A row with nothing else to show (`Strings.untitledTerminal`).
    pub untitled_terminal: String,
    /// Each internal page's title by page id (`InternalPageTabStore.provider(_:)?.title`); a
    /// page without a provider reads as its id.
    pub pages: BTreeMap<String, String>,
}

impl Default for Words {
    fn default() -> Self {
        Words {
            group_title: "Group \u{201c}%@\u{201d}".to_owned(),
            unnamed_group: "Unnamed Group".to_owned(),
            agent_title: "Agent".to_owned(),
            untitled_terminal: "Terminal".to_owned(),
            pages: BTreeMap::new(),
        }
    }
}

impl Words {
    /// A deleted group's title (`WorkspaceGroupUndo.historyTitle`): an empty name reads as the
    /// unnamed group's.
    pub fn group(&self, name: &str) -> String {
        let name = if name.is_empty() { self.unnamed_group.as_str() } else { name };
        self.group_title.replacen("%@", name, 1)
    }
}

/// A closed row's title and detail line (`daemonClosedText`). A page tab (a diff, Settings) is
/// named by its page and has no address to show: its `url` is the `about:blank` placeholder.
pub fn text(item: &ClosedItem, words: &Words) -> (String, Option<String>) {
    let tab = reading::shown_tab(item);
    let page = tab
        .and_then(|tab| tab.page.as_deref())
        .map(|page| words.pages.get(page).cloned().unwrap_or_else(|| page.to_owned()));
    let url = reading::real_text(tab.and_then(|tab| tab.url.as_deref())).map(str::to_owned);
    let cwd = tab.and_then(|tab| tab.cwd.clone());
    // The closed record omits the agent's host: it is named as a chat, not by its source.
    let agent = reading::closed_agent_session(item).map(|_| words.agent_title.clone());
    let title = item
        .group
        .as_ref()
        .map(|group| words.group(&group.name))
        .or_else(|| reading::real_text(item.name.as_deref()).map(str::to_owned))
        .or_else(|| reading::real_text(tab.and_then(|tab| tab.name.as_deref())).map(str::to_owned))
        .or_else(|| page.clone())
        .or(agent)
        .or_else(|| url.clone())
        .or_else(|| cwd.clone())
        .unwrap_or_else(|| words.untitled_terminal.clone());
    let detail = if page.is_none() { url.or(cwd) } else { None };
    (title, detail)
}

/// A closed row's payload (`CmuxNextHistory.ClosedItem`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClosedPayload {
    /// The history id (`daemon:` + the item id).
    pub id: String,
    pub kind: HistoryKind,
    pub title: String,
    pub machine: String,
    pub cwd: Option<String>,
    /// The shown tab's real address, never a page tab's placeholder.
    pub url: Option<String>,
    pub agent_session: Option<HistoryAgentSession>,
}

/// One closed row of History (`HistoryEntry` of kind `closed`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    /// `closed:daemon:` + the item id.
    pub id: String,
    /// Close time, ms since 1970.
    pub time_ms: u64,
    pub title: String,
    pub detail: Option<String>,
    /// The machine's name for another machine's item; None for this Mac's.
    pub machine_name: Option<String>,
    /// Always true here: a closed row is listed only while its machine serves it.
    pub is_available: bool,
    pub closed: ClosedPayload,
    /// The entry it reads, among the machines.
    pub at: EntryRef,
}

/// The closed rows of History (`closedEntries(limit:)`): every machine's items worth
/// reopening, newest first, a page closed again once, only the newest `limit` when set.
pub fn closed_rows(machines: &[Machine], limit: Option<usize>, words: &Words) -> Vec<Row> {
    let shown: Vec<_> = listing::all_entries(machines)
        .into_iter()
        .filter(|entry| reading::is_worth_reopening(entry.item))
        .collect();
    let pairs: Vec<(&ClosedItem, &str)> =
        shown.iter().map(|entry| (entry.item, entry.machine.machine.as_str())).collect();
    let once = listing::newest_once(&pairs);
    let count = limit.unwrap_or(once.len());
    once.into_iter()
        .take(count)
        .filter_map(|index| shown.get(index))
        .map(|entry| {
            let item = entry.item;
            let tab = reading::shown_tab(item);
            let (title, detail) = text(item, words);
            let machine = entry.machine.machine.clone();
            let url = match tab {
                Some(tab) if tab.page.is_none() => {
                    reading::real_text(tab.url.as_deref()).map(str::to_owned)
                }
                _ => None,
            };
            Row {
                id: entry_id(&item.id),
                time_ms: item.closed_at_ms,
                title: title.clone(),
                detail,
                machine_name: (machine != LOCAL_MACHINE).then(|| machine.clone()),
                is_available: true,
                closed: ClosedPayload {
                    id: history_id(&item.id),
                    kind: reading::closed_kind(item),
                    title,
                    machine,
                    cwd: tab.and_then(|tab| tab.cwd.clone()),
                    url,
                    agent_session: reading::closed_agent_session(item),
                },
                at: entry.at,
            }
        })
        .collect()
}
