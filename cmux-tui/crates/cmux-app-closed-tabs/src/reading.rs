//! How a daemon closed item reads in History and Recently Closed (`DaemonClosedItem`,
//! CmuxNextHistoryDaemon/DaemonClosedItem.swift): its kind, its agent chat, its shown tab and
//! text, and whether it is worth reopening.

use crate::item::{ClosedItem, Kind, Tab};
use serde::{Deserialize, Serialize};

/// The History kind of a closed item (`CmuxNextHistory.ClosedItem.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HistoryKind {
    TerminalTab,
    ConversationTab,
    BrowserTab,
    Screen,
    Workspace,
}

/// The agent chat a closed tab reopens (`CmuxNextHistory.ClosedItem.AgentSession`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryAgentSession {
    #[serde(rename = "sessionID")]
    pub session_id: Option<String>,
    pub harness: Option<String>,
}

/// An untouched New Tab page or a browser on `about:blank`, as the daemon marks it (`empty`).
/// A closed chat with no title yet or a remote terminal looks the same otherwise, and reopens.
pub fn is_blank(tab: &Tab) -> bool {
    tab.empty
}

/// The tab an item is named by: its first real one, past any New Tab page beside it; else its
/// first tab; None for an item without tabs.
pub fn shown_tab(item: &ClosedItem) -> Option<&Tab> {
    let tabs = item.tabs();
    tabs.iter().copied().find(|tab| !is_blank(tab)).or_else(|| tabs.first().copied())
}

/// The History kind: a tab by its shown tab's kind (`conversation`, `browser`, else a
/// terminal, a tab without tabs too); a window reads as a workspace.
pub fn closed_kind(item: &ClosedItem) -> HistoryKind {
    match item.kind {
        Kind::Tab => match shown_tab(item).map(|tab| tab.kind.as_str()) {
            Some("conversation") => HistoryKind::ConversationTab,
            Some("browser") => HistoryKind::BrowserTab,
            _ => HistoryKind::TerminalTab,
        },
        Kind::Screen => HistoryKind::Screen,
        Kind::Workspace | Kind::Window => HistoryKind::Workspace,
    }
}

/// A closed tab can be an agent chat. A screen or workspace remains its container kind, even
/// when the first tab it would reopen is an agent chat.
pub fn closed_agent_session(item: &ClosedItem) -> Option<HistoryAgentSession> {
    if item.kind != Kind::Tab {
        return None;
    }
    let agent = shown_tab(item)?.agent_session.as_ref()?;
    Some(HistoryAgentSession { session_id: agent.session.clone(), harness: agent.harness.clone() })
}

/// Whether reopening `item` gives something back (Leo 2026-10-11: Recently Closed was full of
/// "workspace-35 about:blank" rows). A group or a window always does; a tab, screen or
/// workspace only with a tab that is not [`is_blank`].
pub fn is_worth_reopening(item: &ClosedItem) -> bool {
    item.group.is_some()
        || item.kind == Kind::Window
        || item.tabs().iter().any(|tab| !is_blank(tab))
}

/// A closed name or address worth showing: a chat or New Tab page is kept as a browser tab on
/// `about:blank` (a tab item carries that as its name too), never a name or an address.
pub fn real_text(text: Option<&str>) -> Option<&str> {
    text.filter(|text| !text.is_empty() && *text != "about:blank")
}
