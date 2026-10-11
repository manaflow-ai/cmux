//! The pane's optimistic projection (plans/cmux-next/tasks.md, "Clients are
//! projections"): replay the pending intents on the confirmed mirror with
//! the owner's own reducer, so a client never re-derives owner rules (task
//! keys and numbers, default status, sort keys, delegate principals).

use crate::model::{Label, Project};
use crate::query::{self, TaskView};
use crate::{AgentSession, Ctx, Envelope, Op, Origin, Principal, State, Status, TeamSettings};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// The confirmed mirror, in the owner's snapshot shape (`snapshot_value`).
#[derive(Clone, Debug, Deserialize)]
pub struct Mirror {
    pub me: Principal,
    pub settings: TeamSettings,
    #[serde(default)]
    pub statuses: Vec<Status>,
    #[serde(default)]
    pub labels: Vec<Label>,
    #[serde(default)]
    pub projects: Vec<Project>,
    #[serde(default)]
    pub tasks: Vec<TaskView>,
    #[serde(default)]
    pub sessions: Vec<AgentSession>,
    #[serde(default)]
    pub seq: u64,
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
    let mut state = State {
        settings: mirror.settings.clone(),
        statuses: mirror.statuses.iter().map(|s| (s.id.clone(), s.clone())).collect(),
        labels: mirror.labels.iter().map(|l| (l.id.clone(), l.clone())).collect(),
        projects: mirror.projects.iter().map(|p| (p.id.clone(), p.clone())).collect(),
        tasks: mirror.tasks.iter().map(|t| (t.task.id.clone(), t.task.clone())).collect(),
        relations: BTreeMap::new(),
        comments: BTreeMap::new(),
        sessions: mirror.sessions.iter().map(|s| (s.id.clone(), s.clone())).collect(),
        seq: mirror.seq,
        ledger: BTreeMap::new(),
        ledger_order: VecDeque::new(),
    };
    let mut rejected = Vec::new();
    for intent in &request.intents {
        let op = serde_json::from_value::<Op>(serde_json::json!({
            "op": intent.op,
            "params": intent.params,
        }));
        let applied = op.ok().is_some_and(|op| {
            let envelope = Envelope {
                actor: mirror.me.clone(),
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
