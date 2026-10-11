//! Typed mutation ops. Params are flat so the catalog can derive CLI flags,
//! MCP input schemas and code-mode signatures from one list per op
//! (`catalog.rs`). Reads are not ops; they are pure queries (`query.rs`).

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::ids::{AgentClass, Principal};
use crate::model::{
    AgentFlow, Category, GhosttyColor, PlanStep, Priority, ProjectState, RelationKind,
    SessionStatus,
};

/// The channel a request came through (OWNERSHIP-PRINCIPLES origin rule).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    User,
    #[default]
    Cli,
    Mcp,
    Script,
    Remote,
    Automation,
}

/// One request to the owner. `actor` and `grants` are set by the service
/// from the authenticated connection, never by the client.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub actor: Principal,
    #[serde(default)]
    pub origin: Origin,
    /// Client-chosen idempotency key (required for every mutation).
    pub key: String,
    /// Extra rights of the actor (`task.delete`, `task.delegate` for
    /// ordinary agents), from the actor's grant.
    #[serde(default)]
    pub grants: BTreeSet<String>,
    pub op: Op,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", content = "params")]
pub enum Op {
    #[serde(rename = "task.create")]
    TaskCreate(TaskCreate),
    #[serde(rename = "task.update")]
    TaskUpdate(TaskUpdate),
    #[serde(rename = "task.move")]
    TaskMove(TaskMove),
    #[serde(rename = "task.archive")]
    TaskArchive(TaskRef),
    #[serde(rename = "task.unarchive")]
    TaskUnarchive(TaskRef),
    #[serde(rename = "task.delete")]
    TaskDelete(TaskRef),
    #[serde(rename = "task.delegate")]
    TaskDelegate(TaskDelegate),
    #[serde(rename = "task.session.claim")]
    SessionClaim(SessionClaim),
    #[serde(rename = "task.session.attach")]
    SessionAttach(SessionAttach),
    #[serde(rename = "task.session.update")]
    SessionUpdate(SessionUpdate),
    #[serde(rename = "task.session.cancel")]
    SessionCancel(SessionRef),
    #[serde(rename = "task.comment.add")]
    CommentAdd(CommentAdd),
    #[serde(rename = "task.comment.update")]
    CommentUpdate(CommentUpdate),
    #[serde(rename = "task.comment.delete")]
    CommentDelete(CommentRef),
    #[serde(rename = "task.relation.add")]
    RelationAdd(RelationAdd),
    #[serde(rename = "task.relation.remove")]
    RelationRemove(RelationRef),
    #[serde(rename = "task.label.create")]
    LabelCreate(LabelCreate),
    #[serde(rename = "task.label.update")]
    LabelUpdate(LabelUpdate),
    #[serde(rename = "task.label.delete")]
    LabelDelete(LabelRef),
    #[serde(rename = "task.status.create")]
    StatusCreate(StatusCreate),
    #[serde(rename = "task.status.update")]
    StatusUpdate(StatusUpdate),
    #[serde(rename = "task.status.delete")]
    StatusDelete(StatusDelete),
    #[serde(rename = "task.project.create")]
    ProjectCreate(ProjectCreate),
    #[serde(rename = "task.project.update")]
    ProjectUpdate(ProjectUpdate),
    #[serde(rename = "task.project.archive")]
    ProjectArchive(ProjectRef),
    #[serde(rename = "task.settings.update")]
    SettingsUpdate(SettingsUpdate),
}

impl Op {
    /// Catalog name, e.g. `task.create`.
    pub fn name(&self) -> &'static str {
        match self {
            Self::TaskCreate(_) => "task.create",
            Self::TaskUpdate(_) => "task.update",
            Self::TaskMove(_) => "task.move",
            Self::TaskArchive(_) => "task.archive",
            Self::TaskUnarchive(_) => "task.unarchive",
            Self::TaskDelete(_) => "task.delete",
            Self::TaskDelegate(_) => "task.delegate",
            Self::SessionClaim(_) => "task.session.claim",
            Self::SessionAttach(_) => "task.session.attach",
            Self::SessionUpdate(_) => "task.session.update",
            Self::SessionCancel(_) => "task.session.cancel",
            Self::CommentAdd(_) => "task.comment.add",
            Self::CommentUpdate(_) => "task.comment.update",
            Self::CommentDelete(_) => "task.comment.delete",
            Self::RelationAdd(_) => "task.relation.add",
            Self::RelationRemove(_) => "task.relation.remove",
            Self::LabelCreate(_) => "task.label.create",
            Self::LabelUpdate(_) => "task.label.update",
            Self::LabelDelete(_) => "task.label.delete",
            Self::StatusCreate(_) => "task.status.create",
            Self::StatusUpdate(_) => "task.status.update",
            Self::StatusDelete(_) => "task.status.delete",
            Self::ProjectCreate(_) => "task.project.create",
            Self::ProjectUpdate(_) => "task.project.update",
            Self::ProjectArchive(_) => "task.project.archive",
            Self::SettingsUpdate(_) => "task.settings.update",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskRef {
    pub task: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskCreate {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<Priority>,
    /// `me` or `usr_…`. Agents are assigned with `task.delegate`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_key: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskUpdate {
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<Priority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unassign: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub add_labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub remove_labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub clear_project: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub clear_parent: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Required with `description`: the version being replaced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub if_version: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskMove {
    pub task: String,
    /// The task that should precede it (none = first).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    /// The task that should follow it (none = last).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskDelegate {
    pub task: String,
    /// Client-chosen `asess_…` id.
    pub session: String,
    pub harness: String,
    /// Agent principal; default `agt_<harness>-<person>` for the actor's person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<AgentClass>,
    /// `local` (default), `vm` or `host:<id>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionRef {
    pub session: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionClaim {
    pub session: String,
    pub host: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionAttach {
    pub session: String,
    pub acp_session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionUpdate {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<SessionStatus>,
    /// Replaces the whole plan.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Vec<PlanStep>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommentAdd {
    pub id: String,
    pub task: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommentUpdate {
    pub comment: String,
    pub body: String,
    pub if_version: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommentRef {
    pub comment: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelationAdd {
    pub id: String,
    pub kind: RelationKind,
    pub from: String,
    pub to: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelationRef {
    pub relation: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LabelCreate {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<GhosttyColor>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LabelUpdate {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<GhosttyColor>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LabelRef {
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusCreate {
    pub id: String,
    pub name: String,
    pub category: Category,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<GhosttyColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusUpdate {
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<GhosttyColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusDelete {
    pub status: String,
    /// Tasks in the deleted status move here in the same commit.
    pub replacement: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectCreate {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<ProjectState>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectUpdate {
    pub project: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<ProjectState>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectRef {
    pub project: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SettingsUpdate {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_prefix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_status: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub clear_review_status: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_flow: Option<AgentFlow>,
}
