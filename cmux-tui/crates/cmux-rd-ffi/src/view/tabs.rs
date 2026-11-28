//! The remote view tab and its control socket rules (was the decisions inside
//! `RemoteViewPageTab.swift` and `RemoteViewTabsControl.swift`): what a tab
//! shows for its decision, the name its Connect card reads, and how
//! `remote_view.state` / `remote_view.mode` / `debug.remote_view` answer.
//!
//! Why release refuses `connect` and `mode control`: Connect stands in for
//! the person's click, and control of someone's desktop is never an agent's
//! to take. Automation may watch and may hand control back.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::pane::ControlMode;
use super::tab::{TabDecision, TabRecord, UnavailableReason};

/// The methods every build registers. The CLI's `app remote-views` reads the
/// first (`REMOTE_VIEWS_METHOD` in cmux-tui's cli/app.rs).
pub const RELEASE_METHODS: [&str; 2] = ["remote_view.state", "remote_view.mode"];

pub const CONNECT_REFUSED: &str = "connect is the person's click; not on the control socket";
pub const MODE_NEEDS: &str = "mode needs tab and mode (control or view)";
pub const TAKE_OVER_REFUSED: &str = "only the person takes over (the toolbar's Take over)";
pub const NO_SESSION: &str = "no live session on that tab";
pub const UNKNOWN_ACTION: &str = "unknown action";

// MARK: - The page tab

/// What a tab's content view is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TabContent {
    /// The session's pane (make a session; none shows `unavailable`).
    Session {
        record: TabRecord,
        if_none: UnavailableReason,
    },
    /// The Connect card; its Connect opens `url`.
    Confirm {
        record: TabRecord,
        url: String,
    },
    Unavailable {
        reason: UnavailableReason,
    },
}

/// A tab's content for its decision.
pub fn content(decision: TabDecision) -> TabContent {
    match decision {
        TabDecision::Connect { record } => {
            let if_none = UnavailableReason::NoTransport { host: record.host.clone() };
            TabContent::Session { record, if_none }
        }
        TabDecision::Confirm { record } => {
            let url = record.url();
            TabContent::Confirm { record, url }
        }
        TabDecision::Unavailable { reason } => TabContent::Unavailable { reason },
    }
}

/// The machine as the Connect card names it: a Cloud machine reads its
/// name, never its id.
pub fn gate_target_name(record: &TabRecord, display_name: Option<&str>) -> String {
    match display_name {
        Some(name) => name.to_owned(),
        None if record.cloud_desktop => String::new(),
        None => record.host.clone(),
    }
}

// MARK: - The control socket

/// One live tab as the control socket sees it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LiveTab {
    pub id: String,
    pub url: Option<String>,
    pub cloud_desktop: bool,
    pub cloud_rd: bool,
    /// The tab shows the Connect card.
    pub confirm: bool,
    /// `RemoteViewPageSession.debugState()`, or null with no session.
    pub session: Value,
}

/// The tabs a request answers about.
pub fn filter<'a>(tabs: &'a [LiveTab], only: Option<&str>, cloud_only: bool) -> Vec<&'a LiveTab> {
    tabs.iter()
        .filter(|tab| only.is_none_or(|id| tab.id == id) && (!cloud_only || tab.cloud_desktop))
        .collect()
}

/// What the shell does for one request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ControlPlan {
    Error {
        message: String,
    },
    /// Press Connect on these tabs; answer `{pressed: n}`.
    Press {
        tabs: Vec<String>,
    },
    /// `selectMode` on this tab's session; answer `{changed}`.
    SelectMode {
        tab: String,
        mode: ControlMode,
    },
    /// Read each tab's session and answer `{tabs: rows}` (`tabs.rows`).
    State {
        tabs: Vec<String>,
    },
}

fn error(message: &str) -> ControlPlan {
    ControlPlan::Error { message: message.to_owned() }
}

/// `RemoteViewTabsControl.answer`'s decision.
pub fn plan(
    tabs: &[LiveTab],
    action: Option<&str>,
    only: Option<&str>,
    mode: Option<&str>,
    cloud_only: bool,
) -> ControlPlan {
    let picked = filter(tabs, only, cloud_only);
    match action.unwrap_or("state") {
        "connect" => {
            if cloud_only {
                return error(CONNECT_REFUSED);
            }
            ControlPlan::Press {
                tabs: picked.iter().filter(|tab| tab.confirm).map(|tab| tab.id.clone()).collect(),
            }
        }
        "mode" => {
            let mode = match mode {
                Some("control") => ControlMode::Control,
                Some("view") => ControlMode::View,
                _ => return error(MODE_NEEDS),
            };
            if only.is_none() {
                return error(MODE_NEEDS);
            }
            if cloud_only && mode == ControlMode::Control {
                return error(TAKE_OVER_REFUSED);
            }
            match picked.first() {
                Some(tab) if !tab.session.is_null() => {
                    ControlPlan::SelectMode { tab: tab.id.clone(), mode }
                }
                _ => error(NO_SESSION),
            }
        }
        "state" => ControlPlan::State { tabs: picked.iter().map(|tab| tab.id.clone()).collect() },
        _ => error(UNKNOWN_ACTION),
    }
}

/// One `state` row: no credential and no pixel of the screen.
pub fn row(tab: &LiveTab) -> Value {
    let field = |name: &str| tab.session.get(name).and_then(Value::as_str);
    let viewer = field("source").unwrap_or(if tab.cloud_rd { "rd" } else { "vnc" });
    json!({
        "tab": tab.id,
        "url": tab.url,
        "confirm": tab.confirm,
        "viewer": viewer,
        "connected": field("state") == Some("streaming"),
        "control": if field("mode") == Some("control") { "person" } else { "agent" },
        "session": tab.session,
    })
}
