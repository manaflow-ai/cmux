//! Events: the activity log and the client stream are the same thing.
//!
//! Every event names what happened (`kind`, for automation triggers and the
//! activity view) and carries the changed entity in full (`change`), so a
//! client mirror applies events by upsert/remove without re-reading.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::actor::Actor;
use crate::ids::Principal;
use crate::model::{AgentSession, Comment, Label, Project, Relation, Status, Task, TeamSettings};
use crate::op::Origin;

// Events are built once per commit and serialized; the size spread
// between variants costs nothing measurable.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "entity", rename_all = "snake_case")]
pub enum Entity {
    Task(Box<Task>),
    Status(Status),
    Label(Label),
    Project(Project),
    Relation(Relation),
    Comment(Comment),
    Session(AgentSession),
    Settings(TeamSettings),
}

#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Change {
    Upsert { value: Entity },
    Remove { entity: String, id: String },
}

/// One event of a commit, before the service stamps sequence and actor.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventKind {
    /// `task.created`, `task.status_changed`, `task.agent_session.status_changed`, …
    pub kind: String,
    /// Kind-specific facts (for example `{from, to, from_category, to_category, by_agent_flow}`).
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub details: Value,
    pub change: Change,
}

impl EventKind {
    pub fn upsert(kind: &str, value: Entity, details: Value) -> Self {
        Self { kind: kind.to_owned(), details, change: Change::Upsert { value } }
    }

    pub fn remove(kind: &str, entity: &str, id: &str, details: Value) -> Self {
        Self {
            kind: kind.to_owned(),
            details,
            change: Change::Remove { entity: entity.to_owned(), id: id.to_owned() },
        }
    }
}

/// A committed event as clients and automations see it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    /// Commit sequence (per team, gapless).
    pub seq: u64,
    /// Position inside the commit.
    pub index: u32,
    /// The request's idempotency key (the transaction a client waits on).
    pub tx: String,
    pub at: i64,
    /// The accountable principal (who the reducer authorized).
    pub actor: Principal,
    /// The P8 actor stamp (which process acted), when the record has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stamp: Option<Actor>,
    pub origin: Origin,
    #[serde(flatten)]
    pub body: EventKind,
}

/// Event kinds offered as automation triggers (`{type: event, source: task, event}`).
pub const TRIGGER_EVENTS: &[&str] = &[
    "task.created",
    "task.status_changed",
    "task.assigned",
    "task.delegated",
    "task.labeled",
    "task.agent_session.status_changed",
    "task.comment.created",
];
