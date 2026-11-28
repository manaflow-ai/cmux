//! What the app does around `closed.reopen`, `closed.delete` and Clear History
//! (`DaemonClosedHistory.reopen`, `show`, `delete`, `clear`): the steps once the daemon
//! answered, how a failure reads, and what a clear releases. The app runs the daemon calls,
//! waits for the store and shows the windows.

use crate::item::{ClosedItem, Kind};
use crate::listing::{self, Machine};
use crate::records;
use serde::{Deserialize, Serialize};

/// The daemon's error code for an item that is gone.
pub const NOT_FOUND: &str = "resource.not_found";

/// What `closed.reopen` gave back (`StateResourceClient.ReopenedItem`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Reopened {
    #[serde(rename = "tabIDs", alias = "tabIds")]
    pub tab_ids: Vec<String>,
    #[serde(rename = "workspaceID", alias = "workspaceId")]
    pub workspace_id: Option<String>,
    #[serde(rename = "screenIDs", alias = "screenIds")]
    pub screen_ids: Vec<String>,
    /// A reopened window's record (`install/window`).
    pub window: Option<String>,
}

/// What a reopen does before it asks the daemon.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Start {
    /// The pane a tab comes back to, which the app looks up in its store before the reply.
    pub pane: Option<String>,
    /// Its browser tabs' pages restore the history they closed with (cx-d0d.59): this Mac's
    /// daemon only.
    pub expect_page_history: bool,
}

/// The step before `closed.reopen` (`reopen(_:services:)`'s first lines).
pub fn start(item: &ClosedItem, local: bool) -> Start {
    Start { pane: item.pane_id.clone(), expect_page_history: local }
}

/// What the app does once the daemon reopened an item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "step")]
pub enum AfterReply {
    /// A reopened workspace group forms again in the sidebar; no window changes what it shows.
    Done,
    /// A closed window: the app shows window `window` again with the workspaces it kept; when
    /// there is none, or it cannot, it refuses with `noWindow(refuse)`.
    ReopenWindow { window: Option<String>, refuse: String },
    /// A tab whose pane the app shows: select `tab` when the pane reports it.
    SelectTab { tab: String },
    /// Wait for the store to apply the reply, then reveal workspace `workspace` once it is
    /// there; when there is none, or it does not arrive, refuse with `noWorkspace(refuse)`
    /// (the reopen may have applied).
    RevealWorkspace { workspace: Option<String>, refuse: String },
    /// Wait for the store to apply the reply, then [`show`] it.
    Show { kind: Kind },
}

/// The step after `closed.reopen` answered. `pane_shown`: the pane [`start`] named is in the
/// store and the app has its controller.
pub fn after_reply(item: &ClosedItem, reopened: &Reopened, pane_shown: bool) -> AfterReply {
    if item.group.is_some() {
        return AfterReply::Done;
    }
    match item.kind {
        Kind::Window => {
            let window = reopened.window.as_deref().and_then(records::reopened_window_id);
            let refuse = window.clone().unwrap_or_else(|| item.id.clone());
            AfterReply::ReopenWindow { window, refuse }
        }
        Kind::Tab if pane_shown && !reopened.tab_ids.is_empty() => {
            // The guard keeps the list non-empty, so the default is never read.
            AfterReply::SelectTab { tab: reopened.tab_ids.first().cloned().unwrap_or_default() }
        }
        Kind::Workspace => AfterReply::RevealWorkspace {
            workspace: reopened.workspace_id.clone(),
            refuse: reopened.workspace_id.clone().unwrap_or_else(|| item.id.clone()),
        },
        kind => AfterReply::Show { kind },
    }
}

/// What showing a reopened item selects once its workspace is in the store and shown in the
/// active window (`show`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "select")]
pub enum ShowSelect {
    /// Nothing past the workspace (a workspace or window, or a reply without the ids).
    Nothing,
    /// The screen with this resource id.
    Screen { screen: String },
    /// The tab with this resource id, in the pane that holds it.
    Tab { tab: String },
}

/// The selection [`AfterReply::Show`] makes. Nothing shows without a workspace in the reply.
pub fn show(kind: Kind, reopened: &Reopened) -> Option<ShowSelect> {
    reopened.workspace_id.as_ref()?;
    Some(match kind {
        Kind::Screen => reopened
            .screen_ids
            .first()
            .map_or(ShowSelect::Nothing, |screen| ShowSelect::Screen { screen: screen.clone() }),
        Kind::Tab => reopened
            .tab_ids
            .first()
            .map_or(ShowSelect::Nothing, |tab| ShowSelect::Tab { tab: tab.clone() }),
        Kind::Workspace | Kind::Window => ShowSelect::Nothing,
    })
}

/// Whether every reopened tab is in the store (the reopen watch, nxdog54): `store_tabs` are
/// the store's tab resource ids.
pub fn tabs_arrived(tabs: &[String], store_tabs: &[String]) -> bool {
    tabs.iter().all(|tab| store_tabs.contains(tab))
}

/// How a failed `closed.reopen` reads. Either way the app drops the page histories it expected.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "failure")]
pub enum ReopenFailure {
    /// A workspace (not a group) that is gone: refuse with "no recently closed workspace".
    NoRecentlyClosedWorkspace,
    /// Anything else: the tracked work fails with `closed.reopen: <error>`.
    Error,
}

/// The failure of reopening `item` with daemon error `code` (None: not a daemon command error).
pub fn reopen_failure(item: &ClosedItem, code: Option<&str>) -> ReopenFailure {
    if item.kind == Kind::Workspace && item.group.is_none() && code == Some(NOT_FOUND) {
        ReopenFailure::NoRecentlyClosedWorkspace
    } else {
        ReopenFailure::Error
    }
}

/// What deleting an item does (History's Remove, Search Tabs' forget).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Delete {
    /// The closed window of this app it lets go first, if it is one.
    pub release_window: Option<String>,
    /// After a delete on this Mac's daemon, its agent-home folders go to the Trash.
    pub empty_trash: bool,
}

/// The plan of deleting `item` from machine `local`'s daemon (`delete(_:services:)`).
pub fn delete(item: &ClosedItem, local: bool, installs: &[String]) -> Delete {
    Delete { release_window: records::released_window(item, local, installs), empty_trash: local }
}

/// Whether a failed `closed.delete` still reached its goal: an item already gone (a second
/// Remove, or a reopen that ran first) is.
pub fn delete_failure_is_done(code: Option<&str>) -> bool {
    code == Some(NOT_FOUND)
}

/// What Clear History does (`clear(since:services:)`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Clear {
    /// The groups closed at or after this time (ms since 1970, this Mac's clock) clear; None
    /// clears every group.
    pub since_ms: Option<u64>,
    /// The closed windows of this app the clear lets go.
    pub release_windows: Vec<String>,
    /// The machines (indices) whose daemons clear: every one that serves the history.
    pub machines: Vec<usize>,
    /// Those of them that are this Mac's, whose agent-home folders go to the Trash after.
    pub empty_trash: Vec<usize>,
}

/// `since` in seconds since 1970 as the daemon's ms: negative times are 0, fractions of a ms
/// drop (Swift's `UInt64(max(0, since * 1000))`).
pub fn since_ms(since_seconds: f64) -> u64 {
    let ms = (since_seconds * 1000.0).max(0.0);
    ms as u64
}

/// The plan of clearing every machine's closed history from `since_seconds` (None: all).
pub fn clear(machines: &[Machine], since_seconds: Option<f64>, installs: &[String]) -> Clear {
    let since = since_seconds.map(since_ms);
    let release_windows = listing::entries(machines, &[Kind::Window])
        .into_iter()
        .filter(|entry| since.is_none_or(|since| entry.item.closed_at_ms >= since))
        .filter_map(|entry| records::released_window(entry.item, entry.machine.local, installs))
        .collect();
    let serving: Vec<usize> = machines
        .iter()
        .enumerate()
        .filter(|(_, machine)| machine.serves)
        .map(|(index, _)| index)
        .collect();
    let empty_trash = serving
        .iter()
        .copied()
        .filter(|index| machines.get(*index).is_some_and(|machine| machine.local))
        .collect();
    Clear { since_ms: since, release_windows, machines: serving, empty_trash }
}
