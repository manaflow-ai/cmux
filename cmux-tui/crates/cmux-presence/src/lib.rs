//! Session-scoped presence. Callers supply a monotonic millisecond clock and bind messages to
//! their authenticated owner. The model performs no I/O and keeps no history or timers.

mod activity;
mod lease;
mod strip;

pub use activity::AgentActivity;
pub use lease::{Delta, Lease, Merge};
use serde::{Deserialize, Serialize};
pub use strip::{Actor, Face, LINE_NAMES, Line, STRIP_FACES, Strip, strip};

pub const DEFAULT_LEASE_MS: u32 = 30_000;
pub const TYPING_LEASE_MS: u32 = 8_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceId(pub Box<str>);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Person,
    Agent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Live,
    Away,
    Quiet,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Doing {
    Idle,
    Typing,
    Thinking,
    Editing,
    Reading,
    Running,
    Browsing,
    ComputerUse,
    Waiting,
}

impl From<AgentActivity> for Doing {
    fn from(activity: AgentActivity) -> Self {
        match activity {
            AgentActivity::Thinking => Self::Thinking,
            AgentActivity::Editing => Self::Editing,
            AgentActivity::Reading => Self::Reading,
            AgentActivity::Running => Self::Running,
            AgentActivity::Browsing => Self::Browsing,
            AgentActivity::ComputerUse => Self::ComputerUse,
            AgentActivity::Waiting => Self::Waiting,
        }
    }
}

#[derive(Clone, Default, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Location {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub space: Option<Box<str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<Box<str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat: Option<Box<str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<FileTarget>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTarget {
    pub path: Box<str>,
    pub line: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Presence {
    pub id: PresenceId,
    pub kind: Kind,
    pub name: Box<str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<Box<str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_ref: Option<Box<str>>,
    pub status: Status,
    #[serde(rename = "where")]
    pub location: Box<Location>,
    pub doing: Doing,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub following: Option<PresenceId>,
    pub epoch: u64,
    pub lease_ms: u32,
}

impl Presence {
    pub fn new(id: PresenceId, kind: Kind, name: impl Into<Box<str>>, epoch: u64) -> Self {
        Self {
            id,
            kind,
            name: name.into(),
            color: None,
            avatar_ref: None,
            status: Status::Live,
            location: Box::default(),
            doing: Doing::Idle,
            following: None,
            epoch,
            lease_ms: DEFAULT_LEASE_MS,
        }
    }

    /// Apply the owner's opt-in for the destination space before constructing snapshots or deltas.
    pub fn shared(&self, scope: Sharing) -> Option<Self> {
        if !scope.live || (scope.private_chat && self.kind == Kind::Agent) {
            return None;
        }
        let mut shared = self.clone();
        if self.status == Status::Quiet {
            shared.location = Box::default();
            shared.doing = Doing::Idle;
            shared.following = None;
            shared.lease_ms = DEFAULT_LEASE_MS;
        } else if self.kind != Kind::Agent || !scope.share_agent_files {
            shared.location.file = None;
        }
        Some(shared)
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Sharing {
    pub live: bool,
    pub private_chat: bool,
    pub share_agent_files: bool,
}
