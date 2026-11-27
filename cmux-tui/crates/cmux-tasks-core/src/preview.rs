//! The pane's optimistic projection (plans/cmux-next/tasks.md, "Clients are
//! projections"): replay the pending intents on the confirmed mirror with
//! the owner's own reducer, so a client never re-derives owner rules (task
//! keys and numbers, default status, sort keys, delegate principals).

use crate::model::{Description, Label, Project, ProjectState, SessionLinks};
use crate::query::{self, TaskView};
use crate::{
    AgentClass, AgentFlow, AgentRef, AgentSession, Attention, Ctx, Envelope, Op, Origin, Principal,
    Priority, SessionStatus, State, Status, Task, TeamSettings,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// The confirmed mirror, in the owner's snapshot shape (`snapshot_value`),
/// as complete as the client keeps it. Tasks may be snapshot views or bare
/// event entities (view fields and the `entity` tag are ignored). A field
/// the client does not mirror takes the value a new entity would have, and
/// settings it does not mirror take a new team's defaults.
#[derive(Clone, Debug, Deserialize)]
pub struct Mirror {
    pub me: MirrorPrincipal,
    pub settings: MirrorSettings,
    #[serde(default)]
    pub statuses: Vec<Status>,
    #[serde(default)]
    pub labels: Vec<MirrorLabel>,
    #[serde(default)]
    pub projects: Vec<MirrorProject>,
    #[serde(default)]
    pub tasks: Vec<MirrorTask>,
    #[serde(default)]
    pub sessions: Vec<MirrorSession>,
    #[serde(default)]
    pub seq: u64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorSettings {
    #[serde(default)]
    pub team: String,
    pub key_prefix: String,
    pub next_number: Option<u64>,
    pub default_status: Option<String>,
    pub started_status: Option<String>,
    pub review_status: Option<String>,
    pub agent_flow: Option<AgentFlow>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorAgent {
    pub principal: String,
    pub class: Option<AgentClass>,
    #[serde(default)]
    pub harness: String,
    #[serde(default)]
    pub on_behalf_of: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MirrorPrincipal {
    User { id: String },
    Agent(MirrorAgent),
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorLabel {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub color: u8,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorProject {
    pub id: String,
    pub name: String,
    pub state: Option<ProjectState>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorSession {
    pub id: String,
    pub task: String,
    pub agent: MirrorAgent,
    pub status: SessionStatus,
    pub target: Option<String>,
    pub created_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MirrorTask {
    pub id: String,
    pub number: u64,
    pub title: String,
    pub status: String,
    #[serde(default)]
    pub priority: Priority,
    pub assignee: Option<MirrorPrincipal>,
    pub delegate: Option<MirrorAgent>,
    #[serde(default)]
    pub labels: BTreeSet<String>,
    pub project: Option<String>,
    pub parent: Option<String>,
    pub estimate: Option<u32>,
    pub due: Option<String>,
    pub sort_key: String,
    pub attention: Option<Attention>,
    pub description: Option<Description>,
    pub created_by: Option<MirrorPrincipal>,
    pub created_at: Option<i64>,
    pub updated_at: Option<i64>,
    pub started_at: Option<i64>,
    pub completed_at: Option<i64>,
    pub canceled_at: Option<i64>,
    pub manual_status_at: Option<i64>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub deleted: bool,
}

impl MirrorAgent {
    fn agent(&self) -> AgentRef {
        AgentRef {
            principal: self.principal.clone(),
            class: self.class.unwrap_or(AgentClass::Ordinary),
            harness: self.harness.clone(),
            on_behalf_of: self.on_behalf_of.clone(),
        }
    }
}

impl MirrorPrincipal {
    fn principal(&self) -> Principal {
        match self {
            Self::User { id } => Principal::user(id.clone()),
            Self::Agent(agent) => Principal::Agent(agent.agent()),
        }
    }
}

impl Mirror {
    fn state(&self) -> State {
        let me = self.me.principal();
        let defaults = State::new(&self.settings.team, &self.settings.key_prefix).settings;
        let after_last = self.tasks.iter().map(|t| t.number + 1).max().unwrap_or(1);
        let given = &self.settings;
        let settings = TeamSettings {
            team: given.team.clone(),
            key_prefix: given.key_prefix.clone(),
            next_number: given.next_number.unwrap_or(1).max(after_last),
            default_status: given.default_status.clone().unwrap_or(defaults.default_status),
            started_status: given.started_status.clone().unwrap_or(defaults.started_status),
            review_status: given.review_status.clone().or(defaults.review_status),
            agent_flow: given.agent_flow.unwrap_or(defaults.agent_flow),
        };
        let tasks = self.tasks.iter().map(|t| {
            let task = Task {
                id: t.id.clone(),
                number: t.number,
                title: t.title.clone(),
                description: t.description.clone().unwrap_or_default(),
                status: t.status.clone(),
                priority: t.priority,
                assignee: t.assignee.as_ref().map(MirrorPrincipal::principal),
                delegate: t.delegate.as_ref().map(MirrorAgent::agent),
                labels: t.labels.clone(),
                project: t.project.clone(),
                parent: t.parent.clone(),
                estimate: t.estimate,
                due: t.due.clone(),
                sort_key: t.sort_key.clone(),
                attention: t.attention,
                created_by: t
                    .created_by
                    .as_ref()
                    .map_or_else(|| me.clone(), MirrorPrincipal::principal),
                created_at: t.created_at.unwrap_or(0),
                updated_at: t.updated_at.unwrap_or(0),
                started_at: t.started_at,
                completed_at: t.completed_at,
                canceled_at: t.canceled_at,
                manual_status_at: t.manual_status_at,
                archived: t.archived,
                deleted: t.deleted,
            };
            (t.id.clone(), task)
        });
        let sessions = self.sessions.iter().map(|s| {
            let session = AgentSession {
                id: s.id.clone(),
                task: s.task.clone(),
                agent: s.agent.agent(),
                status: s.status,
                target: s.target.clone().unwrap_or_else(|| "local".to_owned()),
                prompt: None,
                claimed_by: None,
                plan: Vec::new(),
                links: SessionLinks::default(),
                created_by: me.clone(),
                created_at: s.created_at.unwrap_or(0),
                started_at: None,
                ended_at: None,
            };
            (s.id.clone(), session)
        });
        let labels = self.labels.iter().map(|l| {
            let label =
                Label { id: l.id.clone(), name: l.name.clone(), color: l.color, archived: false };
            (l.id.clone(), label)
        });
        let projects = self.projects.iter().map(|p| {
            let project = Project {
                id: p.id.clone(),
                name: p.name.clone(),
                state: p.state.unwrap_or(ProjectState::Active),
                lead: None,
                archived: false,
            };
            (p.id.clone(), project)
        });
        State {
            settings,
            statuses: self.statuses.iter().map(|s| (s.id.clone(), s.clone())).collect(),
            labels: labels.collect(),
            projects: projects.collect(),
            tasks: tasks.collect(),
            relations: BTreeMap::new(),
            comments: BTreeMap::new(),
            sessions: sessions.collect(),
            seq: self.seq,
            ledger: BTreeMap::new(),
            ledger_order: VecDeque::new(),
        }
    }
}

/// One pending intent: its idempotency key and its catalog op and params.
#[derive(Clone, Debug, Deserialize)]
pub struct Intent {
    pub key: String,
    pub op: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Request {
    pub mirror: Mirror,
    #[serde(default)]
    pub intents: Vec<Intent>,
    /// The client's clock, ms since the epoch.
    #[serde(default)]
    pub now: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Preview {
    /// Every mirrored task with the intents applied, in manual order.
    pub tasks: Vec<TaskView>,
    /// Keys of intents the owner would refuse on this mirror; they change
    /// nothing until their own reject or echo settles them.
    pub rejected: Vec<String>,
}

pub fn respond(request: &Request) -> Preview {
    let mirror = &request.mirror;
    let mut state = mirror.state();
    let actor = mirror.me.principal();
    let mut rejected = Vec::new();
    for intent in &request.intents {
        let op = serde_json::from_value::<Op>(serde_json::json!({
            "op": intent.op,
            "params": intent.params,
        }));
        let applied = op.ok().is_some_and(|op| {
            let envelope = Envelope {
                actor: actor.clone(),
                origin: Origin::User,
                key: intent.key.clone(),
                grants: BTreeSet::new(),
                op,
            };
            crate::reduce(&mut state, &envelope, Ctx { now: request.now }).is_ok()
        });
        if !applied {
            rejected.push(intent.key.clone());
        }
    }
    let mut tasks: Vec<TaskView> = state.tasks.values().map(|t| query::view(&state, t)).collect();
    tasks.sort_by(|a, b| (&a.task.sort_key, a.task.number).cmp(&(&b.task.sort_key, b.task.number)));
    Preview { tasks, rejected }
}
