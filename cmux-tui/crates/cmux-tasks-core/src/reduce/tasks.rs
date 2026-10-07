//! Task ops: create, update, move, archive, delete.

use std::collections::BTreeSet;

use serde_json::json;

use super::{OpResult, Reject, Tx, conflict, invalid, not_found};
use crate::event::{Entity, EventKind};
use crate::ids::{Principal, is_valid_id, prefix};
use crate::model::{Category, Description, Priority, Task};
use crate::op::{TaskCreate, TaskMove, TaskUpdate};
use crate::sort_key;

pub(crate) const MAX_TITLE: usize = 512;
pub(crate) const MAX_TEXT: usize = 256 * 1024;

pub(crate) fn validate_title(title: &str) -> Result<String, Reject> {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return Err(invalid("title must not be empty"));
    }
    if trimmed.chars().count() > MAX_TITLE {
        return Err(invalid(format!("title is longer than {MAX_TITLE} characters")));
    }
    Ok(trimmed.to_owned())
}

pub(crate) fn validate_text(text: &str, what: &str) -> Result<(), Reject> {
    if text.len() > MAX_TEXT {
        return Err(invalid(format!("{what} is larger than {MAX_TEXT} bytes")));
    }
    Ok(())
}

fn validate_due(due: &str) -> Result<(), Reject> {
    let bytes = due.as_bytes();
    let shape = bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes.iter().enumerate().all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit());
    let month = due.get(5..7).and_then(|m| m.parse::<u8>().ok()).unwrap_or(0);
    let day = due.get(8..10).and_then(|d| d.parse::<u8>().ok()).unwrap_or(0);
    if !shape || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return Err(invalid(format!("due must be YYYY-MM-DD: {due}")));
    }
    Ok(())
}

impl Tx<'_> {
    /// `me` -> the actor's person; `usr_…` -> that person.
    fn resolve_assignee(&self, reference: &str) -> Result<Principal, Reject> {
        if reference == "me" {
            return Ok(Principal::user(self.actor.human()));
        }
        if is_valid_id(reference, prefix::USER) {
            return Ok(Principal::user(reference));
        }
        if reference.starts_with(prefix::AGENT) {
            return Err(invalid("assign agents with task.delegate"));
        }
        Err(invalid(format!("assignee must be `me` or a usr_ id: {reference}")))
    }

    fn resolve_labels(&self, refs: &[String]) -> Result<BTreeSet<String>, Reject> {
        refs.iter()
            .map(|r| self.state.resolve_label(r).ok_or_else(|| not_found("label", r)))
            .collect()
    }

    /// Reject a parent that would create a cycle (`child` may be new).
    fn validate_parent(&self, child: &str, parent_ref: &str) -> Result<String, Reject> {
        let parent = self.task_id(parent_ref)?;
        let mut cursor = Some(parent.clone());
        let mut steps = 0usize;
        while let Some(id) = cursor {
            if id == child {
                return Err(invalid("parent would create a cycle"));
            }
            steps += 1;
            if steps > self.state.tasks.len() + 1 {
                return Err(invalid("parent chain is corrupt"));
            }
            cursor = self.state.tasks.get(&id).and_then(|t| t.parent.clone());
        }
        Ok(parent)
    }

    fn sort_key_taken(&self, key: &str, except: &str) -> bool {
        self.state.live_tasks().any(|t| t.sort_key == key && t.id != except)
    }

    pub(super) fn task_create(&mut self, p: &TaskCreate) -> Result<OpResult, Reject> {
        if !is_valid_id(&p.id, prefix::TASK) {
            return Err(invalid(format!("task id must be task_…: {}", p.id)));
        }
        if self.state.tasks.contains_key(&p.id) {
            return Err(conflict(format!("task id already used: {}", p.id)));
        }
        let title = validate_title(&p.title)?;
        if let Some(text) = &p.description {
            validate_text(text, "description")?;
        }
        let status = match &p.status {
            Some(r) => self.state.resolve_status(r).ok_or_else(|| not_found("status", r))?,
            None => self.state.settings.default_status.clone(),
        };
        let assignee = p.assignee.as_deref().map(|a| self.resolve_assignee(a)).transpose()?;
        let labels = self.resolve_labels(&p.labels)?;
        let project = match &p.project {
            Some(r) => Some(self.state.resolve_project(r).ok_or_else(|| not_found("project", r))?),
            None => None,
        };
        let parent = p.parent.as_deref().map(|r| self.validate_parent(&p.id, r)).transpose()?;
        if let Some(due) = &p.due {
            validate_due(due)?;
        }
        // A client key is used when valid and free; otherwise the task is
        // appended after the last one (rebalancing if the keys ran out).
        let sort_key = match &p.sort_key {
            Some(k) if sort_key::is_valid(k) && !self.sort_key_taken(k, &p.id) => k.clone(),
            _ => {
                let last = self.ordered_ids(&p.id).last().cloned();
                self.place(&p.id, last.as_deref(), None)
            }
        };
        let number = self.state.settings.next_number;
        let mut task = Task {
            id: p.id.clone(),
            number,
            title,
            description: Description {
                text: p.description.clone().unwrap_or_default(),
                version: 1,
            },
            status: status.clone(),
            priority: p.priority.unwrap_or(Priority::None),
            assignee,
            delegate: None,
            labels,
            project,
            parent,
            estimate: p.estimate,
            due: p.due.clone(),
            sort_key,
            attention: None,
            created_by: self.actor.clone(),
            created_at: self.now,
            updated_at: self.now,
            started_at: None,
            completed_at: None,
            canceled_at: None,
            manual_status_at: None,
            archived: false,
            deleted: false,
        };
        let category = self.state.statuses[&status].category;
        stamp_category(&mut task, category, self.now);
        self.state.settings.next_number += 1;
        self.state.tasks.insert(task.id.clone(), task.clone());
        let key = self.state.task_key(&task);
        self.events.push(EventKind::upsert(
            "task.created",
            Entity::Task(Box::new(task)),
            json!({"key": key, "category": category}),
        ));
        Ok(self.result_for_task(&p.id))
    }

    pub(super) fn task_update(&mut self, p: &TaskUpdate) -> Result<OpResult, Reject> {
        let id = self.task_id(&p.task)?;
        let current = self.state.tasks[&id].clone();
        if current.archived {
            return Err(invalid("archived tasks are read-only; unarchive first"));
        }
        let mut next = current.clone();
        let mut fields: Vec<&str> = Vec::new();
        if let Some(title) = &p.title {
            next.title = validate_title(title)?;
            fields.push("title");
        }
        if let Some(priority) = p.priority {
            next.priority = priority;
            fields.push("priority");
        }
        if p.unassign && p.assignee.is_some() {
            return Err(invalid("assignee and unassign are exclusive"));
        }
        if let Some(a) = &p.assignee {
            next.assignee = Some(self.resolve_assignee(a)?);
        } else if p.unassign {
            next.assignee = None;
        }
        if next.assignee != current.assignee {
            fields.push("assignee");
        }
        let added = self.resolve_labels(&p.add_labels)?;
        let removed = self.resolve_labels(&p.remove_labels)?;
        if added.intersection(&removed).next().is_some() {
            return Err(invalid("a label cannot be added and removed at once"));
        }
        next.labels.extend(added.iter().cloned());
        next.labels.retain(|l| !removed.contains(l));
        if next.labels != current.labels {
            fields.push("labels");
        }
        if p.clear_project && p.project.is_some() {
            return Err(invalid("project and clear_project are exclusive"));
        }
        if let Some(r) = &p.project {
            next.project =
                Some(self.state.resolve_project(r).ok_or_else(|| not_found("project", r))?);
        } else if p.clear_project {
            next.project = None;
        }
        if next.project != current.project {
            fields.push("project");
        }
        if p.clear_parent && p.parent.is_some() {
            return Err(invalid("parent and clear_parent are exclusive"));
        }
        if let Some(r) = &p.parent {
            next.parent = Some(self.validate_parent(&id, r)?);
        } else if p.clear_parent {
            next.parent = None;
        }
        if next.parent != current.parent {
            fields.push("parent");
        }
        if let Some(estimate) = p.estimate {
            next.estimate = Some(estimate);
            fields.push("estimate");
        }
        if let Some(due) = &p.due {
            validate_due(due)?;
            next.due = Some(due.clone());
            fields.push("due");
        }
        if let Some(text) = &p.description {
            validate_text(text, "description")?;
            let Some(version) = p.if_version else {
                return Err(invalid("description needs if_version"));
            };
            if version != current.description.version {
                return Err(conflict(format!(
                    "description changed: version {} is current, not {version}",
                    current.description.version
                )));
            }
            next.description = Description { text: text.clone(), version: version + 1 };
            fields.push("description");
        }
        let new_status = match &p.status {
            Some(r) => Some(self.state.resolve_status(r).ok_or_else(|| not_found("status", r))?),
            None => None,
        };
        // Validation is complete; mutate from here on.
        if !fields.is_empty() {
            next.updated_at = self.now;
            self.state.tasks.insert(id.clone(), next.clone());
            self.events.push(EventKind::upsert(
                "task.updated",
                Entity::Task(Box::new(next.clone())),
                json!({"fields": fields}),
            ));
            if fields.contains(&"assignee") {
                self.events.push(EventKind::upsert(
                    "task.assigned",
                    Entity::Task(Box::new(next.clone())),
                    json!({"assignee": next.assignee, "previous": current.assignee}),
                ));
            }
            if fields.contains(&"labels") {
                let added: Vec<_> = next.labels.difference(&current.labels).collect();
                let removed: Vec<_> = current.labels.difference(&next.labels).collect();
                self.events.push(EventKind::upsert(
                    "task.labeled",
                    Entity::Task(Box::new(next.clone())),
                    json!({"added": added, "removed": removed}),
                ));
            }
        }
        if let Some(status) = new_status {
            self.set_status(&id, &status, StatusMove::Manual);
        }
        Ok(self.result_for_task(&id))
    }

    /// Move a task to `status` and emit `task.status_changed`. Only a manual
    /// move that changes the status records `manual_status_at`, which stops
    /// the agent flow from overriding it.
    pub(crate) fn set_status(&mut self, id: &str, status: &str, mode: StatusMove) {
        let from_status = self.state.tasks[id].status.clone();
        if from_status == status {
            return;
        }
        let from = self.state.statuses[&from_status].category;
        let to = self.state.statuses[status].category;
        let now = self.now;
        let task = self.state.tasks.get_mut(id).expect("validated task");
        if mode == StatusMove::Manual {
            task.manual_status_at = Some(now);
        }
        task.status = status.to_owned();
        task.updated_at = now;
        stamp_category(task, to, now);
        let snapshot = task.clone();
        self.events.push(EventKind::upsert(
            "task.status_changed",
            Entity::Task(Box::new(snapshot)),
            json!({
                "from": from_status, "to": status,
                "from_category": from, "to_category": to,
                "by_agent_flow": mode == StatusMove::Flow,
                "cascade": mode == StatusMove::Cascade,
            }),
        ));
    }

    /// Live tasks in manual order, without `except`.
    fn ordered_ids(&self, except: &str) -> Vec<String> {
        let mut tasks: Vec<_> = self.state.live_tasks().filter(|t| t.id != except).collect();
        tasks.sort_by(|a, b| a.sort_key.cmp(&b.sort_key));
        tasks.into_iter().map(|t| t.id.clone()).collect()
    }

    /// A free key for `id` between the tasks `after` and `before` (ids, both
    /// already neighbours in manual order). When the gap is used up (the key
    /// would pass `sort_key::MAX_LEN`), every other live task gets a fresh
    /// evenly spaced key first, in the same commit (owner rebalance).
    pub(crate) fn place(&mut self, id: &str, after: Option<&str>, before: Option<&str>) -> String {
        let key_of = |tx: &Self, t: Option<&str>| t.map(|t| tx.state.tasks[t].sort_key.clone());
        let lower = key_of(self, after);
        let upper = key_of(self, before);
        if let Some(key) = sort_key::between(lower.as_deref(), upper.as_deref())
            && !self.sort_key_taken(&key, id)
        {
            return key;
        }
        self.rebalance(id);
        let lower = key_of(self, after);
        let upper = key_of(self, before);
        sort_key::between(lower.as_deref(), upper.as_deref()).expect("a rebalanced gap has room")
    }

    fn rebalance(&mut self, except: &str) {
        let order = self.ordered_ids(except);
        // Even keys with room between them: every second key of a sequence.
        let keys = sort_key::sequence(order.len() * 2);
        for (index, task_id) in order.iter().enumerate() {
            let key = keys[index * 2 + 1].clone();
            let task = self.state.tasks.get_mut(task_id).expect("live task");
            if task.sort_key != key {
                task.sort_key = key;
                let snapshot = task.clone();
                self.events.push(EventKind::upsert(
                    "task.moved",
                    Entity::Task(Box::new(snapshot)),
                    json!({"rebalance": true}),
                ));
            }
        }
    }

    pub(super) fn task_move(&mut self, p: &TaskMove) -> Result<OpResult, Reject> {
        let id = self.task_id(&p.task)?;
        let neighbour = |tx: &Self, r: &Option<String>| -> Result<Option<String>, Reject> {
            match r {
                Some(r) => {
                    let other = tx.task_id(r)?;
                    if other == id {
                        return Err(invalid("a task cannot be placed next to itself"));
                    }
                    Ok(Some(other))
                }
                None => Ok(None),
            }
        };
        let after = neighbour(self, &p.after)?;
        let before = neighbour(self, &p.before)?;
        let order = self.ordered_ids(&id);
        let position = |t: &str| order.iter().position(|o| o == t).expect("live task");
        // Complete the gap: one named neighbour implies the other.
        let (after, before) = match (after, before) {
            (Some(a), Some(b)) => {
                if position(&a) >= position(&b) {
                    return Err(invalid("after must sort before before"));
                }
                (Some(a), Some(b))
            }
            (Some(a), None) => {
                let next = order.get(position(&a) + 1).cloned();
                (Some(a), next)
            }
            (None, Some(b)) => {
                let previous = position(&b).checked_sub(1).map(|i| order[i].clone());
                (previous, Some(b))
            }
            (None, None) => (order.last().cloned(), None),
        };
        let key = self.place(&id, after.as_deref(), before.as_deref());
        let task = self.state.tasks.get_mut(&id).expect("validated task");
        task.sort_key = key;
        task.updated_at = self.now;
        let snapshot = task.clone();
        self.events.push(EventKind::upsert(
            "task.moved",
            Entity::Task(Box::new(snapshot)),
            serde_json::Value::Null,
        ));
        Ok(self.result_for_task(&id))
    }

    pub(super) fn task_set_archived(
        &mut self,
        reference: &str,
        archived: bool,
    ) -> Result<OpResult, Reject> {
        let id = self.task_id(reference)?;
        let task = self.state.tasks.get_mut(&id).expect("validated task");
        if task.archived != archived {
            task.archived = archived;
            task.updated_at = self.now;
            let snapshot = task.clone();
            let kind = if archived { "task.archived" } else { "task.unarchived" };
            self.events.push(EventKind::upsert(
                kind,
                Entity::Task(Box::new(snapshot)),
                serde_json::Value::Null,
            ));
        }
        Ok(self.result_for_task(&id))
    }

    /// Tombstone the task; remove its relations, clear its children's parent
    /// and cancel its active agent sessions in the same commit (destructive
    /// policy at the owner).
    pub(super) fn task_delete(&mut self, reference: &str) -> Result<OpResult, Reject> {
        let id = self.task_id(reference)?;
        let result = self.result_for_task(&id);
        let relations: Vec<String> = self
            .state
            .relations
            .values()
            .filter(|r| r.from == id || r.to == id)
            .map(|r| r.id.clone())
            .collect();
        for relation in relations {
            self.state.relations.remove(&relation);
            self.events.push(EventKind::remove(
                "task.relation.removed",
                "relation",
                &relation,
                json!({"cascade": true}),
            ));
        }
        let children: Vec<String> = self
            .state
            .tasks
            .values()
            .filter(|t| t.parent.as_deref() == Some(id.as_str()))
            .map(|t| t.id.clone())
            .collect();
        for child in children {
            let task = self.state.tasks.get_mut(&child).expect("child exists");
            task.parent = None;
            task.updated_at = self.now;
            let snapshot = task.clone();
            self.events.push(EventKind::upsert(
                "task.updated",
                Entity::Task(Box::new(snapshot)),
                json!({"fields": ["parent"], "cascade": true}),
            ));
        }
        let sessions: Vec<String> = self.state.active_sessions(&id).map(|s| s.id.clone()).collect();
        for session in sessions {
            self.end_session(&session, crate::model::SessionStatus::Canceled);
        }
        let task = self.state.tasks.get_mut(&id).expect("validated task");
        task.deleted = true;
        task.delegate = None;
        task.attention = None;
        task.updated_at = self.now;
        let snapshot = task.clone();
        self.events.push(EventKind::upsert(
            "task.deleted",
            Entity::Task(Box::new(snapshot)),
            serde_json::Value::Null,
        ));
        Ok(result)
    }
}

/// Why a status changes (only `Manual` blocks the agent flow).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StatusMove {
    Manual,
    Flow,
    Cascade,
}

/// Keep `started_at`, `completed_at` and `canceled_at` consistent with the category.
pub(crate) fn stamp_category(task: &mut Task, category: Category, now: i64) {
    if category.rank() >= Category::Started.rank() && task.started_at.is_none() {
        task.started_at = Some(now);
    }
    task.completed_at = (category == Category::Completed).then(|| task.completed_at.unwrap_or(now));
    task.canceled_at = (category == Category::Canceled).then(|| task.canceled_at.unwrap_or(now));
}
