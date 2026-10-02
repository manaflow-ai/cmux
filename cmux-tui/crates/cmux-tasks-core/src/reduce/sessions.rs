//! Agent sessions: delegate, claim, attach, update, cancel, and the agent
//! flow (task status follows agent activity; invariant 11).

use serde_json::json;

use super::{OpResult, Reject, Tx, conflict, forbidden, invalid, not_found};
use crate::event::{Entity, EventKind};
use crate::ids::{AgentClass, AgentRef, Principal, is_valid_id, prefix};
use crate::model::{AgentFlow, AgentSession, Attention, Category, SessionLinks, SessionStatus};
use crate::op::{SessionAttach, SessionClaim, SessionUpdate, TaskDelegate};

/// Allowed session status transitions.
fn transition_allowed(from: SessionStatus, to: SessionStatus) -> bool {
    use SessionStatus::*;
    match (from, to) {
        (a, b) if a == b => true,
        (Pending, Claimed | Working) => true,
        (Claimed, Working) => true,
        (Working, AwaitingInput) | (AwaitingInput, Working) => true,
        (Working | AwaitingInput, Done | Failed) => true,
        (Pending | Claimed | Working | AwaitingInput, Canceled) => true,
        _ => false,
    }
}

fn valid_target(target: &str) -> bool {
    target == "local"
        || target == "vm"
        || target.strip_prefix("host:").is_some_and(|h| !h.is_empty() && h.len() <= 128)
}

fn harness_slug(harness: &str) -> Option<String> {
    let slug: String = harness.trim().to_ascii_lowercase();
    (!slug.is_empty()
        && slug.len() <= 32
        && slug.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
    .then_some(slug)
}

impl Tx<'_> {
    fn session(&self, id: &str) -> Result<AgentSession, Reject> {
        self.state.sessions.get(id).cloned().ok_or_else(|| not_found("agent session", id))
    }

    /// The session's own agent, any mux (D20), or a person (dispatchers run
    /// as the person) may claim and attach.
    fn may_dispatch(&self, session: &AgentSession) -> bool {
        self.actor.is_user() || self.actor.is_mux() || self.actor.id() == session.agent.principal
    }

    /// Status and plan come only from the session's agent or a mux acting for it.
    fn may_report(&self, session: &AgentSession) -> bool {
        self.actor.is_mux() || self.actor.id() == session.agent.principal
    }

    pub(super) fn task_delegate(&mut self, p: &TaskDelegate) -> Result<OpResult, Reject> {
        let task_id = self.task_id(&p.task)?;
        if self.state.tasks[&task_id].archived {
            return Err(invalid("archived tasks cannot be delegated"));
        }
        if !is_valid_id(&p.session, prefix::SESSION) {
            return Err(invalid(format!("session id must be asess_…: {}", p.session)));
        }
        if self.state.sessions.contains_key(&p.session) {
            return Err(conflict(format!("session id already used: {}", p.session)));
        }
        let harness = harness_slug(&p.harness)
            .ok_or_else(|| invalid(format!("bad harness: {}", p.harness)))?;
        let person = self.actor.human().to_owned();
        let principal = match &p.agent {
            Some(agent) if is_valid_id(agent, prefix::AGENT) => agent.clone(),
            Some(agent) => return Err(invalid(format!("agent must be agt_…: {agent}"))),
            None => format!("agt_{harness}-{}", person.trim_start_matches(prefix::USER)),
        };
        if !is_valid_id(&principal, prefix::AGENT) {
            return Err(invalid(format!("derived agent id is invalid: {principal}")));
        }
        let target = p.target.clone().unwrap_or_else(|| "local".to_owned());
        if !valid_target(&target) {
            return Err(invalid(format!("target must be local, vm or host:<id>: {target}")));
        }
        if let Some(prompt) = &p.prompt {
            super::tasks::validate_text(prompt, "prompt")?;
        }
        if self.state.active_sessions(&task_id).any(|s| s.agent.principal == principal) {
            return Err(conflict(format!(
                "{principal} already has an active session on this task"
            )));
        }
        let agent = AgentRef {
            principal,
            class: p.class.unwrap_or(AgentClass::Ordinary),
            harness,
            on_behalf_of: person.clone(),
        };
        let session = AgentSession {
            id: p.session.clone(),
            task: task_id.clone(),
            agent: agent.clone(),
            status: SessionStatus::Pending,
            target,
            prompt: p.prompt.clone(),
            claimed_by: None,
            plan: Vec::new(),
            links: SessionLinks::default(),
            created_by: self.actor.clone(),
            created_at: self.now,
            started_at: None,
            ended_at: None,
        };
        self.state.sessions.insert(session.id.clone(), session.clone());
        let task = self.state.tasks.get_mut(&task_id).expect("validated task");
        task.delegate = Some(agent);
        if task.assignee.is_none() {
            task.assignee = Some(Principal::user(person));
        }
        task.updated_at = self.now;
        let snapshot = task.clone();
        self.events.push(EventKind::upsert(
            "task.delegated",
            Entity::Task(Box::new(snapshot)),
            json!({"session": session.id, "target": session.target, "harness": session.agent.harness}),
        ));
        self.events.push(EventKind::upsert(
            "task.agent_session.created",
            Entity::Session(session),
            serde_json::Value::Null,
        ));
        Ok(OpResult { id: p.session.clone(), key: self.result_for_task(&task_id).key })
    }

    pub(super) fn session_claim(&mut self, p: &SessionClaim) -> Result<OpResult, Reject> {
        let session = self.session(&p.session)?;
        if !self.may_dispatch(&session) {
            return Err(forbidden("only a person, a mux or the session's agent may claim it"));
        }
        if p.host.is_empty() || p.host.len() > 128 {
            return Err(invalid("host must be 1..=128 bytes"));
        }
        if session.status != SessionStatus::Pending {
            return Err(conflict(format!(
                "session already {}",
                session
                    .claimed_by
                    .as_deref()
                    .map_or("started".to_owned(), |h| format!("claimed by {h}"))
            )));
        }
        let s = self.state.sessions.get_mut(&p.session).expect("validated session");
        s.status = SessionStatus::Claimed;
        s.claimed_by = Some(p.host.clone());
        let snapshot = s.clone();
        self.push_session_status(snapshot, SessionStatus::Pending);
        Ok(self.session_result(&p.session))
    }

    pub(super) fn session_attach(&mut self, p: &SessionAttach) -> Result<OpResult, Reject> {
        let session = self.session(&p.session)?;
        if !self.may_dispatch(&session) {
            return Err(forbidden("only a person, a mux or the session's agent may attach it"));
        }
        if p.acp_session.is_empty() || p.acp_session.len() > 200 {
            return Err(invalid("acp_session must be 1..=200 bytes"));
        }
        if !matches!(session.status, SessionStatus::Pending | SessionStatus::Claimed) {
            return Err(conflict(format!(
                "session is {:?}; attach needs pending or claimed",
                session.status
            )));
        }
        if let (Some(claimed), Some(host)) = (&session.claimed_by, &p.host)
            && claimed != host
        {
            return Err(conflict(format!("session is claimed by {claimed}")));
        }
        let s = self.state.sessions.get_mut(&p.session).expect("validated session");
        s.links.acp_session = Some(p.acp_session.clone());
        if p.workspace.is_some() {
            s.links.workspace = p.workspace.clone();
        }
        s.links.host = p.host.clone().or_else(|| s.claimed_by.clone());
        s.status = SessionStatus::Working;
        s.started_at = Some(self.now);
        let snapshot = s.clone();
        self.push_session_status(snapshot, session.status);
        self.flow_after(&p.session, SessionStatus::Working);
        Ok(self.session_result(&p.session))
    }

    pub(super) fn session_update(&mut self, p: &SessionUpdate) -> Result<OpResult, Reject> {
        let session = self.session(&p.session)?;
        if !self.may_report(&session) {
            return Err(forbidden("only the session's agent or a mux may report its status"));
        }
        if session.status.is_terminal() {
            return Err(conflict("session has ended"));
        }
        if let Some(status) = p.status {
            if status == SessionStatus::Canceled {
                return Err(invalid("use task.session.cancel"));
            }
            if !transition_allowed(session.status, status) {
                return Err(invalid(format!(
                    "session cannot go from {:?} to {status:?}",
                    session.status
                )));
            }
        }
        if let Some(plan) = &p.plan
            && (plan.len() > 200
                || plan.iter().any(|s| s.content.is_empty() || s.content.len() > 2000))
        {
            return Err(invalid("plan: at most 200 steps of 1..=2000 bytes"));
        }
        if let Some(pr) = &p.pr
            && (pr.is_empty() || pr.len() > 500)
        {
            return Err(invalid("pr must be 1..=500 bytes"));
        }
        let s = self.state.sessions.get_mut(&p.session).expect("validated session");
        if let Some(plan) = &p.plan {
            s.plan = plan.clone();
        }
        if p.pr.is_some() {
            s.links.pr = p.pr.clone();
        }
        let new_status = p.status.unwrap_or(s.status);
        let from = s.status;
        s.status = new_status;
        if new_status == SessionStatus::Working && s.started_at.is_none() {
            s.started_at = Some(self.now);
        }
        if new_status.is_terminal() {
            s.ended_at = Some(self.now);
        }
        let snapshot = s.clone();
        if from != new_status {
            self.push_session_status(snapshot, from);
            self.flow_after(&p.session, new_status);
        } else {
            self.events.push(EventKind::upsert(
                "task.agent_session.updated",
                Entity::Session(snapshot),
                serde_json::Value::Null,
            ));
        }
        Ok(self.session_result(&p.session))
    }

    pub(super) fn session_cancel(&mut self, id: &str) -> Result<OpResult, Reject> {
        let session = self.session(id)?;
        if !(self.actor.is_user()
            || self.actor.is_mux()
            || self.actor.id() == session.agent.principal)
        {
            return Err(forbidden("only a person, a mux or the session's agent may cancel it"));
        }
        if session.status.is_terminal() {
            return Ok(self.session_result(id));
        }
        self.end_session(id, SessionStatus::Canceled);
        Ok(self.session_result(id))
    }

    /// End a non-terminal session (cancel paths) and apply the flow.
    pub(crate) fn end_session(&mut self, id: &str, status: SessionStatus) {
        let s = self.state.sessions.get_mut(id).expect("existing session");
        let from = s.status;
        s.status = status;
        s.ended_at = Some(self.now);
        let snapshot = s.clone();
        self.push_session_status(snapshot, from);
        self.flow_after(id, status);
    }

    fn push_session_status(&mut self, session: AgentSession, from: SessionStatus) {
        let to = session.status;
        let task = session.task.clone();
        self.events.push(EventKind::upsert(
            "task.agent_session.status_changed",
            Entity::Session(session),
            json!({"task": task, "from": from, "to": to}),
        ));
    }

    fn session_result(&self, id: &str) -> OpResult {
        let key = self.state.sessions.get(id).and_then(|s| self.result_for_task(&s.task).key);
        OpResult { id: id.to_owned(), key }
    }

    /// Status follows agent activity. Monotonic: never lowers the category
    /// rank, never overrides an explicit change made after the session began.
    fn flow_after(&mut self, session_id: &str, status: SessionStatus) {
        let session = self.state.sessions[session_id].clone();
        let Some(task) = self.state.tasks.get(&session.task).cloned() else { return };
        if task.deleted {
            return;
        }
        let attention = match status {
            SessionStatus::AwaitingInput => Some(Some(Attention::NeedsInput)),
            SessionStatus::Failed => Some(Some(Attention::Failed)),
            SessionStatus::Done => Some(Some(Attention::Review)),
            SessionStatus::Working => Some(None),
            SessionStatus::Canceled => {
                let others = self.state.active_sessions(&task.id).any(|s| s.id != session.id);
                let ours = matches!(task.attention, Some(Attention::NeedsInput));
                (!others && ours).then_some(None)
            }
            _ => None,
        };
        let drop_delegate =
            status == SessionStatus::Canceled && task.delegate.as_ref() == Some(&session.agent);
        let attention = match attention {
            None if drop_delegate => Some(task.attention),
            other => other,
        };
        if let Some(attention) = attention {
            let t = self.state.tasks.get_mut(&task.id).expect("task exists");
            if t.attention != attention || drop_delegate {
                t.attention = attention;
                t.updated_at = self.now;
                if drop_delegate {
                    t.delegate = None;
                }
                let snapshot = t.clone();
                self.events.push(EventKind::upsert(
                    "task.updated",
                    Entity::Task(Box::new(snapshot)),
                    json!({"fields": ["attention"], "by_agent_flow": true}),
                ));
            }
        }
        if self.state.settings.agent_flow == AgentFlow::Off {
            return;
        }
        if task.manual_status_at.is_some_and(|at| at > session.created_at) {
            return;
        }
        let target = match status {
            SessionStatus::Working => Some(self.state.settings.started_status.clone()),
            SessionStatus::Done => self.state.settings.review_status.clone(),
            _ => None,
        };
        let Some(target) = target.filter(|t| self.state.statuses.contains_key(t)) else { return };
        let Some(current) = self.state.category_of(&task) else { return };
        let to = self.state.statuses[&target].category;
        let forward = to.rank() > current.rank()
            || (status == SessionStatus::Done
                && to == Category::Started
                && current == Category::Started);
        if forward && to.rank() >= current.rank() && task.status != target {
            self.set_status(&task.id, &target, true);
        }
    }
}
