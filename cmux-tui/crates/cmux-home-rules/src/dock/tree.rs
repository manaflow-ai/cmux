//! The slice of the daemon's workspace tree the Home dock rules read (`WorkspaceModel`, `ScreenModel`,
//! `PaneModel`, `TabModel`, `ColumnSnapshot` in CmuxNextDaemon). The app sends only what the rules
//! look at; field names are the Swift property names.

use serde::{Deserialize, Serialize};

/// A workspace: its kind (`home` for Home) and its screens.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Workspace {
    pub kind: Option<String>,
    pub screens: Vec<Screen>,
}

/// A screen: its resource id (none until the tree reports it), its columns and its panes.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Screen {
    #[serde(rename = "resourceID")]
    pub resource_id: Option<String>,
    pub columns: Vec<Column>,
    pub panes: Vec<Pane>,
}

/// A column of the strip: the panes its layout holds and its dock, if it is one.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Column {
    #[serde(rename = "paneIDs")]
    pub pane_ids: Vec<u64>,
    pub dock: Option<Dock>,
}

/// A column's dock: its edge (`left`, `right`), its role (`agentChat`, ...), pinned, takes tabs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Dock {
    pub edge: String,
    pub role: String,
    pub is_pinned: bool,
    pub allows_tabs: bool,
}

/// A pane: its handle (the id a column's layout names), its resource id and its tabs, in order.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Pane {
    pub handle: u64,
    #[serde(rename = "resourceID")]
    pub resource_id: Option<String>,
    pub tabs: Vec<Tab>,
}

/// A tab, as the dock rules read it. `kind` is `TabModel.kind`'s raw value (`pty`, `conversation`,
/// `browser`, ...). The booleans stand for the optional or collection fields the rules only test for
/// presence (`agent != nil` is `hasAgent`, `commandSinceMs != nil` is `commandRunning`, ...).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    pub id: String,
    pub surface: u64,
    pub kind: String,
    /// The page a page tab shows (`home-dock`, `home-channels`, ...).
    pub page: Option<String>,
    /// The conversation a conversation tab shows (`snapshot.conversation?.conversation`).
    pub conversation: Option<String>,
    pub has_agent_session: bool,
    pub dead: bool,
    pub name: Option<String>,
    pub has_agent: bool,
    pub command_running: bool,
    pub has_program_status: bool,
    pub has_relaunch: bool,
    pub is_remote: bool,
    pub shows_unread: bool,
    pub pinned: bool,
    pub in_tab_group: bool,
    pub cwd: Option<String>,
    /// `titleText`.
    pub title: String,
}

/// The dock edge a Home dock is on.
pub const LEFT: &str = "left";
/// The dock role of Home's dock (and Cmd-I's chat dock).
pub const AGENT_CHAT: &str = "agentChat";
