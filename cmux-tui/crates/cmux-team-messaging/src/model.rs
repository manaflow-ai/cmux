//! The records RFD 0170 names ("One data model"). The hosted forum and room services persist their
//! own rows; these are cmux's one typed view over them. Times are milliseconds since the epoch, as
//! the host passes them in.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::delivery::DeliveryMode;
use crate::feedback::FeedbackKind;
use crate::identity::{Bridge, PrincipalKind};
use crate::permission::Grants;
use crate::refs::StableRef;

/// A team: its members, spaces and bridges, and the grants its policy allows in its spaces.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Team {
    pub id: String,
    pub name: String,
    /// Principal ids.
    pub members: Vec<String>,
    /// Space ids.
    pub spaces: Vec<String>,
    /// The bridges bound to this team's spaces.
    #[serde(default)]
    pub integrations: Vec<Bridge>,
    /// What any principal may do in this team's spaces at most.
    pub policy: Grants,
    /// Team-scoped display choices (RFD 0038 and RFD 0103). They never grant access or wake.
    #[serde(default)]
    pub customization: BTreeMap<String, String>,
    /// Person ids who may set the team's customization (`settings.rs`). Display choices only: being
    /// an admin grants nothing in a space.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub admins: Vec<String>,
}

/// A person or an agent. An agent is its own principal with an owner (`on_behalf_of`); it never
/// posts as that person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Principal {
    pub id: String,
    pub kind: PrincipalKind,
    /// What `@handle` resolves on, unique in a team.
    pub handle: String,
    pub display_name: String,
    /// The principal's home team.
    pub team_id: String,
    /// An agent's person. Required for an agent, absent for a person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_person_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Reported by the agent, display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Reported by the agent, display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<String>,
    /// The principal's home-team grants.
    pub capabilities: Grants,
    /// Set when the author wrote through a bridge (`via Slack`). Such an author holds no cmux rights.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<Bridge>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SpaceKind {
    Team,
    Pair,
    Project,
    Rfd,
    Session,
}

/// How a person hears about a message stored for them in a space.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Notify {
    /// Inbox and digest.
    #[default]
    Inbox,
    /// Digest only.
    Digest,
    /// Stored and readable, announced nowhere.
    Muted,
}

/// One agent's standing in one space, set by the agent's owner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentGrant {
    /// The person who set it. It counts only when this is the agent's owner.
    pub granted_by: String,
    /// Whether a `wake` message in this space may start the agent's turn.
    pub wake: bool,
    /// The mode the composer suggests for this agent here. It never changes the sender's identity.
    pub default_mode: DeliveryMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Space {
    pub id: String,
    pub team_id: String,
    pub kind: SpaceKind,
    pub title: String,
    /// Principal ids admitted to the space. Joining is a person's act.
    pub members: Vec<String>,
    /// Agent id to its owner's grant here.
    #[serde(default)]
    pub agent_policy: BTreeMap<String, AgentGrant>,
    /// Person id to how they hear about messages here.
    #[serde(default)]
    pub notification_policy: BTreeMap<String, Notify>,
}

impl Space {
    pub fn is_member(&self, principal_id: &str) -> bool {
        self.members.iter().any(|m| m == principal_id)
    }

    pub fn notify_for(&self, person_id: &str) -> Notify {
        self.notification_policy.get(person_id).copied().unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RootKind {
    Message,
    Ask,
    Tip,
    Finding,
    Feedback,
    Rfd,
    Receipt,
}

impl RootKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Message => "message",
            Self::Ask => "ask",
            Self::Tip => "tip",
            Self::Finding => "finding",
            Self::Feedback => "feedback",
            Self::Rfd => "rfd",
            Self::Receipt => "receipt",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "message" => Self::Message,
            "ask" => Self::Ask,
            "tip" => Self::Tip,
            "finding" => Self::Finding,
            "feedback" => Self::Feedback,
            "rfd" => Self::Rfd,
            "receipt" => Self::Receipt,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    #[default]
    Open,
    /// A person marked it handled.
    Handled,
    Closed,
}

/// A thread has one canonical home: its space. Linking it elsewhere keeps that home.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub space_id: String,
    pub root_kind: RootKind,
    pub subject: String,
    pub participants: Vec<String>,
    #[serde(default)]
    pub linked_rfd_ids: Vec<String>,
    #[serde(default)]
    pub linked_session_ids: Vec<String>,
    pub revision: u64,
    pub state: ThreadState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub thread_id: String,
    pub author: Principal,
    /// Principal ids the message is addressed to.
    pub audience: Vec<String>,
    pub body: String,
    #[serde(default)]
    pub refs: Vec<StableRef>,
    pub delivery: DeliveryMode,
    pub created_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    pub revision: u64,
}

/// A comment or a vote on a target. Votes are feedback, never permissions or merge gates.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Feedback {
    pub id: String,
    pub target_ref: StableRef,
    /// The target's revision the feedback is about.
    pub target_revision: u64,
    pub author: Principal,
    pub kind: FeedbackKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<i8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub created_at: u64,
}

/// RFD 0077's role vocabulary for a shared document.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DocRole {
    View,
    Suggest,
    Edit,
}

/// An optional projection attached to a thread or a session. Edits go through RFD 0140's sync cursor
/// and land as a suggestion or a commit through the owning workflow.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedDocument {
    pub id: String,
    pub owner_ref: StableRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub revision: u64,
    pub sync_cursor: u64,
    /// Principal id to role.
    pub roles: BTreeMap<String, DocRole>,
    pub presence_scope: String,
}
