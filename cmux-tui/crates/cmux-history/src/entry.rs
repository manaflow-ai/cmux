use serde::{Deserialize, Serialize};

/// The kind of a history entry (plans/cmux-next/history.md section 2).
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum HistoryKind {
    /// A finished main-frame navigation in a browser profile.
    Page,
    /// A place the user was (the location trail).
    Location,
    /// A closed tab, screen or workspace that can be reopened.
    Closed,
    /// A finished shell command.
    Command,
    /// An agent session (Claude Code, Codex, ...).
    Agent,
}

impl HistoryKind {
    /// Every kind, in wire order.
    pub const ALL: [Self; 5] = [Self::Page, Self::Location, Self::Closed, Self::Command, Self::Agent];

    /// The wire name (`page`, `location`, ...).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::Location => "location",
            Self::Closed => "closed",
            Self::Command => "command",
            Self::Agent => "agent",
        }
    }
}

/// What a `closed` entry reopens.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ClosedKind {
    TerminalTab,
    BrowserTab,
    Screen,
    Workspace,
}

/// One row of the merged history timeline: the wire shape of
/// `cmux.history.entries.list` (react-pages.md section 2.3). Each entry is a
/// read-only view of a fact its owner keeps. Optional fields are omitted
/// from JSON when absent.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct HistoryEntry {
    /// Qualified id, as the Swift app builds it: `page:<profile>:<visit id>`,
    /// `agent:<machine>/<provider>/<session id>`,
    /// `command:<machine>/<terminal>/<start ms>`,
    /// `location:<machine>:<tab>:<index>`, `closed:...`.
    pub id: String,
    pub kind: HistoryKind,
    /// The entry's time in Unix milliseconds (visit, activity, start, close).
    pub at_ms: i64,
    pub title: String,
    /// URL, directory or workspace, shown under the title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// The machine name for machine facts; absent for the local machine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    /// The workspace name the entry belongs to, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    /// False while the owning machine is not connected: shown greyed, restore
    /// refused.
    pub available: bool,
    /// Location only: this entry is the trail cursor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<bool>,
    /// Agent only: the session has not ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Page only: the browser profile wire id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed_kind: Option<ClosedKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Command only: the command line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    /// Agent only: the provider's own session id (what `--resume` takes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Agent only: the hook adapter id (`claude`, `codex`, ...).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
}

impl HistoryEntry {
    /// An available entry with only the required fields set.
    pub fn new(id: impl Into<String>, kind: HistoryKind, at_ms: i64, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            kind,
            at_ms,
            title: title.into(),
            detail: None,
            machine: None,
            workspace: None,
            available: true,
            current: None,
            running: None,
            url: None,
            profile: None,
            closed_kind: None,
            cwd: None,
            command: None,
            exit_code: None,
            session_id: None,
            provider: None,
        }
    }
}
