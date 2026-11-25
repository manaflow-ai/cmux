//! What only the owner sends: the Auto machine, a chat's Auto flag, a chat started with no
//! laptop, and keeping a chat in the Cloud. Also a machine's assignments.

use serde::{Deserialize, Serialize};

use super::{Repo, SessionView};

/// `GET` and `PUT /v1/auto-sessions/machine`: the owner's Auto machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineSetting {
    pub team: String,
    pub machine: String,
}

/// `PUT /:id`: switch Auto on or off for a chat. The first call makes the chat, with holder
/// `device:<device>` and epoch 1. `auto: false` closes it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PutRequest {
    pub auto: bool,
    pub title: String,
    pub harness: String,
    /// This laptop's device id.
    pub device: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep_in_cloud: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<Repo>,
}

/// The first message of a chat started with no laptop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FirstMessage {
    pub id: String,
    pub text: String,
}

/// `POST /v1/auto-sessions`: a chat started with no laptop. The Auto machine holds it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub harness: String,
    pub repo: Repo,
    pub first_message: FirstMessage,
}

/// `POST /:id/keep`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeepRequest {
    pub keep_in_cloud: bool,
}

/// What a Cloud machine's daemon is asked to do for one chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssignmentKind {
    /// Import the events and the newest snapshot, settle the open turn and go on as holder.
    Takeover,
    /// A chat started with no laptop: a worktree, the harness, the first message.
    Create,
    /// Inbox messages arrived while nobody ran the chat.
    Deliver,
}

impl AssignmentKind {
    pub const ALL: [AssignmentKind; 3] =
        [AssignmentKind::Takeover, AssignmentKind::Create, AssignmentKind::Deliver];

    pub fn as_str(self) -> &'static str {
        match self {
            AssignmentKind::Takeover => "takeover",
            AssignmentKind::Create => "create",
            AssignmentKind::Deliver => "deliver",
        }
    }
}

/// One assignment. It stays until the machine acks it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Assignment {
    pub kind: AssignmentKind,
    pub session: SessionView,
}

/// `GET /v1/auto-sessions/assignments`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Assignments {
    pub assignments: Vec<Assignment>,
}
