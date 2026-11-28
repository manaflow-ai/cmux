//! A first chat tab's refusals and key (`WorkspaceCreation.sessionTab`, `sessionTabRefusal`,
//! `AgentTabStore.hostRefusal`): the New Tab page's first chat and `agent.openSessionWorkspace`'s
//! only tab.

use serde::{Deserialize, Serialize};

/// The origin a chat tab's create carries (`AgentTabStore.createOrigin`).
pub const CREATE_ORIGIN: &str = "cmux-next-agent-tab";
/// The host prefix of a Chief home's record (`chief:<id>`).
pub const CHIEF_HOST_PREFIX: &str = "chief:";
/// The key a tab with no resource id gets: `surface:<handle>`.
pub const SURFACE_KEY_PREFIX: &str = "surface:";

/// Why a chat tab cannot open.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum SessionTabRefusal {
    /// The daemon cannot hold agent chat tabs (`agentTabsUnsupported`).
    AgentTabsUnsupported,
    /// The chat runs on another machine (`agentTabMachineMismatch`).
    MachineMismatch,
    /// The session's record is on another host (`agentTabRunsOnHost`).
    RunsOnHost {
        /// That host.
        host: String,
    },
}

impl SessionTabRefusal {
    /// The refusal's English text (`RefusalStrings`; the app localizes by kind).
    pub fn message(&self) -> String {
        match self {
            SessionTabRefusal::AgentTabsUnsupported => {
                "cmux on this machine can't hold agent chat tabs yet: update it".to_owned()
            }
            SessionTabRefusal::MachineMismatch => {
                "this chat runs on another machine: it cannot open in this tab".to_owned()
            }
            SessionTabRefusal::RunsOnHost { host } => format!(
                "this session runs on {host}: open it without a host, or from that machine's workspace"
            ),
        }
    }
}

/// The refusal for a session on `host` (`AgentTabStore.hostRefusal`): none for no host, the Chief's
/// own host, or a Chief home's record when the daemon is this Mac's; this Mac's acpmux host only
/// opens on this Mac's daemon; any other host is refused by name.
pub fn host_refusal(
    host: Option<&str>,
    local_host: Option<&str>,
    chief_host: Option<&str>,
    daemon_is_local: bool,
) -> Option<SessionTabRefusal> {
    let host = host?;
    if Some(host) == chief_host || (daemon_is_local && host.starts_with(CHIEF_HOST_PREFIX)) {
        return None;
    }
    if Some(host) == local_host {
        return (!daemon_is_local).then_some(SessionTabRefusal::MachineMismatch);
    }
    Some(SessionTabRefusal::RunsOnHost { host: host.to_owned() })
}

/// What `sessionTabRefusal` reads of the daemon and the agent tab store.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionTabFacts {
    /// The session's record host; nil: this Mac's acpmux.
    pub host: Option<String>,
    /// The daemon holds agent tabs (`agent-session-tabs-v1`).
    pub holds_tabs: bool,
    /// The daemon is this Mac's.
    pub daemon_is_local: bool,
    /// This Mac's acpmux host.
    pub local_host: Option<String>,
    /// The Chief's host.
    pub chief_host: Option<String>,
}

/// The refusal a chat tab's create would give, known before any workspace is made
/// (`WorkspaceCreation.sessionTabRefusal`): a daemon that holds no tabs, another machine's daemon
/// (never another machine's workspace), else the host's refusal on this Mac.
pub fn session_tab_refusal(facts: &SessionTabFacts) -> Option<SessionTabRefusal> {
    if !facts.holds_tabs {
        return Some(SessionTabRefusal::AgentTabsUnsupported);
    }
    if !facts.daemon_is_local {
        return Some(SessionTabRefusal::MachineMismatch);
    }
    host_refusal(
        facts.host.as_deref(),
        facts.local_host.as_deref(),
        facts.chief_host.as_deref(),
        true,
    )
}

/// What `sessionTab` does before it sends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum SessionTabStart {
    /// No connection or no local host: `notConnected`.
    NotConnected,
    /// Refused before the request.
    Refused {
        /// Why.
        refusal: SessionTabRefusal,
        /// Its English text.
        message: String,
    },
    /// Send `new-conversation-tab` for the record on `host`.
    Send {
        /// The record's host: the asked host, else this Mac's.
        host: String,
        /// The tab's create origin.
        origin: String,
    },
}

/// The start of `sessionTab`: it needs a connection and this Mac's host, then no refusal; the
/// record is on the asked host, else this Mac's.
pub fn session_tab_start(connected: bool, facts: &SessionTabFacts) -> SessionTabStart {
    let Some(local_host) = facts.local_host.as_deref().filter(|_| connected) else {
        return SessionTabStart::NotConnected;
    };
    if let Some(refusal) = session_tab_refusal(facts) {
        let message = refusal.message();
        return SessionTabStart::Refused { refusal, message };
    }
    SessionTabStart::Send {
        host: facts.host.clone().unwrap_or_else(|| local_host.to_owned()),
        origin: CREATE_ORIGIN.to_owned(),
    }
}

/// The new chat tab's key: its resource id, else `surface:<handle>`.
pub fn tab_key(tab_resource_id: Option<&str>, surface: &str) -> String {
    tab_resource_id.map_or_else(|| format!("{SURFACE_KEY_PREFIX}{surface}"), str::to_owned)
}
